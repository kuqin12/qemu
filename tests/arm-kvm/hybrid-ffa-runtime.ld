OUTPUT_ARCH(aarch64)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
}

SECTIONS
{
    . = 0x04000000;
    .text : { *(.text.boot) *(.text*) } :text
    .rodata : { *(.rodata*) } :text
}
