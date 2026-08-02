; =============================================================================
;  strings.asm  —  AsmTaskMgr
;  All global data, BSS variables, and shared constants.
;  Assembled as: nasm -f win64 strings.asm -o strings.obj
; =============================================================================

bits 64
default rel

; ===========================================================================
;  CONSTANTS  (use %define so other files can include this header style via
;              %include or just know the values as equates)
; ===========================================================================

; --- Window / Control IDs ---
%define IDT_REFRESH          1
%define IDC_LISTVIEW         100
%define IDC_SEARCHEDIT       101
%define IDC_STATUSBAR        102

; --- Menu / Command IDs ---
%define IDM_KILL             200
%define IDM_REFRESH          201
%define IDM_PRIORITY_REALTIME 202
%define IDM_PRIORITY_HIGH    203
%define IDM_PRIORITY_ABOVENORMAL 204
%define IDM_PRIORITY_NORMAL  205
%define IDM_PRIORITY_BELOW   206
%define IDM_PRIORITY_IDLE    207
%define IDM_OPEN_LOCATION    208
%define IDM_ABOUT            209

; --- Refresh interval (ms) ---
%define REFRESH_INTERVAL_MS  2000

; --- IOCTL code for kernel driver kill ---
;     CTL_CODE(FILE_DEVICE_UNKNOWN=0x22, 0x800, METHOD_BUFFERED=0, FILE_ANY_ACCESS=0)
;     = ((0x22) << 16) | ((0) << 14) | ((0x800) << 2) | (0)
;     = 0x00220000 | 0x00002000 = 0x00222000
%define IOCTL_KILL_PROCESS   0x00222000

; --- Dark theme COLORREF values (0x00BBGGRR) ---
%define COLOR_BG             0x0017110D   ; #0D1117  background
%define COLOR_ROW_ALT        0x00221B16   ; #161B22  alternating row
%define COLOR_TEXT           0x00D9D1C9   ; #C9D1D9  primary text
%define COLOR_ACCENT         0x00FFA658   ; #58A6FF  accent (blue)
%define COLOR_HEADER_BG      0x002D2621   ; #21262D  header/statusbar bg
%define COLOR_BORDER         0x00302A21   ; border line
%define COLOR_SEL_BG         0x00491A0F   ; #0F1A49  selected row bg
%define COLOR_SEL_TEXT       0x00FFFFE0   ; selected row text

; --- Win32 Window Styles ---
%define WS_OVERLAPPEDWINDOW  0x00CF0000
%define WS_CHILD             0x40000000
%define WS_VISIBLE           0x10000000
%define WS_CLIPSIBLINGS      0x04000000
%define WS_CLIPCHILDREN      0x02000000
%define WS_VSCROLL           0x00200000
%define WS_HSCROLL           0x00100000
%define WS_BORDER            0x00800000

; --- Extended Window Styles ---
%define WS_EX_CLIENTEDGE     0x00000200
%define WS_EX_TOOLWINDOW     0x00000080
%define WS_EX_APPWINDOW      0x00040000

; --- Win32 Messages ---
%define WM_CREATE            0x0001
%define WM_DESTROY           0x0002
%define WM_SIZE              0x0005
%define WM_ACTIVATE          0x0006
%define WM_PAINT             0x000F
%define WM_ERASEBKGND        0x0014
%define WM_CLOSE             0x0010
%define WM_COMMAND           0x0111
%define WM_TIMER             0x0113
%define WM_NOTIFY            0x004E
%define WM_CONTEXTMENU       0x007B
%define WM_CTLCOLOREDIT      0x0133
%define WM_CTLCOLORSTATIC    0x0138
%define WM_CTLCOLORBTN       0x0135
%define WM_CTLCOLORLISTBOX   0x0132
%define WM_CTLCOLORDLG       0x0136
%define WM_INITDIALOG        0x0110
%define WM_SETFONT           0x0030
%define WM_GETMINMAXINFO     0x0024
%define WM_SETCURSOR         0x0020

; --- ListView messages ---
%define LVM_FIRST            0x1000
%define LVM_INSERTCOLUMNA    (LVM_FIRST + 27)   ; 0x101B
%define LVM_INSERTITEMA      (LVM_FIRST + 7)    ; 0x1007
%define LVM_SETITEMA         (LVM_FIRST + 6)    ; 0x1006
%define LVM_GETITEMA         (LVM_FIRST + 5)    ; 0x1005
%define LVM_DELETEALLITEMS   (LVM_FIRST + 9)    ; 0x1009
%define LVM_SETEXTENDEDLISTVIEWSTYLE (LVM_FIRST + 54)  ; 0x1036
%define LVM_SORTITEMSEX      (LVM_FIRST + 81)   ; 0x1051
%define LVM_GETSELECTIONMARK (LVM_FIRST + 66)   ; 0x1042
%define LVM_GETNEXTITEM      (LVM_FIRST + 12)   ; 0x100C
%define LVM_GETITEMCOUNT     (LVM_FIRST + 4)    ; 0x1004
%define LVM_SETBKCOLOR       (LVM_FIRST + 1)    ; 0x1001
%define LVM_SETTEXTCOLOR     (LVM_FIRST + 36)   ; 0x1024
%define LVM_SETTEXTBKCOLOR   (LVM_FIRST + 38)   ; 0x1026
%define LVM_GETITEMTEXT      (LVM_FIRST + 45)   ; 0x102D
%define LVM_SETITEMSTATE     (LVM_FIRST + 43)   ; 0x102B
%define LVM_SETCOLUMNWIDTH   (LVM_FIRST + 30)   ; 0x101E
%define LVM_ENSUREVISIBLE    (LVM_FIRST + 19)   ; 0x1013

; --- ListView extended styles ---
%define LVS_EX_FULLROWSELECT 0x00000020
%define LVS_EX_GRIDLINES     0x00000001
%define LVS_EX_DOUBLEBUFFER  0x00010000
%define LVS_EX_HEADERDRAGDROP 0x00000010

; --- ListView styles ---
%define LVS_REPORT           0x0001
%define LVS_SHOWSELALWAYS    0x0008
%define LVS_SINGLESEL        0x0004
%define LVS_NOSORTHEADER     0x8000

; --- ListView column constants ---
%define LVCF_FMT             0x0001
%define LVCF_WIDTH           0x0002
%define LVCF_TEXT            0x0004
%define LVCF_SUBITEM         0x0008
%define LVCFMT_LEFT          0x0000
%define LVCFMT_RIGHT         0x0001
%define LVCFMT_CENTER        0x0002

; --- ListView item constants ---
%define LVIF_TEXT            0x00000001
%define LVIF_PARAM           0x00000004
%define LVIF_STATE           0x00000008
%define LVNI_SELECTED        0x0002
%define LVNI_ALL             0x0000

; --- ListView notifications ---
%define LVN_FIRST            -100
%define LVN_COLUMNCLICK      (LVN_FIRST - 8)    ; -108
%define LVN_ITEMCHANGED      (LVN_FIRST - 1)    ; -101
%define NM_DBLCLK            -3
%define NM_RCLICK            -5
%define NM_CUSTOMDRAW        -12

; --- Status bar ---
%define SB_SETPARTS          0x0404
%define SB_SETTEXTA          0x0401
%define SB_SETBKCOLOR        0x2001

; --- Edit control ---
%define EN_CHANGE            0x0300

; --- Process access rights ---
%define PROCESS_TERMINATE         0x00000001
%define PROCESS_CREATE_THREAD     0x00000002
%define PROCESS_VM_OPERATION      0x00000008
%define PROCESS_VM_READ           0x00000010
%define PROCESS_VM_WRITE          0x00000020
%define PROCESS_DUP_HANDLE        0x00000040
%define PROCESS_QUERY_INFORMATION 0x00000400
%define PROCESS_ALL_ACCESS        0x001FFFFF

; --- Token privileges ---
%define TOKEN_QUERY               0x00000008
%define TOKEN_ADJUST_PRIVILEGES   0x00000020
%define SE_PRIVILEGE_ENABLED      0x00000002
%define SE_DEBUG_PRIVILEGE        20

; --- Object access ---
%define SYNCHRONIZE               0x00100000
%define GENERIC_ALL               0x10000000

; --- Service control manager ---
%define SC_MANAGER_ALL_ACCESS     0xF003F
%define SC_MANAGER_CREATE_SERVICE 0x0002
%define SERVICE_KERNEL_DRIVER     0x00000001
%define SERVICE_DEMAND_START      0x00000003
%define SERVICE_ERROR_IGNORE      0x00000000
%define SERVICE_ALL_ACCESS        0xF01FF
%define SERVICE_CONTROL_STOP      0x00000001

; --- Shell Execute ---
%define SW_SHOWNORMAL             1
%define SW_SHOW                   5

; --- Priority classes ---
%define REALTIME_PRIORITY_CLASS   0x00000100
%define HIGH_PRIORITY_CLASS       0x00000080
%define ABOVE_NORMAL_PRIORITY_CLASS 0x00008000
%define NORMAL_PRIORITY_CLASS     0x00000020
%define BELOW_NORMAL_PRIORITY_CLASS 0x00004000
%define IDLE_PRIORITY_CLASS       0x00000040

; --- InitCommonControlsEx icc flags ---
%define ICC_LISTVIEW_CLASSES      0x00000001
%define ICC_BAR_CLASSES           0x00000004
%define ICC_WIN95_CLASSES         0x000000FF

; --- Common Dialog Box style ---
%define MB_OK                     0x00000000
%define MB_YESNO                  0x00000004
%define MB_ICONWARNING            0x00000030
%define MB_ICONQUESTION           0x00000020
%define MB_ICONERROR              0x00000010
%define IDYES                     6
%define IDNO                      7

; --- GDI ---
%define TRANSPARENT               1
%define OPAQUE                    2
%define DEFAULT_CHARSET           1
%define OUT_DEFAULT_PRECIS        0
%define CLIP_DEFAULT_PRECIS       0
%define CLEARTYPE_QUALITY         5
%define VARIABLE_PITCH            2
%define FF_SWISS                  2
%define FW_NORMAL                 400
%define FW_BOLD                   700

; --- Menu ---
%define MF_STRING                 0x00000000
%define MF_SEPARATOR              0x00000800
%define MF_POPUP                  0x00000010
%define MF_GRAYED                 0x00000001
%define TPM_LEFTALIGN             0x0000
%define TPM_RETURNCMD             0x0100

; --- PROC_ENTRY structure offsets ---
%define PROC_ENTRY_PID       0     ; DWORD  process ID
%define PROC_ENTRY_SESSID    4     ; DWORD  session ID (unused atm)
%define PROC_ENTRY_MEMKB     8     ; DWORD  working set KB
%define PROC_ENTRY_FLAGS     12    ; DWORD  bit0=system, bit1=protected
%define PROC_ENTRY_CPUTIME   16    ; QWORD  kernel+user FILETIME (for delta)
%define PROC_ENTRY_CPUPCT    24    ; DWORD  last computed CPU% * 10 (fixed-point)
%define PROC_ENTRY_PAD       28    ; DWORD  reserved
%define PROC_ENTRY_NAME      32    ; BYTE[260]  exe name
%define PROC_ENTRY_USER      292   ; BYTE[64]   account name
%define PROC_ENTRY_SIZE      368   ; total (padded to 16-byte multiple)

; --- ListView column indices ---
%define COL_IDX              0
%define COL_PID              1
%define COL_NAME             2
%define COL_CPU              3
%define COL_MEM              4
%define COL_USER             5
%define NUM_COLUMNS          6

; --- Kernel driver device name (user-mode path) ---
; (defined as string below)

; ===========================================================================
;  INITIALIZED DATA  (.data section)
; ===========================================================================
section .data

; --- Window / class strings ---
global szClassName
szClassName:        db 'AsmTaskMgrClass', 0

global szWindowTitle
szWindowTitle:      db 'AsmTaskMgr  —  System Process Manager', 0

global szStatusClass
szStatusClass:      db 'msctls_statusbar32', 0

global szListViewClass
szListViewClass:    db 'SysListView32', 0

global szEditClass
szEditClass:        db 'EDIT', 0

global szButtonClass
szButtonClass:      db 'BUTTON', 0

; --- ListView column headers ---
global szColIdx
global szColPid
global szColName
global szColCpu
global szColMem
global szColUser
szColIdx:           db '#', 0
szColPid:           db 'PID', 0
szColName:          db 'Process Name', 0
szColCpu:           db 'CPU %', 0
szColMem:           db 'Memory (KB)', 0
szColUser:          db 'User', 0

; --- Toolbar / Search ---
global szSearchHint
szSearchHint:       db 'Filter processes...', 0

; --- Gauge format strings (multi-line static: value \r\n label) ---
global szCpuColFmt
szCpuColFmt:        db 'CPU %%  %d%%', 0     ; -> "CPU %  39%"

global szMemColFmt
szMemColFmt:        db 'Memory  %d%%', 0     ; -> "Memory  90%"

global szGaugeBuf
szGaugeBuf:         times 32 db 0

; --- Status bar format strings ---
global szStatusFmt
szStatusFmt:        db '%d processes  |  CPU: %d%%  |  RAM: %d MB / %d MB', 0

; --- Kill confirmation dialogs ---
global szKillTitle
szKillTitle:        db 'Confirm Kill', 0

global szKillFmt
szKillFmt:          db 'Kill process  [%s]  (PID %d)?'
                    db 13, 10
                    db 'This cannot be undone.', 0

global szKillSystemFmt
szKillSystemFmt:    db 'WARNING: This is a system/protected process.'
                    db 13, 10
                    db 'Process: [%s]  PID: %d'
                    db 13, 10, 13, 10
                    db 'Killing it may destabilise your system.'
                    db 13, 10
                    db 'Continue?', 0

global szKillFailed
szKillFailed:       db 'Failed to kill process (PID %d).', 13, 10
                    db 'Even kernel-level termination was denied.', 13, 10
                    db 'The process may be in hypervisor/VTL1 space.', 0

global szKillFailTitle
szKillFailTitle:    db 'Kill Failed', 0

; --- About dialog ---
global szAboutTitle
szAboutTitle:       db 'About AsmTaskMgr', 0

global szAboutText
szAboutText:        db 'AsmTaskMgr  v1.0', 13, 10
                    db '64-bit Windows Task Manager', 13, 10
                    db 'Written in pure x86-64 NASM assembly.', 13, 10, 13, 10
                    db 'Assembled with: NASM 2.16.03', 13, 10
                    db 'Linked with:    GoLink', 13, 10, 13, 10
                    db 'Features:', 13, 10
                    db '  Tier 1: Win32 TerminateProcess', 13, 10
                    db '  Tier 2: NtTerminateProcess (ntdll)', 13, 10
                    db '  Tier 3: Kernel driver (ring-0)', 13, 10, 13, 10
                    db 'SeDebugPrivilege: Active', 0

; --- Driver service name ---
global szDriverSvcName
szDriverSvcName:    db 'AsmTaskMgrDrv', 0

global szDriverSvcDisplay
szDriverSvcDisplay: db 'AsmTaskMgr Kernel Driver', 0

; --- Driver device path (user-mode) ---
global szDriverDevice
szDriverDevice:     db '\\.\AsmTaskMgrDrv', 0

; --- Privilege name ---
global szSeDebugPriv
szSeDebugPriv:      db 'SeDebugPrivilege', 0

; --- Font name ---
global szFontName
szFontName:         db 'Segoe UI', 0

; --- runas verb for ShellExecuteEx ---
global szRunAs
szRunAs:            db 'runas', 0

; --- Number format buffers (shared, single-threaded use only) ---
global szNumBuf
szNumBuf:           times 64 db 0

global szNumBuf2
szNumBuf2:          times 64 db 0

global szMsgBuf
szMsgBuf:           times 512 db 0

; --- Column widths (pixels) ---
global colWidths
colWidths:          dd 30, 60, 200, 60, 100, 120

; ===========================================================================
;  UNINITIALIZED DATA  (.bss section)
; ===========================================================================
section .bss

; --- Win32 handles ---
global hInstance
hInstance:          resq 1    ; HINSTANCE of this .exe

global hMainWnd
hMainWnd:           resq 1    ; main window HWND

global hListView
hListView:          resq 1    ; SysListView32 HWND

global hStatusBar
hStatusBar:         resq 1    ; status bar HWND

global hSearchEdit
hSearchEdit:        resq 1    ; filter edit HWND

global hDeviceDriver
hDeviceDriver:      resq 1    ; kernel driver device handle (INVALID_HANDLE_VALUE if unavailable)

global hBgBrush
hBgBrush:           resq 1    ; HBRUSH dark background

global hRowAltBrush
hRowAltBrush:       resq 1    ; HBRUSH alt row

global hAccentBrush
hAccentBrush:       resq 1    ; HBRUSH accent

global hFont
hFont:              resq 1    ; custom HFONT

global hCpuVal
hCpuVal:            resq 1    ; (unused, kept for compat)

global hMemVal
hMemVal:            resq 1    ; (unused, kept for compat)

global lvcBuf
lvcBuf:             resb 48   ; LVCOLUMNA struct for LVM_SETCOLUMNA calls

global hPopupMenu
hPopupMenu:         resq 1    ; context menu HMENU

; --- Process table ---
global procTable
procTable:          resq 1    ; QWORD pointer to heap-alloc PROC_ENTRY array

global procCount
procCount:          resd 1    ; number of valid entries in procTable

global procCapacity
procCapacity:       resd 1    ; allocated slots

; --- CPU tracking ---
global prevIdleTime
prevIdleTime:       resq 1    ; FILETIME (QWORD)

global prevKernelTime
prevKernelTime:     resq 1

global prevUserTime
prevUserTime:       resq 1

global cpuPercent
cpuPercent:         resd 1    ; 0–100

global cpuInitialized
cpuInitialized:     resd 1    ; 1 once first sample taken

; --- Memory info ---
global totalPhysKB
totalPhysKB:        resq 1

global availPhysKB
availPhysKB:        resq 1

; --- Sorting state ---
global sortColumn
sortColumn:         resd 1    ; COL_* constant

global sortAscending
sortAscending:      resd 1    ; 1 = ascending, 0 = descending

; --- UI state ---
global selectedPid
selectedPid:        resd 1    ; PID of selected item

global driverLoaded
driverLoaded:       resd 1    ; 1 if kernel driver is running

global searchFilter
searchFilter:       resb 260  ; current filter string (ANSI)

global minWidth
minWidth:           resd 1    ; minimum window width (pixels)

global minHeight
minHeight:          resd 1    ; minimum window height

; --- Client area tracking ---
global clientWidth
clientWidth:        resd 1

global clientHeight
clientHeight:       resd 1
