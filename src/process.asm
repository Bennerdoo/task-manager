; =============================================================================
;  process.asm  —  AsmTaskMgr
;  Process enumeration via Toolhelp32.
;  Fills the global procTable with PROC_ENTRY records.
;  Assembled as: nasm -f win64 process.asm -o process.obj
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
;  Win32 / NT imports
; ---------------------------------------------------------------------------
extern CreateToolhelp32Snapshot
extern Process32First
extern Process32Next
extern CloseHandle
extern OpenProcess
extern GetProcessMemoryInfo     ; from psapi.dll
extern GetProcessTimes
extern OpenProcessToken
extern GetTokenInformation
extern LookupAccountSidA
extern GetProcessHeap
extern HeapAlloc
extern HeapReAlloc
extern HeapFree
extern GetCurrentProcess

; ---------------------------------------------------------------------------
;  Globals from strings.asm (.bss and .data)
; ---------------------------------------------------------------------------
extern procTable          ; QWORD: pointer to PROC_ENTRY array
extern procCount          ; DWORD: number of entries
extern procCapacity       ; DWORD: allocated slots

; ---------------------------------------------------------------------------
;  Exports
; ---------------------------------------------------------------------------
global EnumProcesses

; ---------------------------------------------------------------------------
;  Constants
; ---------------------------------------------------------------------------
%define TH32CS_SNAPPROCESS    0x00000002
%define PROCESS_QUERY_INFO    0x00000400
%define PROCESS_VM_READ       0x00000010
%define PROCESS_QUERYINFO_VM  0x00000410   ; PROCESS_QUERY_INFORMATION | VM_READ
%define TOKEN_QUERY           0x00000008
%define TokenUser             1
%define HEAP_ZERO_MEMORY      0x00000008
%define PROC_ENTRY_SIZE       368

; PROCESSENTRY32A offsets (Win64)
%define PE32_dwSize           0
%define PE32_cntUsage         4
%define PE32_th32ProcessID    8
;   (4 bytes padding at 12)
%define PE32_th32DefaultHeapID 16
%define PE32_th32ModuleID     24
%define PE32_cntThreads       28
%define PE32_th32ParentPID    32
%define PE32_pcPriClassBase   36
%define PE32_dwFlags          40
%define PE32_szExeFile        44          ; CHAR[260]
%define PE32_SIZEOF           304

; PROCESS_MEMORY_COUNTERS offsets (Win64)
%define PMC_cb                0
%define PMC_PageFaultCount    4
%define PMC_PeakWorkingSet    8
%define PMC_WorkingSetSize    16          ; SIZE_T (8 bytes)
%define PMC_SIZEOF            72

; PROC_ENTRY offsets (from strings.asm constants)
%define PE_PID       0
%define PE_SESSID    4
%define PE_MEMKB     8
%define PE_FLAGS     12
%define PE_CPUTIME   16
%define PE_CPUPCT    24
%define PE_PAD       28
%define PE_NAME      32
%define PE_USER      292

; ---------------------------------------------------------------------------
;  Module-private BSS
; ---------------------------------------------------------------------------
section .bss
prevProcTable:  resq 1   ; pointer to previous cycle's proc table
prevProcCount:  resd 1   ; count of entries in prevProcTable
hHeap:          resq 1   ; process heap handle (cached)

; ---------------------------------------------------------------------------
;  Module-private DATA
; ---------------------------------------------------------------------------
section .data
szUnknownUser:  db 'SYSTEM', 0
szNA:           db 'N/A', 0
INITIAL_CAP     equ 256

; ===========================================================================
;  SECTION .text
; ===========================================================================
section .text

; ---------------------------------------------------------------------------
;  Internal: EnsureHeap — caches GetProcessHeap()
;  Out: RAX = heap handle
; ---------------------------------------------------------------------------
EnsureHeap:
    mov rax, [rel hHeap]
    test rax, rax
    jnz .done
    sub rsp, 40
    call GetProcessHeap
    add rsp, 40
    mov [rel hHeap], rax
.done:
    ret

; ---------------------------------------------------------------------------
;  Internal: FindPrevEntry(pid) — search prevProcTable for matching PID
;  In:  ECX = pid
;  Out: RAX = pointer to PROC_ENTRY or 0 if not found
; ---------------------------------------------------------------------------
FindPrevEntry:
    push    rbx
    push    rsi

    mov     ebx, ecx                     ; ebx = pid
    xor     ecx, ecx                     ; ecx = index
    mov     esi, [rel prevProcCount]     ; esi = count
    mov     rax, [rel prevProcTable]     ; rax = table ptr
    test    rax, rax
    jz      .notfound
    test    esi, esi
    jz      .notfound

.loop:
    cmp     ecx, esi
    jge     .notfound
    ; Compare PID at rax+PE_PID
    cmp     dword [rax + PE_PID], ebx
    je      .found
    add     rax, PROC_ENTRY_SIZE
    inc     ecx
    jmp     .loop

.found:
    jmp     .done
.notfound:
    xor     eax, eax
.done:
    pop     rsi
    pop     rbx
    ret

; ===========================================================================
;  EnumProcesses
;  Re-enumerates all running processes and rebuilds procTable.
;  Returns: EAX = number of processes found (0 on error).
; ===========================================================================
EnumProcesses:
    push    rbp
    push    rbx
    push    rsi
    push    rdi
    push    r15
    ; 5 pushes × 8 = 40 bytes + 8 (ret addr) = 48 total shift from caller-aligned rsp
    ; Need sub N where (N + 48) ≡ 0 (mod 16)  →  N ≡ 0 (mod 16). Use 512.
    sub     rsp, 512

    ; Stack layout (offsets from current rsp):
    ;   [rsp+  0] shadow space (32 bytes)
    ;   [rsp+ 32] arg-spill for 5th/6th args (16 bytes)
    ;   [rsp+ 48] PROCESSENTRY32A (304 bytes)  → [rsp+351]
    ;   [rsp+352] PROCESS_MEMORY_COUNTERS (72 bytes) → [rsp+423]
    ;   [rsp+424] FILETIME×4 (32 bytes) → [rsp+455]
    ;   [rsp+456] TOKEN_USER+SID buffer (56 bytes)
    ;   [rsp+480..511] locals: hSnap, hToken, hProc, needed

    ; Defined offsets:
    %define PE32_FRAME   rsp+48
    %define PMC_FRAME    rsp+352
    %define FT_FRAME     rsp+424        ; 4 FILETIMEs: creation[0], exit[8], kernel[16], user[24]
    %define SID_FRAME    rsp+456
    %define LOC_HSNAP    rsp+480        ; QWORD snapshot handle
    %define LOC_HTOKEN   rsp+488        ; QWORD token handle
    %define LOC_HPROC    rsp+496        ; QWORD process handle
    %define LOC_NEEDED   rsp+504        ; DWORD needed bytes for GetTokenInformation

    ; -----------------------------------------------------------------------
    ; 0. Ensure process heap is cached
    ; -----------------------------------------------------------------------
    call    EnsureHeap
    mov     rbp, rax                      ; rbp = heap handle

    ; -----------------------------------------------------------------------
    ; 1. Free the old prevProcTable (from last-last cycle)
    ; -----------------------------------------------------------------------
    mov     rax, [rel prevProcTable]
    test    rax, rax
    jz      .no_free_prev
    mov     rcx, rbp
    xor     edx, edx
    mov     r8, rax
    call    HeapFree
.no_free_prev:

    ; -----------------------------------------------------------------------
    ; 2. Move current procTable → prevProcTable
    ; -----------------------------------------------------------------------
    mov     rax, [rel procTable]
    mov     [rel prevProcTable], rax
    mov     eax, [rel procCount]
    mov     [rel prevProcCount], eax

    ; -----------------------------------------------------------------------
    ; 3. Allocate new procTable (INITIAL_CAP slots or double if procCount > INITIAL_CAP)
    ; -----------------------------------------------------------------------
    mov     edx, INITIAL_CAP
    cmp     dword [rel procCount], INITIAL_CAP
    jle     .use_init_cap
    mov     edx, [rel procCount]
    shl     edx, 1                        ; double
.use_init_cap:
    mov     [rel procCapacity], edx

    imul    rdx, PROC_ENTRY_SIZE
    mov     rcx, rbp
    mov     r8, rdx
    mov     edx, HEAP_ZERO_MEMORY
    call    HeapAlloc
    test    rax, rax
    jz      .fail_no_table
    mov     [rel procTable], rax
    mov     r15, rax                       ; r15 = new table write ptr

    ; -----------------------------------------------------------------------
    ; 4. Create Toolhelp32 snapshot
    ; -----------------------------------------------------------------------
    mov     ecx, TH32CS_SNAPPROCESS
    xor     edx, edx
    call    CreateToolhelp32Snapshot
    cmp     rax, -1                        ; INVALID_HANDLE_VALUE
    je      .fail_no_snap
    mov     [LOC_HSNAP], rax
    mov     rdi, rax                       ; rdi = hSnapshot

    ; -----------------------------------------------------------------------
    ; 5. Init PROCESSENTRY32A: dwSize = 304
    ; -----------------------------------------------------------------------
    mov     dword [PE32_FRAME + PE32_dwSize], PE32_SIZEOF
    xor     eax, eax
    mov     dword [rel procCount], 0

    ; -----------------------------------------------------------------------
    ; 6. Process32FirstA
    ; -----------------------------------------------------------------------
    mov     rcx, rdi
    lea     rdx, [PE32_FRAME]
    call    Process32First
    test    eax, eax
    jz      .done_enum                     ; empty system?

    ; -----------------------------------------------------------------------
    ; 7. Main enumeration loop
    ; -----------------------------------------------------------------------
.proc_loop:
    ; Check capacity
    mov     eax, [rel procCount]
    cmp     eax, [rel procCapacity]
    jl      .have_cap

    ; Grow table: double capacity
    mov     edx, [rel procCapacity]
    shl     edx, 1
    mov     [rel procCapacity], edx
    imul    rdx, PROC_ENTRY_SIZE
    mov     rcx, rbp
    mov     r8, rdx
    mov     r9, [rel procTable]
    ; HeapReAlloc(heap, 0, ptr, newSize)
    mov     dword [rsp+32], 0            ; flags
    call    HeapReAlloc
    test    rax, rax
    jz      .done_enum
    mov     [rel procTable], rax
    ; Recalculate r15 write ptr
    mov     rbx, [rel procCount]
    imul    rbx, PROC_ENTRY_SIZE
    lea     r15, [rax + rbx]

.have_cap:
    ; Zero out this entry
    mov     rbx, r15
    xor     eax, eax
    mov     ecx, PROC_ENTRY_SIZE / 8
    .zero_loop:
        mov     [rbx], rax
        add     rbx, 8
        dec     ecx
        jnz     .zero_loop

    ; --- Copy PID ---
    mov     eax, dword [PE32_FRAME + PE32_th32ProcessID]
    mov     dword [r15 + PE_PID], eax
    mov     esi, eax                      ; esi = pid (for OpenProcess calls)

    ; --- Copy exe name (up to 260 bytes) ---
    lea     rsi, [PE32_FRAME + PE32_szExeFile]
    lea     rdi, [r15 + PE_NAME]
    mov     ecx, 260
    .copy_name:
        mov     al, [rsi]
        mov     [rdi], al
        test    al, al
        jz      .copy_name_done
        inc     rsi
        inc     rdi
        dec     ecx
        jnz     .copy_name
    .copy_name_done:

    ; Restore esi = pid
    mov     esi, dword [r15 + PE_PID]

    ; -----------------------------------------------------------------------
    ; 8. OpenProcess for memory and time queries
    ; -----------------------------------------------------------------------
    mov     ecx, PROCESS_QUERYINFO_VM
    xor     edx, edx                        ; FALSE
    mov     r8d, esi                         ; pid
    call    OpenProcess
    test    rax, rax
    jz      .skip_stats
    mov     [LOC_HPROC], rax
    mov     rbx, rax                         ; rbx = hProc

    ; --- GetProcessMemoryInfo ---
    mov     dword [PMC_FRAME + PMC_cb], PMC_SIZEOF
    mov     rcx, rbx
    lea     rdx, [PMC_FRAME]
    mov     r8d, PMC_SIZEOF
    call    GetProcessMemoryInfo
    test    eax, eax
    jz      .skip_mem
    ; WorkingSetSize in bytes → KB
    mov     rax, [PMC_FRAME + PMC_WorkingSetSize]
    shr     rax, 10
    mov     dword [r15 + PE_MEMKB], eax
.skip_mem:

    ; --- GetProcessTimes ---
    ; Args: hProc, lpCreationTime, lpExitTime, lpKernelTime, lpUserTime (5th arg on stack)
    mov     rcx, rbx
    lea     rdx, [FT_FRAME]         ; lpCreationTime
    lea     r8,  [FT_FRAME + 8]     ; lpExitTime
    lea     r9,  [FT_FRAME + 16]    ; lpKernelTime
    lea     rax, [FT_FRAME + 24]    ; lpUserTime (5th arg)
    mov     [rsp + 32], rax
    call    GetProcessTimes
    test    eax, eax
    jz      .skip_times
    ; Sum kernel + user FILETIME → store in PE_CPUTIME
    mov     rax, [FT_FRAME + 16]    ; kernelTime (QWORD)
    add     rax, [FT_FRAME + 24]    ; + userTime
    mov     [r15 + PE_CPUTIME], rax

    ; --- Compute CPU% delta vs prev cycle ---
    mov     ecx, dword [r15 + PE_PID]
    call    FindPrevEntry
    test    rax, rax
    jz      .skip_cpudelta
    mov     rcx, [r15 + PE_CPUTIME]
    sub     rcx, [rax + PE_CPUTIME]   ; delta CPU time (100ns units)
    ; Simple: just store delta / 10000 as a rough "units" → real % computed in window.asm
    mov     qword [r15 + PE_CPUPCT], rcx
.skip_cpudelta:
.skip_times:

    ; --- Get username ---
    mov     rcx, rbx                   ; hProc
    mov     edx, TOKEN_QUERY
    lea     r8,  [LOC_HTOKEN]
    call    OpenProcessToken
    test    eax, eax
    jz      .use_default_user

    mov     r14, [LOC_HTOKEN]

    ; GetTokenInformation(hToken, TokenUser=1, buffer, 512, &needed)
    mov     rcx, r14
    mov     edx, TokenUser
    lea     r8,  [SID_FRAME]
    mov     r9d, 56
    lea     rax, [LOC_NEEDED]
    mov     [rsp+32], rax
    call    GetTokenInformation
    test    eax, eax
    jz      .close_token_skip_user

    ; LookupAccountSidA(NULL, Sid, name, &nameLen, domain, &domainLen, &use)
    ; Sid is the first QWORD of SID_FRAME (SID_AND_ATTRIBUTES.Sid)
    mov     rax, [SID_FRAME]           ; Sid pointer
    xor     ecx, ecx                   ; lpSystemName = NULL
    mov     rdx, rax                   ; Sid
    lea     r8,  [r15 + PE_USER]       ; lpName
    mov     dword [LOC_NEEDED], 64     ; cchName
    lea     r9,  [LOC_NEEDED]          ; pcchName
    ; 5th arg = domain buffer (we don't care, use SID_FRAME as scratch)
    lea     rax, [SID_FRAME + 8]
    mov     [rsp+32], rax
    ; 6th arg = &domainLen
    mov     dword [SID_FRAME + 8], 48
    lea     rax, [SID_FRAME + 8]
    mov     [rsp+40], rax
    ; 7th arg = &peUse
    lea     rax, [SID_FRAME + 16]
    mov     [rsp+48], rax
    call    LookupAccountSidA
    test    eax, eax
    jnz     .close_token_done_user

.close_token_skip_user:
    ; Copy "SYSTEM" as default
    lea     rsi, [rel szUnknownUser]
    lea     rdi, [r15 + PE_USER]
    mov     ecx, 7
    .copy_user: mov al, [rsi]
                mov [rdi], al
                inc rsi
                inc rdi
                dec ecx
                jnz .copy_user

.close_token_done_user:
    mov     rcx, r14
    call    CloseHandle
    jmp     .close_proc

.use_default_user:
    lea     rsi, [rel szNA]
    lea     rdi, [r15 + PE_USER]
    mov     ecx, 4
    .copy_na: mov al, [rsi]
              mov [rdi], al
              inc rsi
              inc rdi
              dec ecx
              jnz .copy_na

.close_proc:
    mov     rcx, [LOC_HPROC]
    call    CloseHandle

.skip_stats:
    ; Advance write pointer and count
    add     r15, PROC_ENTRY_SIZE
    inc     dword [rel procCount]

    ; --- Process32NextA ---
    lea     rsi, [PE32_FRAME]
    mov     dword [rsi + PE32_dwSize], PE32_SIZEOF
    mov     rcx, rdi                    ; hSnapshot
    mov     rdx, rsi                    ; &pe32
    call    Process32Next
    test    eax, eax
    jnz     .proc_loop

    ; -----------------------------------------------------------------------
    ; Done
    ; -----------------------------------------------------------------------
.done_enum:
    mov     rcx, [LOC_HSNAP]
    call    CloseHandle

    mov     eax, [rel procCount]
    jmp     .epilog

.fail_no_snap:
    ; Free new (empty) table
    mov     rcx, rbp
    xor     edx, edx
    mov     r8, [rel procTable]
    call    HeapFree
    xor     eax, eax
    jmp     .epilog

.fail_no_table:
    xor     eax, eax

.epilog:
    add     rsp, 512
    pop     r15
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; Undefine local macros
%undef PE32_FRAME
%undef PMC_FRAME
%undef FT_FRAME
%undef SID_FRAME
%undef LOC_HSNAP
%undef LOC_HTOKEN
%undef LOC_HPROC
%undef LOC_NEEDED
