; =============================================================================
;  window.asm  —  AsmTaskMgr
;  Window class registration, creation, and WndProc (dark-themed).
;  Assembled as: nasm -f win64 window.asm -o window.obj
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
;  Win32 / GDI imports
; ---------------------------------------------------------------------------
extern RegisterClassExA
extern CreateWindowExA
extern ShowWindow
extern UpdateWindow
extern DefWindowProcA
extern PostQuitMessage
extern BeginPaint
extern EndPaint
extern FillRect
extern MoveWindow
extern GetClientRect
extern SetTimer
extern KillTimer
extern CreateSolidBrush
extern DeleteObject
extern CreateFontA
extern SelectObject
extern SetBkColor
extern SetBkMode
extern SetTextColor
extern MessageBoxA
extern wsprintfA
extern SendMessageA
extern AppendMenuA
extern CreatePopupMenu
extern TrackPopupMenu
extern GetCursorPos
extern DestroyMenu
extern LoadCursorA
extern LoadIconA
extern GetSystemMetrics
extern SetWindowLongPtrA
extern GetWindowLongPtrA
extern InvalidateRect
extern SetPriorityClass
extern OpenProcess
extern CloseHandle
extern SetWindowTextA

; ---------------------------------------------------------------------------
;  External functions from other modules
; ---------------------------------------------------------------------------
extern EnumProcesses
extern RefreshListView
extern InitListView
extern GetSelectedPid
extern SortCompareProc
extern KillProcess
extern LoadKernelDriver
extern UnloadKernelDriver
extern AcquireDebugPrivilege

; ---------------------------------------------------------------------------
;  Globals from strings.asm
; ---------------------------------------------------------------------------
extern hInstance
extern hMainWnd
extern hListView
extern hStatusBar
extern hSearchEdit
extern hBgBrush
extern hRowAltBrush
extern hAccentBrush
extern hFont
extern hPopupMenu
extern sortColumn
extern sortAscending
extern selectedPid
extern clientWidth
extern clientHeight
extern minWidth
extern minHeight
extern searchFilter

extern szClassName
extern szWindowTitle
extern szStatusClass
extern szListViewClass
extern szEditClass
extern szFontName
extern szKillTitle
extern szKillFmt
extern szKillSystemFmt
extern szKillFailed
extern szKillFailTitle
extern szAboutTitle
extern szAboutText
extern szMsgBuf
extern cpuPercent
extern totalPhysKB
extern availPhysKB
extern hCpuVal
extern hMemVal
extern szGaugeBuf
extern szCpuColFmt
extern szMemColFmt
extern lvcBuf

; ---------------------------------------------------------------------------
;  Exports
; ---------------------------------------------------------------------------
global RegisterWindowClass
global CreateMainWindow
global WndProc

; ---------------------------------------------------------------------------
;  Constants
; ---------------------------------------------------------------------------
%define WS_OVERLAPPEDWINDOW   0x00CF0000
%define WS_CHILD              0x40000000
%define WS_VISIBLE            0x10000000
%define WS_CLIPSIBLINGS       0x04000000
%define WS_CLIPCHILDREN       0x02000000
%define WS_VSCROLL            0x00200000
%define WS_BORDER             0x00800000
%define WS_EX_CLIENTEDGE      0x00000200
%define WM_CREATE             0x0001
%define WM_DESTROY            0x0002
%define WM_SIZE               0x0005
%define WM_PAINT              0x000F
%define WM_ERASEBKGND         0x0014
%define WM_CLOSE              0x0010
%define WM_COMMAND            0x0111
%define WM_TIMER              0x0113
%define WM_NOTIFY             0x004E
%define WM_CONTEXTMENU        0x007B
%define WM_CTLCOLOREDIT       0x0133
%define WM_CTLCOLORSTATIC     0x0138
%define WM_CTLCOLORBTN        0x0135
%define WM_CTLCOLORLISTBOX    0x0132
%define WM_GETMINMAXINFO      0x0024
%define LVN_COLUMNCLICK       -108
%define LVN_ITEMCHANGED       -101
%define NM_DBLCLK             -3
%define NM_RCLICK             -5
%define IDT_REFRESH           1
%define REFRESH_INTERVAL_MS   2000
%define IDC_LISTVIEW          100
%define IDC_SEARCHEDIT        101
%define IDC_STATUSBAR         102
%define IDM_KILL              200
%define IDM_REFRESH           201
%define IDM_PRIORITY_HIGH     203
%define IDM_PRIORITY_NORMAL   205
%define IDM_PRIORITY_LOW      207
%define IDM_ABOUT             209
%define MB_OK                 0
%define MB_YESNO              4
%define MB_ICONWARNING        0x30
%define MB_ICONQUESTION       0x20
%define MB_ICONERROR          0x10
%define IDYES                 6
%define LVS_REPORT            0x0001
%define LVS_SHOWSELALWAYS     0x0008
%define LVS_SINGLESEL         0x0004
%define LVS_EX_FULLROWSELECT  0x00000020
%define LVM_SORTITEMS         0x1030
%define LVM_SORTITEMSEX       0x1051
%define SB_SETPARTS           0x0404
%define MF_STRING             0
%define MF_SEPARATOR          0x800
%define TPM_LEFTALIGN         0
%define TPM_RETURNCMD         0x100
%define EN_CHANGE             0x0300
%define COLOR_BG              0x0017110D
%define COLOR_TEXT            0x00D9D1C9
%define COLOR_ACCENT          0x00FFA658
%define COLOR_HEADER_BG       0x002D2621
%define TRANSPARENT           1
; --- ListView column indices (must match strings.asm) ---
%define COL_IDX              0
%define COL_PID              1
%define COL_NAME             2
%define COL_CPU              3
%define COL_MEM              4
%define COL_USER             5
%define SM_CXSCREEN           0
%define SM_CYSCREEN           1
%define FW_NORMAL             400
%define DEFAULT_CHARSET       1
%define OUT_DEFAULT_PRECIS    0
%define CLIP_DEFAULT_PRECIS   0
%define CLEARTYPE_QUALITY     5
%define VARIABLE_PITCH        2
%define FF_SWISS              0x20
%define PROCESS_ALL_ACCESS    0x001FFFFF
%define HIGH_PRIORITY_CLASS   0x00000080
%define NORMAL_PRIORITY_CLASS 0x00000020
%define IDLE_PRIORITY_CLASS   0x00000040

; WNDCLASSEXA offsets (64-bit, total 80 bytes)
%define WCEX_cbSize          0
%define WCEX_style           4
%define WCEX_lpfnWndProc     8
%define WCEX_cbClsExtra      16
%define WCEX_cbWndExtra      20
%define WCEX_hInstance       24
%define WCEX_hIcon           32
%define WCEX_hCursor         40
%define WCEX_hbrBackground   48
%define WCEX_lpszMenuName    56
%define WCEX_lpszClassName   64
%define WCEX_hIconSm         72
%define WCEX_SIZEOF          80

; RECT offsets
%define RECT_left   0
%define RECT_top    4
%define RECT_right  8
%define RECT_bottom 12
%define RECT_SIZEOF 16

; PAINTSTRUCT offsets (64-bit, 64 bytes approx)
%define PS_hdc         0
%define PS_fErase      8
%define PS_rcPaint     12    ; RECT (16 bytes)
%define PS_SIZEOF      64

; NMHDR offsets
%define NMHDR_hwndFrom  0
%define NMHDR_idFrom    8
%define NMHDR_code      16   ; (but stored as INT, so 4 bytes)

; NMLISTVIEW offsets (from WM_NOTIFY LPARAM)
%define NMLV_hdr        0    ; NMHDR (24 bytes on x64: hwndFrom(8)+idFrom(8)+code(4)+pad(4))
%define NMLV_iItem      24
%define NMLV_iSubItem   28
%define NMLV_uNewState  32
%define NMLV_iColumn    80   ; for LVN_COLUMNCLICK: iSubItem in NM_LISTVIEW

; MINMAXINFO offsets
%define MMI_ptReserved    0
%define MMI_ptMaxSize     8
%define MMI_ptMaxPosition 16
%define MMI_ptMinTrackSize 24
%define MMI_ptMaxTrackSize 32

; POINT size = 8 bytes (two DWORDs)

; ---------------------------------------------------------------------------
section .data

szLVStyle:      db 'SysListView32', 0
szStaticBar:    db 'msctls_statusbar32', 0
szEditCtl:      db 'EDIT', 0
szFilterPH:     db 'Filter...', 0

szPriorityHigh:  db 'Set High Priority', 0
szPriorityNorm:  db 'Set Normal Priority', 0
szPriorityIdle:  db 'Set Idle Priority', 0
szKillText:      db 'Kill Process', 0
szRefreshText:   db 'Refresh Now', 0
szAboutMenuText: db 'About', 0

; Debug strings
szWC_A:  db 'WC-A: Font created',0
szWC_B:  db 'WC-B: ListView created',0
szWC_C:  db 'WC-C: Controls done',0
szWC_D:  db 'WC-D: Menus done',0
szWC_E:  db 'WC-E: Before LoadKernelDriver',0
szWC_F:  db 'WC-F: After LoadKernelDriver',0
szWC_G:  db 'WC-G: Before EnumProcesses',0
szWC_H:  db 'WC-H: After RefreshListView',0
szWC_I:  db 'WC-I: WM_CREATE done',0
szWC_T:  db 'WM_CREATE Debug',0

; Window initial size
INIT_WIDTH    equ 900
INIT_HEIGHT   equ 600
TOOLBAR_H     equ 32
STATUSBAR_H   equ 22

; LVCOLUMNA offsets (x64 struct)
%define LVCF_TEXT       0x0004
%define LVC_mask        0
%define LVC_fmt         4
%define LVC_cx          8
%define LVC_pszText     16     ; pointer at offset 16 (4 bytes pad after cx)
%define LVC_cchTextMax  24
%define LVC_SIZEOF      40
%define LVM_SETCOLUMNA  0x101A ; LVM_FIRST + 26

; ---------------------------------------------------------------------------
section .text

; ===========================================================================
;  RegisterWindowClass
;  Registers the main window class.
;  Returns: EAX = non-zero on success.
; ===========================================================================
RegisterWindowClass:
    push    rbx
    ; 1 push + 8 ret = 16. RSP after push = caller_rsp - 16 (ALIGNED).
    ; sub N divisible by 16: shadow(32)+WNDCLASSEXA(80) = 112. 112/16=7 ✓
    sub     rsp, 112

    %define WCX  rsp+32

    ; Zero out all 80 bytes of WNDCLASSEXA struct
    lea     rdi, [WCX]
    xor     eax, eax
    mov     ecx, 10             ; 10 qwords = 80 bytes
    rep stosq

    ; Fill struct fields
    mov     dword [WCX + WCEX_cbSize], 80
    mov     dword [WCX + WCEX_style],  0x0003   ; CS_HREDRAW | CS_VREDRAW
    lea     rax, [rel WndProc]
    mov     [WCX + WCEX_lpfnWndProc],  rax
    mov     rax, [rel hInstance]
    mov     [WCX + WCEX_hInstance],    rax

    ; Cursor = IDC_ARROW (32512)
    xor     ecx, ecx
    mov     edx, 32512
    call    LoadCursorA
    mov     [WCX + WCEX_hCursor],      rax

    ; Background = dark brush (crColor passed in RCX for 1st param)
    mov     ecx, COLOR_BG
    call    CreateSolidBrush
    mov     [rel hBgBrush],            rax
    mov     [WCX + WCEX_hbrBackground], rax

    lea     rax, [rel szClassName]
    mov     [WCX + WCEX_lpszClassName], rax

    lea     rcx, [WCX]
    call    RegisterClassExA

    add     rsp, 112
    pop     rbx
    ret
    %undef WCX

; ===========================================================================
;  CreateMainWindow
;  Creates and shows the main application window.
;  Returns: HWND in RAX, or 0 on failure.
; ===========================================================================
CreateMainWindow:
    push    rbx
    ; 1 push + 8 ret = 16. RSP after push = caller_rsp - 16 (ALIGNED).
    ; sub N divisible by 16: shadow(32) + 8 stack args for CreateWindowExA(64) = 96. 96/16=6 ✓
    sub     rsp, 96

    ; Get screen center for placement
    mov     ecx, SM_CXSCREEN
    call    GetSystemMetrics
    mov     ebx, eax
    sub     ebx, INIT_WIDTH
    sar     ebx, 1           ; x = (screenW - INIT_WIDTH) / 2

    ; CreateWindowExA(0, szClassName, szWindowTitle, WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN,
    ;                 x, y, INIT_WIDTH, INIT_HEIGHT, NULL, NULL, hInstance, NULL)
    xor     ecx, ecx                               ; dwExStyle
    lea     rdx, [rel szClassName]
    lea     r8,  [rel szWindowTitle]
    mov     r9d, (WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN | WS_VISIBLE)
    ; 5th+ args on stack (8 args = 64 bytes space, set as clean QWORDs)
    movsxd  rax, ebx
    mov     [rsp+32], rax                          ; x
    mov     qword [rsp+40], 100                    ; y
    mov     qword [rsp+48], INIT_WIDTH             ; nWidth
    mov     qword [rsp+56], INIT_HEIGHT            ; nHeight
    mov     qword [rsp+64], 0                      ; hwndParent
    mov     qword [rsp+72], 0                      ; hmenu
    mov     rax, [rel hInstance]
    mov     [rsp+80], rax
    mov     qword [rsp+88], 0                      ; lpParam
    call    CreateWindowExA

    mov     [rel hMainWnd], rax
    test    rax, rax
    jz      .fail

    ; Show and update window
    mov     rcx, rax
    mov     edx, 1                                 ; SW_SHOWNORMAL
    call    ShowWindow

    mov     rcx, [rel hMainWnd]
    call    UpdateWindow

    mov     rax, [rel hMainWnd]

.fail:
    add     rsp, 96
    pop     rbx
    ret

; ===========================================================================
;  WndProc
;  Main window procedure.
;  In: RCX=hWnd, RDX=uMsg, R8=wParam, R9=lParam
; ===========================================================================
WndProc:
    push    rbp
    push    rbx
    push    rsi
    push    rdi
    push    r15
    ; 5 pushes + 8 ret = 48. RSP after pushes = caller - 48 (ALIGNED: 48/16=3).
    ; sub N divisible by 16.
    ; CreateFontA has 14 args: args 5-14 need [rsp+32..111] = 80 bytes
    ; LOC_* must be above [rsp+111] to avoid clobbering.
    ; Layout: shadow(32) + arg_spill_5_14(80) + LOC_*(48) + pad(16) = 176. 176/16=11 ✓
    sub     rsp, 176

    ; Locals: [rsp+112..175]
    %define LOC_HWND   rsp+112    ; QWORD: original hWnd
    %define LOC_MSG    rsp+120    ; DWORD: uMsg
    %define LOC_WP     rsp+128    ; QWORD: wParam
    %define LOC_LP     rsp+136    ; QWORD: lParam
    %define LOC_RECT   rsp+144    ; RECT  (16 bytes @ [144..159])
    %define LOC_PS     rsp+160    ; PAINTSTRUCT hdc only (8 bytes @ [160..167])

    mov     [LOC_HWND], rcx
    mov     [LOC_MSG],  edx
    mov     [LOC_WP],   r8
    mov     [LOC_LP],   r9

    mov     rbp, rcx               ; rbp = hWnd
    mov     ebx, edx               ; ebx = uMsg
    mov     r15, r8                ; r15 = wParam
    mov     rdi, r9                ; rdi = lParam

    ; --- Dispatch ---
    cmp     ebx, WM_CREATE
    je      .on_create
    cmp     ebx, WM_DESTROY
    je      .on_destroy
    cmp     ebx, WM_SIZE
    je      .on_size
    cmp     ebx, WM_ERASEBKGND
    je      .on_erasebkg
    cmp     ebx, WM_TIMER
    je      .on_timer
    cmp     ebx, WM_NOTIFY
    je      .on_notify
    cmp     ebx, WM_COMMAND
    je      .on_command
    cmp     ebx, WM_CONTEXTMENU
    je      .on_contextmenu
    cmp     ebx, WM_GETMINMAXINFO
    je      .on_minmax
    cmp     ebx, WM_CTLCOLOREDIT
    je      .on_ctlcolor
    cmp     ebx, WM_CTLCOLORSTATIC
    je      .on_ctlcolor
    cmp     ebx, WM_CLOSE
    je      .on_close
    jmp     .defwnd

; ===================== WM_CREATE =============================================
.on_create:
    ; --- Create custom font (Segoe UI, 14pt) ---
    xor     ecx, ecx
    mov     ecx, -14               ; nHeight (negative = char height)
    xor     edx, edx               ; nWidth
    xor     r8d, r8d               ; nEscapement
    xor     r9d, r9d               ; nOrientation
    mov     qword [rsp+32], FW_NORMAL
    mov     qword [rsp+40], 0     ; bItalic
    mov     qword [rsp+48], 0     ; bUnderline
    mov     qword [rsp+56], 0     ; bStrikeOut
    mov     qword [rsp+64], DEFAULT_CHARSET
    mov     qword [rsp+72], OUT_DEFAULT_PRECIS
    mov     qword [rsp+80], CLIP_DEFAULT_PRECIS
    mov     qword [rsp+88], CLEARTYPE_QUALITY
    mov     qword [rsp+96], (VARIABLE_PITCH | FF_SWISS)
    lea     rax, [rel szFontName]
    mov     [rsp+104], rax
    call    CreateFontA
    mov     [rel hFont], rax

    ; --- Create ListView ---
    mov     ecx, WS_EX_CLIENTEDGE
    lea     rdx, [rel szLVStyle]
    xor     r8d, r8d               ; window title (none)
    mov     r9d, (WS_CHILD | WS_VISIBLE | LVS_REPORT | LVS_SHOWSELALWAYS | LVS_SINGLESEL)
    mov     qword [rsp+32], TOOLBAR_H   ; x
    mov     qword [rsp+40], TOOLBAR_H   ; y
    mov     qword [rsp+48], 600         ; w (will resize)
    mov     qword [rsp+56], 500         ; h (will resize)
    mov     [rsp+64], rbp              ; parent = our hwnd
    mov     qword [rsp+72], IDC_LISTVIEW ; hMenu = control ID
    mov     rax, [rel hInstance]
    mov     [rsp+80], rax
    mov     qword [rsp+88], 0
    call    CreateWindowExA
    mov     [rel hListView], rax

    ; Set font on listview
    mov     rcx, rax
    mov     edx, 0x0030             ; WM_SETFONT
    mov     r8,  [rel hFont]
    mov     r9d, 1
    call    SendMessageA

    call    InitListView

    ; --- Create search Edit ---
    xor     ecx, ecx
    lea     rdx, [rel szEditCtl]
    xor     r8d, r8d
    mov     r9d, (WS_CHILD | WS_VISIBLE | WS_BORDER)
    mov     qword [rsp+32], 0
    mov     qword [rsp+40], 0
    mov     qword [rsp+48], 200
    mov     qword [rsp+56], TOOLBAR_H
    mov     [rsp+64], rbp
    mov     qword [rsp+72], IDC_SEARCHEDIT
    mov     rax, [rel hInstance]
    mov     [rsp+80], rax
    mov     qword [rsp+88], 0
    call    CreateWindowExA
    mov     [rel hSearchEdit], rax
    ; Set font
    mov     rcx, rax
    mov     edx, 0x0030
    mov     r8,  [rel hFont]
    mov     r9d, 1
    call    SendMessageA
    ; Set placeholder text (Windows 6.0+ EM_SETCUEBANNER)
    mov     rcx, [rel hSearchEdit]
    mov     edx, 0x1501               ; EM_SETCUEBANNER
    mov     r8d, 0
    lea     r9,  [rel szFilterPH]
    call    SendMessageA

    ; --- Create status bar ---
    xor     ecx, ecx
    lea     rdx, [rel szStaticBar]
    xor     r8d, r8d
    mov     r9d, (WS_CHILD | WS_VISIBLE)
    mov     qword [rsp+32], 0
    mov     qword [rsp+40], 0
    mov     qword [rsp+48], 0        ; status bar auto-sizes width
    mov     qword [rsp+56], 0
    mov     [rsp+64], rbp
    mov     qword [rsp+72], IDC_STATUSBAR
    mov     rax, [rel hInstance]
    mov     [rsp+80], rax
    mov     qword [rsp+88], 0
    call    CreateWindowExA
    mov     [rel hStatusBar], rax
    mov     rcx, rax
    mov     edx, 0x0030
    mov     r8, [rel hFont]
    mov     r9d, 1
    call    SendMessageA

    ; --- Create context menu ---
    call    CreatePopupMenu
    mov     [rel hPopupMenu], rax
    mov     rbx, rax
    ; AppendMenuA(hMenu, MF_STRING, IDM_KILL, "Kill Process")
    mov     rcx, rbx
    mov     edx, MF_STRING
    mov     r8d, IDM_KILL
    lea     r9, [rel szKillText]
    call    AppendMenuA
    ; Separator
    mov     rcx, rbx
    mov     edx, MF_SEPARATOR
    xor     r8d, r8d
    xor     r9d, r9d
    call    AppendMenuA
    ; Set Priority High
    mov     rcx, rbx
    mov     edx, MF_STRING
    mov     r8d, IDM_PRIORITY_HIGH
    lea     r9, [rel szPriorityHigh]
    call    AppendMenuA
    ; Set Priority Normal
    mov     rcx, rbx
    mov     edx, MF_STRING
    mov     r8d, IDM_PRIORITY_NORMAL
    lea     r9, [rel szPriorityNorm]
    call    AppendMenuA
    ; Set Priority Idle
    mov     rcx, rbx
    mov     edx, MF_STRING
    mov     r8d, IDM_PRIORITY_LOW
    lea     r9, [rel szPriorityIdle]
    call    AppendMenuA
    ; Separator
    mov     rcx, rbx
    mov     edx, MF_SEPARATOR
    xor     r8d, r8d
    xor     r9d, r9d
    call    AppendMenuA
    ; Refresh
    mov     rcx, rbx
    mov     edx, MF_STRING
    mov     r8d, IDM_REFRESH
    lea     r9, [rel szRefreshText]
    call    AppendMenuA
    ; About
    mov     rcx, rbx
    mov     edx, MF_STRING
    mov     r8d, IDM_ABOUT
    lea     r9, [rel szAboutMenuText]
    call    AppendMenuA

    ; --- Load kernel driver ---
    call    LoadKernelDriver

    ; --- Initial process enumeration ---
    call    EnumProcesses
    call    RefreshListView

    ; --- Set minimum window size ---
    mov     dword [rel minWidth],  700
    mov     dword [rel minHeight], 400

    ; --- Set 2-second refresh timer ---
    mov     rcx, rbp
    mov     edx, IDT_REFRESH
    mov     r8d, REFRESH_INTERVAL_MS
    xor     r9d, r9d
    call    SetTimer

    xor     eax, eax               ; return 0 = handled
    jmp     .epilog

; ===================== WM_DESTROY ============================================
.on_destroy:
    mov     rcx, rbp
    mov     edx, IDT_REFRESH
    call    KillTimer

    call    UnloadKernelDriver

    mov     rcx, [rel hBgBrush]
    test    rcx, rcx
    jz      .no_del_brush
    call    DeleteObject
.no_del_brush:
    mov     rcx, [rel hFont]
    test    rcx, rcx
    jz      .no_del_font
    call    DeleteObject
.no_del_font:
    mov     rcx, [rel hPopupMenu]
    test    rcx, rcx
    jz      .no_del_menu
    call    DestroyMenu
.no_del_menu:

    xor     ecx, ecx
    call    PostQuitMessage
    xor     eax, eax
    jmp     .epilog

; ===================== WM_CLOSE ===============================================
.on_close:
    ; Allow default processing (sends WM_DESTROY)
    jmp     .defwnd

; ===================== WM_ERASEBKGND =========================================
.on_erasebkg:
    ; Fill with dark background
    mov     rcx, r15                   ; wParam = HDC
    lea     rdx, [LOC_RECT]
    xor     eax, eax
    mov     dword [LOC_RECT+RECT_left],   eax
    mov     dword [LOC_RECT+RECT_top],    eax
    mov     eax, [rel clientWidth]
    mov     dword [LOC_RECT+RECT_right],  eax
    mov     eax, [rel clientHeight]
    mov     dword [LOC_RECT+RECT_bottom], eax
    mov     r8, [rel hBgBrush]
    call    FillRect
    mov     eax, 1
    jmp     .epilog

; ===================== WM_SIZE ===============================================
.on_size:
    ; lParam low word = new width, high word = new height
    mov     eax, edi                   ; edi = lParam
    movzx   ecx, ax                    ; ecx = new width
    shr     eax, 16
    movzx   edx, ax                    ; edx = new height
    mov     [rel clientWidth],  ecx
    mov     [rel clientHeight], edx

    ; Edit box: top-left, full toolbar height, 220px wide
    mov     rcx, [rel hSearchEdit]
    xor     edx, edx                   ; x = 0
    xor     r8d, r8d                   ; y = 0
    mov     r9d, 220                   ; w = 220
    mov     dword [rsp+32], TOOLBAR_H  ; h = TOOLBAR_H
    mov     dword [rsp+40], 1
    call    MoveWindow

    ; ListView: below toolbar, above status bar
    mov     ecx, [rel clientWidth]
    mov     edx, [rel clientHeight]
    sub     edx, TOOLBAR_H
    sub     edx, STATUSBAR_H

    mov     rcx, [rel hListView]
    xor     edx, edx                   ; x = 0
    mov     r8d, TOOLBAR_H             ; y = toolbar height
    mov     r9d, [rel clientWidth]     ; w = full width
    mov     dword [rsp+32], edx        ; h = clientH - toolbar - statusbar (pre-calc in edx? no, recalc)
    ; Recalc h
    mov     eax, [rel clientHeight]
    sub     eax, TOOLBAR_H
    sub     eax, STATUSBAR_H
    mov     dword [rsp+32], eax
    mov     dword [rsp+40], 1
    call    MoveWindow

    ; Status bar: pin to bottom; send WM_SIZE to auto-resize it
    mov     rcx, [rel hStatusBar]
    mov     edx, WM_SIZE
    xor     r8d, r8d
    xor     r9d, r9d
    call    SendMessageA

    xor     eax, eax
    jmp     .epilog

; ===================== WM_TIMER ===============================================
.on_timer:
    cmp     r15d, IDT_REFRESH
    jne     .defwnd

    ; Check if search filter changed
    mov     rcx, [rel hSearchEdit]
    mov     edx, 0x000D               ; WM_GETTEXT
    mov     r8d, 256
    lea     r9, [rel searchFilter]
    call    SendMessageA

    call    EnumProcesses
    call    RefreshListView

    ; --- Update column headers with live CPU% and Memory% ---
    ; Use szGaugeBuf as temp, lvcBuf as LVCOLUMNA struct (zeroed via bss)
    ; Column 3 (CPU%): format "CPU %  NN%" into header
    lea     rcx, [rel szGaugeBuf]
    lea     rdx, [rel szCpuColFmt]
    mov     r8d, [rel cpuPercent]
    call    wsprintfA
    ; Set up LVCOLUMNA: only mask + pszText
    mov     dword [rel lvcBuf + LVC_mask], LVCF_TEXT
    lea     rax, [rel szGaugeBuf]
    mov     [rel lvcBuf + LVC_pszText], rax
    mov     rcx, [rel hListView]
    mov     edx, LVM_SETCOLUMNA
    mov     r8d, COL_CPU               ; column index 3
    lea     r9, [rel lvcBuf]
    call    SendMessageA

    ; Column 4 (Memory%): compute mem% and format
    mov     rax, [rel totalPhysKB]
    test    rax, rax
    jz      .col_mem_zero
    mov     rcx, rax                   ; rcx = totalPhysKB
    sub     rax, [rel availPhysKB]     ; rax = usedKB
    imul    rax, 100
    xor     rdx, rdx
    div     rcx                        ; rax = mem%
    cmp     rax, 100
    jbe     .col_mem_ok
    mov     rax, 100
.col_mem_ok:
    mov     r8d, eax
    jmp     .col_mem_fmt
.col_mem_zero:
    xor     r8d, r8d
.col_mem_fmt:
    lea     rcx, [rel szGaugeBuf]
    lea     rdx, [rel szMemColFmt]
    call    wsprintfA
    mov     dword [rel lvcBuf + LVC_mask], LVCF_TEXT
    lea     rax, [rel szGaugeBuf]
    mov     [rel lvcBuf + LVC_pszText], rax
    mov     rcx, [rel hListView]
    mov     edx, LVM_SETCOLUMNA
    mov     r8d, COL_MEM               ; column index 4
    lea     r9, [rel lvcBuf]
    call    SendMessageA

    xor     eax, eax
    jmp     .epilog

; ===================== WM_NOTIFY =============================================
.on_notify:
    ; lParam = LPNMHDR
    ; NMHDR: hwndFrom(8), idFrom(8), code(INT=4)
    mov     rsi, rdi               ; rsi = LPNMHDR (lParam)
    mov     ecx, dword [rsi + 16]  ; code (INT at NMHDR+16)
    ; Note: on x64, NMHDR is hwndFrom(8) + idFrom(8) + code(4) = offsets 0,8,16

    cmp     ecx, LVN_COLUMNCLICK
    je      .on_col_click

    cmp     ecx, NM_DBLCLK
    je      .on_dblclick

    cmp     ecx, NM_RCLICK
    je      .on_rclick

    jmp     .defwnd

.on_col_click:
    ; NMLISTVIEW: hdr(24 bytes? on x64) + iItem(4) + iSubItem(4) + ... + iColumn = need offset
    ; NM_LISTVIEW for LVN_COLUMNCLICK stores the column in iSubItem at offset:
    ; NMHDR = hwndFrom(8) + idFrom(8) + code(4) + pad(4) = 24 bytes
    ; Then iItem(4) at +24, iSubItem(4) at +28
    mov     ecx, dword [rsi + 28]   ; iSubItem = clicked column
    ; Toggle sort direction if same column
    cmp     ecx, [rel sortColumn]
    jne     .new_col
    xor     dword [rel sortAscending], 1   ; toggle
    jmp     .do_sort
.new_col:
    mov     [rel sortColumn], ecx
    mov     dword [rel sortAscending], 1   ; default ascending
.do_sort:
    ; LVM_SORTITEMS passes stored lParam (PROC_ENTRY*) to comparator — correct.
    ; LVM_SORTITEMSEX passes item *indices*, which SortCompareProc would
    ; dereference as pointers → crash.
    mov     rcx, [rel hListView]
    mov     edx, LVM_SORTITEMS
    lea     r8, [rel SortCompareProc]
    mov     r9d, [rel sortColumn]
    call    SendMessageA
    ; Repopulate with fresh lParam pointers from current procTable.
    ; This also prevents stale-pointer crashes if procTable was reallocated
    ; between the last timer tick and this column click.
    call    RefreshListView
    xor     eax, eax
    jmp     .epilog

.on_dblclick:
    ; Double-click = kill selected process
    call    GetSelectedPid
    test    eax, eax
    jz      .defwnd
    jmp     .do_kill_id   ; eax = pid

.on_rclick:
    xor     eax, eax
    jmp     .epilog

; ===================== WM_CONTEXTMENU ========================================
.on_contextmenu:
    ; Show popup at cursor position
    ; lParam = MAKELPARAM(x, y)
    mov     eax, edi               ; edi = lParam
    movsx   ecx, ax
    sar     eax, 16
    movsx   edx, ax

    ; TrackPopupMenu(hPopupMenu, TPM_LEFTALIGN|TPM_RETURNCMD, x, y, 0, hWnd, NULL)
    mov     rcx, [rel hPopupMenu]
    mov     edx, (TPM_LEFTALIGN | TPM_RETURNCMD)
    ; x from lParam low word, y from high word
    mov     r8d, dword [LOC_LP]    ; restore lParam
    movsx   r9d, r8w               ; x
    sar     r8d, 16
    movsx   r8d, r8w               ; y
    ; Actually TrackPopupMenu(hMenu, uFlags, x, y, nReserved, hWnd, NULL)
    ; Args 5-7 on stack
    ; rcx=hMenu, edx=flags, r8d=x, r9d=y
    ; Wait - I have the args wrong. Let me fix:
    mov     rax, [LOC_LP]
    movsx   r8d, ax                ; x = LOWORD(lParam)
    sar     eax, 16
    movsx   r9d, ax               ; y = HIWORD(lParam)
    mov     rcx, [rel hPopupMenu]
    mov     edx, (TPM_LEFTALIGN | TPM_RETURNCMD)
    ; Swap: TrackPopupMenu(hMenu, flags, x, y, ...) → rcx=hMenu, edx=flags, r8d=x, r9d=y
    ; But I now have x in r8 and y in r9. Correct!
    mov     dword [rsp+32], 0     ; nReserved
    mov     [rsp+40], rbp         ; hWnd
    mov     qword [rsp+48], 0     ; prcRect = NULL
    call    TrackPopupMenu
    ; rax = selected command ID (because TPM_RETURNCMD)
    test    eax, eax
    jz      .epilog
    ; Dispatch: simulate WM_COMMAND
    mov     r15d, eax             ; r15 = command id
    jmp     .cmd_dispatch

; ===================== WM_COMMAND ============================================
.on_command:
    movzx   r15d, r15w            ; low word of wParam = command ID
.cmd_dispatch:
    cmp     r15d, IDM_KILL
    je      .cmd_kill
    cmp     r15d, IDM_REFRESH
    je      .cmd_refresh
    cmp     r15d, IDM_PRIORITY_HIGH
    je      .cmd_priority_high
    cmp     r15d, IDM_PRIORITY_NORMAL
    je      .cmd_priority_normal
    cmp     r15d, IDM_PRIORITY_LOW
    je      .cmd_priority_idle
    cmp     r15d, IDM_ABOUT
    je      .cmd_about
    ; Check EN_CHANGE from search edit
    mov     eax, [LOC_WP]
    shr     eax, 16               ; HIWORD(wParam) = notification code
    cmp     eax, EN_CHANGE
    je      .cmd_filter_change
    jmp     .defwnd

.cmd_kill:
    call    GetSelectedPid
    test    eax, eax
    jz      .epilog
.do_kill_id:
    mov     rbx, rax              ; save pid

    ; Confirm kill
    lea     rcx, [rel szMsgBuf]
    lea     rdx, [rel szKillFmt]
    ; We'd need the process name too — for now just show PID
    mov     r8d, ebx
    call    wsprintfA
    xor     ecx, ecx
    lea     rdx, [rel szMsgBuf]
    lea     r8, [rel szKillTitle]
    mov     r9d, (MB_YESNO | MB_ICONWARNING)
    call    MessageBoxA
    cmp     eax, IDYES
    jne     .epilog

    ; Call KillProcess
    mov     ecx, ebx             ; pid
    call    KillProcess
    test    eax, eax
    jnz     .kill_failed
    ; Success: refresh immediately
    call    EnumProcesses
    call    RefreshListView
    jmp     .epilog

.kill_failed:
    xor     ecx, ecx
    lea     rdx, [rel szKillFailed]
    lea     r8, [rel szKillFailTitle]
    mov     r9d, (MB_OK | MB_ICONERROR)
    call    MessageBoxA
    jmp     .epilog

.cmd_refresh:
    call    EnumProcesses
    call    RefreshListView
    jmp     .epilog

.cmd_priority_high:
    call    GetSelectedPid
    test    eax, eax
    jz      .epilog
    mov     ebx, eax
    mov     ecx, PROCESS_ALL_ACCESS
    xor     edx, edx
    mov     r8d, ebx
    call    OpenProcess
    test    rax, rax
    jz      .epilog
    mov     rbx, rax
    mov     rcx, rbx
    mov     edx, HIGH_PRIORITY_CLASS
    call    SetPriorityClass
    mov     rcx, rbx
    call    CloseHandle
    jmp     .epilog

.cmd_priority_normal:
    call    GetSelectedPid
    test    eax, eax
    jz      .epilog
    mov     ebx, eax
    mov     ecx, PROCESS_ALL_ACCESS
    xor     edx, edx
    mov     r8d, ebx
    call    OpenProcess
    test    rax, rax
    jz      .epilog
    mov     rbx, rax
    mov     rcx, rbx
    mov     edx, NORMAL_PRIORITY_CLASS
    call    SetPriorityClass
    mov     rcx, rbx
    call    CloseHandle
    jmp     .epilog

.cmd_priority_idle:
    call    GetSelectedPid
    test    eax, eax
    jz      .epilog
    mov     ebx, eax
    mov     ecx, PROCESS_ALL_ACCESS
    xor     edx, edx
    mov     r8d, ebx
    call    OpenProcess
    test    rax, rax
    jz      .epilog
    mov     rbx, rax
    mov     rcx, rbx
    mov     edx, IDLE_PRIORITY_CLASS
    call    SetPriorityClass
    mov     rcx, rbx
    call    CloseHandle
    jmp     .epilog

.cmd_about:
    xor     ecx, ecx
    lea     rdx, [rel szAboutText]
    lea     r8, [rel szAboutTitle]
    mov     r9d, (MB_OK)
    call    MessageBoxA
    jmp     .epilog

.cmd_filter_change:
    call    EnumProcesses
    call    RefreshListView
    jmp     .epilog

; ===================== WM_GETMINMAXINFO ======================================
.on_minmax:
    ; lParam = LPMINMAXINFO
    mov     rax, rdi              ; rdi = LPMINMAXINFO
    ; Set minimum tracking size (offset 24 = ptMinTrackSize)
    mov     dword [rax + 24], 700  ; minX
    mov     dword [rax + 28], 400  ; minY
    xor     eax, eax
    jmp     .epilog

; ===================== WM_CTLCOLOR* ==========================================
.on_ctlcolor:
    ; wParam = HDC, lParam = control HWND
    ; Set dark background and text color on the DC
    mov     rcx, r15              ; HDC
    mov     edx, COLOR_BG
    call    SetBkColor
    mov     rcx, r15
    mov     edx, COLOR_TEXT
    call    SetTextColor
    mov     rcx, r15
    mov     edx, TRANSPARENT
    call    SetBkMode
    mov     rax, [rel hBgBrush]   ; return background brush
    jmp     .epilog

; ===================== DEFAULT ===============================================
.defwnd:
    mov     rcx, [LOC_HWND]
    mov     edx, [LOC_MSG]
    mov     r8,  [LOC_WP]
    mov     r9,  [LOC_LP]
    call    DefWindowProcA
    jmp     .epilog

.epilog:
    add     rsp, 176
    pop     r15
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

    %undef LOC_HWND
    %undef LOC_MSG
    %undef LOC_WP
    %undef LOC_LP
    %undef LOC_RECT
    %undef LOC_PS
