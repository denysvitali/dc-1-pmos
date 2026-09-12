# Numbered installer releases

Every successful push-to-`main` build publishes a retained prerelease named
`build-N`, where N is GitHub's workflow run number, and then refreshes the
[`latest` download](https://github.com/denysvitali/dc-1-pmos/releases/tag/latest).
Browse [all releases](https://github.com/denysvitali/dc-1-pmos/releases) to select
an older build. Published numbered releases are kept; the workflow does not
delete them or replace their assets.

For example, build 123 has this installer URL:

```text
https://github.com/denysvitali/dc-1-pmos/releases/download/build-123/installer-boot.img
```

The corresponding rootfs, system boot image, packages, installation helpers,
provenance and checksum manifest are on that same release. Follow
[the installation guide](installation.md) and verify `SHA256SUMS`. Host-side
installation requires files from one release. The on-device installer embeds
its release tag and downloads that release's payloads even if `latest` has
advanced. The copy downloaded from `latest` is also pinned to the numbered
build it came from, so an in-progress installation cannot silently switch
builds. Local builds default to `latest`; set `DC1_RELEASE_TAG` when building
an installer for a particular published tag.

Installed devices retain the normal automatic-update policy. To keep a chosen
build after installation, create `/var/lib/dc1/no-auto-update` before the first
scheduled update (for example from the recovery shell before first login):

```sh
sudo touch /var/lib/dc1/no-auto-update
```

That stops the DC-1 automatic updater; manually running `apk upgrade` can still
change the installation. Retained release assets provide an exact install
snapshot, not a snapshot of the upstream Alpine package repositories.

## Publication behavior

- Builds queue instead of cancelling earlier pushes. GitHub's `queue: max`
  currently permits up to 100 pending runs in a concurrency group; failed
  builds do not publish a usable release. See the
  [GitHub concurrency reference](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency).
- Numbers may have gaps because pull requests, manual runs and failed builds
  also consume workflow run numbers. Rerunning a workflow keeps its number.
- Uploads go to a draft first. The numbered release is published only after
  all assets are uploaded. An interrupted draft can be resumed; a published
  release with different bytes is refused. Start a new manual workflow run
  without a custom tag to obtain a new number.
- `latest` advances only after the retained release exists. Its manifest is
  uploaded last, preserving checksum failure during a partial replacement.
  An older run cannot move `latest` backwards. The `latest` Git tag moves to
  the corresponding source commit; numbered tags stay fixed.
- Manual `pmos-v*` tags remain supported and are retained without changing
  `latest`. A manual run without a custom tag uses `build-N` and updates
  `latest` only when run on the default branch.
- Pull requests receive workflow artifacts and never publish releases or use
  the production APK signing key.

All releases remain prereleases and record `hardware_verified=false` until
separate hardware validation is recorded. CI success alone does not prove a
successful installation or boot.
