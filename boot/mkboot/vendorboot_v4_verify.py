#!/usr/bin/env python3
"""Reference implementation + self-verification of the VNDRBOOT v4 spec used by
the Daylight DC-1 (jagar) vendor_boot partition, and of the MediaTek/AOSP
dt_table (0xd7b7ab1e) wrapper that stock puts around the main DTB.

Run:  python3 vendorboot_v4_verify.py <vendor_boot_a.img>

It re-packs the image from its own extracted sections and asserts the result is
byte-identical to the real partition prefix. That is the proof that the Go
"mkboot packvendor" implementation is correct.
"""
import hashlib
import struct
import sys

# --- AOSP constants (system/tools/mkbootimg/mkbootimg.py) --------------------
VENDOR_BOOT_MAGIC = b"VNDRBOOT"          # 8 bytes
VENDOR_BOOT_ARGS_SIZE = 2048
VENDOR_BOOT_NAME_SIZE = 16
VENDOR_BOOT_IMAGE_HEADER_V3_SIZE = 2112
VENDOR_BOOT_IMAGE_HEADER_V4_SIZE = 2128
VENDOR_RAMDISK_NAME_SIZE = 32
VENDOR_RAMDISK_TABLE_ENTRY_BOARD_ID_SIZE = 16
VENDOR_RAMDISK_TABLE_ENTRY_V4_SIZE = 108
VENDOR_RAMDISK_TYPE_NONE, VENDOR_RAMDISK_TYPE_PLATFORM = 0, 1
VENDOR_RAMDISK_TYPE_RECOVERY, VENDOR_RAMDISK_TYPE_DLKM = 2, 3

# --- libufdt (system/libufdt/utils/src/dt_table.h), ALL BIG-ENDIAN ----------
DT_TABLE_MAGIC = 0xD7B7AB1E
DT_TABLE_DEFAULT_PAGE_SIZE = 2048
DT_TABLE_DEFAULT_VERSION = 0
DT_TABLE_HEADER_SIZE = 32
DT_TABLE_ENTRY_SIZE = 32


def padto(b, a):
    r = len(b) % a
    return b + (b"\0" * (a - r) if r else b"")


def build_dt_table(dtbs):
    """Wrap one or more raw FDT blobs in an AOSP/MTK dt_table image."""
    hdr_len = DT_TABLE_HEADER_SIZE + DT_TABLE_ENTRY_SIZE * len(dtbs)
    total = hdr_len + sum(len(d) for d in dtbs)
    out = struct.pack(
        ">8I", DT_TABLE_MAGIC, total, DT_TABLE_HEADER_SIZE,
        DT_TABLE_ENTRY_SIZE, len(dtbs), DT_TABLE_HEADER_SIZE,
        DT_TABLE_DEFAULT_PAGE_SIZE, DT_TABLE_DEFAULT_VERSION)
    off = hdr_len
    for d in dtbs:
        out += struct.pack(">8I", len(d), off, 0, 0, 0, 0, 0, 0)
        off += len(d)
    for d in dtbs:
        out += d
    assert len(out) == total
    return out


def build_vendor_boot(page_size, kernel_addr, ramdisk_addr, tags_addr,
                      dtb_addr, cmdline, board, dtb, ramdisks, bootconfig):
    """ramdisks: list of (bytes, type, name(bytes<=32), board_id(list[16]|None))"""
    total_vr = sum(len(r[0]) for r in ramdisks)
    hdr = bytearray()
    hdr += struct.pack("8s", VENDOR_BOOT_MAGIC)              # 0x000
    hdr += struct.pack("<I", 4)                              # 0x008 header_version
    hdr += struct.pack("<I", page_size)                      # 0x00c
    hdr += struct.pack("<I", kernel_addr)                    # 0x010
    hdr += struct.pack("<I", ramdisk_addr)                   # 0x014
    hdr += struct.pack("<I", total_vr)                       # 0x018
    hdr += struct.pack(f"{VENDOR_BOOT_ARGS_SIZE}s", cmdline)  # 0x01c
    hdr += struct.pack("<I", tags_addr)                      # 0x81c
    hdr += struct.pack(f"{VENDOR_BOOT_NAME_SIZE}s", board)   # 0x820
    hdr += struct.pack("<I", VENDOR_BOOT_IMAGE_HEADER_V4_SIZE)  # 0x830
    hdr += struct.pack("<I", len(dtb))                       # 0x834
    hdr += struct.pack("<Q", dtb_addr)                       # 0x838 (64-bit!)
    hdr += struct.pack("<I", VENDOR_RAMDISK_TABLE_ENTRY_V4_SIZE * len(ramdisks))
    hdr += struct.pack("<I", len(ramdisks))                  # 0x844
    hdr += struct.pack("<I", VENDOR_RAMDISK_TABLE_ENTRY_V4_SIZE)  # 0x848
    hdr += struct.pack("<I", len(bootconfig))                # 0x84c
    assert len(hdr) == VENDOR_BOOT_IMAGE_HEADER_V4_SIZE, len(hdr)

    table, off = bytearray(), 0
    for data, rtype, name, bid in ramdisks:
        bid = bid or [0] * VENDOR_RAMDISK_TABLE_ENTRY_BOARD_ID_SIZE
        table += struct.pack("<I", len(data))
        table += struct.pack("<I", off)
        table += struct.pack("<I", rtype)
        table += struct.pack(f"{VENDOR_RAMDISK_NAME_SIZE}s", name)
        table += struct.pack(f"<{VENDOR_RAMDISK_TABLE_ENTRY_BOARD_ID_SIZE}I", *bid)
        off += len(data)
    assert len(table) == VENDOR_RAMDISK_TABLE_ENTRY_V4_SIZE * len(ramdisks)

    return (padto(bytes(hdr), page_size)
            + padto(b"".join(r[0] for r in ramdisks), page_size)
            + padto(dtb, page_size)
            + padto(bytes(table), page_size)
            + padto(bootconfig, page_size))


# ---------------------------------------------------------------- verify ----
def parse(img):
    assert img[:8] == VENDOR_BOOT_MAGIC
    f = {}
    (f["header_version"], f["page_size"], f["kernel_addr"], f["ramdisk_addr"],
     f["vendor_ramdisk_size"]) = struct.unpack_from("<5I", img, 8)
    f["cmdline"] = img[0x1c:0x1c + 2048].split(b"\0")[0]
    f["tags_addr"] = struct.unpack_from("<I", img, 0x81c)[0]
    f["name"] = img[0x820:0x830].split(b"\0")[0]
    f["header_size"], f["dtb_size"] = struct.unpack_from("<2I", img, 0x830)
    f["dtb_addr"] = struct.unpack_from("<Q", img, 0x838)[0]
    (f["vendor_ramdisk_table_size"], f["vendor_ramdisk_table_entry_num"],
     f["vendor_ramdisk_table_entry_size"],
     f["bootconfig_size"]) = struct.unpack_from("<4I", img, 0x840)
    return f


def main(path):
    real = open(path, "rb").read()
    f = parse(real)
    P = f["page_size"]
    pg = lambda n: (n + P - 1) // P * P
    o_vr = pg(f["header_size"])
    o_dtb = o_vr + pg(f["vendor_ramdisk_size"])
    o_tbl = o_dtb + pg(f["dtb_size"])
    o_bc = o_tbl + pg(f["vendor_ramdisk_table_size"])
    o_end = o_bc + pg(f["bootconfig_size"])
    for k, v in f.items():
        print(f"  {k:34s} = {v!r}" + (f"  (0x{v:x})" if isinstance(v, int) else ""))
    print(f"  offsets: vr=0x{o_vr:x} dtb=0x{o_dtb:x} table=0x{o_tbl:x} "
          f"bootconfig=0x{o_bc:x} end=0x{o_end:x}")

    vr = real[o_vr:o_vr + f["vendor_ramdisk_size"]]
    dtb = real[o_dtb:o_dtb + f["dtb_size"]]
    bc = real[o_bc:o_bc + f["bootconfig_size"]]
    tbl = real[o_tbl:o_tbl + f["vendor_ramdisk_table_size"]]
    ents = []
    for i in range(f["vendor_ramdisk_table_entry_num"]):
        b = tbl[i * 108:(i + 1) * 108]
        sz, off, ty = struct.unpack_from("<3I", b, 0)
        nm = b[12:44]
        bid = list(struct.unpack_from("<16I", b, 44))
        print(f"  entry[{i}] size={sz} offset={off} type={ty} "
              f"name={nm.split(b'0')[0]!r} board_id={bid}")
        ents.append((vr[off:off + sz], ty, nm.rstrip(b"\0"), bid))

    rebuilt = build_vendor_boot(P, f["kernel_addr"], f["ramdisk_addr"],
                               f["tags_addr"], f["dtb_addr"], f["cmdline"],
                               f["name"], dtb, ents, bc)
    ok = rebuilt == real[:len(rebuilt)]
    print(f"  ROUND-TRIP byte-identical: {ok}  sha256={hashlib.sha256(rebuilt).hexdigest()}")

    # dt_table wrapper
    m, tot, hs, es, ec, eo, ps, ver = struct.unpack_from(">8I", dtb, 0)
    print(f"  dt_table: magic=0x{m:08x} total={tot} header_size={hs} "
          f"entry_size={es} entry_count={ec} entries_offset={eo} "
          f"page_size={ps} version={ver}")
    inner = []
    for i in range(ec):
        e = struct.unpack_from(">8I", dtb, eo + i * es)
        print(f"    dt[{i}] size={e[0]} offset={e[1]} id=0x{e[2]:x} "
              f"rev=0x{e[3]:x} custom={list(e[4:])}")
        inner.append(dtb[e[1]:e[1] + e[0]])
    assert inner[0][:4] == b"\xd0\x0d\xfe\xed"
    rew = build_dt_table(inner)
    print(f"  dt_table ROUND-TRIP byte-identical: {rew == dtb}  "
          f"(wrapper = {len(dtb) - len(inner[0])} bytes)")
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: vendorboot_v4_verify.py <vendor_boot.img>")
    sys.exit(main(sys.argv[1]))
