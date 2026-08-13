package main

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestPackBootV4CarriesSignature(t *testing.T) {
	kernel := []byte{1, 2, 3}
	ramdisk := []byte{4, 5}
	signature := bytes.Repeat([]byte{0xa5}, bootSignatureSize)
	image, err := packBoot(packOpts{
		kernel: kernel, ramdisk: ramdisk, signature: signature,
		osVersion: 0x1800017b, headerVersion: 4,
	})
	if err != nil {
		t.Fatal(err)
	}
	h, err := parseBoot(image)
	if err != nil {
		t.Fatal(err)
	}
	k, r, s, err := sections(h, image)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(k, kernel) || !bytes.Equal(r, ramdisk) || !bytes.Equal(s, signature) {
		t.Fatal("packed v4 sections differ from input")
	}
	if h.SignatureSize != bootSignatureSize || h.OSVersion != 0x1800017b {
		t.Fatalf("header has signature_size=%d os_version=0x%08x", h.SignatureSize, h.OSVersion)
	}
}

func TestPackBootV3DoesNotCarrySignature(t *testing.T) {
	image, err := packBoot(packOpts{
		kernel: []byte{1}, signature: []byte{2, 3}, headerVersion: 3,
	})
	if err != nil {
		t.Fatal(err)
	}
	h, err := parseBoot(image)
	if err != nil {
		t.Fatal(err)
	}
	_, _, signature, err := sections(h, image)
	if err != nil {
		t.Fatal(err)
	}
	if len(signature) != 0 || h.SignatureSize != 0 {
		t.Fatalf("v3 unexpectedly carries signature: len=%d size=%d", len(signature), h.SignatureSize)
	}
}

func TestSetArm64ImageSize(t *testing.T) {
	image := make([]byte, 0x40)
	copy(image[arm64ImageMagicOff:], "ARMd")
	if err := setArm64ImageSize(image, 0x2a80000); err != nil {
		t.Fatal(err)
	}
	if got := binary.LittleEndian.Uint64(image[arm64ImageSizeOff : arm64ImageSizeOff+8]); got != 0x2a80000 {
		t.Fatalf("image_size = 0x%x, want 0x2a80000", got)
	}
}

func TestSetArm64ImageSizeRejectsNonImage(t *testing.T) {
	if err := setArm64ImageSize(make([]byte, 0x40), 1); err == nil {
		t.Fatal("accepted a non-arm64 image")
	}
}
