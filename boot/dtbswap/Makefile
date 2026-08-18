# SPDX-License-Identifier: GPL-2.0-only
# Freestanding arm64 stub. Built with the same clang the kernel uses.
CC      := /usr/lib/llvm20/bin/clang
OBJCOPY := /usr/lib/llvm20/bin/llvm-objcopy
CFLAGS  := --target=aarch64-linux-gnu -ffreestanding -fno-stack-protector \
           -fno-PIE -mgeneral-regs-only -Os -Wall -Wextra -std=gnu11
LDFLAGS := --ld-path=/usr/lib/llvm20/bin/ld.lld -nostdlib -static -no-pie -Wl,-T,dtbswap.lds -Wl,--build-id=none

dtbswap.bin: dtbswap.elf
	$(OBJCOPY) -O binary $< $@

dtbswap.elf: head.S main.c dtbswap.lds
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ head.S main.c

clean:
	rm -f dtbswap.elf dtbswap.bin
.PHONY: clean
