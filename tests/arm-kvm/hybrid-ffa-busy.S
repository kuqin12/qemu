.section .text.boot, "ax"
.global _start

.equ UART0,              0x09000000
.equ UARTDR,             0x000
.equ UARTFR,             0x018

.equ PSCI_CPU_ON,        0xc4000003
.equ PSCI_SYSTEM_OFF,    0x84000008
.equ FFA_DIRECT_REQ2,    0xc400008d
.equ FFA_DIRECT_RESP2,   0xc400008e
.equ FFA_ERROR,          0x84000060
.equ FFA_BUSY,           0xfffffffc
.equ FFA_ENDPOINTS_REQ,  0x00008002

.equ STACK_SIZE,         0x1000
.equ READY_MASK,         3

_start:
    msr daifset, #0xf
    mov x21, #0
    bl setup_stack

    ldr x0, =shared_start
    ldr x1, =shared_end
clear_shared:
    cmp x0, x1
    b.hs shared_cleared
    str xzr, [x0], #8
    b clear_shared
shared_cleared:

    ldr x0, =PSCI_CPU_ON
    mov x1, #1
    ldr x2, =secondary_entry
    mov x3, #1
    hvc #0
    cbnz x0, failed

    bl mark_ready
wait_both_ready:
    ldr x0, =ready_mask
    ldar x0, [x0]
    cmp x0, #READY_MASK
    b.ne wait_both_ready

    ldr x0, =start_flag
    mov x1, #1
    stlr x1, [x0]
    sev
    b issue_call

secondary_entry:
    msr daifset, #0xf
    mov x21, x0
    bl setup_stack
    bl mark_ready
wait_start:
    ldr x0, =start_flag
    ldar x0, [x0]
    cbz x0, wait_start

issue_call:
    ldr x0, =FFA_DIRECT_REQ2
    ldr x1, =FFA_ENDPOINTS_REQ
    ldr x2, =0xaf4f0618a462b817
    ldr x3, =0x613835589a08b386
    ldr x4, =0x0f000001
    mov x5, #0
    mov x6, #0
    mov x7, #0
    mov x8, #0
    mov x9, #0
    mov x10, #0
    mov x11, #0
    mov x12, #0
    mov x13, #0
    mov x14, #0
    mov x15, #0
    mov x16, #0
    mov x17, #0
    smc #0

    mov x19, x0
    mov x22, x2
    ldr x3, =result_x0
    str x19, [x3, x21, lsl #3]
    ldr x3, =result_x2
    str x22, [x3, x21, lsl #3]

    mov x0, #1
    lsl x0, x0, x21
    ldr x1, =done_mask
mark_done:
    ldaxr x2, [x1]
    orr x2, x2, x0
    stlxr w3, x2, [x1]
    cbnz w3, mark_done
    sev

    cbz x21, primary_wait
secondary_wait:
    wfe
    b secondary_wait

primary_wait:
    ldar x0, [x1]
    cmp x0, #READY_MASK
    b.ne primary_wait

    mov x20, #0
    mov x21, #0
check_cpu:
    ldr x0, =result_x0
    ldr x0, [x0, x21, lsl #3]
    ldr x1, =FFA_DIRECT_RESP2
    cmp x0, x1
    b.eq saw_success
    ldr x1, =FFA_ERROR
    cmp x0, x1
    b.ne failed
    ldr x0, =result_x2
    ldr x0, [x0, x21, lsl #3]
    ldr x1, =FFA_BUSY
    cmp x0, x1
    b.ne failed
    add x20, x20, #2
    b next_cpu
saw_success:
    add x20, x20, #1
next_cpu:
    add x21, x21, #1
    cmp x21, #2
    b.ne check_cpu
    cmp x20, #3
    b.ne failed

    ldr x0, =pass
    bl puts
    b power_off

setup_stack:
    ldr x0, =stacks_end
    add x1, x21, #1
    sub x0, x0, x1, lsl #12
    mov sp, x0
    ret

mark_ready:
    mov x0, #1
    lsl x0, x0, x21
    ldr x1, =ready_mask
mark_ready_retry:
    ldaxr x2, [x1]
    orr x2, x2, x0
    stlxr w3, x2, [x1]
    cbnz w3, mark_ready_retry
    sev
    ret

failed:
    ldr x0, =fail
    bl puts
power_off:
    ldr x0, =PSCI_SYSTEM_OFF
    hvc #0
    b .

puts:
    mov x9, x30
    mov x8, x0
puts_loop:
    ldrb w0, [x8], #1
    cbz w0, puts_done
    bl putc
    b puts_loop
puts_done:
    ret x9

putc:
    ldr x1, =UART0
putc_wait:
    ldr w2, [x1, #UARTFR]
    tbnz w2, #5, putc_wait
    str w0, [x1, #UARTDR]
    ret

.section .rodata, "a"
pass: .asciz "HYBRID FFA BUSY PASS\n"
fail: .asciz "HYBRID FFA BUSY FAIL\n"

.section .bss, "aw", %nobits
.balign 16
shared_start:
ready_mask:  .skip 8
start_flag: .skip 8
done_mask:  .skip 8
result_x0:  .skip 16
result_x2:  .skip 16
shared_end:
.balign 4096
stacks: .skip STACK_SIZE * 2
stacks_end:
