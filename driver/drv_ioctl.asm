; =============================================================================
;  drv_ioctl.asm  —  AsmTaskMgr Kernel Driver
;  IRP dispatch handlers: IRP_MJ_CREATE, IRP_MJ_CLOSE, IRP_MJ_DEVICE_CONTROL
;  Assembled as: nasm -f win64 drv_ioctl.asm -o drv_ioctl.obj
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
;  Kernel API imports
; ---------------------------------------------------------------------------
extern IofCompleteRequest

; ---------------------------------------------------------------------------
;  Internal kernel kill function
; ---------------------------------------------------------------------------
extern KernelKillProcess

; ---------------------------------------------------------------------------
;  Exports
; ---------------------------------------------------------------------------
global IrpCreate
global IrpClose
global IrpDevCtrl

; ---------------------------------------------------------------------------
;  Constants
; ---------------------------------------------------------------------------
%define STATUS_SUCCESS             0x00000000
%define STATUS_INVALID_PARAMETER   0xC000000D
%define STATUS_INVALID_DEVICE_REQUEST 0xC0000010
%define STATUS_BUFFER_TOO_SMALL    0xC0000023
%define IO_NO_INCREMENT            0

%define IOCTL_KILL_PROCESS         0x00222000

; IRP field offsets (Win10/11 x64, documented layout)
; See implementation_plan.md for derivation
%define IRP_SystemBuffer    0x18    ; AssociatedIrp.SystemBuffer (PVOID at offset 0x18)
%define IRP_IoStatus_Status 0x30    ; IoStatus.Status (NTSTATUS, DWORD at 0x30)
%define IRP_IoStatus_Info   0x38    ; IoStatus.Information (ULONG_PTR at 0x38)

; IO_STACK_LOCATION field offsets
; MajorFunction(1) MinorFunction(1) Flags(1) Control(1) = 4 bytes
; 4 bytes padding → Parameters start at offset 8
%define IRPSL_IoControlCode     0x18   ; Parameters.DeviceIoControl.IoControlCode (ULONG at 0x18)
%define IRPSL_InputBufferLength 0x10   ; Parameters.DeviceIoControl.InputBufferLength (ULONG_PTR)
%define IRPSL_OutputBufferLength 0x08  ; Parameters.DeviceIoControl.OutputBufferLength (ULONG_PTR)

; ---------------------------------------------------------------------------
section .text

; ===========================================================================
;  IrpCreate  —  IRP_MJ_CREATE handler
;  Simply completes with STATUS_SUCCESS (allow any caller to open device).
; ===========================================================================
IrpCreate:
    ; RCX = PDEVICE_OBJECT, RDX = PIRP
    push    rbx
    sub     rsp, 40

    mov     rbx, rdx                        ; save IRP

    ; Set IoStatus
    mov     dword [rbx + IRP_IoStatus_Status], STATUS_SUCCESS
    mov     qword [rbx + IRP_IoStatus_Info],   0

    ; IofCompleteRequest(Irp, IO_NO_INCREMENT)
    mov     rcx, rbx
    xor     edx, edx                        ; IO_NO_INCREMENT = 0
    call    IofCompleteRequest

    mov     eax, STATUS_SUCCESS
    add     rsp, 40
    pop     rbx
    ret

; ===========================================================================
;  IrpClose  —  IRP_MJ_CLOSE handler
; ===========================================================================
IrpClose:
    push    rbx
    sub     rsp, 40

    mov     rbx, rdx

    mov     dword [rbx + IRP_IoStatus_Status], STATUS_SUCCESS
    mov     qword [rbx + IRP_IoStatus_Info],   0

    mov     rcx, rbx
    xor     edx, edx
    call    IofCompleteRequest

    mov     eax, STATUS_SUCCESS
    add     rsp, 40
    pop     rbx
    ret

; ===========================================================================
;  IrpDevCtrl  —  IRP_MJ_DEVICE_CONTROL handler
;
;  Handles IOCTL_KILL_PROCESS:
;    Input buffer:  DWORD pid
;    Output buffer: DWORD NTSTATUS from ZwTerminateProcess
;
;  All other IOCTLs return STATUS_INVALID_DEVICE_REQUEST.
; ===========================================================================
IrpDevCtrl:
    push    rbp
    push    rbx
    push    rsi
    ; 3 pushes = 24 + 8 ret = 32. sub 56: 56 mod 16 = 8. RSP shift = 88; 88/16 = 5.5 WRONG.
    ; RSP after pushes = original_caller - 32. sub 56 → total = 88. 88/16 = 5.5 → not aligned!
    ; Need 32 + N = multiple of 16, where N mod 16 = 0, BUT the push+ret adds 32 bytes.
    ; Actually: after pushes (24 bytes) + ret addr (8) = 32 total shift from aligned RSP.
    ; 32 mod 16 = 0, so RSP is aligned after pushes.
    ; sub N must also be 0 mod 16 to keep it aligned. sub 48: 48 mod 16 = 0 ✓
    sub     rsp, 48

    ; Stack: [rsp+0] shadow(32), [rsp+32] arg spill, [rsp+40] locals

    mov     rbp, rcx               ; rbp = PDEVICE_OBJECT
    mov     rbx, rdx               ; rbx = PIRP

    ; -----------------------------------------------------------------------
    ; 1. Get current IO stack location (Irp->Tail.Overlay.CurrentStackLocation at offset 0xB8)
    ; -----------------------------------------------------------------------
    mov     rsi, [rbx + 0xB8]      ; rsi = PIO_STACK_LOCATION

    ; -----------------------------------------------------------------------
    ; 2. Check IoControlCode
    ; -----------------------------------------------------------------------
    mov     eax, dword [rsi + IRPSL_IoControlCode]
    cmp     eax, IOCTL_KILL_PROCESS
    jne     .unsupported_ioctl

    ; -----------------------------------------------------------------------
    ; 3. Validate input buffer size (must be at least 4 bytes = DWORD pid)
    ; -----------------------------------------------------------------------
    mov     rax, [rsi + IRPSL_InputBufferLength]
    cmp     rax, 4
    jl      .buffer_too_small

    ; -----------------------------------------------------------------------
    ; 4. Read PID from METHOD_BUFFERED input buffer (Irp->AssociatedIrp.SystemBuffer)
    ; -----------------------------------------------------------------------
    mov     rax, [rbx + IRP_SystemBuffer]   ; SystemBuffer pointer
    mov     ecx, dword [rax]                 ; ecx = pid (DWORD)

    ; -----------------------------------------------------------------------
    ; 5. Call kernel kill function
    ; -----------------------------------------------------------------------
    call    KernelKillProcess               ; ecx = pid
    ; rax = NTSTATUS from ZwTerminateProcess chain

    ; Write result back to output buffer (if output buffer provided)
    mov     rcx, [rsi + IRPSL_OutputBufferLength]
    cmp     rcx, 4
    jl      .no_output
    mov     rdx, [rbx + IRP_SystemBuffer]
    mov     dword [rdx], eax               ; write NTSTATUS result

.no_output:
    ; Set IRP status
    mov     dword [rbx + IRP_IoStatus_Status], eax   ; NTSTATUS from kill
    mov     qword [rbx + IRP_IoStatus_Info],   4     ; bytes returned

    ; Complete IRP
    mov     rcx, rbx
    xor     edx, edx                        ; IO_NO_INCREMENT
    call    IofCompleteRequest

    ; Return STATUS_SUCCESS to indicate IRP was handled (even if kill itself failed)
    mov     eax, STATUS_SUCCESS
    jmp     .done

.unsupported_ioctl:
    mov     dword [rbx + IRP_IoStatus_Status], STATUS_INVALID_DEVICE_REQUEST
    mov     qword [rbx + IRP_IoStatus_Info],   0
    mov     rcx, rbx
    xor     edx, edx
    call    IofCompleteRequest
    mov     eax, STATUS_INVALID_DEVICE_REQUEST
    jmp     .done

.buffer_too_small:
    mov     dword [rbx + IRP_IoStatus_Status], STATUS_BUFFER_TOO_SMALL
    mov     qword [rbx + IRP_IoStatus_Info],   0
    mov     rcx, rbx
    xor     edx, edx
    call    IofCompleteRequest
    mov     eax, STATUS_BUFFER_TOO_SMALL

.done:
    add     rsp, 48
    pop     rsi
    pop     rbx
    pop     rbp
    ret
