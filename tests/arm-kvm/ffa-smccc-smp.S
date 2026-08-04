.section .text.boot, "ax"
.global _start

.equ UART0,              0x09000000
.equ UARTDR,             0x000
.equ UARTFR,             0x018
.equ UARTFR_TXFF,        (1 << 5)

.equ PSCI_CPU_ON,        0xc4000003
.equ PSCI_SYSTEM_OFF,    0x84000008
.equ FFA_BELOW32,        0x8400005f
.equ FFA_ABOVE32,        0x8400008f
.equ FFA_BELOW64,        0xc400005f
.equ FFA_ABOVE64,        0xc400008f
.equ FFA_TEST_CALL32,    0x84000063
.equ FFA_TEST_CALL64,    0xc400006f
.equ FFA_ERROR,          0x84000060
.equ FFA_NOT_SUPPORTED,  0xffffffff

.equ CPU_COUNT,          4
.equ STACK_SIZE,         0x1000
.equ RESULT_SIZE,        0x40
.equ COMPLETE_MASK,      ((1 << CPU_COUNT) - 1)

_start:
    msr daifset, #0xf
    ldr x20, =stacks_end
    mrs x21, mpidr_el1
    and x21, x21, #0xff
    add x22, x21, #1
    sub x20, x20, x22, lsl #12
    mov sp, x20

    cbnz x21, run_test

    ldr x0, =results
    mov x1, #(RESULT_SIZE * CPU_COUNT)
clear_results:
    str xzr, [x0], #8
    subs x1, x1, #8
    b.ne clear_results

    ldr x0, =FFA_BELOW32
    smc #0
    ldr x0, =FFA_ABOVE32
    smc #0
    ldr x0, =FFA_BELOW64
    smc #0
    ldr x0, =FFA_ABOVE64
    smc #0

    ldr x23, =secondary_entry
    mov x24, #1
start_secondary:
    ldr x0, =PSCI_CPU_ON
    mov x1, x24
    mov x2, x23
    mov x3, x24
    hvc #0

    ldr x4, =results
    add x4, x4, x24, lsl #6
    str x0, [x4, #0]

    add x24, x24, #1
    cmp x24, #CPU_COUNT
    b.ne start_secondary
    b run_test

secondary_entry:
    msr daifset, #0xf
    mov x21, x0
    ldr x20, =stacks_end
    add x22, x21, #1
    sub x20, x20, x22, lsl #12
    mov sp, x20

run_test:
    ldr x0, =FFA_TEST_CALL32
    bl do_ffa_call

    ldr x26, =results
    add x26, x26, x21, lsl #6
    str x0, [x26, #8]
    str x2, [x26, #16]
    str x1, [x26, #24]

    ldr x0, =FFA_TEST_CALL64
    bl do_ffa_call

    str x0, [x26, #32]
    str x2, [x26, #40]
    str x1, [x26, #48]
    dmb ish
    b mark_complete

do_ffa_call:
    mov x1, #0x101
    mov x2, #0x202
    mov x3, #0x303
    mov x4, #0x404
    mov x5, #0x505
    mov x6, #0x606
    mov x7, #0x707
    mov x8, #0x808
    mov x9, #0x909
    mov x10, #0xa0a
    mov x11, #0xb0b
    mov x12, #0xc0c
    mov x13, #0xd0d
    mov x14, #0xe0e
    mov x15, #0xf0f
    mov x16, #0x1010
    mov x17, #0x1111
    smc #0

    mov x18, x1
    orr x18, x18, x3
    orr x18, x18, x4
    orr x18, x18, x5
    orr x18, x18, x6
    orr x18, x18, x7
    orr x18, x18, x8
    orr x18, x18, x9
    orr x18, x18, x10
    orr x18, x18, x11
    orr x18, x18, x12
    orr x18, x18, x13
    orr x18, x18, x14
    orr x18, x18, x15
    orr x18, x18, x16
    orr x1, x18, x17
    ret

mark_complete:
    mov x0, #1
    lsl x0, x0, x21
    ldr x1, =complete_mask
set_complete:
    ldaxr x2, [x1]
    orr x2, x2, x0
    stlxr w3, x2, [x1]
    cbnz w3, set_complete

    cbz x21, primary_wait
secondary_wait:
    wfe
    b secondary_wait

primary_wait:
    ldr x0, [x1]
    cmp x0, #COMPLETE_MASK
    b.eq report
    wfe
    b primary_wait

report:
    ldr x0, =banner
    bl puts

    mov x21, #0
    mov x22, #0
report_cpu:
    ldr x23, =results
    add x23, x23, x21, lsl #6

    ldr x0, =cpu_label
    bl puts
    mov x0, x21
    bl puthex

    ldr x0, =psci_label
    bl puts
    ldr x0, [x23, #0]
    bl puthex

    ldr x0, =s32_x0_label
    bl puts
    ldr x0, [x23, #8]
    bl puthex

    ldr x0, =x2_label
    bl puts
    ldr x0, [x23, #16]
    bl puthex

    ldr x0, =other_label
    bl puts
    ldr x0, [x23, #24]
    bl puthex

    ldr x0, =s64_x0_label
    bl puts
    ldr x0, [x23, #32]
    bl puthex

    ldr x0, =x2_label
    bl puts
    ldr x0, [x23, #40]
    bl puthex

    ldr x0, =other_label
    bl puts
    ldr x0, [x23, #48]
    bl puthex

    mov x0, #'\n'
    bl putc

    cbz x21, check_ffa
    ldr x0, [x23, #0]
    orr x22, x22, x0
check_ffa:
    ldr x0, [x23, #8]
    ldr x1, =FFA_ERROR
    cmp x0, x1
    cset x0, ne
    orr x22, x22, x0

    ldr x0, [x23, #16]
    mov x1, #FFA_NOT_SUPPORTED
    cmp x0, x1
    cset x0, ne
    orr x22, x22, x0

    ldr x0, [x23, #24]
    orr x22, x22, x0

    ldr x0, [x23, #32]
    ldr x1, =FFA_ERROR
    cmp x0, x1
    cset x0, ne
    orr x22, x22, x0

    ldr x0, [x23, #40]
    mov x1, #FFA_NOT_SUPPORTED
    cmp x0, x1
    cset x0, ne
    orr x22, x22, x0

    ldr x0, [x23, #48]
    orr x22, x22, x0

    add x21, x21, #1
    cmp x21, #CPU_COUNT
    b.ne report_cpu

    cbnz x22, failed
    ldr x0, =pass
    bl puts
    mov x0, #0
    b exit
failed:
    ldr x0, =fail
    bl puts
    mov x0, #1
exit:
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
banner:      .asciz "FFA SMCCC SMP validation\n"
cpu_label:   .asciz "cpu="
psci_label:  .asciz " psci="
s32_x0_label: .asciz " smc32.x0="
s64_x0_label: .asciz " smc64.x0="
x2_label:    .asciz " x2="
other_label: .asciz " other="
pass:        .asciz "PASS\n"
fail:        .asciz "FAIL\n"

.section .bss, "aw", %nobits
.balign 16
results:
    .skip RESULT_SIZE * CPU_COUNT
complete_mask:
    .skip 8
.balign 4096
stacks:
    .skip STACK_SIZE * CPU_COUNT
stacks_end:
