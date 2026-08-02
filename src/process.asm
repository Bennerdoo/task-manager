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
%define PROCESS_QUERYINFO_VM  0x00000410   ; QUERY_INFORMATION | VM_READ
%define PROCESS_QUERY_LIMITED 0x00001000   ; sufficient for mem+time queries
%define TOKEN_QUERY           0x00000008
%define TokenUser             1
%define HEAP_ZERO_MEMORY      0x00000008
%define PROC_ENTRY_SIZE       368

; PROCESSENTRY32A offsets (Win64)
%define PE32_dwSize           0
%define PE32_cntUsage         4
%define PE32_th32ProcessID    8
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
    push    r12
    push    r14
    push    r13              ; used for snapshot handle (hSnap)
    ; 7 pushes (56) + 8 ret = 64. sub 528: 64+528=592=37x16 OK
    sub     rsp, 528

    ; Stack layout (528 bytes):
    ;   [rsp+  0..31] shadow space (32 bytes)
    ;   [rsp+ 32..55] arg spill 5th/6th/7th (24 bytes)
    ;   [rsp+ 56..359] PROCESSENTRY32A (304 bytes)
    ;   [rsp+360..431] PROCESS_MEMORY_COUNTERS (72 bytes)
    ;   [rsp+432..463] FILETIMEs x4 (32 bytes)
    ;   [rsp+464..527] SID/TOKEN buffer (64 bytes, needs all 64)
    ;   hSnap stored in r13 (non-volatile) — avoids stack overlap

    %define PE32_FRAME   rsp+56
    %define PMC_FRAME    rsp+360
    %define FT_FRAME     rsp+432
    %define SID_FRAME    rsp+464

    ; -----------------------------------------------------------------------
    ; 0. Ensure process heap is cached
    ; -----------------------------------------------------------------------
    call    EnsureHeap
    mov     rbp, rax                      ; rbp = heap handle

    ; -----------------------------------------------------------------------
    ; 1. Free old prevProcTable
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
    ; 3. Allocate new procTable
    ; -----------------------------------------------------------------------
    mov     edx, INITIAL_CAP
    cmp     dword [rel procCount], INITIAL_CAP
    jle     .use_init_cap
    mov     edx, [rel procCount]
    shl     edx, 1                        ; double capacity
.use_init_cap:
    mov     [rel procCapacity], edx

    movsxd  r8,  edx
    imul    r8,  PROC_ENTRY_SIZE
    mov     rcx, rbp
    mov     edx, HEAP_ZERO_MEMORY
    call    HeapAlloc
    test    rax, rax
    jz      .fail_no_table
    mov     [rel procTable], rax
    mov     rdi, rax                       ; rdi = current write ptr

    ; -----------------------------------------------------------------------
    ; 4. Create Toolhelp32 snapshot
    ; -----------------------------------------------------------------------
    mov     ecx, TH32CS_SNAPPROCESS
    xor     edx, edx
    call    CreateToolhelp32Snapshot
    cmp     rax, -1                        ; INVALID_HANDLE_VALUE
    je      .fail_no_snap
    mov     r13, rax                       ; r13 = snapshot handle (non-volatile)

    ; -----------------------------------------------------------------------
    ; 5. Init PROCESSENTRY32A: dwSize = 304
    ; -----------------------------------------------------------------------
    mov     dword [PE32_FRAME + PE32_dwSize], PE32_SIZEOF
    mov     dword [rel procCount], 0

    ; -----------------------------------------------------------------------
    ; 6. Process32First
    ; -----------------------------------------------------------------------
    mov     rcx, r13
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
    mov     eax, [rel procCapacity]
    shl     eax, 1
    mov     [rel procCapacity], eax
    movsxd  r9, eax
    imul    r9, PROC_ENTRY_SIZE
    mov     rcx, rbp                      ; hHeap
    xor     edx, edx                      ; dwFlags = 0
    mov     r8,  [rel procTable]          ; lpMem
    call    HeapReAlloc
    test    rax, rax
    jz      .done_enum
    mov     [rel procTable], rax
    ; Recalculate write ptr rdi
    movsxd  rbx, dword [rel procCount]
    imul    rbx, PROC_ENTRY_SIZE
    lea     rdi, [rax + rbx]

.have_cap:
    ; Zero out current entry (PROC_ENTRY_SIZE / 8 qwords)
    mov     rbx, rdi
    xor     eax, eax
    mov     ecx, PROC_ENTRY_SIZE / 8
.zero_loop:
    mov     [rbx], rax
    add     rbx, 8
    dec     ecx
    jnz     .zero_loop

    ; --- Copy PID ---
    mov     eax, dword [PE32_FRAME + PE32_th32ProcessID]
    mov     dword [rdi + PE_PID], eax
    mov     r12d, eax                     ; r12d = pid

    ; --- Copy exe name (up to 260 bytes) using scratch registers ---
    lea     rax, [PE32_FRAME + PE32_szExeFile]
    lea     rdx, [rdi + PE_NAME]
.copy_name:
    mov     cl, [rax]
    mov     [rdx], cl
    test    cl, cl
    jz      .copy_name_done
    inc     rax
    inc     rdx
    jmp     .copy_name
.copy_name_done:

    ; -----------------------------------------------------------------------
    ; 8. OpenProcess for memory and time queries
    ; -----------------------------------------------------------------------
    ; Try full rights first; fall back to LIMITED for protected/system procs
    mov     ecx, PROCESS_QUERYINFO_VM
    xor     edx, edx
    mov     r8d, r12d
    call    OpenProcess
    test    rax, rax
    jnz     .have_proc
    mov     ecx, PROCESS_QUERY_LIMITED
    xor     edx, edx
    mov     r8d, r12d
    call    OpenProcess
    test    rax, rax
    jz      .skip_stats
.have_proc:
    mov     rbx, rax                      ; rbx = hProc

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
    mov     dword [rdi + PE_MEMKB], eax
.skip_mem:

    ; --- GetProcessTimes ---
    mov     rcx, rbx
    lea     rdx, [FT_FRAME]              ; lpCreationTime
    lea     r8,  [FT_FRAME + 8]          ; lpExitTime
    lea     r9,  [FT_FRAME + 16]         ; lpKernelTime
    lea     rax, [FT_FRAME + 24]         ; lpUserTime (5th arg on stack)
    mov     [rsp + 32], rax
    call    GetProcessTimes
    test    eax, eax
    jz      .skip_times
    ; Sum kernel + user FILETIME → store in PE_CPUTIME
    mov     rax, [FT_FRAME + 16]         ; kernelTime
    add     rax, [FT_FRAME + 24]         ; + userTime
    mov     [rdi + PE_CPUTIME], rax

    ; --- Compute CPU% delta vs prev cycle ---
    mov     ecx, dword [rdi + PE_PID]
    call    FindPrevEntry
    test    rax, rax
    jz      .skip_cpudelta
    mov     rcx, [rdi + PE_CPUTIME]
    sub     rcx, [rax + PE_CPUTIME]       ; delta CPU time (100ns units)
    mov     qword [rdi + PE_CPUPCT], rcx
.skip_cpudelta:
.skip_times:

    ; --- Get username via OpenProcessToken ---
    mov     rcx, rbx                      ; hProc
    mov     edx, TOKEN_QUERY
    lea     r8,  [SID_FRAME + 40]         ; store hToken at end of SID_FRAME
    call    OpenProcessToken
    test    eax, eax
    jz      .use_default_user

    mov     r14, [SID_FRAME + 40]         ; r14 = hToken

    ; GetTokenInformation(hToken, TokenUser=1, buffer, bufSize, &needed)
    mov     rcx, r14
    mov     edx, TokenUser
    lea     r8,  [SID_FRAME]              ; buffer
    mov     r9d, 40                       ; buffer size
    lea     rax, [SID_FRAME + 44]         ; &needed
    mov     [rsp+32], rax
    call    GetTokenInformation
    test    eax, eax
    jz      .close_token_skip_user

    ; LookupAccountSidA(NULL, Sid, name, &cchName, domain, &cchDomain, &peUse)
    mov     rdx, [SID_FRAME]              ; Sid pointer
    test    rdx, rdx
    jz      .close_token_skip_user

    xor     ecx, ecx                      ; lpSystemName = NULL
    lea     r8,  [rdi + PE_USER]          ; lpName (output)
    mov     dword [SID_FRAME + 44], 64    ; cchName = 64
    lea     r9,  [SID_FRAME + 44]         ; pcchName
    ; 5th arg: domain scratch buffer
    lea     rax, [SID_FRAME + 8]
    mov     [rsp+32], rax
    ; 6th arg: &cchDomain
    mov     dword [SID_FRAME + 48], 32
    lea     rax, [SID_FRAME + 48]
    mov     [rsp+40], rax
    ; 7th arg: &peUse
    lea     rax, [SID_FRAME + 52]
    mov     [rsp+48], rax
    call    LookupAccountSidA
    test    eax, eax
    jnz     .close_token_done_user

.close_token_skip_user:
    ; Copy "SYSTEM" as fallback
    lea     rax, [rel szUnknownUser]
    lea     rdx, [rdi + PE_USER]
.copy_user:
    mov     cl, [rax]
    mov     [rdx], cl
    test    cl, cl
    jz      .close_token_done_user
    inc     rax
    inc     rdx
    jmp     .copy_user

.close_token_done_user:
    mov     rcx, r14
    call    CloseHandle
    jmp     .close_proc

.use_default_user:
    lea     rax, [rel szNA]
    lea     rdx, [rdi + PE_USER]
.copy_na:
    mov     cl, [rax]
    mov     [rdx], cl
    test    cl, cl
    jz      .close_proc
    inc     rax
    inc     rdx
    jmp     .copy_na

.close_proc:
    mov     rcx, rbx
    call    CloseHandle

.skip_stats:
    ; Advance write pointer and count
    add     rdi, PROC_ENTRY_SIZE
    inc     dword [rel procCount]

    ; --- Process32Next ---
    mov     dword [PE32_FRAME + PE32_dwSize], PE32_SIZEOF
    mov     rcx, r13
    lea     rdx, [PE32_FRAME]
    call    Process32Next
    test    eax, eax
    jnz     .proc_loop

    ; -----------------------------------------------------------------------
    ; Done
    ; -----------------------------------------------------------------------
.done_enum:
    mov     rcx, r13
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
    add     rsp, 528
    pop     r13
    pop     r14
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

%undef PE32_FRAME
%undef PMC_FRAME
%undef FT_FRAME
%undef SID_FRAME
