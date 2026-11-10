#!/usr/bin/env python3
"""Focused offline tests: synthetic archives, no network/chroot/root required."""
import hashlib
import importlib.util
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("profile_stage", ROOT / "scripts/mutter-profile-stage.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class Staging(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.repo = self.base / "repo"
        self.cache = self.base / "production-cache"
        self.cache.mkdir()
        self.overlay = self.repo / "pmaports/device/testing/mutter-mobile"
        shutil.copytree(ROOT / "pmaports/device/testing/mutter-mobile", self.overlay)
        self.daemon = self.overlay.parent / "gnome-settings-daemon-mobile/APKBUILD"
        self.daemon.parent.mkdir()
        self.daemon.write_text("pkgver=1\npkgrel=7\n")
        (self.repo / "scripts").mkdir()
        shutil.copyfile(ROOT / "scripts/versions.env", self.repo / "scripts/versions.env")
        self.recipe = self.overlay / "APKBUILD"
        text = self.recipe.read_text()
        self.pkgrel = re.search(r"^pkgrel=([0-9]+)$", text, re.M).group(1)
        for checksum, name in re.findall(r"^([0-9a-f]{128})  (.*\.tar.gz)$", text, re.M):
            data = ("synthetic " + name).encode()
            (self.cache / name).write_bytes(data)
            text = text.replace(checksum, hashlib.sha512(data).hexdigest())
        self.recipe.write_text(text)
        self.before = text
        self.destination = self.base / "profile"
        self.old_repo = profile.REPO
        profile.REPO = self.repo
        self.addCleanup(setattr, profile, "REPO", self.old_repo)

    def stage(self):
        return profile.stage(self.repo, self.cache, self.destination)

    def test_isolated_reproducible_and_production_unchanged(self):
        manifest = self.stage()
        staged = (self.destination / "overlay/APKBUILD").read_text()
        self.assertIn("-Dprofiler=true", staged)
        self.assertNotIn("-Dprofiler=false", staged)
        self.assertIn("\tsysprof-dev\n", staged)
        self.assertIn("--wrap-mode=nofallback", staged)
        # Only Mutter carries the local revision; the daemon pins must name the
        # revision its own recipe builds, or the build cannot resolve them.
        self.assertIn("\tgnome-settings-daemon-mobile=$pkgver-r7\n", staged)
        self.assertIn("\tgnome-settings-daemon-mobile-dev=$pkgver-r7\n", staged)
        self.assertNotIn("gnome-settings-daemon-mobile=$pkgver-r$pkgrel", staged)
        self.assertNotIn("gnome-settings-daemon-mobile-dev=$pkgver-r$pkgrel", staged)
        self.assertIn("mutter-mobile-schemas=$pkgver-r$pkgrel", staged)
        self.assertEqual(manifest["settings_daemon_pkgrel"], 7)
        self.assertGreater(manifest["profile_pkgrel"], manifest["production_pkgrel"])
        self.assertEqual(self.recipe.read_text(), self.before)
        self.assertIn("-Dprofiler=false", self.before)
        self.assertEqual(profile.check(self.destination), manifest)
        other = profile.stage(self.repo, self.cache, self.base / "other")
        self.assertEqual(other, manifest)
        for source in self.cache.iterdir():
            target = self.destination / "distfiles" / source.name
            self.assertFalse(target.is_symlink())
            self.assertNotEqual(source.stat().st_ino, target.stat().st_ino)
        self.assertFalse((self.destination / "build").exists())

    def test_existing_work_or_symlink_rejected(self):
        self.destination.mkdir()
        (self.destination / "keep").write_text("production")
        with self.assertRaises(ValueError):
            self.stage()
        self.assertEqual((self.destination / "keep").read_text(), "production")
        alias = self.base / "alias"
        alias.symlink_to(self.cache, target_is_directory=True)
        with self.assertRaises(ValueError):
            profile.stage(self.repo, self.cache, alias)

    def test_source_tree_rejected(self):
        with self.assertRaises(ValueError):
            profile.stage(self.repo, self.cache, self.repo / "new-stage")

    def test_checksum_or_missing_archive_fails_before_writes(self):
        archive = next(self.cache.iterdir())
        archive.write_bytes(b"corrupt")
        with self.assertRaises(ValueError):
            self.stage()
        self.assertFalse(self.destination.exists())
        archive.unlink()
        with self.assertRaises(ValueError):
            self.stage()
        self.assertFalse(self.destination.exists())

    def test_recipe_drift_rejected(self):
        for text in (self.before.replace("-Dprofiler=false", "-Dprofiler=true"),
                     self.before.replace(f"pkgrel={self.pkgrel}\n", "pkgrel=bad\n"),
                     self.before.replace("\tgnome-settings-daemon-mobile-dev=$pkgver-r$pkgrel\n", ""),
                     self.before + "\n# -Dprofiler=false\n"):
            self.recipe.write_text(text)
            with self.assertRaises(ValueError):
                self.stage()
            self.assertFalse(self.destination.exists())

    def test_settings_daemon_recipe_drift_rejected(self):
        for text in ("pkgver=1\n", "pkgrel=1\npkgrel=2\n", "pkgrel=bad\n"):
            self.daemon.write_text(text)
            with self.assertRaises(ValueError):
                self.stage()
            self.assertFalse(self.destination.exists())
        self.daemon.unlink()
        with self.assertRaises(OSError):
            self.stage()
        self.assertFalse(self.destination.exists())

    def test_patch_checksum_rejected(self):
        (self.overlay / "mutter-mobile-orientation.patch").write_text("bad")
        with self.assertRaises(ValueError):
            self.stage()
        self.assertFalse(self.destination.exists())

    def test_mutated_stage_and_changed_pins_rejected(self):
        self.stage()
        recipe = self.destination / "overlay/APKBUILD"
        original = recipe.read_text()
        recipe.write_text(original + "\n# changed\n")
        with self.assertRaises(ValueError):
            profile.check(self.destination)
        recipe.write_text(original)
        (self.repo / "scripts/versions.env").write_text("changed")
        with self.assertRaises(ValueError):
            profile.check(self.destination)

    def test_profile_generation_changes_revision(self):
        first = self.stage()
        old = profile.PROFILE_GENERATION
        try:
            profile.PROFILE_GENERATION += 1
            second = profile.stage(self.repo, self.cache, self.base / "next")
        finally:
            profile.PROFILE_GENERATION = old
        self.assertNotEqual(first["profile_pkgrel"], second["profile_pkgrel"])

    def test_wrapper_refuses_bad_invocation_and_check(self):
        wrapper = ROOT / "scripts/mutter-profile-build.sh"
        result = subprocess.run(["sh", str(wrapper)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage", result.stderr)
        profile.stage(self.repo, self.cache, self.destination)
        (self.destination / "overlay/APKBUILD").write_text("tampered")
        result = subprocess.run(["sh", str(wrapper), "--build", str(self.destination)],
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("staged input changed", result.stderr)
        self.assertFalse((self.destination / "build").exists())


if __name__ == "__main__":
    unittest.main()
