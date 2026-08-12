.section .text.boot, "ax"
.global _start

.equ UART0,             0x09000000
.equ UARTDR,            0x000
.equ UARTFR,            0x018

.equ STACK_TOP,         0x48000000
.equ REBOOT_COUNTER,    0x49000000

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
