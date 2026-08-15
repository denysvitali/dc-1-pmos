package rebootfastboot

import "unsafe"

// register reinterprets the four bytes at the start of b as the 32-bit MMIO
// register they are, so the store and the read-back can be atomic (i.e. real)
// accesses. Confined to this file so the rest of the package stays free of
// unsafe.
//
// The alignment mmap(2) guarantees is a page, and WDT_NONRST_REG2 sits at
// offset 0x24 in it, so the pointer is 4-byte aligned by construction --
// which arm64's LDAR/STLR require.
func register(b []byte) *uint32 {
	if len(b) < 4 {
		panic("register: short mapping")
	}
	return (*uint32)(unsafe.Pointer(&b[0]))
}
