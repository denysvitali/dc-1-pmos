#!/usr/bin/env python3
"""Offline, non-deploying opt-in Mutter profiler recipe/distfile staging."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys

# Increment for every change to the profiling recipe transformation.
PROFILE_GENERATION = 2
REPO = Path(__file__).resolve().parent.parent


def digest(path, algorithm="sha512"):
    h = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"expected exactly one production marker: {old!r}")
    return text.replace(old, new, 1)


def production_pkgrel(recipe):
    releases = re.findall(r"^pkgrel=([0-9]+)$", recipe.read_text(), re.M)
    if len(releases) != 1 or not 0 <= int(releases[0]) < 1000000:
        raise ValueError(f"expected one conventional production pkgrel: {recipe.parent.name}")
    return releases[0]


def stage(repo, cache, destination):
    repo, cache, destination = (p.resolve() for p in (repo, cache, destination))
    if destination == repo or repo in destination.parents:
        raise ValueError("stage must be outside the source repository")
    if destination.exists():
        raise ValueError("stage must not already exist (never reuse production work/cache)")
    overlay = repo / "pmaports/device/testing/mutter-mobile"
    text = (overlay / "APKBUILD").read_text()
    release = production_pkgrel(overlay / "APKBUILD")
    daemon = production_pkgrel(overlay.parent / "gnome-settings-daemon-mobile/APKBUILD")
    revision = 1000000 + int(release) * 1000 + PROFILE_GENERATION
    transformed = once(text, "pkgrel=" + release + "\n", f"pkgrel={revision}\n")
    # Production pins the settings daemon to Mutter's own revision. Only Mutter
    # gets the local revision, so pin the daemon to the one that really exists.
    for name in ("gnome-settings-daemon-mobile", "gnome-settings-daemon-mobile-dev"):
        transformed = once(transformed, f"\t{name}=$pkgver-r$pkgrel\n",
                           f"\t{name}=$pkgver-r{daemon}\n")
    transformed = once(transformed, "-Dprofiler=false", "-Dprofiler=true")
    transformed = once(transformed, 'makedepends="\n', 'makedepends="\n\tsysprof-dev\n')
    # Never silently download Meson wrap fallbacks during this experiment.
    transformed = once(transformed, "abuild-meson \\\n", "abuild-meson --wrap-mode=nofallback \\\n")
    sums = re.findall(r"^([0-9a-f]{128})  ([A-Za-z0-9_.+-]+)$", text, re.M)
    if len(sums) != 3:
        raise ValueError("expected Mutter, gvdb and orientation patch checksums")
    inputs = []
    for expected, name in sums:
        source = cache / name if name.endswith(".tar.gz") else overlay / name
        if not source.is_file() or digest(source) != expected:
            raise ValueError(f"missing or checksum-mismatched input: {name}")
        inputs.append((source, name))
    # All validation precedes creation. No subprocess, archive extraction or root access.
    destination.mkdir(mode=0o700, parents=True)
    shutil.copytree(overlay, destination / "overlay")
    (destination / "overlay/APKBUILD").write_text(transformed)
    (destination / "distfiles").mkdir()
    for source, name in inputs:
        if name.endswith(".tar.gz"):
            shutil.copyfile(source, destination / "distfiles" / name)
    shutil.copyfile(repo / "scripts/versions.env", destination / "versions.env")
    files = sorted(p for p in destination.rglob("*") if p.is_file())
    manifest = {
        "purpose": "local-profiler-only-not-for-release-or-install",
        "production_pkgrel": int(release), "profile_pkgrel": revision,
        "settings_daemon_pkgrel": int(daemon),
        "generation": PROFILE_GENERATION,
        "production_recipe_sha512": digest(overlay / "APKBUILD"),
        "files": {str(p.relative_to(destination)): digest(p) for p in files},
    }
    (destination / "PROFILE.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def check(destination):
    manifest = json.loads((destination / "PROFILE.json").read_text())
    for name, expected in manifest["files"].items():
        path = destination / name
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise ValueError(f"staged input changed: {name}")
    if digest(REPO / "scripts/versions.env") != digest(destination / "versions.env"):
        raise ValueError("source pins changed; create a new stage")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check staged input integrity only")
    parser.add_argument("stage", type=Path, help="new directory outside this repository")
    parser.add_argument("distfiles", type=Path, nargs="?", help="read-only cached production archives")
    args = parser.parse_args()
    if args.check:
        if args.distfiles:
            parser.error("--check takes only STAGE")
        result = check(args.stage.resolve())
    else:
        if not args.distfiles:
            parser.error("DISTFILES is required for offline staging")
        result = stage(REPO, args.distfiles, args.stage)
    print(f"local profile pkgrel={result['profile_pkgrel']}; no build or deployment performed")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as exc:
        sys.exit(f"mutter-profile-stage: {exc}")
