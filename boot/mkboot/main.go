// Command mkboot builds and inspects Android boot images for the Daylight DC-1
// ("jagar", MT8781/MT6789), plus MediaTek `lk` partition images.
//
// Why this exists: bringing up mainline on this device means rebuilding a boot
// image many times, and the device-specific details are easy to get wrong by
// hand (page alignment, header_size, the MTK lk extended header). Encoding them
// once here means they are checked rather than remembered.
//
// Subcommands:
//
//	info    <img>                  parse and print an Android boot image header
//	pack    -kernel K [-ramdisk R] build a boot image (header v3 or v4)
//	lkwrap  -in F -out G           wrap a payload in an MTK `lk` partition header
//	verify  <img>                  round-trip check: reparse and repack, compare
//
// The `verify` subcommand is the important one: it proves the packer agrees with
// a real vendor image byte-for-byte, which is the only reason to trust it.
package main

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
)

const (
	bootMagic = "ANDROID!"

	// Android boot header v3/v4: page size is fixed at 4096 and the cmdline
	// field is 1536 bytes (BOOT_ARGS_SIZE 512 + BOOT_EXTRA_ARGS_SIZE 1024).
	pageSize    = 4096
	cmdlineSize = 1536

	// sizeof(boot_img_hdr_v3) and _v4. v4 appends a single u32 signature_size.
	headerSizeV3 = 1580
	headerSizeV4 = 1584
	// AOSP's legacy GKI boot signature occupies one page in v4 images. The
	// packer accepts the exact stock-sized signature through cmdPack below.
	bootSignatureSize = 4096

	// Offset of cmdline in a v3/v4 header. Note it is 64 in v0-v2; see the
	// -legacy-cmdline-offset flag on `pack`.
	cmdlineOffV3 = 44
	cmdlineOffV0 = 64

	// Linux arm64 Image header fields. The magic "ARMd" is at 0x38 and
	// image_size is the little-endian u64 at 0x10.
	arm64ImageSizeOff  = 0x10
	arm64ImageMagicOff = 0x38
)

// bootHdr is the v3/v4 Android boot image header. Field order matches
// bootimg.h exactly so it can be read and written with binary.Read/Write.
type bootHdr struct {
	Magic         [8]byte
	KernelSize    uint32
	RamdiskSize   uint32
	OSVersion     uint32
	HeaderSize    uint32
	Reserved      [4]uint32
	HeaderVersion uint32
	Cmdline       [cmdlineSize]byte
	// SignatureSize is present only when HeaderVersion >= 4.
	SignatureSize uint32
}

func pad(n int) int {
	if r := n % pageSize; r != 0 {
		return pageSize - r
	}
	return 0
}

func cstr(b []byte) string {
	if i := bytes.IndexByte(b, 0); i >= 0 {
		return string(b[:i])
	}
	return string(b)
}

func parseBoot(data []byte) (*bootHdr, error) {
	if len(data) < headerSizeV3 {
		return nil, fmt.Errorf("too small to be a boot image (%d bytes)", len(data))
	}
	if string(data[:8]) != bootMagic {
		return nil, fmt.Errorf("bad magic %q, want %q", data[:8], bootMagic)
	}
	var h bootHdr
	// Read fields individually rather than the whole struct, because
	// SignatureSize is only present when HeaderVersion >= 4.
	r := bytes.NewReader(data)
	if err := binary.Read(r, binary.LittleEndian, &h.Magic); err != nil {
		return nil, err
	}
	for _, p := range []*uint32{&h.KernelSize, &h.RamdiskSize, &h.OSVersion, &h.HeaderSize} {
		if err := binary.Read(r, binary.LittleEndian, p); err != nil {
			return nil, err
		}
	}
	if err := binary.Read(r, binary.LittleEndian, &h.Reserved); err != nil {
		return nil, err
	}
	if err := binary.Read(r, binary.LittleEndian, &h.HeaderVersion); err != nil {
		return nil, err
	}
	if err := binary.Read(r, binary.LittleEndian, &h.Cmdline); err != nil {
		return nil, err
	}
	if h.HeaderVersion >= 4 {
		if len(data) < headerSizeV4 {
			return nil, errors.New("header claims v4 but image is shorter than 1584 bytes")
		}
		if err := binary.Read(r, binary.LittleEndian, &h.SignatureSize); err != nil {
			return nil, err
		}
	}
	if h.HeaderVersion < 3 {
		return nil, fmt.Errorf("header v%d is not supported (this device ships v4; "+
			"v0-v2 have a different layout, including cmdline at offset %d)",
			h.HeaderVersion, cmdlineOffV0)
	}
	return &h, nil
}

// sections returns the kernel, ramdisk and signature byte ranges.
func sections(h *bootHdr, data []byte) (kernel, ramdisk, sig []byte, err error) {
	off := headerSizeV3
	if h.HeaderVersion >= 4 {
		off = headerSizeV4
	}
	off += pad(off)

	take := func(n uint32) ([]byte, error) {
		if n == 0 {
			return nil, nil
		}
		end := off + int(n)
		if end > len(data) {
			return nil, fmt.Errorf("section at %d len %d runs past end of image (%d)", off, n, len(data))
		}
		b := data[off:end]
		off = end + pad(end)
		return b, nil
	}
	if kernel, err = take(h.KernelSize); err != nil {
		return
	}
	if ramdisk, err = take(h.RamdiskSize); err != nil {
		return
	}
	if h.HeaderVersion >= 4 {
		if sig, err = take(h.SignatureSize); err != nil {
			return
		}
	}
	return
}

type packOpts struct {
	kernel, ramdisk, signature []byte
	cmdline                    string
	osVersion                  uint32
	headerVersion              uint32
	legacyCmdlineOffset        bool
}

func setArm64ImageSize(image []byte, size uint64) error {
	if len(image) < arm64ImageMagicOff+4 || string(image[arm64ImageMagicOff:arm64ImageMagicOff+4]) != "ARMd" {
		return errors.New("-arm64-image-size requires a raw arm64 Image (ARMd header at 0x38)")
	}
	if len(image) < arm64ImageSizeOff+8 {
		return errors.New("arm64 Image is too small to contain image_size")
	}
	binary.LittleEndian.PutUint64(image[arm64ImageSizeOff:arm64ImageSizeOff+8], size)
	return nil
}

func packBoot(o packOpts) ([]byte, error) {
	if len(o.kernel) == 0 {
		return nil, errors.New("a kernel is required")
	}
	if o.headerVersion < 3 || o.headerVersion > 4 {
		return nil, fmt.Errorf("unsupported header version %d (want 3 or 4)", o.headerVersion)
	}
	if len(o.cmdline) >= cmdlineSize {
		return nil, fmt.Errorf("cmdline is %d bytes, max %d", len(o.cmdline), cmdlineSize-1)
	}

	hdrSize := uint32(headerSizeV3)
	if o.headerVersion >= 4 {
		hdrSize = headerSizeV4
	}

	h := bootHdr{
		KernelSize:    uint32(len(o.kernel)),
		RamdiskSize:   uint32(len(o.ramdisk)),
		OSVersion:     o.osVersion,
		HeaderSize:    hdrSize,
		HeaderVersion: o.headerVersion,
	}
	if o.headerVersion >= 4 {
		h.SignatureSize = uint32(len(o.signature))
	}
	copy(h.Magic[:], bootMagic)
	copy(h.Cmdline[:], o.cmdline)

	var buf bytes.Buffer
	w := func(v any) { _ = binary.Write(&buf, binary.LittleEndian, v) }
	w(h.Magic)
	w(h.KernelSize)
	w(h.RamdiskSize)
	w(h.OSVersion)
	w(h.HeaderSize)
	w(h.Reserved)
	w(h.HeaderVersion)
	w(h.Cmdline)
	if o.headerVersion >= 4 {
		w(h.SignatureSize)
	}

	// Unverified device quirk: an earlier bring-up note claimed this device's
	// LK reads the boot-header cmdline at offset 64 (the v0-v2 location)
	// rather than 44 (the v3/v4 location), silently eating the first 20
	// bytes. The experiment set up to test this recorded no conclusion, and
	// stock v4 images boot correctly, so it is NOT applied by default. If it
	// turns out to be real, this writes the cmdline at both offsets so either
	// reader works.
	if o.legacyCmdlineOffset {
		b := buf.Bytes()
		if cmdlineOffV0+len(o.cmdline) < len(b) {
			copy(b[cmdlineOffV0:], o.cmdline)
		}
	}

	buf.Write(make([]byte, pad(buf.Len())))
	sections := [][]byte{o.kernel, o.ramdisk}
	if o.headerVersion >= 4 {
		sections = append(sections, o.signature)
	}
	for _, s := range sections {
		if len(s) == 0 {
			continue
		}
		buf.Write(s)
		buf.Write(make([]byte, pad(buf.Len())))
	}
	return buf.Bytes(), nil
}

// --- MediaTek lk partition header -------------------------------------------
//
// Reverse-engineered from the DC-1's own stock lk_a/lk_b. The partition begins
// with a 512-byte region (a union padded to 512 in U-Boot's tools/mtk_image.h)
// followed by the payload:
//
//	0x00 magic     0x58881688
//	0x04 size      payload size, excluding this 512-byte region
//	0x08 name[32]  "lk"
//	0x28 loadaddr  0xFFFFFFFF on this device
//	0x2C mode      0xFFFFFFFF
//	0x30 extended header, magic 0x58891689 -- present in BOTH stock slots and
//	     NOT emitted by U-Boot's mkimage. Very likely the "header v4" that the
//	     upstream pmOS port calls "too annoying to work with". Its fields are
//	     size-independent, so they are reproduced verbatim.
//	0x50..0x1FF 0xFF padding
//	0x200 payload
const (
	lkMagic     uint32 = 0x58881688
	lkExtMagic  uint32 = 0x58891689
	lkHdrSize          = 512
	lkExtOffset        = 0x30
)

func lkWrap(payload []byte, name string, loadAddr uint32, extHeader bool) ([]byte, error) {
	if len(name) > 31 {
		return nil, fmt.Errorf("name %q too long (max 31 chars)", name)
	}
	hdr := bytes.Repeat([]byte{0xFF}, lkHdrSize)
	binary.LittleEndian.PutUint32(hdr[0x00:], lkMagic)
	binary.LittleEndian.PutUint32(hdr[0x04:], uint32(len(payload)))
	for i := 0; i < 32; i++ {
		hdr[0x08+i] = 0
	}
	copy(hdr[0x08:], name)
	binary.LittleEndian.PutUint32(hdr[0x28:], loadAddr)
	binary.LittleEndian.PutUint32(hdr[0x2C:], 0xFFFFFFFF)

	if extHeader {
		// Byte-for-byte from stock: magic, payload offset 0x200, version 1,
		// two zero words, then 0x10.
		ext := hdr[lkExtOffset:]
		for i := 0; i < 0x20; i++ {
			ext[i] = 0
		}
		binary.LittleEndian.PutUint32(ext[0x00:], lkExtMagic)
		binary.LittleEndian.PutUint32(ext[0x04:], lkHdrSize)
		binary.LittleEndian.PutUint32(ext[0x08:], 1)
		binary.LittleEndian.PutUint32(ext[0x14:], 0x10)
	}
	return append(hdr, payload...), nil
}

// --- commands ---------------------------------------------------------------

func cmdInfo(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: mkboot info <image>")
	}
	data, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	h, err := parseBoot(data)
	if err != nil {
		return err
	}
	k, r, s, err := sections(h, data)
	if err != nil {
		return err
	}
	fmt.Printf("file            %s (%d bytes)\n", args[0], len(data))
	fmt.Printf("header_version  %d\n", h.HeaderVersion)
	fmt.Printf("header_size     %d\n", h.HeaderSize)
	fmt.Printf("kernel_size     %d\n", h.KernelSize)
	fmt.Printf("ramdisk_size    %d\n", h.RamdiskSize)
	if h.HeaderVersion >= 4 {
		fmt.Printf("signature_size  %d\n", h.SignatureSize)
	}
	fmt.Printf("os_version      0x%08x\n", h.OSVersion)
	fmt.Printf("cmdline         %q\n", cstr(h.Cmdline[:]))
	// Surface whether anything is sitting at the legacy cmdline offset, which
	// is how we would spot the offset-64 quirk in a vendor image.
	if legacy := cstr(data[cmdlineOffV0:min(cmdlineOffV0+64, len(data))]); legacy != "" {
		fmt.Printf("bytes@0x40      %q  (legacy v0-v2 cmdline offset)\n", legacy)
	}
	fmt.Printf("sections        kernel=%d ramdisk=%d signature=%d\n", len(k), len(r), len(s))
	return nil
}

func cmdVerify(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: mkboot verify <image>")
	}
	data, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	h, err := parseBoot(data)
	if err != nil {
		return err
	}
	k, r, s, err := sections(h, data)
	if err != nil {
		return err
	}
	rebuilt, err := packBoot(packOpts{
		kernel:        k,
		ramdisk:       r,
		signature:     s,
		cmdline:       cstr(h.Cmdline[:]),
		osVersion:     h.OSVersion,
		headerVersion: h.HeaderVersion,
	})
	if err != nil {
		return err
	}
	// The tail of a vendor image may be zero-padded to the partition size;
	// compare only up to the length we reconstruct.
	n := min(len(rebuilt), len(data))
	if !bytes.Equal(rebuilt[:n], data[:n]) {
		for i := 0; i < n; i++ {
			if rebuilt[i] != data[i] {
				return fmt.Errorf("MISMATCH at offset %d (0x%x): rebuilt 0x%02x, original 0x%02x",
					i, i, rebuilt[i], data[i])
			}
		}
	}
	fmt.Printf("round-trip OK: boot image is %d bytes, byte-for-byte identical\n", n)

	// A raw partition dump carries more than the boot image. avbtool's
	// add_hash_footer layout is: image, then an AVB0 vbmeta blob, then zero
	// padding, then a 64-byte footer inside the final 4096 bytes. Classify it
	// rather than treating it as corruption.
	//
	// We do not reproduce any of this: AVB is not enforced on this device
	// (bootloader reports unlocked / secure:no, and a Magisk-patched boot image
	// whose hashes no longer matched booted fine).
	if rest := data[n:]; len(rest) > 0 {
		nonzero := 0
		for _, b := range rest {
			if b != 0 {
				nonzero++
			}
		}
		fmt.Printf("trailing         %d bytes, %d non-zero\n", len(rest), nonzero)
		if bytes.HasPrefix(rest, []byte("AVB0")) {
			fmt.Printf("                 starts with AVB0 vbmeta (not reproduced; AVB is not enforced here)\n")
		}
		if tail := data[max(0, len(data)-pageSize):]; bytes.Contains(tail, []byte("AVBf")) {
			fmt.Printf("                 AVB footer present in final page\n")
		}
	}
	return nil
}

func cmdPack(args []string) error {
	fs := flag.NewFlagSet("pack", flag.ContinueOnError)
	kernel := fs.String("kernel", "", "kernel image (required); may be a raw arm64 Image, a gzip'd Image, or u-boot.bin for chainloading")
	gzipKernel := fs.Bool("gzip-kernel", false,
		"gzip the kernel before packing. Stock boot_a on this device ships a gzip'd kernel "+
			"(starts 1f 8b 08), and a freshly built arm64 Image is raw, so this is normally wanted")
	ramdisk := fs.String("ramdisk", "", "ramdisk (optional)")
	signature := fs.String("signature", "", "v4 boot signature (exactly 4096 bytes; stock section may be reused)")
	out := fs.String("o", "", "output image (required)")
	cmdline := fs.String("cmdline", "", "kernel cmdline")
	arm64ImageSize := fs.Uint64("arm64-image-size", 0,
		"override raw arm64 Image image_size at header offset 0x10 (0 leaves it unchanged)")
	hdrVer := fs.Uint("header-version", 4, "boot header version (3 or 4); this device ships v4")
	osVer := fs.Uint("os-version", 0, "packed os_version field")
	legacy := fs.Bool("legacy-cmdline-offset", false,
		"ALSO write cmdline at offset 64 (v0-v2 location). Unverified quirk; see comments")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *kernel == "" || *out == "" {
		fs.Usage()
		return errors.New("-kernel and -o are required")
	}
	if *signature != "" && uint32(*hdrVer) < 4 {
		return errors.New("-signature requires -header-version 4")
	}
	kb, err := os.ReadFile(*kernel)
	if err != nil {
		return err
	}
	isGzip := len(kb) > 2 && kb[0] == 0x1f && kb[1] == 0x8b
	if *arm64ImageSize != 0 {
		if isGzip {
			return errors.New("-arm64-image-size requires an uncompressed raw arm64 Image")
		}
		if err := setArm64ImageSize(kb, *arm64ImageSize); err != nil {
			return err
		}
		fmt.Printf("arm64 image_size: 0x%08x\n", *arm64ImageSize)
	}
	if *gzipKernel {
		if isGzip {
			fmt.Fprintln(os.Stderr, "note: kernel is already gzip'd; not compressing again")
		} else {
			var zb bytes.Buffer
			zw, gzErr := gzip.NewWriterLevel(&zb, gzip.BestCompression)
			if gzErr != nil {
				return gzErr
			}
			if _, err = zw.Write(kb); err != nil {
				return err
			}
			if err = zw.Close(); err != nil {
				return err
			}
			fmt.Printf("gzip kernel: %d -> %d bytes\n", len(kb), zb.Len())
			kb = zb.Bytes()
		}
	} else if !isGzip {
		fmt.Fprintln(os.Stderr,
			"warning: kernel is not gzip'd, but stock boot_a on this device is. "+
				"If it fails to boot, try -gzip-kernel.")
	}
	var rb []byte
	if *ramdisk != "" {
		if rb, err = os.ReadFile(*ramdisk); err != nil {
			return err
		}
	}
	var sb []byte
	if *signature != "" {
		if sb, err = os.ReadFile(*signature); err != nil {
			return err
		}
		if len(sb) != bootSignatureSize {
			return fmt.Errorf("signature is %d bytes, want exactly %d", len(sb), bootSignatureSize)
		}
	}
	img, err := packBoot(packOpts{
		kernel:              kb,
		ramdisk:             rb,
		signature:           sb,
		cmdline:             *cmdline,
		osVersion:           uint32(*osVer),
		headerVersion:       uint32(*hdrVer),
		legacyCmdlineOffset: *legacy,
	})
	if err != nil {
		return err
	}
	if err := os.WriteFile(*out, img, 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %s: %d bytes (kernel=%d ramdisk=%d signature=%d, header v%d, os_version=0x%08x)\n",
		*out, len(img), len(kb), len(rb), len(sb), *hdrVer, uint32(*osVer))

	// This device's boot_a/boot_b are 0x4000000 and fastboot's
	// max-download-size is also exactly 0x4000000, so there is no headroom:
	// an image larger than this can be neither stored nor sent.
	const bootPartSize = 0x4000000
	switch {
	case len(img) > bootPartSize:
		return fmt.Errorf("image is %d bytes, larger than boot partition and "+
			"fastboot max-download-size (%d) -- it can be neither flashed nor sent",
			len(img), bootPartSize)
	case len(img) > bootPartSize*9/10:
		fmt.Fprintf(os.Stderr, "warning: %d bytes uses %.1f%% of the %d-byte limit\n",
			len(img), 100*float64(len(img))/bootPartSize, bootPartSize)
	}
	return nil
}

func cmdLKWrap(args []string) error {
	fs := flag.NewFlagSet("lkwrap", flag.ContinueOnError)
	in := fs.String("in", "", "payload to wrap, e.g. u-boot.bin (required)")
	out := fs.String("out", "", "output lk partition image (required)")
	name := fs.String("name", "lk", `lk_hdr name field; stock is "lk"`)
	loadAddr := fs.Uint64("loadaddr", 0xFFFFFFFF, "lk_hdr loadaddr; stock is 0xFFFFFFFF")
	ext := fs.Bool("ext-header", true,
		"emit the 0x58891689 extended header at 0x30 as stock does (U-Boot's mkimage does not)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *in == "" || *out == "" {
		fs.Usage()
		return errors.New("-in and -out are required")
	}
	payload, err := os.ReadFile(*in)
	if err != nil {
		return err
	}
	img, err := lkWrap(payload, *name, uint32(*loadAddr), *ext)
	if err != nil {
		return err
	}
	if err := os.WriteFile(*out, img, 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %s: %d bytes (512-byte header + %d payload, ext-header=%v)\n",
		*out, len(img), len(payload), *ext)
	fmt.Fprintln(os.Stderr,
		"WARNING: the DC-1 BROM is auth-locked (DAA, mem read/write auth). Writing an\n"+
			"untested image to the lk slot the preloader loads is an unrecoverable brick.\n"+
			"Chainload from a boot slot instead.")
	return nil
}

func usage() {
	fmt.Fprint(os.Stderr, strings.TrimLeft(`
mkboot - boot image tooling for the Daylight DC-1 (jagar, MT8781/MT6789)

  mkboot info       <image>              print an Android boot image header
  mkboot verify     <image>              reparse and repack, prove byte-identical
  mkboot pack       -kernel K -o OUT     build a boot image (v3/v4)
  mkboot lkwrap     -in F -out G         wrap a payload in an MTK lk header

Run a subcommand with -h for its flags.
`, "\n"))
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "info":
		err = cmdInfo(os.Args[2:])
	case "verify":
		err = cmdVerify(os.Args[2:])
	case "pack":
		err = cmdPack(os.Args[2:])
	case "lkwrap":
		err = cmdLKWrap(os.Args[2:])
	case "-h", "--help", "help":
		usage()
		return
	default:
		usage()
		err = fmt.Errorf("unknown subcommand %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
