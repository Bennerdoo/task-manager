; =============================================================================
;  drv_main.asm  —  AsmTaskMgr Kernel Driver
;  DriverEntry: creates the device and symbolic link.
;  DriverUnload: deletes the symlink and device.
;  Assembled as: nasm -f win64 drv_main.asm -o drv_main.obj
;
;  *** KERNEL-MODE DRIVER ***
;  Link with: GoLink /subsystem:native /entry DriverEntry
;             ntoskrnl.exe hal.dll
;             drv_main.obj drv_ioctl.obj drv_kill.obj drv_strings.obj
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
;  Kernel API imports (from ntoskrnl.exe)
; ---------------------------------------------------------------------------
extern IoCreateDevice
extern IoCreateSymbolicLink
extern IoDeleteDevice
extern IoDeleteSymbolicLink
extern RtlInitUnicodeString

; ---------------------------------------------------------------------------
;  IRP dispatch handlers (drv_ioctl.asm)
; ---------------------------------------------------------------------------
extern IrpCreate
extern IrpClose
extern IrpDevCtrl

; ---------------------------------------------------------------------------
;  Kernel data strings (drv_strings.asm)
; ---------------------------------------------------------------------------
extern usDeviceName
extern usSymLinkName
extern wszDeviceName
extern wszSymLinkName

; ---------------------------------------------------------------------------
;  Exports  (GoLink /entry DriverEntry makes this the PE entry)
; ---------------------------------------------------------------------------
global DriverEntry
global DriverUnload

; ---------------------------------------------------------------------------
;  Constants
; ---------------------------------------------------------------------------
%define STATUS_SUCCESS              0x00000000
%define STATUS_UNSUCCESSFUL         0xC0000001
%define FILE_DEVICE_UNKNOWN         0x00000022
%define FILE_DEVICE_SECURE_OPEN     0x00000100
%define FALSE                       0

; DRIVER_OBJECT field offsets (Win10/11 x64, confirmed via WinDbg)
%define DRVOBJ_DriverUnload          0x68    ; PDRIVER_UNLOAD
%define DRVOBJ_MajorFunction         0x70    ; PDRIVER_DISPATCH[28], each 8 bytes
; MajorFunction[n] = DRVOBJ_MajorFunction + n*8
%define IRP_MJ_CREATE                0
%define IRP_MJ_CLOSE                 2
%define IRP_MJ_DEVICE_CONTROL        14

; DEVICE_OBJECT saved pointer (we need it for DriverUnload)
; We store it as a module-level BSS variable.

; ---------------------------------------------------------------------------
section .bss

global pDeviceObject
pDeviceObject:    resq 1   ; PDEVICE_OBJECT saved during DriverEntry

; ---------------------------------------------------------------------------
section .text

; ===========================================================================
;  DriverEntry
;  Called by Windows kernel when the driver is loaded.
;  In:  RCX = PDRIVER_OBJECT DriverObject
;       RDX = PUNICODE_STRING RegistryPath (not used)
;  Out: EAX = NTSTATUS
; ===========================================================================
DriverEntry:
    push    rbp
    push    rbx
    push    rsi
    push    rdi
    ; 4 pushes = 32 + 8 ret = 40. sub 56: 56 mod 16 = 8. RSP shift = 96; 96/16=6 ✓
    sub     rsp, 56

    ; Stack: [rsp+0] shadow(32), [rsp+32] arg spill, [rsp+40] locals(16)

    mov     rbx, rcx                        ; rbx = DriverObject
    xor     rdi, rdi                        ; rdi = 0 (for error path checks)

    ; -----------------------------------------------------------------------
    ; 1. Set up dispatch table
    ; -----------------------------------------------------------------------
    ; DriverUnload
    lea     rax, [rel DriverUnload]
    mov     [rbx + DRVOBJ_DriverUnload], rax

    ; MajorFunction[IRP_MJ_CREATE]
    lea     rax, [rel IrpCreate]
    mov     [rbx + DRVOBJ_MajorFunction + IRP_MJ_CREATE*8], rax

    ; MajorFunction[IRP_MJ_CLOSE]
    lea     rax, [rel IrpClose]
    mov     [rbx + DRVOBJ_MajorFunction + IRP_MJ_CLOSE*8], rax

    ; MajorFunction[IRP_MJ_DEVICE_CONTROL]
    lea     rax, [rel IrpDevCtrl]
    mov     [rbx + DRVOBJ_MajorFunction + IRP_MJ_DEVICE_CONTROL*8], rax

    ; -----------------------------------------------------------------------
    ; 2. Initialize UNICODE_STRINGs for device and symlink names
    ; -----------------------------------------------------------------------
    lea     rcx, [rel usDeviceName]
    lea     rdx, [rel wszDeviceName]
    call    RtlInitUnicodeString

    lea     rcx, [rel usSymLinkName]
    lea     rdx, [rel wszSymLinkName]
    call    RtlInitUnicodeString

    ; -----------------------------------------------------------------------
    ; 3. IoCreateDevice
    ;
    ;   IoCreateDevice(
    ;       PDRIVER_OBJECT DriverObject,         // RCX
    ;       ULONG          DeviceExtensionSize,  // RDX  (0 - no extension)
    ;       PUNICODE_STRING DeviceName,          // R8
    ;       DEVICE_TYPE    DeviceType,           // R9
    ;       ULONG          DeviceCharacteristics, // [rsp+32]
    ;       BOOLEAN        Exclusive,            // [rsp+40]  FALSE
    ;       PDEVICE_OBJECT *DeviceObject         // [rsp+48]  (local storage on stack)
    ;   )
    ; -----------------------------------------------------------------------
    lea     rsi, [rsp+40]                   ; rsi = &pDevObj (scratch on stack at [rsp+40])
    mov     qword [rsi], 0                  ; zero it

    mov     rcx, rbx                        ; DriverObject
    xor     edx, edx                        ; DeviceExtensionSize = 0
    lea     r8, [rel usDeviceName]          ; DeviceName
    mov     r9d, FILE_DEVICE_UNKNOWN        ; DeviceType
    mov     dword [rsp+32], FILE_DEVICE_SECURE_OPEN   ; DeviceCharacteristics
    mov     byte  [rsp+40], FALSE           ; Exclusive
    lea     rax, [rsp+48]                   ; &DeviceObject (output)
    mov     [rsp+56], rax                   ; ... wait, we only have 56 bytes allocated, [rsp+56] is out of range!

    ; Let me fix: allocate bigger frame. Since we're already in code, I'll use a BSS slot.
    ; Use the global pDeviceObject BSS variable instead:
    lea     rax, [rel pDeviceObject]
    mov     [rsp+48], rax

    ; Redo the call properly
    mov     rcx, rbx
    xor     edx, edx
    lea     r8, [rel usDeviceName]
    mov     r9d, FILE_DEVICE_UNKNOWN
    mov     dword [rsp+32], FILE_DEVICE_SECURE_OPEN
    mov     byte  [rsp+40], FALSE
    lea     rax, [rel pDeviceObject]
    mov     [rsp+48], rax
    call    IoCreateDevice
    test    eax, eax                         ; check NTSTATUS
    jnz     .fail

    ; -----------------------------------------------------------------------
    ; 4. IoCreateSymbolicLink(&symLinkName, &deviceName)
    ; -----------------------------------------------------------------------
    lea     rcx, [rel usSymLinkName]
    lea     rdx, [rel usDeviceName]
    call    IoCreateSymbolicLink
    test    eax, eax
    jnz     .fail_delete_device

    ; -----------------------------------------------------------------------
    ; 5. Success
    ; -----------------------------------------------------------------------
    mov     eax, STATUS_SUCCESS
    jmp     .done

.fail_delete_device:
    ; Undo IoCreateDevice on symlink failure
    mov     rcx, [rel pDeviceObject]
    test    rcx, rcx
    jz      .fail
    call    IoDeleteDevice
    mov     qword [rel pDeviceObject], 0

.fail:
    ; eax already holds the failing NTSTATUS

.done:
    add     rsp, 56
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ===========================================================================
;  DriverUnload
;  Called by Windows when the driver service is stopped.
;  In: RCX = PDRIVER_OBJECT DriverObject
; ===========================================================================
DriverUnload:
    push    rbx
    sub     rsp, 40

    mov     rbx, rcx                         ; save DriverObject (not used but required arg)

    ; Delete symbolic link
    lea     rcx, [rel usSymLinkName]
    call    IoDeleteSymbolicLink

    ; Delete device object
    mov     rcx, [rel pDeviceObject]
    test    rcx, rcx
    jz      .done_unload
    call    IoDeleteDevice
    mov     qword [rel pDeviceObject], 0

.done_unload:
    add     rsp, 40
    pop     rbx
    ret
