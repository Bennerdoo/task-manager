; =============================================================================
;  main.asm  —  AsmTaskMgr
;  Entry point: WinMainCRTStartup.
;  No C runtime. Calls privilege engine, then window setup, then message loop.
;  Assembled as: nasm -f win64 main.asm -o main.obj
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
;  Win32 imports
; ---------------------------------------------------------------------------
extern GetModuleHandleA
extern GetCommandLineA
extern ExitProcess
extern InitCommonControlsEx
extern MessageBoxA

; ---------------------------------------------------------------------------
;  External functions from other modules
; ---------------------------------------------------------------------------
extern CheckElevation
extern AcquireDebugPrivilege
extern RegisterWindowClass
extern CreateMainWindow
extern WndProc

; ---------------------------------------------------------------------------
;  Globals from strings.asm
; ---------------------------------------------------------------------------
extern hInstance

; ---------------------------------------------------------------------------
;  Exports
; ---------------------------------------------------------------------------
global WinMainCRTStartup

; ---------------------------------------------------------------------------
;  Constants
; ---------------------------------------------------------------------------
%define SW_SHOWDEFAULT        10
%define ICC_WIN95_CLASSES     0x000000FF
%define MB_OK                 0
%define MB_ICONINFORMATION    0x40

; INITCOMMONCONTROLSEX struct (8 bytes)
%define ICCE_dwSize  0
%define ICCE_dwICC   4

; MSG struct offsets (x64: hwnd(8), message(4), pad(4), wParam(8), lParam(8), time(4), pt.x(4), pt.y(4))
; Total: 48 bytes (padded)
%define MSG_hwnd     0
%define MSG_message  8
%define MSG_wParam   16
%define MSG_lParam   24
%define MSG_time     32
%define MSG_pt       36
%define MSG_SIZEOF   48

extern GetMessageA
extern TranslateMessage
extern DispatchMessageA
extern IsDialogMessageA

; ---------------------------------------------------------------------------
section .data
szDbg1:  db 'DBG1: Entry point reached',0
szDbg2:  db 'DBG2: After CheckElevation (not 0xDEAD)',0
szDbg3:  db 'DBG3: After InitCommonControlsEx',0
szDbg4:  db 'DBG4: RegisterWindowClass returned non-zero',0
szDbg4f: db 'DBG4F: RegisterWindowClass returned ZERO - FAIL',0
szDbg5:  db 'DBG5: CreateMainWindow returned non-zero',0
szDbg5f: db 'DBG5F: CreateMainWindow returned ZERO - FAIL',0
szDbg6:  db 'DBG6: Entering message loop',0
szDbgT:  db 'AsmTaskMgr Debug',0

; ===========================================================================
;  WinMainCRTStartup  —  PE entry point
;  Windows calls this directly (subsystem:gui → no console).
; ===========================================================================
section .text

WinMainCRTStartup:
    push    rbp
    mov     rbp, rsp
    ; 1 push: RSP after push = orig_rsp - 16 (aligned). sub N must be divisible by 16.
    ; Layout: shadow(32) + ICCE(8) + pad(8) + MSG(48) = 96. 96/16=6 ✓
    sub     rsp, 96

    ; Stack layout:
    ;   [rsp+  0..31] shadow space
    ;   [rsp+ 32..39] INITCOMMONCONTROLSEX (8 bytes)
    ;   [rsp+ 40..47] scratch / padding
    ;   [rsp+ 48..95] MSG struct  (48 bytes)
    %define ICCE_FRAME  rsp+32
    %define MSG_FRAME   rsp+48

    ; -----------------------------------------------------------------------
    ; 1. Get module handle
    ; -----------------------------------------------------------------------
    xor     ecx, ecx
    call    GetModuleHandleA
    mov     [rel hInstance], rax

    ; --- DEBUG 1 ---
    xor     ecx, ecx
    lea     rdx, [rel szDbg1]
    lea     r8,  [rel szDbgT]
    mov     r9d, MB_OK
    call    MessageBoxA

    ; -----------------------------------------------------------------------
    ; 2. Check / acquire elevation
    ; -----------------------------------------------------------------------
    call    CheckElevation
    cmp     eax, 0xDEAD               ; sentinel: re-launched, exit this instance
    je      .exit_now
    ; If EAX == 0 (no elevation and ShellExecute failed), we proceed anyway

    ; --- DEBUG 2 ---
    xor     ecx, ecx
    lea     rdx, [rel szDbg2]
    lea     r8,  [rel szDbgT]
    mov     r9d, MB_OK
    call    MessageBoxA

    ; -----------------------------------------------------------------------
    ; 3. Acquire SeDebugPrivilege
    ; -----------------------------------------------------------------------
    call    AcquireDebugPrivilege
    ; Ignore failure (we try anyway)

    ; -----------------------------------------------------------------------
    ; 4. InitCommonControlsEx  (enables Common Controls v6 manifest)
    ; -----------------------------------------------------------------------
    mov     dword [ICCE_FRAME + ICCE_dwSize], 8
    mov     dword [ICCE_FRAME + ICCE_dwICC],  ICC_WIN95_CLASSES
    lea     rcx, [ICCE_FRAME]
    call    InitCommonControlsEx

    ; --- DEBUG 3 ---
    xor     ecx, ecx
    lea     rdx, [rel szDbg3]
    lea     r8,  [rel szDbgT]
    mov     r9d, MB_OK
    call    MessageBoxA

    ; -----------------------------------------------------------------------
    ; 5. Register window class
    ; -----------------------------------------------------------------------
    call    RegisterWindowClass
    test    eax, eax
    jnz     .regclass_ok

    ; --- DEBUG 4F: RegisterWindowClass failed ---
    xor     ecx, ecx
    lea     rdx, [rel szDbg4f]
    lea     r8,  [rel szDbgT]
    mov     r9d, MB_OK
    call    MessageBoxA
    jmp     .exit_now

.regclass_ok:
    ; --- DEBUG 4 ---
    xor     ecx, ecx
    lea     rdx, [rel szDbg4]
    lea     r8,  [rel szDbgT]
    mov     r9d, MB_OK
    call    MessageBoxA

    ; -----------------------------------------------------------------------
    ; 6. Create main window
    ; -----------------------------------------------------------------------
    call    CreateMainWindow
    test    rax, rax
    jnz     .createwnd_ok

    ; --- DEBUG 5F: CreateMainWindow failed ---
    xor     ecx, ecx
    lea     rdx, [rel szDbg5f]
    lea     r8,  [rel szDbgT]
    mov     r9d, MB_OK
    call    MessageBoxA
    jmp     .exit_now

.createwnd_ok:
    ; --- DEBUG 5 ---
    xor     ecx, ecx
    lea     rdx, [rel szDbg5]
    lea     r8,  [rel szDbgT]
    mov     r9d, MB_OK
    call    MessageBoxA

    ; --- DEBUG 6 ---
    xor     ecx, ecx
    lea     rdx, [rel szDbg6]
    lea     r8,  [rel szDbgT]
    mov     r9d, MB_OK
    call    MessageBoxA

    ; -----------------------------------------------------------------------
    ; 7. Message loop
    ; -----------------------------------------------------------------------
.msg_loop:
    ; GetMessageA(&msg, NULL, 0, 0)
    lea     rcx, [MSG_FRAME]
    xor     edx, edx
    xor     r8d, r8d
    xor     r9d, r9d
    call    GetMessageA
    test    eax, eax
    jz      .msg_done             ; WM_QUIT received
    cmp     eax, -1
    je      .msg_done             ; error

    ; TranslateMessage(&msg)
    lea     rcx, [MSG_FRAME]
    call    TranslateMessage

    ; DispatchMessageA(&msg)
    lea     rcx, [MSG_FRAME]
    call    DispatchMessageA

    jmp     .msg_loop

    ; -----------------------------------------------------------------------
    ; 8. Exit
    ; -----------------------------------------------------------------------
.msg_done:
    mov     ecx, [MSG_FRAME + MSG_wParam]   ; exit code (QWORD wParam, use low DWORD)
    jmp     .exit

.exit_now:
    xor     ecx, ecx

.exit:
    call    ExitProcess
    ; Never returns

    %undef ICCE_FRAME
    %undef MSG_FRAME
