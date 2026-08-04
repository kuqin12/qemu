.section .text.boot, "ax"
.global _start

.equ UART0,              0x09000000
.equ UARTDR,             0x000
.equ UARTFR,             0x018

.equ GICD_BASE,          0x08000000
.equ GICD_CTLR,          0x0000
.equ GICD_ENABLE_GRP1NS, (1 << 1)
.equ GICD_RWP,           (1 << 31)
.equ GICR_BASE,          0x080a0000
.equ GICR_STRIDE,        0x00020000
.equ GICR_WAKER,         0x0014
.equ GICR_IGROUPR0,      0x10080
.equ GICR_ISENABLER0,    0x10100
.equ GICR_IPRIORITYR,    0x10400
.equ GICR_PROCESSOR_SLEEP, (1 << 1)
.equ GICR_CHILDREN_ASLEEP, (1 << 2)

.equ VIRTUAL_TIMER_IRQ,  27
.equ VIRTUAL_TIMER_BIT,  (1 << VIRTUAL_TIMER_IRQ)

.equ PSCI_CPU_ON,        0xc4000003
.equ PSCI_SYSTEM_OFF,    0x84000008
.equ FFA_TEST_CALL64,    0xc400006f
.equ FFA_ERROR,          0x84000060
.equ FFA_NOT_SUPPORTED,  0xffffffff

.equ CPU_COUNT,          4
.equ STACK_SIZE,         0x1000
.equ READY_MASK,         ((1 << CPU_COUNT) - 1)
.equ MIN_SIBLING_IRQS,   4

_start:
    msr daifset, #0xf
    mrs x21, mpidr_el1
    and x21, x21, #0xff
    bl setup_stack_and_vectors
    cbnz x21, secondary_entry

    ldr x0, =shared_start
    ldr x1, =shared_end
clear_shared:
    cmp x0, x1
    b.hs shared_cleared
    str xzr, [x0], #8
    b clear_shared
shared_cleared:
    mrs x0, cntfrq_el0
    mov x1, #200
    udiv x0, x0, x1
    ldr x1, =timer_ticks
    str x0, [x1]

    bl gic_dist_init
    bl gic_init
    bl mark_ready

    ldr x23, =secondary_entry
    mov x24, #1
start_secondary:
    ldr x0, =PSCI_CPU_ON
    mov x1, x24
    mov x2, x23
    mov x3, x24
    hvc #0
    cbnz x0, failed

    add x24, x24, #1
    cmp x24, #CPU_COUNT
    b.ne start_secondary

wait_ready:
    ldr x0, =ready_mask
    ldar x0, [x0]
    cmp x0, #READY_MASK
    b.ne wait_ready

    ldr x19, =timer_counts
    ldr x20, [x19, #8]
    ldr x21, [x19, #16]
    ldr x22, [x19, #24]

    mrs x0, cntfrq_el0
    mov x1, #20
    udiv x0, x0, x1
    mrs x1, cntvct_el0
    add x0, x0, x1
    msr cntv_cval_el0, x0
    mov x0, #1
    msr cntv_ctl_el0, x0
    isb
    msr daifclr, #2

    ldr x0, [x19]
    ldr x1, =caller_before
    str x0, [x1]

    ldr x0, =FFA_TEST_CALL64
    mov x1, #0x101
    mov x2, #0x202
    smc #0

    mov x24, x0
    mov x25, x2

    ldar x0, [x19]
    msr daifset, #2
    ldr x1, =caller_after
    str x0, [x1]

    ldr x0, [x19, #8]
    sub x0, x0, x20
    ldr x1, =sibling_deltas
    str x0, [x1]

    ldr x0, [x19, #16]
    sub x0, x0, x21
    str x0, [x1, #8]

    ldr x0, [x19, #24]
    sub x0, x0, x22
    str x0, [x1, #16]

    ldr x0, =banner
    bl puts
    ldr x0, =caller_before_label
    bl puts
    ldr x0, =caller_before
    ldr x0, [x0]
    bl puthex
    ldr x0, =caller_after_label
    bl puts
    ldr x0, =caller_after
    ldr x0, [x0]
    bl puthex
    ldr x0, =deltas_label
    bl puts
    ldr x23, =sibling_deltas
    ldr x0, [x23]
    bl puthex
    mov x0, #' '
    bl putc
    ldr x0, [x23, #8]
    bl puthex
    mov x0, #' '
    bl putc
    ldr x0, [x23, #16]
    bl puthex
    ldr x0, =response_label
    bl puts
    mov x0, x24
    bl puthex
    mov x0, #' '
    bl putc
    mov x0, x25
    bl puthex
    mov x0, #'\n'
    bl putc

    ldr x0, =caller_before
    ldr x0, [x0]
    cbnz x0, failed

    ldr x0, =caller_after
    ldr x0, [x0]
    cbz x0, failed

    ldr x0, =FFA_ERROR
    cmp x24, x0
    b.ne failed
    mov x0, #FFA_NOT_SUPPORTED
    cmp x25, x0
    b.ne failed

    ldr x0, =sibling_deltas
    ldr x1, [x0]
    cmp x1, #MIN_SIBLING_IRQS
    b.lo failed
    ldr x1, [x0, #8]
    cmp x1, #MIN_SIBLING_IRQS
    b.lo failed
    ldr x1, [x0, #16]
    cmp x1, #MIN_SIBLING_IRQS
    b.lo failed

    ldr x0, =pass
    bl puts
    b power_off

secondary_entry:
    msr daifset, #0xf
    mov x21, x0
    bl setup_stack_and_vectors
    bl gic_init
    bl arm_periodic_timer
    bl mark_ready
    msr daifclr, #2
secondary_wait:
    wfi
    b secondary_wait

setup_stack_and_vectors:
    ldr x20, =stacks_end
    add x22, x21, #1
    sub x20, x20, x22, lsl #12
    mov sp, x20
    ldr x0, =vector_table
    msr vbar_el1, x0
    isb
    ret

gic_dist_init:
    ldr x0, =GICD_BASE
    ldr w1, [x0, #GICD_CTLR]
    orr w1, w1, #GICD_ENABLE_GRP1NS
    str w1, [x0, #GICD_CTLR]
    dsb sy
gic_dist_wait:
    ldr w1, [x0, #GICD_CTLR]
    tbnz w1, #31, gic_dist_wait
    ret

gic_init:
    ldr x0, =GICR_BASE
    mov x1, #GICR_STRIDE
    madd x0, x21, x1, x0

    ldr w1, [x0, #GICR_WAKER]
    bic w1, w1, #GICR_PROCESSOR_SLEEP
    str w1, [x0, #GICR_WAKER]
wait_redistributor:
    ldr w1, [x0, #GICR_WAKER]
    tbnz w1, #2, wait_redistributor

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
    isb
    ret

arm_periodic_timer:
    ldr x0, =timer_ticks
    ldr x0, [x0]
    mrs x1, cntvct_el0
    add x0, x0, x1
    msr cntv_cval_el0, x0
    mov x0, #1
    msr cntv_ctl_el0, x0
    isb
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
    msr daifset, #2
    ldr x0, =fail
    bl puts
    ldr x0, =counts_label
    bl puts
    ldr x23, =timer_counts
    mov x22, #0
print_fail_counts:
    ldr x0, [x23, x22, lsl #3]
    bl puthex
    mov x0, #' '
    bl putc
    add x22, x22, #1
    cmp x22, #CPU_COUNT
    b.ne print_fail_counts
    ldr x0, =control_label
    bl puts
    mrs x0, cntv_ctl_el0
    bl puthex
    mov x0, #' '
    bl putc
    mrs x0, S3_0_C12_C12_7
    bl puthex
    mov x0, #'\n'
    bl putc
power_off:
    ldr x0, =PSCI_SYSTEM_OFF
    hvc #0
    b .

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
    sub sp, sp, #64
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]

    mrs x0, S3_0_C12_C12_0
    and w1, w0, #0x3ff
    cmp w1, #1020
    b.hs irq_restore
    cmp w1, #VIRTUAL_TIMER_IRQ
    b.ne irq_eoi

    mrs x2, mpidr_el1
    and x2, x2, #0xff
    ldr x3, =timer_counts
    add x3, x3, x2, lsl #3
    ldr x4, [x3]
    add x4, x4, #1
    stlr x4, [x3]

    ldr x5, =timer_ticks
    ldr x5, [x5]
    mrs x6, cntvct_el0
    add x5, x5, x6
    msr cntv_cval_el0, x5
    mov x5, #1
    msr cntv_ctl_el0, x5
irq_eoi:
    msr S3_0_C12_C12_1, x0
    isb
irq_restore:
    ldp x6, x7, [sp, #48]
    ldp x4, x5, [sp, #32]
    ldp x2, x3, [sp, #16]
    ldp x0, x1, [sp, #0]
    add sp, sp, #64
    eret

unexpected:
    msr daifset, #0xf
    b failed

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

puthex:
    mov x9, x30
    mov x10, x0
    mov x11, #60
puthex_loop:
    lsr x0, x10, x11
    and x0, x0, #0xf
    cmp x0, #10
    add x1, x0, #'0'
    add x2, x0, #('a' - 10)
    csel x0, x1, x2, lo
    bl putc
    subs x11, x11, #4
    b.ge puthex_loop
    ret x9

putc:
    ldr x1, =UART0
putc_wait:
    ldr w2, [x1, #UARTFR]
    tbnz w2, #5, putc_wait
    str w0, [x1, #UARTDR]
    ret

.section .rodata, "a"
banner:              .asciz "FFA SMCCC interrupt validation\n"
caller_before_label: .asciz "caller_before="
caller_after_label:  .asciz " caller_after="
deltas_label:        .asciz " sibling_deltas="
response_label:      .asciz " response="
pass:                .asciz "PASS\n"
fail:                .asciz "FAIL\n"
counts_label:         .asciz "counts="
control_label:        .asciz "cntv_ctl igrpen1="

.section .bss, "aw", %nobits
.balign 16
shared_start:
ready_mask:
    .skip 8
timer_ticks:
    .skip 8
timer_counts:
    .skip 8 * CPU_COUNT
caller_before:
    .skip 8
caller_after:
    .skip 8
sibling_deltas:
    .skip 8 * (CPU_COUNT - 1)
shared_end:
.balign 4096
stacks:
    .skip STACK_SIZE * CPU_COUNT
stacks_end:
