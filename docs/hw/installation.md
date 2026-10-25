# Installation — measurement record

## 2026-10-25: touch installation on another DC-1

The owner installed Linux over Wi-Fi on a DC-1 previously running LineageOS.
They saw the installer on the panel, completed Wi-Fi and account setup, and
reached GNOME Mobile. After they rebooted the tablet, authenticated SSH over
Wi-Fi worked again. The installed distribution reports Nura edge, based on
Alpine/postmarketOS.

The initial installer was the checksum-verified
[build-410](https://github.com/denysvitali/dc-1-pmos/releases/tag/build-410)
`installer-boot.img`, SHA-256:

```text
a428b7355de0760ba7d5ca86858e64802b86ab2888b1005c9912f8f31f7ea5df
```

The host flashed only `boot_a` before the owner continued on the touch UI.
The standard fastboot command stalled. A local client using the AOSP fastboot
protocol completed the transfer, flash, slot selection and reboot after USB
resets. The standard host flash procedure therefore remains unverified in
this session.

The network installer downloaded its own rootfs and boot image. Their hashes
and selected release were not recorded, so the verified installer hash alone
does not identify the installed release.

Installed versions checked via apk on 2026-10-25:

| Package | Version |
| --- | --- |
| `linux-postmarketos-mediatek-mt6789` | `7.2_rc5_git20260819-r67` |
| `linux-postmarketos-mediatek-mt6789-modules` | `7.2_rc5_git20260819-r67` |
| `device-daylight-jagar` | `1-r116` |
| `mutter-mobile` | `999948.0-r6` |

Two observations help with installation troubleshooting:

- Android's boot properties reported locked/green, but fastboot directly
  reported `unlocked: yes`. No bootloader unlock was performed.
- The host did not see installer USB serial or Ethernet, although the owner
  saw the running installer and completed installation over Wi-Fi. Check the
  panel before diagnosing a failed boot from missing USB interfaces.

Remaining checks include installation from stock Android, host USB
Ethernet/SSH, boot-image/package byte parity, the first automatic update and
A/B fallback. Physical Sway operation also remains untested. Keep
`hardware_verified=false` until one exact release passes
[published-release acceptance](../roadmap.md#published-release-acceptance).
