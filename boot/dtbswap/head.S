/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * dtbswap -- arm64 stub that sits where the kernel goes in boot.img.
 *
 * LK hands control over using the Linux arm64 boot protocol: MMU and caches
 * off, x0 = physical address of the device tree it built (signed lk_main_dtb
 * merged with the signed dtbo), x1..x3 = 0. Since boot.img is the one image
 * on this device LK does not authenticate, this is the only place we can get
 * our own device tree in front of the kernel.
 *
 * The image is laid out by pack.sh as:
 *
 *     [ this stub | our dtb | real kernel Image ]
 *
 * with the offsets patched into the header below. LK gunzips the whole thing
 * to one address and jumps to offset 0, so everything is found PC-relative.
 */

	.section .head.text, "ax"
	.globl _start
_start:
	/* arm64 Image header -- makes LK treat us as a kernel. */
	nop					/* code0 (must be a valid insn) */
	b	stub_entry			/* code1 */
	.quad	0				/* text_offset */
	.quad	_end - _start			/* image_size */
	.quad	0				/* flags: LE, 4K, any placement */
	.quad	0, 0, 0				/* res2..res4 */
	.ascii	"ARM\x64"			/* magic */
	.long	0				/* res5 */

	/*
	 * Payload table, patched by pack.sh. Kept right after the header so
	 * the packer can find it at a fixed file offset (0x40).
	 */
	.globl payload
payload:
	.long	0				/* dtb offset from _start */
	.long	0				/* dtb length */
	.long	0				/* kernel offset from _start */
	.long	0				/* kernel length */

stub_entry:
	/*
	 * Trace from assembly, before the stack exists and before any C runs.
	 * This is what distinguishes "LK never jumped to us" (trace stays 0)
	 * from "we got control but the C side died" (trace reads 0xa1).
	 * 0xff0c1000, magic "DTBS".
	 */
	movz	x2, #0x1000
	movk	x2, #0xff0c, lsl #16
	movz	w3, #0x4253
	movk	w3, #0x4454, lsl #16
	str	w3, [x2]
	mov	w3, #0xa1
	str	w3, [x2, #4]

	mov	x19, x0				/* keep LK's fdt */
	adrp	x20, _start
	add	x20, x20, :lo12:_start		/* our load address */

	/*
	 * Stack. It MUST live inside this stub's own image: pack.sh appends
	 * the dtb and the kernel immediately after _end, so anything "just
	 * past the image" grows straight down through the payload. An earlier
	 * version put sp at _end+0x1000 and the C frame quietly scribbled over
	 * the device tree we were about to hand the kernel.
	 */
	adrp	x1, stack_top
	add	x1, x1, :lo12:stack_top
	and	x1, x1, #~0xf			/* SP must be 16-byte aligned */
	mov	sp, x1

	/* Reached the stack setup. */
	mov	w3, #0xa2
	str	w3, [x2, #4]

	mov	x0, x19				/* lk_fdt */
	mov	x1, x20				/* base */
	bl	dtbswap_main			/* -> x0 = fdt to boot with */

	mov	x19, x0				/* chosen fdt (ours, or LK's) */

	/*
	 * Where to jump, published by dtbswap_main. Held in x5: x0..x3 must
	 * be fdt,0,0,0 at kernel entry, so the target cannot live in x2.
	 */
	adrp	x5, jump_target
	add	x5, x5, :lo12:jump_target
	ldr	x5, [x5]

	mov	x0, x19
	mov	x1, xzr
	mov	x2, xzr
	mov	x3, xzr
	br	x5

	.globl jump_target
	.align	3
jump_target:
	.quad	0

	/* Inside .data, so it is part of the image pack.sh measures. */
	.section .data
	.align	4
stack_bottom:
	.space	4096
stack_top:
