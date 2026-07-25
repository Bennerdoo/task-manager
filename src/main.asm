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

; ===========================================================================
;  WinMainCRTStartup  —  PE entry point
;  Windows calls this directly (subsystem:gui → no console).
; ===========================================================================
section .text

WinMainCRTStartup:
    ; No callee-saved regs to save at the entry point.
    ; We MUST align RSP to 16 bytes. Upon entry RSP is 8-byte aligned
    ; (return address from OS was pushed before). Push a dummy value:
    push    rbp
    mov     rbp, rsp
    ; 1 push: RSP after push = orig_rsp - 16 (aligned). sub N must be divisible by 16.
    ; Layout: shadow(32) + ICCE(8) + pad(8) + MSG(48) = 96. 96/16=6 ✓
    sub     rsp, 96

    ; Stack layout:
    ;   [rsp+  0..31] shadow space
    ;   [rsp+ 32..39] INITCOMMONCONTROLSEX (8 bytes)
    ;   [rsp+ 40..87] scratch / alignment padding
    ;   [rsp+ 48..95] MSG struct  (48 bytes → [rsp+48..95])
    %define ICCE_FRAME  rsp+32
    %define MSG_FRAME   rsp+48

    ; -----------------------------------------------------------------------
    ; 1. Get module handle
    ; -----------------------------------------------------------------------
    xor     ecx, ecx
    call    GetModuleHandleA
    mov     [rel hInstance], rax

    ; -----------------------------------------------------------------------
    ; 2. Check / acquire elevation
    ; -----------------------------------------------------------------------
    call    CheckElevation
    cmp     eax, 0xDEAD               ; sentinel: re-launched, exit this instance
    je      .exit_now
    ; If EAX == 0 (no elevation and ShellExecute failed), we proceed anyway
    ; (might as well try – no harm in running without admin for listing)

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

    ; -----------------------------------------------------------------------
    ; 5. Register window class
    ; -----------------------------------------------------------------------
    call    RegisterWindowClass
    test    eax, eax
    jz      .exit_now

    ; -----------------------------------------------------------------------
    ; 6. Create main window
    ; -----------------------------------------------------------------------
    call    CreateMainWindow
    test    rax, rax
    jz      .exit_now

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
