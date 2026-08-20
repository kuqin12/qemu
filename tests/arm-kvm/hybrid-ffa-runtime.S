.section .text.boot, "ax"
.global _start

.equ UART0,             0x09000000
.equ UARTDR,            0x000
.equ UARTFR,            0x018

.equ GICD_BASE,          0x08000000
.equ GICD_CTLR,          0x0000
.equ GICD_ENABLE_GRP1NS, (1 << 1)
.equ GICD_RWP,           (1 << 31)
.equ GICR_BASE,          0x080a0000
.equ GICR_WAKER,         0x0014
.equ GICR_IGROUPR0,      0x10080
.equ GICR_ISENABLER0,    0x10100
.equ GICR_IPRIORITYR,    0x10400
.equ GICR_PROCESSOR_SLEEP, (1 << 1)
.equ GICR_CHILDREN_ASLEEP, (1 << 2)

.equ VIRTUAL_TIMER_IRQ,  27
.equ VIRTUAL_TIMER_BIT,  (1 << VIRTUAL_TIMER_IRQ)

.equ STACK_TOP,         0x48000000
.equ REBOOT_COUNTER,    0x49000000
.equ TIMER_SEEN,         0x49000008

.equ PSCI_SYSTEM_OFF,   0x84000008
.equ PSCI_FEATURES,     0x8400000a
#ifndef PSCI_RESET_FID
#define PSCI_RESET_FID 0x84000009
#endif
.equ PSCI_SYSTEM_RESET, PSCI_RESET_FID
.equ FFA_VERSION,       0x84000063
.equ FFA_VERSION_1_2,   0x00010002
.equ FFA_ERROR,         0x84000060
.equ FFA_ABORTED,       0x00000000fffffff8
.equ FFA_DIRECT_REQ2,   0xc400008d
.equ FFA_DIRECT_RESP2,  0xc400008e
.equ FFA_ENDPOINTS_REQ, 0x00008002
.equ FFA_ENDPOINTS_RSP, 0x80020000
.equ TPM_STUB_ERROR,    0xffffffffffffffff
.equ TPM_SUCCESS,       0x05000002
.equ TPM_VERSION_1_0,   0x00010000

_start:
    msr daifset, #0xf
    ldr x0, =STACK_TOP
    mov sp, x0

    ldr x0, =FFA_VERSION
    ldr x1, =FFA_VERSION_1_2
    smc #0
#ifdef EXPECT_TIMEOUT
    mov x20, x0
    mov x24, x2
    ldr x1, =FFA_ERROR
    cmp x20, x1
    b.ne version_succeeded
    ldr x1, =FFA_ABORTED
    cmp x24, x1
    b.eq passed
    b failed
version_succeeded:
#endif
    tbnz x0, #31, failed
    ldr x1, =FFA_VERSION_1_2
    cmp x0, x1
    b.lo failed

    bl setup_timer_irq

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

    mov x20, x0
    mov x21, x1
    mov x24, x2
    mov x22, x4
    mov x23, x5

timer_wait:
    ldr x0, =TIMER_SEEN
    ldar x0, [x0]
    cbnz x0, timer_received
    wfi
    b timer_wait
timer_received:
    msr daifset, #2

#ifdef EXPECT_TIMEOUT
    ldr x0, =FFA_ERROR
    cmp x20, x0
    b.ne failed
    ldr x0, =FFA_ABORTED
    cmp x24, x0
    b.eq passed
    b failed
#else
    ldr x0, =FFA_DIRECT_RESP2
    cmp x20, x0
    b.ne failed
    ldr x0, =FFA_ENDPOINTS_RSP
    cmp x21, x0
    b.ne failed
    ldr x0, =TPM_STUB_ERROR
    cmp x22, x0
    b.eq passed
    ldr x0, =TPM_SUCCESS
    cmp x22, x0
    b.ne failed
    ldr x0, =TPM_VERSION_1_0
    cmp x23, x0
    b.ne failed
#endif

#ifdef EXPECT_RESET_REJECT
    ldr x0, =PSCI_FEATURES
    ldr x1, =PSCI_SYSTEM_RESET
    smc #0
    sxtw x20, w0
    cbnz x20, failed

    ldr x0, =PSCI_SYSTEM_RESET
    mov x1, #1
    smc #0
    sxtw x20, w0
    mov x21, #0
    mov x22, #0
    mov x23, #0
    ldr x1, =0xfffffffffffffffe
    cmp x20, x1
    b.eq passed
    b failed
#endif

#ifdef EXPECT_COLD_RESET
    ldr x0, =REBOOT_COUNTER
    ldr x1, [x0]
    cbnz x1, failed
    mov x1, #1
    str x1, [x0]
    dsb sy
    ldr x0, =cold_ready
    bl puts
#ifdef EXPECT_GUEST_COLD_RESET
    mrs x2, cntpct_el0
    mrs x3, cntfrq_el0
    add x2, x2, x3
guest_cold_delay:
    mrs x3, cntpct_el0
    cmp x3, x2
    b.lo guest_cold_delay
    ldr x0, =PSCI_SYSTEM_RESET
    mov x1, #0
    smc #0
    b .
#endif
cold_wait:
    wfi
    b cold_wait
#endif

#ifdef EXPECT_REBOOT
    ldr x0, =PSCI_FEATURES
    ldr x1, =PSCI_SYSTEM_RESET
    smc #0
    sxtw x20, w0
    cbnz x20, failed

    ldr x0, =REBOOT_COUNTER
    ldr x1, [x0]
    cmp x1, #REBOOT_COUNT
    b.hs passed
    add x1, x1, #1
    str x1, [x0]
    dsb sy
    ldr x0, =PSCI_SYSTEM_RESET
    mov x1, #0
    smc #0
    b .
#endif

passed:
    ldr x0, =pass
    bl puts
    b power_off

failed:
    msr daifset, #2
    ldr x0, =fail
    bl puts
    mov x0, x20
    bl puthex
    mov x0, #' '
    bl putc
    mov x0, x21
    bl puthex
    mov x0, #' '
    bl putc
    mov x0, x22
    bl puthex
    mov x0, #' '
    bl putc
    mov x0, x23
    bl puthex
    mov x0, #'\n'
    bl putc

power_off:
    ldr x0, =PSCI_SYSTEM_OFF
    hvc #0
    b .

setup_timer_irq:
    ldr x0, =TIMER_SEEN
    str xzr, [x0]

    ldr x0, =vector_table
    msr vbar_el1, x0
    isb

    ldr x0, =GICD_BASE
    ldr w1, [x0, #GICD_CTLR]
    orr w1, w1, #GICD_ENABLE_GRP1NS
    str w1, [x0, #GICD_CTLR]
    dsb sy
gic_dist_wait:
    ldr w1, [x0, #GICD_CTLR]
    tbnz w1, #31, gic_dist_wait

    ldr x0, =GICR_BASE
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
    sub sp, sp, #32
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]

    mrs x0, S3_0_C12_C12_0
    and w1, w0, #0x3ff
    cmp w1, #1020
    b.hs irq_restore
    cmp w1, #VIRTUAL_TIMER_IRQ
    b.ne irq_eoi

    msr cntv_ctl_el0, xzr
    ldr x2, =TIMER_SEEN
    mov x3, #1
    stlr x3, [x2]
irq_eoi:
    msr S3_0_C12_C12_1, x0
    isb
irq_restore:
    ldp x2, x3, [sp, #16]
    ldp x0, x1, [sp, #0]
    add sp, sp, #32
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
#ifdef EXPECT_TIMEOUT
pass: .asciz "HYBRID FFA TIMEOUT PASS\n"
fail: .asciz "HYBRID FFA TIMEOUT FAIL "
#else
pass: .asciz "HYBRID FFA RUNTIME PASS\n"
fail: .asciz "HYBRID FFA RUNTIME FAIL "
#endif
#ifdef EXPECT_COLD_RESET
cold_ready: .asciz "HYBRID FFA COLD READY\n"
#endif
