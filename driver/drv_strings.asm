; =============================================================================
;  drv_strings.asm  —  AsmTaskMgr Kernel Driver
;  All kernel-mode data: device/symlink names, IOCTL code.
;  Assembled as: nasm -f win64 drv_strings.asm -o drv_strings.obj
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
;  Exports (used by drv_main.asm)
; ---------------------------------------------------------------------------
global wszDeviceName
global wszSymLinkName
global usDeviceName
global usSymLinkName

; ---------------------------------------------------------------------------
;  IOCTL
; ---------------------------------------------------------------------------
; IOCTL_KILL_PROCESS = CTL_CODE(FILE_DEVICE_UNKNOWN=0x22, 0x800, METHOD_BUFFERED=0, FILE_ANY_ACCESS=0)
;                    = ((0x22)<<16)|((0x800)<<2) = 0x00222000
%define IOCTL_KILL_PROCESS  0x00222000

; ---------------------------------------------------------------------------
;  NTSTATUS
; ---------------------------------------------------------------------------
%define STATUS_SUCCESS             0x00000000
%define STATUS_UNSUCCESSFUL        0xC0000001
%define STATUS_INVALID_PARAMETER   0xC000000D
%define STATUS_ACCESS_DENIED       0xC0000022
%define STATUS_NOT_FOUND           0xC0000225

; ---------------------------------------------------------------------------
;  Device / symlink names (UTF-16 LE)
; ---------------------------------------------------------------------------
; Device:  L"\Device\AsmTaskMgrDrv"
; SymLink: L"\DosDevices\AsmTaskMgrDrv"

section .data

global wszDeviceName
wszDeviceName:
    dw '\','D','e','v','i','c','e','\','A','s','m','T','a','s','k','M','g','r','D','r','v', 0
DEVICE_NAME_LEN  equ ($ - wszDeviceName - 2)   ; byte length WITHOUT null terminator

global wszSymLinkName
wszSymLinkName:
    dw '\','D','o','s','D','e','v','i','c','e','s','\','A','s','m','T','a','s','k','M','g','r','D','r','v', 0
SYMLINK_NAME_LEN equ ($ - wszSymLinkName - 2)

; ---------------------------------------------------------------------------
;  UNICODE_STRING structs (filled by drv_main at DriverEntry time via RtlInitUnicodeString)
; ---------------------------------------------------------------------------
section .bss

global usDeviceName
usDeviceName:       resb 16    ; UNICODE_STRING: Length(2), MaxLength(2), pad(4), Buffer*(8)

global usSymLinkName
usSymLinkName:      resb 16    ; UNICODE_STRING for symbolic link
