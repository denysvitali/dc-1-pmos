package rebootfastboot

import "unsafe"

// unsafePointer gives msync the address of the mapping. Confined to this file
// so the rest of the package stays free of unsafe.
func unsafePointer(b []byte) unsafe.Pointer {
	if len(b) == 0 {
		return nil
	}
	return unsafe.Pointer(&b[0])
}
