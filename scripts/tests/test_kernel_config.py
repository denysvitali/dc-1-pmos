#!/usr/bin/env python3
"""Exercise the actual kernel recipe with mocked kbuild and ccache."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "pmaports/device/testing/linux-postmarketos-mediatek-mt6789"
REQUIRED = [
    "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y",
    "# CONFIG_CC_OPTIMIZE_FOR_SIZE is not set",
    "# CONFIG_SLUB_TINY is not set",
    "CONFIG_COMPACTION=y",
    "CONFIG_CC_IS_CLANG=y",
    "CONFIG_LD_IS_LLD=y",
    "CONFIG_CLANG_VERSION=200108",
    "CONFIG_LLD_VERSION=200108",
]
for fragment in ("sdcard.config", "latency.config", "usb-host.config"):
    REQUIRED.extend(line for line in (OVERLAY / fragment).read_text().splitlines()
                    if line.startswith("CONFIG_") and line.endswith(("=y", "=m")))
VALID = "\n".join(dict.fromkeys(REQUIRED)) + "\n"
HARNESS = r'''
error() { printf '%s\n' "$*" >&2; }
msg() { :; }
amove() {
    mkdir -p "$subpkgdir/$(dirname "$1")"
    mv "$pkgdir/$1" "$subpkgdir/$1"
}
make() {
    case " $* " in
        *' Image.gz modules '*)
            [ "${FAIL_KERNEL:-0}" = 0 ] || return 1
            [ "${MUTATE_KERNEL:-0}" = 0 ] || printf 'CONFIG_LD_IS_BFD=y\n' > .config
            ;;
        *' dtbs '*) printf 'CONFIG_LD_IS_BFD=y\n' > .config ;;
    esac
}
ccache() {
    [ "$1" != --print-stats ] || printf 'cache_miss 1\n'
    return 0
}
. "$RECIPE"
'''


class KernelConfigTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        (self.work / ".config").write_text(VALID)
        for path in ("arch/arm64/boot/Image.gz", "include/config/kernel.release",
                     "arch/arm64/boot/dts/mediatek/mt8781-daylight-jagar-live-gpu-probe.dtbo",
                     "arch/arm64/boot/dts/mediatek/mt8781-daylight-jagar-live-audio-probe.dtbo"):
            target = self.work / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"fixture\n")

    def run_recipe(self, command, **extra):
        env = dict(os.environ, RECIPE=str(OVERLAY / "APKBUILD"),
                   srcdir=str(OVERLAY), pkgdir=str(self.work / "pkg"), **extra)
        return subprocess.run(["sh", "-eu", "-c", HARNESS + command],
                              cwd=self.work, env=env, text=True, capture_output=True)

    def test_package_uses_pre_dtb_snapshot(self):
        result = self.run_recipe("build\npackage\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work / ".config").read_text(), "CONFIG_LD_IS_BFD=y\n")
        packaged = self.work / "pkg/usr/share/kernel/postmarketos-mediatek-mt6789/config"
        self.assertEqual(packaged.read_text(), VALID)

    def test_valid_config(self):
        result = self.run_recipe("_check_kernel_config .config\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_each_setting(self):
        for setting in dict.fromkeys(REQUIRED):
            with self.subTest(setting=setting):
                (self.work / ".config").write_text(VALID.replace(setting + "\n", ""))
                result = self.run_recipe("_check_kernel_config .config\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("required kernel", result.stderr)

    def test_optional_driver_must_remain_modular(self):
        for setting in REQUIRED:
            if not setting.endswith("=m"):
                continue
            with self.subTest(setting=setting):
                (self.work / ".config").write_text(VALID.replace(setting, setting[:-1] + "y"))
                result = self.run_recipe("_check_kernel_config .config\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(setting, result.stderr)

    def test_modules_split_keeps_tree_and_metadata_together(self):
        pkgdir = self.work / "pkg"
        tree = pkgdir / "lib/modules/test-release"
        (tree / "kernel/drivers/usb").mkdir(parents=True)
        (tree / "kernel/drivers/usb/example.ko").write_bytes(b"module")
        (tree / "modules.alias").write_text("alias usb:* example\n")
        (tree / "modules.dep").write_text("kernel/drivers/usb/example.ko:\n")
        (pkgdir / "boot").mkdir()
        (pkgdir / "boot/vmlinuz").write_bytes(b"kernel")
        subpkg = self.work / "modules-package"
        result = self.run_recipe('printf "%s\\n" "$depends"\nmodules\nprintf "%s\\n" "$depends"\n',
                                 subpkgdir=str(subpkg))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("linux-postmarketos-mediatek-mt6789-modules=", result.stdout)
        self.assertEqual(result.stdout.splitlines()[-1], "kmod linux-firmware-rtl_nic")
        self.assertFalse((pkgdir / "lib/modules").exists())
        self.assertTrue((pkgdir / "boot/vmlinuz").exists())
        self.assertEqual((subpkg / "lib/modules/test-release/modules.alias").read_text(),
                         "alias usb:* example\n")
        self.assertTrue((subpkg / "lib/modules/test-release/kernel/drivers/usb/example.ko").exists())

    def test_wrong_compiler_versions(self):
        for compiler in ("CLANG", "LLD"):
            for version in ("190108", "210100", "20", "2001080"):
                with self.subTest(compiler=compiler, version=version):
                    (self.work / ".config").write_text(VALID.replace(
                        f"CONFIG_{compiler}_VERSION=200108", f"CONFIG_{compiler}_VERSION={version}"))
                    self.assertNotEqual(self.run_recipe("_check_kernel_config .config\n").returncode, 0)

    def test_missing_config(self):
        (self.work / ".config").unlink()
        self.assertNotEqual(self.run_recipe("_check_kernel_config .config\n").returncode, 0)

    def test_build_failure_removes_stale_snapshot(self):
        (self.work / ".config.kernel").write_text(VALID)
        self.assertNotEqual(self.run_recipe("build\n", FAIL_KERNEL="1").returncode, 0)
        self.assertFalse((self.work / ".config.kernel").exists())

    def test_invalid_build_boundary(self):
        (self.work / ".config").write_text("CONFIG_LD_IS_BFD=y\n")
        self.assertNotEqual(self.run_recipe("build\n").returncode, 0)
        self.assertFalse((self.work / ".config.kernel").exists())

    def test_kernel_mutation_rejected(self):
        self.assertNotEqual(self.run_recipe("build\n", MUTATE_KERNEL="1").returncode, 0)
        self.assertFalse((self.work / ".config.kernel").exists())

    def test_package_requires_valid_snapshot(self):
        for content in (None, "CONFIG_LD_IS_BFD=y\n"):
            with self.subTest(content=content):
                if content is not None:
                    (self.work / ".config.kernel").write_text(content)
                self.assertNotEqual(self.run_recipe("package\n").returncode, 0)


if __name__ == "__main__":
    unittest.main()
