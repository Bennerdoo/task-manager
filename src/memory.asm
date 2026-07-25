; =============================================================================
;  memory.asm  —  AsmTaskMgr
;  Memory statistics via GlobalMemoryStatusEx.
;  Assembled as: nasm -f win64 memory.asm -o memory.obj
; =============================================================================

bits 64
default rel

extern GlobalMemoryStatusEx

extern totalPhysKB    ; QWORD in strings.asm .bss
extern availPhysKB    ; QWORD in strings.asm .bss

global UpdateMemoryStats

; ---------------------------------------------------------------------------
;  MEMORYSTATUSEX structure (64-byte, all 64-bit windows)
;    DWORD dwLength          offset  0  (4 bytes)
;    DWORD dwMemoryLoad      offset  4  (4 bytes)  0-100 percent
;    DWORDLONG ullTotalPhys  offset  8  (8 bytes)
;    DWORDLONG ullAvailPhys  offset 16  (8 bytes)
;    DWORDLONG ullTotalPageFile offset 24
;    DWORDLONG ullAvailPageFile offset 32
;    DWORDLONG ullTotalVirtual  offset 40
;    DWORDLONG ullAvailVirtual  offset 48
;    DWORDLONG ullAvailExtendedVirtual offset 56
; Total: 64 bytes
; ---------------------------------------------------------------------------

section .text

; ===========================================================================
;  UpdateMemoryStats
;  Fills totalPhysKB and availPhysKB with current values.
;  Returns: EAX = memory load percent (0-100), or 0xFFFF on failure.
; ===========================================================================
UpdateMemoryStats:
    push    rbp
    mov     rbp, rsp
    ; Stack alignment: push rbp makes rsp 16-byte aligned (2 adjustments of 8 bytes each).
    ; After push rbp: rsp = caller_rsp - 16 (ALIGNED). sub N must be divisible by 16.
    ; shadow(32) + MEMORYSTATUSEX(64) = 96 bytes. 96/16 = 6. ✓
    sub     rsp, 96

    ; --- Fill struct at [rsp+32] (MEMORYSTATUSEX, 64 bytes → [rsp+32..95]) ---
    mov     dword [rsp+32], 64       ; dwLength = sizeof(MEMORYSTATUSEX)
    ; zero out rest
    xor     eax, eax
    mov     [rsp+36], eax
    mov     [rsp+40], rax
    mov     [rsp+48], rax
    mov     [rsp+56], rax
    mov     [rsp+64], rax
    mov     [rsp+72], rax
    mov     [rsp+80], rax
    mov     [rsp+88], rax

    ; --- Call GlobalMemoryStatusEx(&msex) ---
    lea     rcx, [rsp+32]
    call    GlobalMemoryStatusEx
    test    eax, eax
    jz      .fail

    ; --- Extract values ---
    ; ullTotalPhys at offset 8 from struct = [rsp+32+8] = [rsp+40]
    ; ullAvailPhys at offset 16 = [rsp+48]
    mov     rax, [rsp+40]            ; ullTotalPhys (bytes)
    shr     rax, 10                  ; → KB
    mov     [rel totalPhysKB], rax

    mov     rax, [rsp+48]            ; ullAvailPhys (bytes)
    shr     rax, 10                  ; → KB
    mov     [rel availPhysKB], rax

    ; Return dwMemoryLoad (offset 4 from struct)
    mov     eax, [rsp+36]            ; dwMemoryLoad (DWORD; mov auto-zero-extends on x64)
    jmp     .done

.fail:
    mov     eax, 0xFFFF

.done:
    add     rsp, 96
    pop     rbp
    ret
