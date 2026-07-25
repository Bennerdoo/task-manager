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
    ; 3 pushes + 8 ret = 32 total. RSP after pushes = caller_rsp - 32 (ALIGNED).
    ; sub N must be divisible by 16.
    ; Layout: shadow(32) + arg5/6 spill(16) + TOKEN_PRIVILEGES(24) + hToken(8) = 80. 80/16=5 ✓
    sub     rsp, 80

    ; Stack:
    ;   [rsp+  0..31] shadow space
    ;   [rsp+ 32..39] 5th arg slot for calls with 5+ args
    ;   [rsp+ 40..47] 6th arg slot
    ;   [rsp+ 48..51] TOKEN_PRIVILEGES.PrivilegeCount (DWORD)
    ;   [rsp+ 52..55] (4 bytes padding for LUID 8-byte alignment)
    ;   [rsp+ 56..63] TOKEN_PRIVILEGES.Luid (QWORD)
    ;   [rsp+ 64..67] TOKEN_PRIVILEGES.Attributes (DWORD)
    ;   [rsp+ 68..71] (padding)
    ;   [rsp+ 72..79] hToken (QWORD)

    ; --- 1. Get current process handle ---
    call    GetCurrentProcess
    mov     rbx, rax         ; rbx = pseudo-handle

    ; --- 2. OpenProcessToken(CurrentProcess, TOKEN_QUERY|TOKEN_ADJUST, &hToken) ---
    mov     rcx, rbx                    ; hProcess
    mov     edx, 0x0028                 ; TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES
    lea     r8,  [rsp+72]               ; &hToken  ← stored at [rsp+72]
    call    OpenProcessToken
    test    eax, eax
    jz      .fail

    mov     rsi, [rsp+72]               ; rsi = hToken

    ; --- 3. LookupPrivilegeValueA(NULL, "SeDebugPrivilege", &luid) ---
    ;     LUID lives inside TOKEN_PRIVILEGES at [rsp+56] (offset 8 from struct base [rsp+48])
    xor     ecx, ecx                    ; lpSystemName = NULL
    lea     rdx, [rel szSeDebugPriv]    ; lpName
    lea     r8,  [rsp+56]               ; lpLuid (TOKEN_PRIVILEGES.Luid)
    call    LookupPrivilegeValueA
    test    eax, eax
    jz      .close_token_fail

    ; --- 4. Fill TOKEN_PRIVILEGES struct at [rsp+48] ---
    mov     dword [rsp+48], 1           ; PrivilegeCount = 1
    ; Luid already filled by LookupPrivilegeValueA into [rsp+56..63]
    mov     dword [rsp+64], 0x00000002  ; Attributes = SE_PRIVILEGE_ENABLED

    ; --- 5. AdjustTokenPrivileges(hToken, FALSE, &tp, sizeof, NULL, NULL) ---
    ;   Args 5/6 go to [rsp+32]/[rsp+40] — SAFE: TOKEN_PRIVILEGES is at [rsp+48]
    mov     rcx, rsi                    ; hToken
    xor     edx, edx                    ; DisableAllPrivileges = FALSE
    lea     r8,  [rsp+48]               ; pNewState (TOKEN_PRIVILEGES)
    mov     r9d, 24                     ; BufferLength (sizeof TOKEN_PRIVILEGES w/ 1 entry)
    mov     qword [rsp+32], 0           ; arg5: PreviousState = NULL
    mov     qword [rsp+40], 0           ; arg6: ReturnLength = NULL
    call    AdjustTokenPrivileges
    test    eax, eax
    jz      .close_token_fail

    ; Check GetLastError for ERROR_NOT_ALL_ASSIGNED
    call    GetLastError
    test    eax, eax
    jnz     .close_token_fail

    ; --- 6. Close token ---
    mov     rcx, rsi
    call    CloseHandle

    mov     eax, 1                      ; success
    jmp     .done

.close_token_fail:
    mov     rcx, rsi
    call    CloseHandle
.fail:
    xor     eax, eax
.done:
    add     rsp, 80
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
