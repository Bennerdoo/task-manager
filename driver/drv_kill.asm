; =============================================================================
;  drv_kill.asm  —  AsmTaskMgr Kernel Driver
;  Ring-0 process termination:
;    PsLookupProcessByProcessId → ObOpenObjectByPointer (KernelMode)
;    → ZwTerminateProcess → ZwClose → ObDereferenceObject
;
;  This bypasses Protected Process Light (PPL) because ObOpenObjectByPointer
;  with KernelMode access skips user-mode PPL enforcement entirely.
;
;  Assembled as: nasm -f win64 drv_kill.asm -o drv_kill.obj
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
;  Kernel API imports (from ntoskrnl.exe)
; ---------------------------------------------------------------------------
extern PsLookupProcessByProcessId
extern ObOpenObjectByPointer
extern ObDereferenceObject
extern ZwTerminateProcess
extern ZwClose

; ---------------------------------------------------------------------------
;  Exports
; ---------------------------------------------------------------------------
global KernelKillProcess

; ---------------------------------------------------------------------------
;  Constants
; ---------------------------------------------------------------------------
%define STATUS_SUCCESS           0x00000000
%define STATUS_INVALID_PARAMETER 0xC000000D
%define STATUS_NOT_FOUND         0xC0000225
%define PROCESS_ALL_ACCESS       0x001FFFFF
%define OBJ_KERNEL_HANDLE        0x00000200
%define KernelMode               0           ; KPROCESSOR_MODE enum value

; ---------------------------------------------------------------------------
section .text

; ===========================================================================
;  KernelKillProcess(pid)
;  Called from drv_ioctl.asm when IOCTL_KILL_PROCESS is received.
;
;  In:  ECX = PID (HANDLE-sized, but we pass as DWORD-truncated ULONG_PTR)
;  Out: EAX = NTSTATUS (0 = STATUS_SUCCESS)
;
;  Strategy:
;    1. PsLookupProcessByProcessId(pid, &pEprocess)
;    2. ObOpenObjectByPointer(pEprocess, OBJ_KERNEL_HANDLE, NULL,
;                             PROCESS_ALL_ACCESS, NULL, KernelMode, &hProc)
;    3. ZwTerminateProcess(hProc, 0)
;    4. ZwClose(hProc)
;    5. ObDereferenceObject(pEprocess)  [always, even on step 2 failure]
;
;  NOTE: NULL is passed for ObjectType (arg5) to skip type checking.
;        This is safe in kernel mode.
; ===========================================================================
KernelKillProcess:
    push    rbp
    push    rbx
    push    rsi
    push    rdi
    ; 4 pushes = 32 + 8 ret = 40. sub 88: 88 mod 16 = 8. RSP shift = 128; 128/16=8 ✓
    sub     rsp, 88

    ; Stack layout:
    ;   [rsp+ 0]  shadow (32 bytes)
    ;   [rsp+32]  5th/6th arg spill
    ;   [rsp+64]  pEprocess (QWORD local)
    ;   [rsp+72]  hProc     (QWORD local)
    ;   [rsp+80]  ntstatus  (DWORD local)

    %define LOC_PEPROCESS  rsp+64
    %define LOC_HPROC      rsp+72
    %define LOC_STATUS     rsp+80

    mov     ebx, ecx                  ; ebx = pid (DWORD)
    xor     rax, rax
    mov     [LOC_PEPROCESS], rax
    mov     [LOC_HPROC], rax

    ; Guard: PID 0 and PID 4 (System) are killable but let's allow them
    test    ebx, ebx
    jz      .invalid_pid

    ; -----------------------------------------------------------------------
    ; 1. PsLookupProcessByProcessId(pid, &pEprocess)
    ;    In: RCX = pid (as HANDLE/ULONG_PTR), RDX = &pEprocess (PEPROCESS*)
    ; -----------------------------------------------------------------------
    movsxd  rcx, ebx                  ; sign-extend pid to 64 bits (HANDLE)
    lea     rdx, [LOC_PEPROCESS]
    call    PsLookupProcessByProcessId
    test    eax, eax                   ; NTSTATUS
    jnz     .done                      ; failed → return status

    mov     rsi, [LOC_PEPROCESS]       ; rsi = PEPROCESS pointer
    test    rsi, rsi
    jz      .invalid_pid

    ; -----------------------------------------------------------------------
    ; 2. ObOpenObjectByPointer(Object, HandleAttributes, AccessState,
    ;                          DesiredAccess, ObjectType, AccessMode, &Handle)
    ;
    ;   RCX = pEprocess  (the PEPROCESS)
    ;   RDX = OBJ_KERNEL_HANDLE
    ;   R8  = NULL       (no PACCESS_STATE)
    ;   R9  = PROCESS_ALL_ACCESS
    ;   [rsp+32] = NULL  (ObjectType = NULL → no type checking)
    ;   [rsp+40] = KernelMode (0)
    ;   [rsp+48] = &hProc
    ; -----------------------------------------------------------------------
    mov     rcx, rsi                   ; PEPROCESS
    mov     edx, OBJ_KERNEL_HANDLE
    xor     r8d, r8d                   ; AccessState = NULL
    mov     r9d, PROCESS_ALL_ACCESS
    mov     qword [rsp+32], 0          ; ObjectType = NULL
    mov     qword [rsp+40], KernelMode ; AccessMode = KernelMode
    lea     rax, [LOC_HPROC]
    mov     [rsp+48], rax              ; &Handle
    call    ObOpenObjectByPointer
    mov     [LOC_STATUS], eax
    test    eax, eax
    jnz     .deref_and_done            ; open failed

    ; -----------------------------------------------------------------------
    ; 3. ZwTerminateProcess(hProc, 0)
    ; -----------------------------------------------------------------------
    mov     rcx, [LOC_HPROC]
    xor     edx, edx                   ; ExitStatus = 0
    call    ZwTerminateProcess
    mov     [LOC_STATUS], eax

    ; -----------------------------------------------------------------------
    ; 4. ZwClose(hProc)
    ; -----------------------------------------------------------------------
    mov     rcx, [LOC_HPROC]
    call    ZwClose

    jmp     .deref_and_done

.invalid_pid:
    mov     dword [LOC_STATUS], STATUS_INVALID_PARAMETER
    xor     rsi, rsi                   ; skip deref if pEprocess is NULL

.deref_and_done:
    ; 5. ObDereferenceObject(pEprocess) — always release the reference
    test    rsi, rsi
    jz      .done
    mov     rcx, rsi
    call    ObDereferenceObject

.done:
    mov     eax, [LOC_STATUS]
    add     rsp, 88
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

    %undef LOC_PEPROCESS
    %undef LOC_HPROC
    %undef LOC_STATUS
