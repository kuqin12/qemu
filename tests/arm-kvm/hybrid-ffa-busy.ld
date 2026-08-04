OUTPUT_ARCH(aarch64)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = 0x04000000;
    .text : { *(.text.boot) *(.text*) } :text
    .rodata : { *(.rodata*) } :text

    . = 0x47fc0000;
    .data : { *(.data*) } :data
    .bss (NOLOAD) : { *(.bss*) *(COMMON) } :data
}
