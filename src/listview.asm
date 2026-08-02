; =============================================================================
;  listview.asm  —  AsmTaskMgr
;  ListView initialisation, column setup, row population, sort, filter.
;  Assembled as: nasm -f win64 listview.asm -o listview.obj
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
;  Win32 / GDI imports
; ---------------------------------------------------------------------------
extern SendMessageA
extern SendMessageW
extern wsprintfA
extern SetBkColor
extern SetTextColor
extern CreateSolidBrush
extern GetStockObject
extern InvalidateRect

; ---------------------------------------------------------------------------
;  Globals (from strings.asm)
; ---------------------------------------------------------------------------
extern hListView
extern hStatusBar
extern hFont
extern hBgBrush
extern procTable
extern procCount
extern sortColumn
extern sortAscending
extern searchFilter
extern totalPhysKB
extern availPhysKB
extern cpuPercent
extern selectedPid

extern szColIdx
extern szColPid
extern szColName
extern szColCpu
extern szColMem
extern szColUser
extern colWidths
extern szStatusFmt
extern szNumBuf
extern szNumBuf2

; External CPU/memory updaters
extern UpdateCpuUsage
extern UpdateMemoryStats

; ---------------------------------------------------------------------------
;  Exports
; ---------------------------------------------------------------------------
global InitListView
global RefreshListView
global GetSelectedPid
global SortCompareProc

; ---------------------------------------------------------------------------
;  Constants
; ---------------------------------------------------------------------------
%define WM_SETREDRAW         0x000B
%define LVM_FIRST            0x1000
%define LVM_INSERTCOLUMNA    (LVM_FIRST + 27)
%define LVM_INSERTITEMA      (LVM_FIRST + 7)
%define LVM_SETITEMTEXTA     (LVM_FIRST + 46)
%define LVM_DELETEALLITEMS   (LVM_FIRST + 9)
%define LVM_SETEXTENDEDLISTVIEWSTYLE (LVM_FIRST + 54)
%define LVM_SETBKCOLOR       (LVM_FIRST + 1)
%define LVM_SETTEXTCOLOR     (LVM_FIRST + 36)
%define LVM_SETTEXTBKCOLOR   (LVM_FIRST + 38)
%define LVM_GETNEXTITEM      (LVM_FIRST + 12)
%define LVM_GETITEMCOUNT     (LVM_FIRST + 4)
%define LVM_GETITEMA         (LVM_FIRST + 5)
%define LVM_SORTITEMSEX      (LVM_FIRST + 81)
%define LVM_ENSUREVISIBLE    (LVM_FIRST + 19)
%define LVM_GETTOPINDEX      (LVM_FIRST + 39)

%define LVS_EX_FULLROWSELECT 0x00000020
%define LVS_EX_GRIDLINES     0x00000001
%define LVS_EX_DOUBLEBUFFER  0x00010000

%define LVCF_FMT             0x0001
%define LVCF_WIDTH           0x0002
%define LVCF_TEXT            0x0004
%define LVCF_SUBITEM         0x0008

%define LVCFMT_LEFT          0x0000
%define LVCFMT_RIGHT         0x0001

%define LVIF_TEXT            0x00000001
%define LVIF_PARAM           0x00000004
%define LVNI_SELECTED        0x0002
%define LVNI_ALL             0x0000

%define SB_SETTEXTA          0x0401
%define SB_SETPARTS          0x0404
%define SB_SETBKCOLOR        0x2001

; Dark theme colors (COLORREF 0x00BBGGRR)
%define COLOR_BG             0x0017110D
%define COLOR_TEXT           0x00D9D1C9
%define COLOR_ROW_ALT        0x00221B16
%define CLR_NONE             0xFFFFFFFF

; LVCOLUMNA offsets (64-bit alignment)
; struct LVCOLUMNA: mask(4), fmt(4), cx(4), pad(4), pszText(8), cchTextMax(4), iSubItem(4), iImage(4), iOrder(4)
%define LVCOL_mask       0
%define LVCOL_fmt        4
%define LVCOL_cx         8
%define LVCOL_pad        12
%define LVCOL_pszText    16    ; pointer (8 bytes)
%define LVCOL_cchTextMax 24
%define LVCOL_iSubItem   28
%define LVCOL_SIZEOF     32

; LVITEMA offsets (64-bit)
; mask(4), iItem(4), iSubItem(4), state(4), stateMask(4), pad(4), pszText(8), cchTextMax(4), iImage(4), lParam(8)
%define LVIT_mask        0
%define LVIT_iItem       4
%define LVIT_iSubItem    8
%define LVIT_state       12
%define LVIT_stateMask   16
%define LVIT_pad         20
%define LVIT_pszText     24    ; pointer (8 bytes)
%define LVIT_cchTextMax  32
%define LVIT_iImage      36
%define LVIT_lParam      40    ; LPARAM (8 bytes)
%define LVIT_SIZEOF      48

%define PROC_ENTRY_SIZE      368
%define PE_PID               0
%define PE_MEMKB             8
%define PE_FLAGS             12
%define PE_CPUTIME           16
%define PE_CPUPCT            24
%define PE_NAME              32
%define PE_USER              292

; ---------------------------------------------------------------------------
section .data
szIdxBuf:       times 16  db 0
szPidBuf:       times 16  db 0
szCpuBuf:       times 16  db 0
szMemBuf:       times 16  db 0
szFmtIdx:       db '%d', 0
szFmtPid:       db '%d', 0
szFmtCpu:       db '%d.%d%%', 0
szFmtMem:       db '%d', 0

; Status bar text buffer
szStatusBuf:    times 128 db 0

; Refresh cycle counter (for CPU delta normalization)
refreshTick:    dd 0

; ---------------------------------------------------------------------------
section .text

; ===========================================================================
;  InitListView
;  Sets up columns, background colors, and extended styles on hListView.
;  Must be called after hListView is valid.
; ===========================================================================
InitListView:
    push    rbx
    push    rsi
    push    rdi
    ; 3 pushes: 24 + 8 ret = 32. sub 96: 96 mod 16 = 0. RSP shift = 128, 128/16=8 ✓
    sub     rsp, 96

    ; Stack: [rsp+0] shadow, [rsp+32] LVCOLUMNA (32 bytes), [rsp+64] scratch
    %define COL_FRAME  rsp+32

    mov     rbx, [rel hListView]        ; rbx = hListView

    ; --- Set extended styles: full-row select + grid + double-buffer ---
    mov     rcx, rbx
    mov     edx, LVM_SETEXTENDEDLISTVIEWSTYLE
    mov     r8d, (LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES | LVS_EX_DOUBLEBUFFER)
    mov     r9d, (LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES | LVS_EX_DOUBLEBUFFER)
    call    SendMessageA

    ; --- Background color ---
    mov     rcx, rbx
    mov     edx, LVM_SETBKCOLOR
    xor     r8d, r8d
    mov     r9d, COLOR_BG
    call    SendMessageA

    ; --- Text color ---
    mov     rcx, rbx
    mov     edx, LVM_SETTEXTCOLOR
    xor     r8d, r8d
    mov     r9d, COLOR_TEXT
    call    SendMessageA

    ; --- Text background color (COLOR_BG = dark background) ---
    mov     rcx, rbx
    mov     edx, LVM_SETTEXTBKCOLOR
    xor     r8d, r8d
    mov     r9d, COLOR_BG
    call    SendMessageA

    ; --- Insert columns ---
    ; LVCOLUMNA at COL_FRAME
    xor     rax, rax
    mov     rsi, 0                     ; column index

    ; Column 0: "#"
    mov     dword [COL_FRAME + LVCOL_mask],    (LVCF_FMT | LVCF_WIDTH | LVCF_TEXT | LVCF_SUBITEM)
    mov     dword [COL_FRAME + LVCOL_fmt],     LVCFMT_RIGHT
    mov     dword [COL_FRAME + LVCOL_cx],      30
    lea     rax, [rel szColIdx]
    mov     [COL_FRAME + LVCOL_pszText],       rax
    mov     dword [COL_FRAME + LVCOL_cchTextMax], 4
    mov     dword [COL_FRAME + LVCOL_iSubItem],  0
    mov     rcx, rbx
    mov     edx, LVM_INSERTCOLUMNA
    mov     r8d, 0                     ; column index
    lea     r9, [COL_FRAME]
    call    SendMessageA

    ; Column 1: "PID"
    mov     dword [COL_FRAME + LVCOL_fmt],  LVCFMT_RIGHT
    mov     dword [COL_FRAME + LVCOL_cx],   60
    lea     rax, [rel szColPid]
    mov     [COL_FRAME + LVCOL_pszText],    rax
    mov     dword [COL_FRAME + LVCOL_iSubItem], 1
    mov     rcx, rbx
    mov     edx, LVM_INSERTCOLUMNA
    mov     r8d, 1
    lea     r9, [COL_FRAME]
    call    SendMessageA

    ; Column 2: "Process Name"
    mov     dword [COL_FRAME + LVCOL_fmt],  LVCFMT_LEFT
    mov     dword [COL_FRAME + LVCOL_cx],   210
    lea     rax, [rel szColName]
    mov     [COL_FRAME + LVCOL_pszText],    rax
    mov     dword [COL_FRAME + LVCOL_iSubItem], 2
    mov     rcx, rbx
    mov     edx, LVM_INSERTCOLUMNA
    mov     r8d, 2
    lea     r9, [COL_FRAME]
    call    SendMessageA

    ; Column 3: "CPU %"
    mov     dword [COL_FRAME + LVCOL_fmt],  LVCFMT_RIGHT
    mov     dword [COL_FRAME + LVCOL_cx],   65
    lea     rax, [rel szColCpu]
    mov     [COL_FRAME + LVCOL_pszText],    rax
    mov     dword [COL_FRAME + LVCOL_iSubItem], 3
    mov     rcx, rbx
    mov     edx, LVM_INSERTCOLUMNA
    mov     r8d, 3
    lea     r9, [COL_FRAME]
    call    SendMessageA

    ; Column 4: "Memory (KB)"
    mov     dword [COL_FRAME + LVCOL_fmt],  LVCFMT_RIGHT
    mov     dword [COL_FRAME + LVCOL_cx],   105
    lea     rax, [rel szColMem]
    mov     [COL_FRAME + LVCOL_pszText],    rax
    mov     dword [COL_FRAME + LVCOL_iSubItem], 4
    mov     rcx, rbx
    mov     edx, LVM_INSERTCOLUMNA
    mov     r8d, 4
    lea     r9, [COL_FRAME]
    call    SendMessageA

    ; Column 5: "User"
    mov     dword [COL_FRAME + LVCOL_fmt],  LVCFMT_LEFT
    mov     dword [COL_FRAME + LVCOL_cx],   120
    lea     rax, [rel szColUser]
    mov     [COL_FRAME + LVCOL_pszText],    rax
    mov     dword [COL_FRAME + LVCOL_iSubItem], 5
    mov     rcx, rbx
    mov     edx, LVM_INSERTCOLUMNA
    mov     r8d, 5
    lea     r9, [COL_FRAME]
    call    SendMessageA

    add     rsp, 96
    pop     rdi
    pop     rsi
    pop     rbx
    ret
    %undef COL_FRAME

; ===========================================================================
;  RefreshListView
;  Clears the ListView and repopulates it from procTable.
;  Also updates the status bar with process count + CPU + RAM.
; ===========================================================================
RefreshListView:
    push    rbp
    push    rbx
    push    rsi
    push    rdi
    push    r15
    push    r14
    ; 6 pushes: 48 + 8 ret = 56. sub 152: 152 mod 16 = 8 → RSP shift = 208, 208/16=13 ✓
    sub     rsp, 152

    ; Stack layout:
    ;   [rsp+  0] shadow (32)
    ;   [rsp+ 32] arg spill (32)
    ;   [rsp+ 64] LVITEMA (48 bytes) → up to [rsp+111]
    ;   [rsp+112] text scratch buffer (40 bytes)
    %define ITEM_FRAME  rsp+64
    %define TXT_FRAME   rsp+112

    mov     rbp, [rel hListView]         ; rbp = hListView

    ; --- Update CPU and memory stats ---
    call    UpdateCpuUsage
    call    UpdateMemoryStats

    ; --- Save scroll position before clearing ---
    mov     rcx, rbp
    mov     edx, LVM_GETTOPINDEX
    xor     r8d, r8d
    xor     r9d, r9d
    call    SendMessageA
    mov     r14d, eax                    ; r14d = top visible item index

    ; --- Freeze redraws to avoid blink during delete+repopulate ---
    mov     rcx, rbp
    mov     edx, WM_SETREDRAW
    xor     r8d, r8d               ; FALSE = stop drawing
    xor     r9d, r9d
    call    SendMessageA

    ; --- Delete all items ---
    mov     rcx, rbp
    mov     edx, LVM_DELETEALLITEMS
    xor     r8d, r8d
    xor     r9d, r9d
    call    SendMessageA

    ; --- Populate rows ---
    mov     r15, [rel procTable]         ; r15 = proc table ptr
    mov     edi, [rel procCount]         ; edi = count
    test    rdi, rdi
    jz      .after_rows
    xor     esi, esi                     ; esi = row index (item index)

.row_loop:
    cmp     esi, edi
    jge     .after_rows

    ; Apply search filter (skip if name doesn't match filter)
    lea     rcx, [rel searchFilter]
    cmp     byte [rcx], 0               ; empty filter?
    je      .no_filter
    ; Simple substring match: check if filter is in PE_NAME
    lea     rdx, [r15 + PE_NAME]
    call    SubstrMatchI                 ; in: rcx=filter, rdx=haystack; out: eax=1 match
    test    eax, eax
    jz      .next_row
.no_filter:

    ; Zero the LVITEMA struct
    xor     rax, rax
    mov     [ITEM_FRAME + LVIT_mask],     eax
    mov     [ITEM_FRAME + LVIT_iItem],    eax
    mov     [ITEM_FRAME + LVIT_iSubItem], eax
    mov     [ITEM_FRAME + LVIT_state],    eax
    mov     [ITEM_FRAME + LVIT_stateMask],eax
    mov     [ITEM_FRAME + LVIT_pad],      eax
    mov     [ITEM_FRAME + LVIT_pszText],  rax
    mov     [ITEM_FRAME + LVIT_cchTextMax],eax
    mov     [ITEM_FRAME + LVIT_iImage],   eax
    mov     [ITEM_FRAME + LVIT_lParam],   rax

    ; Set LVIF_TEXT | LVIF_PARAM
    mov     dword [ITEM_FRAME + LVIT_mask],    (LVIF_TEXT | LVIF_PARAM)
    mov     dword [ITEM_FRAME + LVIT_iItem],   esi
    mov     dword [ITEM_FRAME + LVIT_iSubItem],0

    ; lParam = pointer to PROC_ENTRY (for sort callback)
    mov     [ITEM_FRAME + LVIT_lParam],   r15

    ; Column 0: row index "#"
    lea     rcx, [TXT_FRAME]
    lea     rdx, [rel szFmtIdx]
    mov     r8d, esi
    inc     r8d                          ; 1-based index
    call    wsprintfA
    lea     rax, [TXT_FRAME]
    mov     [ITEM_FRAME + LVIT_pszText], rax
    mov     dword [ITEM_FRAME + LVIT_cchTextMax], 16

    ; InsertItem (column 0)
    mov     rcx, rbp
    mov     edx, LVM_INSERTITEMA
    xor     r8d, r8d                     ; wParam MUST be 0 for LVM_INSERTITEM
    lea     r9, [ITEM_FRAME]
    call    SendMessageA

    ; Columns 1-5: SetItemText via LVM_SETITEMTEXTA
    ; We reuse ITEM_FRAME, changing iSubItem and pszText each time

    ; Column 1: PID
    mov     dword [ITEM_FRAME + LVIT_mask],    LVIF_TEXT
    mov     dword [ITEM_FRAME + LVIT_iSubItem], 1
    lea     rcx, [TXT_FRAME]
    lea     rdx, [rel szFmtPid]
    mov     r8d, dword [r15 + PE_PID]
    call    wsprintfA
    lea     rax, [TXT_FRAME]
    mov     [ITEM_FRAME + LVIT_pszText], rax
    mov     rcx, rbp
    mov     edx, LVM_SETITEMTEXTA
    mov     r8d, esi
    lea     r9, [ITEM_FRAME]
    call    SendMessageA

    ; Column 2: Process Name
    mov     dword [ITEM_FRAME + LVIT_iSubItem], 2
    lea     rax, [r15 + PE_NAME]
    mov     [ITEM_FRAME + LVIT_pszText], rax
    mov     rcx, rbp
    mov     edx, LVM_SETITEMTEXTA
    mov     r8d, esi
    lea     r9, [ITEM_FRAME]
    call    SendMessageA

    ; Column 3: CPU% (stored as 100ns units delta; convert to rough percentage)
    ; cpuPct = PROC_ENTRY.CPUPCT (raw delta in 100ns); divide by REFRESH_INTERVAL_MS*10000
    ; Simplified: divide by 20000000 (2 sec * 10^7 100ns units per sec) * 100
    ; cpuPercent_proc = (delta * 100) / 20_000_000
    mov     dword [ITEM_FRAME + LVIT_iSubItem], 3
    mov     rax, [r15 + PE_CPUPCT]      ; delta (QWORD)
    test    rax, rax
    jle     .cpu_zero                   ; if <= 0 -> 0%
    mov     r8, 20000000000
    cmp     rax, r8                     ; if huge delta -> cap
    jae     .cpu_zero
    imul    rax, 100
    mov     rcx, 20000000
    xor     rdx, rdx
    div     rcx                         ; rax = integer CPU%
    cmp     rax, 100
    jle     .cpu_ok
    mov     rax, 100
    jmp     .cpu_ok
.cpu_zero:
    xor     eax, eax
.cpu_ok:
    mov     r8d, eax
    lea     rcx, [TXT_FRAME]
    lea     rdx, [rel szFmtPid]         ; reuse %d format
    call    wsprintfA
    lea     rax, [TXT_FRAME]
    mov     [ITEM_FRAME + LVIT_pszText], rax
    mov     rcx, rbp
    mov     edx, LVM_SETITEMTEXTA
    mov     r8d, esi
    lea     r9, [ITEM_FRAME]
    call    SendMessageA

    ; Column 4: Memory KB
    mov     dword [ITEM_FRAME + LVIT_iSubItem], 4
    lea     rcx, [TXT_FRAME]
    lea     rdx, [rel szFmtPid]
    mov     r8d, dword [r15 + PE_MEMKB]
    call    wsprintfA
    lea     rax, [TXT_FRAME]
    mov     [ITEM_FRAME + LVIT_pszText], rax
    mov     rcx, rbp
    mov     edx, LVM_SETITEMTEXTA
    mov     r8d, esi
    lea     r9, [ITEM_FRAME]
    call    SendMessageA

    ; Column 5: Username
    mov     dword [ITEM_FRAME + LVIT_iSubItem], 5
    lea     rax, [r15 + PE_USER]
    mov     [ITEM_FRAME + LVIT_pszText], rax
    mov     rcx, rbp
    mov     edx, LVM_SETITEMTEXTA
    mov     r8d, esi
    lea     r9, [ITEM_FRAME]
    call    SendMessageA

    ; Advance
    inc     esi
.next_row:
    add     r15, PROC_ENTRY_SIZE
    mov     edi, [rel procCount]         ; re-read in case of race (unlikely)
    cmp     dword [rel procCount], 0
    je      .after_rows
    mov     ecx, esi
    mov     edi, [rel procCount]
    cmp     ecx, edi
    jl      .row_loop

.after_rows:
    ; --- Re-enable redraws and force one clean repaint ---
    mov     rcx, rbp
    mov     edx, WM_SETREDRAW
    mov     r8d, 1                 ; TRUE = resume drawing
    xor     r9d, r9d
    call    SendMessageA

    ; InvalidateRect(hListView, NULL, FALSE) → schedule a clean repaint
    mov     rcx, rbp
    xor     edx, edx               ; lpRect = NULL (entire client)
    xor     r8d, r8d               ; bErase = FALSE
    call    InvalidateRect

    ; --- Restore scroll position ---
    test    r14d, r14d
    jz      .scroll_done           ; was at top, nothing to restore
    mov     rcx, rbp
    mov     edx, LVM_ENSUREVISIBLE
    mov     r8d, r14d              ; iItem = saved top index
    mov     r9d, 1                 ; bPartialOK = TRUE
    call    SendMessageA
.scroll_done:

    ; --- Update status bar ---
    ; Format: "NNN processes  |  CPU: NN%  |  RAM: XXXX MB / YYYY MB"
    ; wsprintfA(szStatusBuf, szStatusFmt, procCount, cpuPercent, availMB, totalMB)
    lea     rcx, [rel szStatusBuf]
    lea     rdx, [rel szStatusFmt]
    mov     r8d, [rel procCount]
    mov     r9d, [rel cpuPercent]
    mov     rax, [rel availPhysKB]
    shr     rax, 10                      ; → MB
    mov     [rsp+32], rax
    mov     rax, [rel totalPhysKB]
    shr     rax, 10
    mov     [rsp+40], rax
    call    wsprintfA

    ; SendMessage(hStatusBar, SB_SETTEXTA, 0, &szStatusBuf)
    mov     rcx, [rel hStatusBar]
    mov     edx, SB_SETTEXTA
    xor     r8d, r8d
    lea     r9, [rel szStatusBuf]
    call    SendMessageA

    add     rsp, 152
    pop     r14
    pop     r15
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret
    %undef ITEM_FRAME
    %undef TXT_FRAME

; ===========================================================================
;  GetSelectedPid
;  Returns PID of the currently selected ListView item.
;  Out: EAX = PID (0 if none selected).
; ===========================================================================
GetSelectedPid:
    push    rbx
    sub     rsp, 56
    ; Stack: 32 shadow + 24 LVITEMA mini

    %define ITEM_SMALL   rsp+32

    ; LVM_GETNEXTITEM with LVNI_SELECTED to get selected index
    mov     rbx, [rel hListView]
    mov     rcx, rbx
    mov     edx, LVM_GETNEXTITEM
    mov     r8d, -1                      ; start from beginning
    mov     r9d, LVNI_SELECTED
    call    SendMessageA
    cmp     rax, -1
    je      .no_sel

    mov     r8d, eax                     ; selected index

    ; Get LVITEMA.lParam (pointer to PROC_ENTRY)
    xor     eax, eax
    mov     dword [ITEM_SMALL],    LVIF_PARAM   ; mask
    mov     dword [ITEM_SMALL+4],  r8d           ; iItem
    mov     dword [ITEM_SMALL+8],  0             ; iSubItem
    mov     dword [ITEM_SMALL+12], 0             ; state
    mov     dword [ITEM_SMALL+16], 0
    mov     dword [ITEM_SMALL+20], 0
    mov     qword [ITEM_SMALL+24], 0             ; pszText
    mov     qword [ITEM_SMALL+32], 0             ; lParam
    mov     rcx, rbx
    mov     edx, LVM_GETITEMA
    mov     r8, r8
    lea     r9, [ITEM_SMALL]
    call    SendMessageA

    ; lParam = pointer to PROC_ENTRY → read PID from it
    mov     rax, [ITEM_SMALL + 32]      ; lParam (QWORD) = PROC_ENTRY*
    test    rax, rax
    jz      .no_sel
    mov     eax, dword [rax + PE_PID]
    mov     [rel selectedPid], eax
    jmp     .done

.no_sel:
    xor     eax, eax
    mov     dword [rel selectedPid], 0

.done:
    add     rsp, 56
    pop     rbx
    ret
    %undef ITEM_SMALL

; ===========================================================================
;  SubstrMatchI(filter_ptr, haystack_ptr)
;  Case-insensitive substring search (ANSI).
;  In:  RCX = filter string, RDX = haystack string
;  Out: EAX = 1 if match, 0 if no match
; ===========================================================================
SubstrMatchI:
    push    rbx
    push    rsi
    push    rdi

    mov     rsi, rcx          ; rsi = filter
    mov     rdi, rdx          ; rdi = haystack

    cmp     byte [rsi], 0
    je      .match_yes        ; empty filter matches everything

.outer:
    cmp     byte [rdi], 0
    je      .match_no         ; end of haystack

    ; Try matching from current haystack position
    mov     rbx, rdi          ; save haystack pos
    mov     rcx, rsi          ; filter start

.inner:
    cmp     byte [rcx], 0
    je      .match_yes        ; matched entire filter

    ; Read filter char, uppercase
    movzx   eax, byte [rcx]
    cmp     eax, 'a'
    jl      .fchar_done
    cmp     eax, 'z'
    jg      .fchar_done
    sub     eax, 32           ; lowercase → uppercase
.fchar_done:
    mov     r8d, eax          ; r8d = filter char (uppercase)

    ; Read haystack char, uppercase
    movzx   eax, byte [rbx]
    cmp     eax, 'a'
    jl      .hchar_done
    cmp     eax, 'z'
    jg      .hchar_done
    sub     eax, 32
.hchar_done:

    cmp     eax, r8d
    jne     .no_match_here

    inc     rcx
    inc     rbx
    jmp     .inner

.no_match_here:
    inc     rdi               ; advance haystack start
    jmp     .outer

.match_yes:
    mov     eax, 1
    jmp     .done
.match_no:
    xor     eax, eax
.done:
    pop     rdi
    pop     rsi
    pop     rbx
    ret

; ===========================================================================
;  SortCompareProc  (callback for LVM_SORTITEMSEX)
;  In:  RCX = lParam1 (PROC_ENTRY* for item1)
;       RDX = lParam2 (PROC_ENTRY* for item2)
;       R8  = lParamSort (sortColumn value)
;  Out: EAX < 0 if item1 < item2, 0 if equal, > 0 if item1 > item2
; ===========================================================================
SortCompareProc:
    push    rbx
    push    rsi
    push    rdi
    ; 3 pushes (24) + 8 ret = 32. sub 32: RSP shift = 64, 64/16=4 OK
    sub     rsp, 32             ; shadow space required before any CALL

    mov     rbx, rcx            ; entry1 (PROC_ENTRY*)
    mov     rsi, rdx            ; entry2 (PROC_ENTRY*)
    mov     edi, r8d            ; sort column (saved in rdi across calls)

    ; NULL guard
    test    rbx, rbx
    jz      .cmp_equal
    test    rsi, rsi
    jz      .cmp_equal

    ; Switch on sort column
    cmp     edi, 1
    je      .sort_pid
    cmp     edi, 2
    je      .sort_name
    cmp     edi, 3
    je      .sort_cpu
    cmp     edi, 4
    je      .sort_mem
    cmp     edi, 5
    je      .sort_user
.cmp_equal:
    xor     eax, eax
    jmp     .apply_dir

.sort_pid:
    mov     eax, [rbx + PE_PID]
    sub     eax, [rsi + PE_PID]
    jmp     .apply_dir

.sort_cpu:
    mov     rax, [rbx + PE_CPUPCT]
    sub     rax, [rsi + PE_CPUPCT]
    test    rax, rax
    jz      .apply_dir
    js      .cpu_neg
    mov     eax, 1
    jmp     .apply_dir
.cpu_neg:
    mov     eax, -1
    jmp     .apply_dir

.sort_mem:
    mov     eax, [rbx + PE_MEMKB]
    sub     eax, [rsi + PE_MEMKB]
    jmp     .apply_dir

.sort_name:
    ; strcmp-like (ANSI, case-sensitive for now)
    lea     rcx, [rbx + PE_NAME]
    lea     rdx, [rsi + PE_NAME]
    call    StrCmpAnsi
    jmp     .apply_dir

.sort_user:
    lea     rcx, [rbx + PE_USER]
    lea     rdx, [rsi + PE_USER]
    call    StrCmpAnsi

.apply_dir:
    ; If sortAscending == 0, negate result
    cmp     dword [rel sortAscending], 0
    jne     .done_sort
    neg     eax

.done_sort:
    add     rsp, 32
    pop     rdi
    pop     rsi
    pop     rbx
    ret

; ===========================================================================
;  StrCmpAnsi(a, b) — strcmp
;  In:  RCX = string a, RDX = string b
;  Out: EAX = -1/0/1
; ===========================================================================
StrCmpAnsi:
    push    rsi
    push    rdi
    mov     rsi, rcx
    mov     rdi, rdx

.cmp_loop:
    movzx   eax, byte [rsi]
    movzx   ecx, byte [rdi]
    cmp     eax, ecx
    jl      .less
    jg      .greater
    test    eax, eax
    jz      .equal
    inc     rsi
    inc     rdi
    jmp     .cmp_loop

.less:
    mov     eax, -1
    jmp     .ret
.greater:
    mov     eax, 1
    jmp     .ret
.equal:
    xor     eax, eax
.ret:
    pop     rdi
    pop     rsi
    ret
