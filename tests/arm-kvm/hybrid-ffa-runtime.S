.section .text.boot, "ax"
.global _start

.equ UART0,             0x09000000
.equ UARTDR,            0x000
.equ UARTFR,            0x018

.equ INTERNAL_CRB,      0x40200000
.equ STACK_TOP,         0x48000000

.equ PSCI_SYSTEM_OFF,   0x84000008
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

    ldr x0, =INTERNAL_CRB
    ldr x1, =0x4352424b564d5443
    str x1, [x0]
    dsb sy

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
    mov x22, x4
    mov x23, x5

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
pass: .asciz "HYBRID FFA RUNTIME PASS\n"
fail: .asciz "HYBRID FFA RUNTIME FAIL "
