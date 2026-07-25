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
extern MessageBoxA

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

; Debug strings for EnumProcesses
szEP1:  db 'EP1: EnumProcesses entry',0
szEP2:  db 'EP2: After EnsureHeap',0
szEP3:  db 'EP3: After HeapAlloc (new table)',0
szEP4:  db 'EP4: After CreateToolhelp32Snapshot',0
szEP5:  db 'EP5: After Process32First',0
szEP6:  db 'EP6: Leaving proc_loop',0
szEPT:  db 'EnumProcesses Debug',0

; ===========================================================================
;  SECTION .text
; ===========================================================================
section .text

; ---------------------------------------------------------------------------
;  Internal: EnsureHeap — caches GetProcessHeap()
;  Out: RAX = heap handle
;  Preserves all other registers.
; ---------------------------------------------------------------------------
EnsureHeap:
    mov rax, [rel hHeap]
    test rax, rax
    jnz .done
    ; Need shadow space (32) + alignment. On entry RSP is 8-byte aligned
    ; (caller did CALL which pushed 8-byte ret addr). sub 40 → 48 total shift → misaligned.
    ; sub 24 → 32 total shift → still misaligned for calls. Use sub 40 (shadow=32 + pad=8).
    ; Actually: entry RSP mod 16 = 8 (ret addr pushed). sub 40 → RSP mod 16 = (8-40) mod 16 = 0. ✓
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
;
;  Register use:
;    rbp = heap handle
;    rbx = hProc (per-process open handle)
;    rsi = snapshot handle (hSnap) / string src during name copy
;    rdi = current write ptr (r15 was clobbered risk; using rdi)
;    r14 = hToken (callee-saved, pushed in prologue)
;    r15 = spare (saved)
; ===========================================================================
EnumProcesses:
    push    rbp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r14
    push    r15
    ; Alignment: 7 pushes = 56 bytes. On entry RSP = 16k-8 (after CALL pushed ret addr from 16k-aligned site).
    ; After 7 pushes: RSP = 16k-8-56 = 16(k-4). Need sub N where N mod 16 = 0 to stay aligned.
    ; Use N=528 (528/16=33 exactly ✓).
    sub     rsp, 528

    ; Stack layout (528 bytes, 0..527):
    ; rsp+  0..31:  shadow space (32 bytes)
    ; rsp+ 32..55:  arg spill 5th/6th/7th (24 bytes)
    ; rsp+ 56..359: PROCESSENTRY32A (304 bytes)
    ; rsp+360..431: PROCESS_MEMORY_COUNTERS (72 bytes)
    ; rsp+432..463: FILETIMEs x4 (32 bytes)
    ; rsp+464..527: SID/TOKEN buffer (64 bytes) — hSnap held in r15 register
    ; Total = 528

    %define PE32_FRAME   rsp+56
    %define PMC_FRAME    rsp+360
    %define FT_FRAME     rsp+432
    %define SID_FRAME    rsp+464
    ; hSnapshot stored in r15 (callee-saved, already pushed)

    ; --- EP1: entry ---
    xor     ecx, ecx
    lea     rdx, [rel szEP1]
    lea     r8,  [rel szEPT]
    xor     r9d, r9d
    call    MessageBoxA

    ; -----------------------------------------------------------------------
    ; 0. Ensure process heap is cached
    ; -----------------------------------------------------------------------
    call    EnsureHeap
    mov     rbp, rax                      ; rbp = heap handle

    ; --- EP2: after EnsureHeap ---
    xor     ecx, ecx
    lea     rdx, [rel szEP2]
    lea     r8,  [rel szEPT]
    xor     r9d, r9d
    call    MessageBoxA

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
    ; 3. Allocate new procTable
    ; -----------------------------------------------------------------------
    mov     edx, INITIAL_CAP
    cmp     dword [rel procCount], INITIAL_CAP
    jle     .use_init_cap
    mov     edx, [rel procCount]
    shl     edx, 1                        ; double
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

    ; --- EP3: after HeapAlloc ---
    xor     ecx, ecx
    lea     rdx, [rel szEP3]
    lea     r8,  [rel szEPT]
    xor     r9d, r9d
    call    MessageBoxA

    ; -----------------------------------------------------------------------
    ; 4. Create Toolhelp32 snapshot
    ; -----------------------------------------------------------------------
    mov     ecx, TH32CS_SNAPPROCESS
    xor     edx, edx
    call    CreateToolhelp32Snapshot
    cmp     rax, -1                        ; INVALID_HANDLE_VALUE
    je      .fail_no_snap
    mov     r15, rax                       ; r15 = hSnapshot
    mov     rsi, rax                       ; rsi = hSnapshot

    ; --- EP4: after Snapshot ---
    xor     ecx, ecx
    lea     rdx, [rel szEP4]
    lea     r8,  [rel szEPT]
    xor     r9d, r9d
    call    MessageBoxA

    ; -----------------------------------------------------------------------
    ; 5. Init PROCESSENTRY32A: dwSize = 304
    ; -----------------------------------------------------------------------
    mov     dword [PE32_FRAME + PE32_dwSize], PE32_SIZEOF
    mov     dword [rel procCount], 0

    ; -----------------------------------------------------------------------
    ; 6. Process32First
    ; -----------------------------------------------------------------------
    mov     rcx, rsi
    lea     rdx, [PE32_FRAME]
    call    Process32First
    test    eax, eax
    jz      .done_enum                     ; empty system?

    ; --- EP5: Process32First succeeded ---
    xor     ecx, ecx
    lea     rdx, [rel szEP5]
    lea     r8,  [rel szEPT]
    xor     r9d, r9d
    call    MessageBoxA

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
    ; Zero out current entry (PROC_ENTRY_SIZE / 8 qwords).
    ; Use rbx as temp — it's free at this point (hProc not yet opened).
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
    mov     r12d, eax                     ; r12 = pid (r12 is callee-saved, preserved across calls)

    ; --- Copy exe name (up to 260 bytes) using r15 as temp src ptr---
    lea     r15, [PE32_FRAME + PE32_szExeFile]
    push    rdi                           ; save rdi (write ptr)
    lea     rdi, [rdi + PE_NAME]
    mov     ecx, 260
.copy_name:
    mov     al, [r15]
    mov     [rdi], al
    test    al, al
    jz      .copy_name_done
    inc     r15
    inc     rdi
    dec     ecx
    jnz     .copy_name
.copy_name_done:
    pop     rdi                           ; restore write ptr

    ; -----------------------------------------------------------------------
    ; 8. OpenProcess for memory and time queries
    ; -----------------------------------------------------------------------
    mov     ecx, PROCESS_QUERYINFO_VM
    xor     edx, edx                      ; FALSE (bInheritHandle)
    mov     r8d, r12d                     ; pid
    call    OpenProcess
    test    rax, rax
    jz      .skip_stats
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
    lea     r8,  [SID_FRAME + 40]         ; store hToken at end of SID_FRAME (offset 40)
    call    OpenProcessToken
    test    eax, eax
    jz      .use_default_user

    mov     r14, [SID_FRAME + 40]         ; r14 = hToken — stored at SID_FRAME+40 (past token buffer)

    ; GetTokenInformation(hToken, TokenUser=1, buffer, bufSize, &needed)
    mov     rcx, r14
    mov     edx, TokenUser
    lea     r8,  [SID_FRAME]              ; buffer
    mov     r9d, 40                       ; buffer size (TOKEN_USER = SID_AND_ATTRIBUTES = 16 + SID itself ≤ 28)
    lea     rax, [SID_FRAME + 44]         ; &needed (at offset 44, past our 40-byte buffer)
    mov     [rsp+32], rax
    call    GetTokenInformation
    test    eax, eax
    jz      .close_token_skip_user

    ; LookupAccountSidA(NULL, Sid, name, &cchName, domain, &cchDomain, &peUse)
    ; SID_AND_ATTRIBUTES.Sid is the first QWORD at SID_FRAME
    mov     rax, [SID_FRAME]              ; Sid pointer
    xor     ecx, ecx                      ; lpSystemName = NULL
    mov     rdx, rax                      ; Sid
    lea     r8,  [rdi + PE_USER]          ; lpName (output)
    mov     dword [SID_FRAME + 44], 64    ; cchName = 64
    lea     r9,  [SID_FRAME + 44]         ; pcchName
    ; 5th arg: domain scratch buffer (SID_FRAME+8, well within 64-byte region)
    lea     rax, [SID_FRAME + 8]
    mov     [rsp+32], rax
    ; 6th arg: &cchDomain — use SID_FRAME+48 (safe: within our 64-byte SID region, not at LOC_HSNAP)
    mov     dword [SID_FRAME + 48], 32
    lea     rax, [SID_FRAME + 48]
    mov     [rsp+40], rax
    ; 7th arg: &peUse — use SID_FRAME+52
    lea     rax, [SID_FRAME + 52]
    mov     [rsp+48], rax
    call    LookupAccountSidA
    test    eax, eax
    jnz     .close_token_done_user

.close_token_skip_user:
    ; Copy "SYSTEM" as fallback
    lea     r15, [rel szUnknownUser]
    lea     r12, [rdi + PE_USER]
    mov     ecx, 7
.copy_user:
    mov     al,  [r15]
    mov     [r12], al
    inc     r15
    inc     r12
    dec     ecx
    jnz     .copy_user
    ; reset r12 to pid
    mov     r12d, dword [rdi + PE_PID]

.close_token_done_user:
    mov     rcx, r14
    call    CloseHandle
    jmp     .close_proc

.use_default_user:
    lea     r15, [rel szNA]
    lea     r12, [rdi + PE_USER]
    mov     ecx, 4
.copy_na:
    mov     al,  [r15]
    mov     [r12], al
    inc     r15
    inc     r12
    dec     ecx
    jnz     .copy_na
    ; reset r12 to pid
    mov     r12d, dword [rdi + PE_PID]

.close_proc:
    mov     rcx, rbx
    call    CloseHandle

.skip_stats:
    ; Advance write pointer and count
    add     rdi, PROC_ENTRY_SIZE
    inc     dword [rel procCount]

    ; --- Process32Next ---
    ; rsi holds hSnapshot (callee-saved, untouched by all loop body calls including FindPrevEntry)
    mov     dword [PE32_FRAME + PE32_dwSize], PE32_SIZEOF
    mov     rcx, rsi                      ; hSnapshot from rsi (preserved by all callees)
    lea     rdx, [PE32_FRAME]
    call    Process32Next
    test    eax, eax
    jnz     .proc_loop

    ; -----------------------------------------------------------------------
    ; Done
    ; -----------------------------------------------------------------------
.done_enum:
    mov     rcx, rsi                      ; hSnapshot from rsi (always preserved)
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
    pop     r15
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
