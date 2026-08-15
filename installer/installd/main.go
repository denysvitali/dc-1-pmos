// dc1-installd -- the device-side USB installer daemon.
//
// Listens on TCP 5555 and serves one DC1-INSTALL-V1 session at a time, the
// same wire protocol the shell implementation spoke, so the host script
// (installer/host/dc1-install.sh) is unchanged.
//
// It exists because the shell version silently corrupted every install: the
// busybox pipeline that split the held-back superblock off the stream
// (head -c | tee | dd) discarded whatever `head` over-read past its byte
// count -- 1023 bytes, measured on hardware -- so the body write began
// mid-image and every byte after the superblock landed shifted. Nothing
// caught it: the SHA-256 was computed on the `tee` branch, i.e. on what
// ARRIVED, never on what was written, and the post-write check only asked
// blkid for the filesystem type and label, which the (correct) superblock
// still satisfied. The install reported success and the root would not mount.
//
// The byte-critical path is therefore exact by construction here (io.ReadFull
// consumes precisely what it is asked for, whatever sizes the socket returns)
// and the image is read back off the device and hashed before the session is
// called a success.
//
// Everything after the bytes land -- mount, grow, provision -- is delegated to
// the existing, proven shell (finalize.sh); it is not byte-critical and
// rewriting it would risk a working path for no gain.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/denysvitali/dc-1-pmos/installer/installd/internal/imagewrite"
	"github.com/denysvitali/dc-1-pmos/installer/installd/internal/partition"
	"github.com/denysvitali/dc-1-pmos/installer/installd/internal/wire"
)

const (
	answersPath  = "/tmp/answers"
	finalizePath = "/etc/installer/finalize.sh"
	lockDir      = "/tmp/install.lock"
)

func main() {
	addr := flag.String("listen", "172.16.42.1:5555", "address to serve DC1-INSTALL-V1 on")
	finalize := flag.String("finalize", finalizePath, "script that mounts, grows and provisions")
	once := flag.Bool("once", false, "serve a single session and exit (tests)")
	flag.Parse()

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen %s: %v", *addr, err)
	}
	log.Printf("installer daemon listening on %s", *addr)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		serve(conn, *finalize)
		conn.Close()
		if *once {
			return
		}
	}
}

// serve handles one session. Every reply the host sees is written here, and
// the session always ends in exactly one OK or FAIL line.
func serve(conn net.Conn, finalize string) {
	say := func(format string, args ...any) {
		fmt.Fprintf(conn, "DC1: "+format+"\n", args...)
	}
	fail := func(format string, args ...any) {
		fmt.Fprintf(conn, "DC1-INSTALL: FAIL "+format+"\n", args...)
		log.Printf("session failed: "+format, args...)
	}

	say("HOST CONNECTED")

	// One install at a time, across both transports. mkdir is the atomic test.
	if err := os.Mkdir(lockDir, 0o700); err != nil {
		fail("another install is running")
		return
	}
	defer os.Remove(lockDir)

	// The SAME buffered reader must carry the body: bufio will have read past
	// the header's blank line, and handing the raw conn to the body would drop
	// those bytes.
	br := bufio.NewReaderSize(conn, 1<<20)
	hdr, err := wire.ParseHeader(br)
	if err != nil {
		fail("bad header: %v", err)
		return
	}

	if hdr.Unprovisioned {
		say("UNPROVISIONED INSTALL: onboarding will run on first boot")
	} else {
		if err := writeAnswers(hdr.Answers); err != nil {
			fail("answers: %v", err)
			return
		}
		// Validate BEFORE anything destructive, so a typo in the username does
		// not cost a 1.5 GiB transfer and a wiped partition.
		if out, err := exec.Command("/etc/installer/provision.sh", "--validate", answersPath).CombinedOutput(); err != nil {
			fail("answers failed validation: %s", firstLine(out))
			return
		}
	}

	target, err := partition.ResolveUserdata()
	if err != nil {
		fail("cannot resolve userdata: %v", err)
		return
	}
	say("TARGET %s (%d GIB)", target.Device, target.Bytes/(1<<30))

	if hdr.Size > target.Bytes {
		fail("image (%d bytes) larger than userdata (%d bytes)", hdr.Size, target.Bytes)
		return
	}

	dev, err := imagewrite.OpenTarget(target.Device)
	if err != nil {
		fail("cannot open %s: %v", target.Device, err)
		return
	}
	defer dev.Close()

	res, err := imagewrite.Write(dev, br, hdr.Size, hdr.SHA256, func(state string) {
		say("%s", state)
	})
	if err != nil {
		fail("%v", err)
		return
	}
	say("IMAGE WRITTEN + VERIFIED")

	// Not byte-critical: mount, resize2fs, provision.sh, unmount.
	args := []string{target.Device}
	if hdr.Unprovisioned {
		args = append(args, "")
	} else {
		args = append(args, answersPath)
	}
	cmd := exec.Command("/bin/sh", append([]string{finalize}, args...)...)
	cmd.Env = append(os.Environ(), "DC1_DEV="+target.Device)
	if hdr.Unprovisioned {
		cmd.Env = append(cmd.Env, "DC1_SKIP_PROVISION=1")
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		fail("finalize: %s", firstLine(out))
		return
	}
	os.Remove(answersPath)

	fmt.Fprintf(conn, "DC1-INSTALL: OK %d bytes sha256=%s rebooting-to-bootloader\n",
		res.Bytes, res.SHA256)
	log.Printf("install complete: %d bytes, sha256 %s", res.Bytes, res.SHA256)
}

func writeAnswers(answers []byte) error {
	if err := os.MkdirAll(filepath.Dir(answersPath), 0o755); err != nil {
		return err
	}
	return os.WriteFile(answersPath, answers, 0o600)
}

func firstLine(b []byte) string {
	for i, c := range b {
		if c == '\n' {
			return string(b[:i])
		}
	}
	if len(b) == 0 {
		return "(no output)"
	}
	return string(b)
}
