; =============================================================================
;  killer.asm  —  AsmTaskMgr
;  Three-tier process kill cascade:
;    Tier 1: Win32  TerminateProcess
;    Tier 2: ntdll  NtTerminateProcess  (NtOpenProcess first)
;    Tier 3: Kernel driver IOCTL_KILL_PROCESS
;  Assembled as: nasm -f win64 killer.asm -o killer.obj
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
;  Win32 / NT imports
; ---------------------------------------------------------------------------
extern OpenProcess
extern TerminateProcess
extern CloseHandle
extern CreateFileA
extern DeviceIoControl
extern GetLastError

; ntdll NT-native APIs
extern NtOpenProcess
extern NtTerminateProcess

; SCManager (for driver install/start/stop)
extern OpenSCManagerA
extern CreateServiceA
extern OpenServiceA
extern StartServiceA
extern ControlService
extern DeleteService
extern CloseServiceHandle
extern GetModuleFileNameA

; ---------------------------------------------------------------------------
;  Globals from strings.asm
; ---------------------------------------------------------------------------
extern hDeviceDriver
extern driverLoaded
extern szDriverDevice
extern szDriverSvcName
extern szDriverSvcDisplay

; ---------------------------------------------------------------------------
;  Exports
; ---------------------------------------------------------------------------
global KillProcess
global LoadKernelDriver
global UnloadKernelDriver
global OpenDriverDevice

; ---------------------------------------------------------------------------
;  Constants
; ---------------------------------------------------------------------------
%define PROCESS_TERMINATE             0x0001
%define PROCESS_ALL_ACCESS            0x001FFFFF
%define IOCTL_KILL_PROCESS            0x00222000
%define STATUS_SUCCESS                0x00000000
%define INVALID_HANDLE_VALUE          -1
%define GENERIC_READ                  0x80000000
%define GENERIC_WRITE                 0x40000000
%define FILE_SHARE_READ               0x00000001
%define FILE_SHARE_WRITE              0x00000002
%define OPEN_EXISTING                 3
%define FILE_ATTRIBUTE_NORMAL         0x80
%define SC_MANAGER_ALL_ACCESS         0xF003F
%define SERVICE_KERNEL_DRIVER         0x00000001
%define SERVICE_DEMAND_START          0x00000003
%define SERVICE_ERROR_IGNORE          0x00000000
%define SERVICE_ALL_ACCESS            0xF01FF
%define SERVICE_CONTROL_STOP          0x00000001

; OBJECT_ATTRIBUTES offsets (64-bit, total 48 bytes)
%define OA_Length          0     ; ULONG  (4)
%define OA_RootDirectory   8     ; HANDLE (8) — aligned to 8
%define OA_ObjectName      16    ; PUNICODE_STRING (8)
%define OA_Attributes      24    ; ULONG (4)
%define OA_SecurityDesc    32    ; PVOID (8) — aligned to 8
%define OA_SecurityQoS     40    ; PVOID (8)
%define OA_SIZEOF          48

; CLIENT_ID offsets (16 bytes)
%define CID_UniqueProcess  0     ; HANDLE (8)
%define CID_UniqueThread   8     ; HANDLE (8)
%define CID_SIZEOF         16

; SERVICE_STATUS offset for ControlService
%define SS_SIZEOF          28

; ---------------------------------------------------------------------------
;  Module-private data
; ---------------------------------------------------------------------------
section .data
szExePathBuf:   times 520 db 0    ; exe path buffer for driver .sys path

; ---------------------------------------------------------------------------
section .text

; ===========================================================================
;  KillProcess(pid)
;  In:  ECX = PID to kill
;  Out: EAX = 0 on success, 1 on failure (all tiers exhausted)
; ===========================================================================
KillProcess:
    push    rbx
    push    rsi
    push    rdi
    ; 3 pushes = 24 bytes. After ret addr (8) = 32 total shift.
    ; Need sub N where N ≡ 0 (mod 16) [since 32 already divisible by 16, but we need RSP 16-aligned, so N must be ≡ 0 (mod 16)]
    ; sub 128: 128 mod 16 = 0 ✓  RSP after = caller_rsp - 32 - 128 = caller_rsp - 160; 160/16=10 ✓
    sub     rsp, 128

    ; Stack layout:
    ;   [rsp+  0] shadow (32)
    ;   [rsp+ 32] 5th/6th arg spill
    ;   [rsp+ 48] OBJECT_ATTRIBUTES (48 bytes)
    ;   [rsp+ 96] CLIENT_ID (16 bytes)
    ;   [rsp+112] local: hProc (8), bytes (4), pad
    %define OA_LOC    rsp+48
    %define CID_LOC   rsp+96
    %define HPROC_LOC rsp+112
    %define BYTES_LOC rsp+120

    mov     rbx, rcx                       ; rbx = pid

    ; ==================================================================
    ; TIER 1: Win32 TerminateProcess
    ; ==================================================================
    mov     ecx, PROCESS_TERMINATE
    xor     edx, edx                       ; bInheritHandle = FALSE
    mov     r8d, ebx                       ; pid
    call    OpenProcess
    test    rax, rax
    jz      .tier2

    mov     rdi, rax                       ; rdi = hProc
    mov     rcx, rdi
    mov     edx, 1                         ; uExitCode
    call    TerminateProcess
    push    rax
    mov     rcx, rdi
    call    CloseHandle
    pop     rax
    test    eax, eax
    jnz     .success                       ; TerminateProcess returned non-zero = success

    ; ==================================================================
    ; TIER 2: NtOpenProcess + NtTerminateProcess
    ; ==================================================================
.tier2:
    ; Build OBJECT_ATTRIBUTES: Length=48, all others 0
    xor     eax, eax
    mov     dword [OA_LOC + OA_Length],       OA_SIZEOF
    mov     qword [OA_LOC + OA_RootDirectory], 0
    mov     qword [OA_LOC + OA_ObjectName],    0
    mov     dword [OA_LOC + OA_Attributes],    0
    mov     qword [OA_LOC + OA_SecurityDesc],  0
    mov     qword [OA_LOC + OA_SecurityQoS],   0

    ; Build CLIENT_ID: UniqueProcess = pid, UniqueThread = 0
    mov     qword [CID_LOC + CID_UniqueProcess], 0
    mov     dword [CID_LOC + CID_UniqueProcess], ebx   ; write DWORD pid into QWORD slot
    mov     qword [CID_LOC + CID_UniqueThread],  0

    ; NtOpenProcess(&handle, PROCESS_ALL_ACCESS, &oa, &cid)
    lea     rcx, [HPROC_LOC]
    mov     edx, PROCESS_ALL_ACCESS
    lea     r8,  [OA_LOC]
    lea     r9,  [CID_LOC]
    call    NtOpenProcess
    test    eax, eax                        ; eax = NTSTATUS, 0 = STATUS_SUCCESS
    jnz     .tier3

    mov     rsi, [HPROC_LOC]               ; rsi = handle from NtOpenProcess

    ; NtTerminateProcess(handle, 0)
    mov     rcx, rsi
    xor     edx, edx
    call    NtTerminateProcess
    push    rax
    mov     rcx, rsi
    call    CloseHandle
    pop     rax
    test    eax, eax
    jz      .success                        ; NTSTATUS 0 = success

    ; ==================================================================
    ; TIER 3: Kernel Driver IOCTL
    ; ==================================================================
.tier3:
    ; Ensure driver device is open
    call    OpenDriverDevice
    mov     rdi, [rel hDeviceDriver]
    cmp     rdi, INVALID_HANDLE_VALUE
    je      .fail
    test    rdi, rdi
    jz      .fail

    ; Write pid to [BYTES_LOC] as DWORD input buffer
    mov     dword [BYTES_LOC], ebx

    ; DeviceIoControl(hDevice, IOCTL_KILL_PROCESS, &pid, 4, NULL, 0, &bytes_returned, NULL)
    mov     rcx, rdi
    mov     edx, IOCTL_KILL_PROCESS
    lea     r8,  [BYTES_LOC]
    mov     r9d, 4
    xor     eax, eax
    mov     qword [rsp+32], rax              ; lpOutBuffer = NULL
    mov     dword [rsp+40], 0               ; nOutBufferSize = 0
    lea     rax, [BYTES_LOC + 4]
    mov     [rsp+48], rax                   ; lpBytesReturned
    mov     qword [rsp+56], 0               ; lpOverlapped = NULL
    call    DeviceIoControl
    test    eax, eax
    jnz     .success

.fail:
    mov     eax, 1                          ; failure
    jmp     .epilog

.success:
    xor     eax, eax                        ; success

.epilog:
    add     rsp, 128
    pop     rdi
    pop     rsi
    pop     rbx
    ret

    %undef OA_LOC
    %undef CID_LOC
    %undef HPROC_LOC
    %undef BYTES_LOC

; ===========================================================================
;  OpenDriverDevice
;  Opens \\.\AsmTaskMgrDrv device handle and caches it in hDeviceDriver.
;  Returns: RAX = handle (or INVALID_HANDLE_VALUE on failure).
; ===========================================================================
OpenDriverDevice:
    push    rbx
    ; 1 push + 8 ret = 16. RSP after push = caller_rsp - 16 (ALIGNED).
    ; sub N divisible by 16: shadow(32)+arg5/6/7 spill(24)+pad(8)=64. 64/16=4 ✓
    sub     rsp, 64

    ; Check if already open
    mov     rax, [rel hDeviceDriver]
    cmp     rax, INVALID_HANDLE_VALUE
    je      .do_open
    test    rax, rax
    jnz     .done               ; already valid

.do_open:
    ; CreateFileA("\\.\AsmTaskMgrDrv", GENERIC_READ|GENERIC_WRITE,
    ;              FILE_SHARE_READ|WRITE, NULL, OPEN_EXISTING,
    ;              FILE_ATTRIBUTE_NORMAL, NULL)
    lea     rcx, [rel szDriverDevice]
    mov     edx, (GENERIC_READ | GENERIC_WRITE)
    mov     r8d, (FILE_SHARE_READ | FILE_SHARE_WRITE)
    xor     r9d, r9d                         ; lpSecurityAttributes = NULL
    mov     dword [rsp+32], OPEN_EXISTING
    mov     dword [rsp+40], FILE_ATTRIBUTE_NORMAL
    mov     qword [rsp+48], 0               ; hTemplateFile = NULL
    call    CreateFileA
    mov     [rel hDeviceDriver], rax

.done:
    add     rsp, 64
    pop     rbx
    ret

; ===========================================================================
;  LoadKernelDriver
;  Installs (if needed) and starts the AsmTaskMgr.sys driver.
;  The .sys file must be in the same directory as this .exe.
;  Returns: EAX = 1 on success, 0 on failure.
; ===========================================================================
LoadKernelDriver:
    push    rbp
    push    rbx
    push    rsi
    push    rdi
    push    r15
    ; 5 pushes = 40 + 8 (ret addr) = 48. sub N ≡ 0 (mod 16) → sub 208
    sub     rsp, 208

    ; Stack:
    ;   [rsp+  0] shadow (32)
    ;   [rsp+ 32] arg spill
    ;   [rsp+ 64] SERVICE_STATUS struct (28 bytes)
    ;   [rsp+ 96] full driver .sys path buffer (512 bytes)
    ; → 32+32+28+... = layout: 32 shadow, 32 spill, 28 svcstatus, then path (too big for 208)
    ; Use a static buffer instead (szExePathBuf already in .data)

    ; --- Build driver .sys path ---
    ; GetModuleFileNameA(NULL, szExePathBuf, 512)
    xor     ecx, ecx
    lea     rdx, [rel szExePathBuf]
    mov     r8d, 512
    call    GetModuleFileNameA
    ; rax = length of path
    ; Replace trailing ".exe" with ".sys"
    lea     rbx, [rel szExePathBuf]
    lea     rbx, [rbx + rax - 4]       ; point to ".exe" (assuming 4-char extension)
    mov     dword [rbx], 0x7379732E     ; ".sys" (little-endian: 2E 73 79 73)
    mov     byte  [rbx + 4], 0         ; null terminate

    ; --- OpenSCManagerA(NULL, NULL, SC_MANAGER_ALL_ACCESS) ---
    xor     ecx, ecx
    xor     edx, edx
    mov     r8d, SC_MANAGER_ALL_ACCESS
    call    OpenSCManagerA
    test    rax, rax
    jz      .lkd_fail
    mov     rbp, rax                    ; rbp = hSCM

    ; --- Try CreateServiceA first ---
    mov     rcx, rbp
    lea     rdx, [rel szDriverSvcName]
    lea     r8,  [rel szDriverSvcDisplay]
    mov     r9d, SERVICE_ALL_ACCESS
    ; 5th-13th args on stack (qword slots)
    mov     qword [rsp+32], SERVICE_KERNEL_DRIVER     ; dwServiceType
    mov     qword [rsp+40], SERVICE_DEMAND_START       ; dwStartType
    mov     qword [rsp+48], SERVICE_ERROR_IGNORE       ; dwErrorControl
    lea     rax, [rel szExePathBuf]
    mov     [rsp+56], rax                              ; lpBinaryPathName
    mov     qword [rsp+64], 0                          ; lpLoadOrderGroup
    mov     qword [rsp+72], 0                          ; lpdwTagId
    mov     qword [rsp+80], 0                          ; lpDependencies
    mov     qword [rsp+88], 0                          ; lpServiceStartName
    mov     qword [rsp+96], 0                          ; lpPassword
    call    CreateServiceA
    test    rax, rax
    jnz     .start_service

    ; CreateService failed → maybe already registered, try OpenServiceA
    mov     rcx, rbp
    lea     rdx, [rel szDriverSvcName]
    mov     r8d, SERVICE_ALL_ACCESS
    call    OpenServiceA
    test    rax, rax
    jz      .close_scm_fail

.start_service:
    mov     r15, rax                    ; r15 = hService

    ; --- StartServiceA(hService, 0, NULL) ---
    mov     rcx, r15
    xor     edx, edx
    xor     r8d, r8d
    call    StartServiceA
    ; Ignore return: might already be running

    ; --- Open the device handle ---
    call    OpenDriverDevice
    cmp     rax, INVALID_HANDLE_VALUE
    je      .svc_fail
    test    rax, rax
    jz      .svc_fail

    mov     dword [rel driverLoaded], 1
    mov     rcx, r15
    call    CloseServiceHandle
    mov     rcx, rbp
    call    CloseServiceHandle
    mov     eax, 1
    jmp     .lkd_done

.svc_fail:
    mov     rcx, r15
    call    CloseServiceHandle
.close_scm_fail:
    mov     rcx, rbp
    call    CloseServiceHandle
.lkd_fail:
    xor     eax, eax
.lkd_done:
    add     rsp, 208
    pop     r15
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ===========================================================================
;  UnloadKernelDriver
;  Stops and optionally removes the AsmTaskMgr.sys driver service.
;  Returns: void
; ===========================================================================
UnloadKernelDriver:
    push    rbx
    push    rsi
    sub     rsp, 72

    ; Close device handle
    mov     rcx, [rel hDeviceDriver]
    cmp     rcx, INVALID_HANDLE_VALUE
    je      .no_close
    test    rcx, rcx
    jz      .no_close
    call    CloseHandle
    mov     qword [rel hDeviceDriver], 0
.no_close:

    cmp     dword [rel driverLoaded], 0
    je      .done_unload

    ; OpenSCManager + OpenService + ControlService(STOP) + DeleteService
    xor     ecx, ecx
    xor     edx, edx
    mov     r8d, SC_MANAGER_ALL_ACCESS
    call    OpenSCManagerA
    test    rax, rax
    jz      .done_unload
    mov     rbx, rax

    mov     rcx, rbx
    lea     rdx, [rel szDriverSvcName]
    mov     r8d, SERVICE_ALL_ACCESS
    call    OpenServiceA
    test    rax, rax
    jz      .close_scm_unload
    mov     rsi, rax

    ; ControlService(hSvc, SERVICE_CONTROL_STOP, &svcStatus)
    mov     rcx, rsi
    mov     edx, SERVICE_CONTROL_STOP
    lea     r8, [rsp+32]              ; &SERVICE_STATUS (scratch)
    call    ControlService

    ; DeleteService(hSvc) — optional, comment out to persist across reboots
    mov     rcx, rsi
    call    DeleteService

    mov     rcx, rsi
    call    CloseServiceHandle
.close_scm_unload:
    mov     rcx, rbx
    call    CloseServiceHandle

    mov     dword [rel driverLoaded], 0

.done_unload:
    add     rsp, 72
    pop     rsi
    pop     rbx
    ret
