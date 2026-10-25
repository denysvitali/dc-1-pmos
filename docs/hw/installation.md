# Installation — measurement record

## 2026-10-25: second-unit touch installation

A DC-1 previously running LineageOS completed an on-device network install.
The owner observed the installer on the panel, connected it to Wi-Fi,
completed installation/account provisioning and reached GNOME Mobile.
After a subsequent owner-initiated reboot, authenticated SSH over Wi-Fi
returned. The installed distribution identifies itself as Nura edge
(Alpine/postmarketOS lineage).

The initial installer was the checksum-verified
[build-410](https://github.com/denysvitali/dc-1-pmos/releases/tag/build-410)
`installer-boot.img`, SHA-256:

```text
a428b7355de0760ba7d5ca86858e64802b86ab2888b1005c9912f8f31f7ea5df
```

Only `boot_a` was flashed from the host before handing off to the touch UI.
Host fastboot stalled; a local minimal AOSP fastboot protocol client completed
the download/flash, slot selection and reboot after USB resets. Thus this
session does not validate the standard host CLI flash sequence end-to-end.
The on-device network installer fetched its own payload; its exact rootfs
hash and selected release were not captured. The staged host rootfs is not
proof of which rootfs the installer downloaded.

Installed versions checked via apk on 2026-10-25:

| Package | Version |
| --- | --- |
| `linux-postmarketos-mediatek-mt6789` | `7.2_rc5_git20260819-r67` |
| `linux-postmarketos-mediatek-mt6789-modules` | `7.2_rc5_git20260819-r67` |
| `device-daylight-jagar` | `1-r116` |
| `mutter-mobile` | `999948.0-r6` |

Two diagnostic observations bound this result:

- Android's boot properties reported locked/green, but fastboot directly
  reported `unlocked: yes`. No bootloader unlock was performed.
- The host did not see installer USB serial or Ethernet, although the owner
  saw the running installer and completed installation over Wi-Fi. Absence
  of USB enumeration alone did not establish a failed boot.

This establishes owner-observed touch installation and first desktop use,
plus remotely verified installed versions and Wi-Fi administrative access.
It does not establish host USB Ethernet/SSH, stock-to-Linux installation,
full boot-image/package byte parity, first automatic update, A/B fallback,
or physical Sway operation. Keep `hardware_verified=false` until the
[published-release acceptance](../roadmap.md#published-release-acceptance)
procedure passes on one exact artifact set.
