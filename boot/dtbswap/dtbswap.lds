/* SPDX-License-Identifier: GPL-2.0-only */
OUTPUT_ARCH(aarch64)
ENTRY(_start)
SECTIONS
{
	. = 0;
	.head.text : { *(.head.text) }
	.text      : { *(.text .text.*) }
	.rodata    : { *(.rodata .rodata.*) }
	.data      : { *(.data .data.*) }
	/* No .bss: nothing is zero-initialised, and LK will not clear it. */
	. = ALIGN(8);
	_end = .;
	/DISCARD/  : { *(.comment) *(.note.*) *(.eh_frame*) }
}
