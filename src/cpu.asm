; =============================================================================
;  cpu.asm  —  AsmTaskMgr
;  CPU usage via GetSystemTimes delta method.
;  Assembled as: nasm -f win64 cpu.asm -o cpu.obj
; =============================================================================

bits 64
default rel

extern GetSystemTimes

extern prevIdleTime     ; QWORD
extern prevKernelTime   ; QWORD
extern prevUserTime     ; QWORD
extern cpuPercent       ; DWORD
extern cpuInitialized   ; DWORD

global UpdateCpuUsage

; ---------------------------------------------------------------------------
;  GetSystemTimes fills three FILETIME structs (each 8 bytes / QWORD).
;  FILETIME = 100-nanosecond intervals since Jan 1 1601.
;
;  CPU % = 1 - (deltaIdle / (deltaKernel + deltaUser)) * 100
;
;  Note: deltaKernel already INCLUDES idle time on Windows.
;  So: active = (deltaKernel + deltaUser) - deltaIdle
;      total  = deltaKernel + deltaUser
;      cpu%   = (active * 100) / total
; ---------------------------------------------------------------------------

section .text

; ===========================================================================
;  UpdateCpuUsage
;  Updates cpuPercent global (0-100).
;  Returns: EAX = current CPU percent.
;  On first call, saves baseline and returns 0.
; ===========================================================================
UpdateCpuUsage:
    push    rbx
    push    rsi
    push    rdi
    ; 3 pushes + 8 ret = 32 total. RSP after pushes = caller_rsp - 32 (ALIGNED).
    ; sub N must be divisible by 16. shadow(32) + FILETIMEs(24) + pad(8) = 64. 64/16=4 ✓
    sub     rsp, 64

    ; --- GetSystemTimes(&idleTime, &kernelTime, &userTime) ---
    ; Store the three FILETIMEs at [rsp+32], [rsp+40], [rsp+48]
    lea     rcx, [rsp+32]       ; lpIdleTime
    lea     rdx, [rsp+40]       ; lpKernelTime
    lea     r8,  [rsp+48]       ; lpUserTime
    call    GetSystemTimes
    test    eax, eax
    jz      .fail

    ; --- Load current values ---
    mov     rbx, [rsp+32]       ; curIdle
    mov     rsi, [rsp+40]       ; curKernel
    mov     rdi, [rsp+48]       ; curUser

    ; --- Check if first call ---
    cmp     dword [rel cpuInitialized], 0
    jne     .compute_delta

    ; First call: save baseline and return 0
    mov     [rel prevIdleTime],   rbx
    mov     [rel prevKernelTime], rsi
    mov     [rel prevUserTime],   rdi
    mov     dword [rel cpuInitialized], 1
    xor     eax, eax
    jmp     .done

.compute_delta:
    ; --- Compute deltas ---
    sub     rbx, [rel prevIdleTime]     ; deltaIdle
    sub     rsi, [rel prevKernelTime]   ; deltaKernel
    sub     rdi, [rel prevUserTime]     ; deltaUser

    ; --- Save new baseline ---
    mov     rax, [rsp+32]
    mov     [rel prevIdleTime], rax
    mov     rax, [rsp+40]
    mov     [rel prevKernelTime], rax
    mov     rax, [rsp+48]
    mov     [rel prevUserTime], rax

    ; --- total = deltaKernel + deltaUser ---
    add     rsi, rdi                    ; rsi = total

    ; --- Guard against division by zero ---
    test    rsi, rsi
    jz      .return_prev

    ; --- active = total - deltaIdle ---
    mov     rax, rsi
    sub     rax, rbx                    ; rax = active
    js      .return_prev               ; sanity: active shouldn't be negative

    ; --- cpu% = (active * 100) / total ---
    imul    rax, 100
    xor     rdx, rdx
    div     rsi                        ; rax = percent (0-100)

    ; Clamp to 100
    cmp     rax, 100
    jbe     .store_result
    mov     rax, 100

.store_result:
    mov     dword [rel cpuPercent], eax
    jmp     .done

.return_prev:
    mov     eax, [rel cpuPercent]       ; plain mov auto-zero-extends (movzx dword is illegal)
    jmp     .done

.fail:
    xor     eax, eax

.done:
    add     rsp, 64
    pop     rdi
    pop     rsi
    pop     rbx
    ret
