; =============================================================================
;  privilege.asm  —  AsmTaskMgr
;  Privilege escalation: SeDebugPrivilege + UAC elevation check/relaunch.
;  Assembled as: nasm -f win64 privilege.asm -o privilege.obj
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
;  Win32 / NT imports
; ---------------------------------------------------------------------------
extern GetCurrentProcess
extern OpenProcessToken
extern LookupPrivilegeValueA
extern AdjustTokenPrivileges
extern CloseHandle
extern GetLastError
extern IsUserAnAdmin
extern GetModuleFileNameA
extern ShellExecuteA

; ---------------------------------------------------------------------------
;  Globals from strings.asm
; ---------------------------------------------------------------------------
extern szSeDebugPriv      ; "SeDebugPrivilege"
extern szRunAs            ; "runas"
extern hInstance

; ---------------------------------------------------------------------------
;  Exports
; ---------------------------------------------------------------------------
global AcquireDebugPrivilege
global CheckElevation

; ---------------------------------------------------------------------------
;  TOKEN_PRIVILEGES structure for one privilege:
;    DWORD PrivilegeCount                    offset  0   (4 bytes)
;    DWORD pad                               offset  4   (alignment)
;    LUID  Luid (LowPart DWORD, HighPart LONG) offset 8  (8 bytes)
;    DWORD Attributes                        offset 16   (4 bytes)
;    DWORD pad2                              offset 20
;  Total used: ~24 bytes  → allocate 32 bytes on stack
;
;  TOKEN_ELEVATION structure:
;    DWORD TokenIsElevated                   offset  0   (4 bytes)
;
;  LUID_AND_ATTRIBUTES:
;    LUID  Luid (8 bytes)
;    DWORD Attributes (4 bytes)
; ---------------------------------------------------------------------------

section .data
szExePath:      times 520 db 0   ; buffer for this exe's path

section .text

; ===========================================================================
;  AcquireDebugPrivilege
;  Enables SeDebugPrivilege in the current process token.
;  Returns: EAX = 1 on success, 0 on failure.
;  Preserves: RBX, RBP, RSI, RDI, R12-R15
; ===========================================================================
AcquireDebugPrivilege:
    push    rbx
    push    rsi
    push    rdi
    sub     rsp, 88          ; 32 shadow + 48 locals + 8 align

    ; --- Allocate TOKEN_PRIVILEGES on stack (24 bytes) ---
    ; We'll use [rsp+32] for TOKEN_PRIVILEGES

    ; --- 1. Get current process handle ---
    call    GetCurrentProcess
    mov     rbx, rax         ; rbx = pseudo-handle (-1 / 0xFFFFFFFFFFFFFFFF)

    ; --- 2. OpenProcessToken(CurrentProcess, TOKEN_QUERY|TOKEN_ADJUST, &hToken) ---
    lea     rdi, [rsp+64]    ; rdi = &hToken (on stack above shadow)
    mov     rcx, rbx                    ; hProcess
    mov     edx, 0x0028                 ; TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES
    mov     r8,  rdi                    ; &hToken
    call    OpenProcessToken
    test    eax, eax
    jz      .fail

    mov     rsi, [rsp+64]    ; rsi = hToken

    ; --- 3. LookupPrivilegeValueA(NULL, "SeDebugPrivilege", &luid) ---
    ;     luid lives at [rsp+32+8] = [rsp+40] (inside TOKEN_PRIVILEGES.Luid)
    xor     ecx, ecx                    ; lpSystemName = NULL
    lea     rdx, [rel szSeDebugPriv]    ; lpName
    lea     r8,  [rsp+40]               ; lpLuid  (TOKEN_PRIVILEGES.Luid)
    call    LookupPrivilegeValueA
    test    eax, eax
    jz      .close_token_fail

    ; --- 4. Fill TOKEN_PRIVILEGES struct ---
    mov     dword [rsp+32],  1          ; PrivilegeCount = 1
    ; Luid already written by LookupPrivilegeValueA at [rsp+40..47]
    mov     dword [rsp+48],  0x00000002 ; Attributes = SE_PRIVILEGE_ENABLED

    ; --- 5. AdjustTokenPrivileges(hToken, FALSE, &tp, sizeof, NULL, NULL) ---
    mov     rcx, rsi                    ; hToken
    xor     edx, edx                    ; DisableAllPrivileges = FALSE
    lea     r8,  [rsp+32]               ; pNewState (TOKEN_PRIVILEGES)
    mov     r9d, 24                     ; BufferLength
    mov     qword [rsp+32+32], 0        ; PreviousState = NULL (5th arg on stack above shadow)
    mov     qword [rsp+32+40], 0        ; ReturnLength = NULL (6th arg)
    call    AdjustTokenPrivileges
    test    eax, eax
    jz      .close_token_fail

    ; Check GetLastError == ERROR_NOT_ALL_ASSIGNED (doesn't mean API failed but priv unavail)
    call    GetLastError
    test    eax, eax
    jnz     .close_token_fail           ; non-zero → partial / not all assigned

    ; --- 6. Close token ---
    mov     rcx, rsi
    call    CloseHandle

    mov     eax, 1                      ; success
    jmp     .done

.close_token_fail:
    mov     rcx, rsi
    call    CloseHandle
.fail:
    xor     eax, eax                    ; failure
.done:
    add     rsp, 88
    pop     rdi
    pop     rsi
    pop     rbx
    ret


; ===========================================================================
;  CheckElevation
;  Checks if the process is running elevated (admin token).
;  If NOT elevated: re-launches self with "runas" verb and exits.
;  Returns: only returns if already elevated (EAX = 1).
; ===========================================================================
CheckElevation:
    push    rbx
    push    rsi
    sub     rsp, 72          ; 32 shadow + 32 locals + 8 align

    ; --- IsUserAnAdmin() quick check ---
    call    IsUserAnAdmin
    test    eax, eax
    jnz     .already_elevated    ; non-zero = admin

    ; -----------------------------------------------------------------------
    ; Not elevated. Get our own exe path and re-launch with "runas" verb.
    ; -----------------------------------------------------------------------
    lea     rcx, [rel szExePath]         ; buffer
    mov     edx, 512                     ; size
    xor     r8d, r8d                     ; hModule = NULL (this exe)
    call    GetModuleFileNameA

    ; ShellExecuteA(NULL, "runas", exePath, NULL, NULL, SW_SHOWNORMAL)
    xor     ecx, ecx                     ; hwnd = NULL
    lea     rdx, [rel szRunAs]           ; lpOperation
    lea     r8,  [rel szExePath]         ; lpFile
    xor     r9d, r9d                     ; lpParameters = NULL
    ; 5th arg (lpDirectory) = NULL   → [rsp+32]
    ; 6th arg (nShowCmd)    = 1      → [rsp+40]
    mov     qword [rsp+32], 0
    mov     dword [rsp+40], 1            ; SW_SHOWNORMAL
    call    ShellExecuteA

    ; Exit this (non-elevated) instance immediately
    ; We call ExitProcess(0) — use kernel32 imported in main.asm
    ; Since privilege.asm doesn't import ExitProcess, we just RET with a
    ; special value (0xDEAD) so main.asm can call ExitProcess.
    mov     eax, 0xDEAD                  ; signal to main: please exit
    jmp     .done

.already_elevated:
    mov     eax, 1                       ; already elevated

.done:
    add     rsp, 72
    pop     rsi
    pop     rbx
    ret
