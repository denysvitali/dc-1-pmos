# SPDX-License-Identifier: GPL-2.0-only
# Freestanding arm64 stub. Built with the same clang family the kernel uses.
# LLVM/LLD are overridable so CI (Ubuntu, /usr/bin/clang + /usr/bin/ld.lld)
# and this host (Alpine, llvm19/llvm20 in /usr/lib/llvmNN/bin) can both build
# it: the stub is 6 KB of -ffreestanding C with a fixed linker script, and a
# clang19 build was boot-proven on hardware 2026-08-19, so minor compiler
# drift is acceptable here in a way it is not for the kernel itself.
LLVM    ?= /usr/lib/llvm20/bin/
LLD     ?= $(LLVM)ld.lld
CC      := $(LLVM)clang
OBJCOPY := $(LLVM)llvm-objcopy
CFLAGS  := --target=aarch64-linux-gnu -ffreestanding -fno-stack-protector \
           -fno-PIE -mgeneral-regs-only -Os -Wall -Wextra -std=gnu11
LDFLAGS := --ld-path=$(LLD) -nostdlib -static -Wl,-T,dtbswap.lds -Wl,--build-id=none

dtbswap.bin: dtbswap.elf
	$(OBJCOPY) -O binary $< $@

dtbswap.elf: head.S main.c dtbswap.lds
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ head.S main.c

clean:
	rm -f dtbswap.elf dtbswap.bin
.PHONY: clean
