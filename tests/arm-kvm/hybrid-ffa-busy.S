.section .text.boot, "ax"
.global _start

.equ UART0,              0x09000000
.equ UARTDR,             0x000
.equ UARTFR,             0x018

.equ GICD_BASE,          0x08000000
.equ GICD_CTLR,          0x0000
.equ GICD_ENABLE_GRP1NS, (1 << 1)
.equ GICD_RWP,            (1 << 31)
.equ GICR_BASE,           0x080a0000
.equ GICR_STRIDE,         0x00020000
.equ GICR_WAKER,          0x0014
.equ GICR_IGROUPR0,       0x10080
.equ GICR_ISENABLER0,     0x10100
.equ GICR_IPRIORITYR,     0x10400
.equ GICR_PROCESSOR_SLEEP, (1 << 1)
.equ GICR_CHILDREN_ASLEEP, (1 << 2)

.equ VIRTUAL_TIMER_IRQ,  27
.equ VIRTUAL_TIMER_BIT,  (1 << VIRTUAL_TIMER_IRQ)

.equ PSCI_CPU_ON,        0xc4000003
.equ PSCI_SYSTEM_OFF,    0x84000008
.equ FFA_VERSION,        0x84000063
.equ FFA_VERSION_1_2,    0x00010002
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

    ldr x0, =FFA_VERSION
    ldr x1, =FFA_VERSION_1_2
    smc #0
    tbnz x0, #31, failed
    ldr x1, =FFA_VERSION_1_2
    cmp x0, x1
    b.lo failed

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
    bl setup_timer_irq
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
    bl setup_timer_irq

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

wait_timer:
    ldr x0, =timer_mask
    ldar x0, [x0]
    mov x1, #1
    lsl x1, x1, x21
    tst x0, x1
    b.ne timer_received
    wfi
    b wait_timer
timer_received:
    msr daifset, #2

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

setup_timer_irq:
    ldr x0, =vector_table
    msr vbar_el1, x0
    isb

    cbnz x21, gic_redist_setup
    ldr x0, =GICD_BASE
    ldr w1, [x0, #GICD_CTLR]
    orr w1, w1, #GICD_ENABLE_GRP1NS
    str w1, [x0, #GICD_CTLR]
    dsb sy
gic_dist_wait:
    ldr w1, [x0, #GICD_CTLR]
    tbnz w1, #31, gic_dist_wait

gic_redist_setup:
    ldr x0, =GICR_BASE
    mov x1, #GICR_STRIDE
    madd x0, x21, x1, x0
    ldr w1, [x0, #GICR_WAKER]
    bic w1, w1, #GICR_PROCESSOR_SLEEP
    str w1, [x0, #GICR_WAKER]
gic_redist_wait:
    ldr w1, [x0, #GICR_WAKER]
    tbnz w1, #2, gic_redist_wait

    mov w1, #VIRTUAL_TIMER_BIT
    ldr x2, =GICR_IGROUPR0
    str w1, [x0, x2]
    ldr x2, =GICR_ISENABLER0
    str w1, [x0, x2]
    ldr x2, =GICR_IPRIORITYR
    add x0, x0, x2
    mov w1, #0x80
    strb w1, [x0, #VIRTUAL_TIMER_IRQ]
    dsb sy

    mov x0, #1
    msr S3_0_C12_C12_5, x0
    isb
    mov x0, #0xff
    msr S3_0_C4_C6_0, x0
    mov x0, #1
    msr S3_0_C12_C12_7, x0

    mrs x0, cntfrq_el0
    mov x1, #100
    udiv x0, x0, x1
    mrs x1, cntvct_el0
    add x0, x0, x1
    msr cntv_cval_el0, x0
    mov x0, #1
    msr cntv_ctl_el0, x0
    isb
    msr daifclr, #2
    ret

.balign 2048
vector_table:
.macro vector target
    b \target
    .space 124
.endm
    vector unexpected
    vector irq_handler
    vector unexpected
    vector unexpected
    vector unexpected
    vector irq_handler
    vector unexpected
    vector unexpected
    vector unexpected
    vector irq_handler
    vector unexpected
    vector unexpected
    vector unexpected
    vector irq_handler
    vector unexpected
    vector unexpected

irq_handler:
    sub sp, sp, #48
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    str x4, [sp, #32]

    mrs x0, S3_0_C12_C12_0
    and w1, w0, #0x3ff
    cmp w1, #1020
    b.hs irq_restore
    cmp w1, #VIRTUAL_TIMER_IRQ
    b.ne irq_eoi

    msr cntv_ctl_el0, xzr
    mrs x1, mpidr_el1
    and x1, x1, #0xff
    mov x4, #1
    lsl x4, x4, x1
    ldr x2, =timer_mask
mark_timer:
    ldaxr x3, [x2]
    orr x3, x3, x4
    stlxr w1, x3, [x2]
    cbnz w1, mark_timer
irq_eoi:
    msr S3_0_C12_C12_1, x0
    isb
irq_restore:
    ldr x4, [sp, #32]
    ldp x2, x3, [sp, #16]
    ldp x0, x1, [sp, #0]
    add sp, sp, #48
    eret

unexpected:
    msr daifset, #0xf
    b failed

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
timer_mask: .skip 8
result_x0:  .skip 16
result_x2:  .skip 16
shared_end:
.balign 4096
stacks: .skip STACK_SIZE * 2
stacks_end:
