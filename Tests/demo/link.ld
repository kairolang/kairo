ENTRY(Reset_Handler)

MEMORY {
    BOOT2 (rx)  : ORIGIN = 0x10000000, LENGTH = 256
    FLASH (rx)  : ORIGIN = 0x10000100, LENGTH = 2048K - 256
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 264K
}

_estack = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS {
    .boot2 : { KEEP(*(.boot2)) } > BOOT2

    .vectors : {
        LONG(_estack)
        LONG(Reset_Handler)
    } > FLASH

    .text : {
        *(.text*)
        *(.rodata*)
        *(.got)
        *(.got.plt)
    } > FLASH

    /DISCARD/ : { *(.init_array*) *(.fini_array*) }
}