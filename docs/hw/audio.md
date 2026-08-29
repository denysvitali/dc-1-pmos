# Audio — measurement record

Deep-dive for the status-table row *Audio* in
[README.md](../../README.md#hardware-support-at-a-glance). Newest facts last.

## Invariants

- Speakers: RT9101 amp behind the codec headphone buffers (`HPL`/`HPR Mux`
  = `LoudSPK Playback`), enabled by the machine driver's `Ext_Speaker_Amp`
  widget (VIBR rail + GPIO158/159). The known-good mixer sequence lives
  in `dc1-audio` and is mirrored by the UCM verb; keep the two in sync.
- Microphones: two two-wire digital DMICs on AIN0/AIN2. Capture front end
  is UL1 (ALSA device 9, `Capture_1`). `Mic Type Mux` must stay `DMIC`
  (any other value records digital silence) and `MTKAIF_DMIC` must stay
  `Off` — the codec delivers PCM over MTKAIF, and forcing raw-DMIC
  interpretation does not change or improve capture.
- There is no headset jack, no analog mic, and no JackControl; do not
  model ACC/DCC/PGA input paths.
- GNOME audio needs both: the `55-dc1-audio.conf` WirePlumber fragment
  (Alpine's `pulseaudio-wireplumber` disables `hardware.audio`, which
  stops ALSA enumeration entirely) and the `pipewire-pulse` package (the
  image's PulseAudio backend never starts under systemd, so without it
  there is no server at `$XDG_RUNTIME_DIR/pulse/native` and
  gnome-shell/g-c-c get connection refused).
- WirePlumber 0.5.15 `scripts/monitors/alsa.lua` concatenated a nil
  `node.name` when adapter bind fails (transient EBUSY on `hw:0,0`),
  which kills the ALSA monitor and leaves GNOME on Dummy Output. Do not
  fork that versioned script. `dc1-fix-wireplumber-alsa` reapplies a
  one-line `tostring()` guard from post-install/post-upgrade and from the
  apk trigger on the file, so a wireplumber upgrade cannot restore the
  crash. Alpine's current wireplumber 0.5.16 ships those call sites
  already guarded and was verified guarded on-device 2026-08-29 — the
  fix script no-ops on it by inspection; re-verify its pattern at every
  WirePlumber bump instead of assuming the guard is obsolete.

## History

**Both speakers, correct L/R, balanced — hardware-verified 2026-08-20 —
and microphone capture verified 2026-08-22.** The board mic is a digital
DMIC microphone wired to the MT6366 codec: 5 s recorded from `hw:0,9`
(`Capture_1`/UL1 front end) peaked at −29 dBFS broadband with zero mixer
changes, and a control experiment flipping `Mic Type Mux` off DMIC
recorded exact digital silence, proving the signal originates in the DMIC
front end (`mt6358_dmic_enable` ran for exactly the capture window). There
is no jack detection anywhere — zero `snd_jack`/`snd_soc_jack`
registrations in codec or machine driver, no accdet platform device, no
headphone switch in the input devices — so headset detect cannot work and
there is no analog headset mic.

Speakers took four kernel fixes from "dummy output": **power domain** —
the AFE must attach `power-domains = <&spm MT6789_POWER_DOMAIN_AUDIO>`
(`100b7a8c7`, pkgrel 16); without it the card probes but `hw_ptr` never
advances and playback underruns to silence. **Right channel** — HPL →
line-out buffer feeds the left speaker, HPR → DAC-R the right, and DAC-R
must be powered up (`AUDDEC_ANA_CON0` = `0x30ff`, not mainline's
`0x30f9`; vendor-matched `9c9f6ead`, pkgrel 17). **Balance** — the left
channel rides two gain stages, so both channels ride the `Headphone`
master gain (+8 dB, value 18; device pkgrel 48) and since `e1a31d1`
(2026-08-20) Lineout adds a +2 dB trim (value 12, superseding the
unity/value-10 pin recorded here before). **Channel swap** — the board
wires HPL to the *right* speaker and HPR to the *left*, so the codec's
downlink swap bit `AFE_DL_LR_SWAP` is set on the loudspeaker path
(`586fc14`, pkgrel 20); the dead HPL re-mux alternative was reverted. The
DAPM routing is applied at startup by `dc1-audio` via amixer.

**Gain-clobbering race root-caused from live evidence and fixed (device
pkgrel=59):** an evening audit caught `Headphone`/`Lineout` sitting at
0,0 (and `ADDA_DL_GAIN` dragged from 65535 down to a stale stored value)
75 minutes into a boot where `dc1-audio` had exited 0. Mechanism:
`alsa-restore.service` is `WantedBy=sound.target`, which udev pulls when
the card registers — *after* multi-user already started `dc1-audio`. An
`After=` between units queued by different transactions does not order
them; execution inverted (dc1-audio finished 22:12:08, restore ran
22:12:09) and the saved mute landed on top of the calibrated gains. Fix,
three layers in pkgrel=59: the unit joins the `sound.target` transaction
(`[Install] WantedBy=sound.target`), which makes
`After=alsa-restore.service` enforceable; `dc1-audio` now persists the
calibrated gains with `alsactl store` right after applying them, so any
later restore converges on the working state instead of stop-ramp zeros;
and `post-upgrade` runs `systemctl reenable dc1-audio` so upgraded
devices leave the stale multi-user symlink. Verified on this build: UCM
files parse (`alsaucm list _verbs` → HiFi), WirePlumber adopted the
profile without fallback (sink node
`alsa_output.platform-sound.HiFi__Speaker__sink`, description "Internal
Speakers"), and PCM0=DL1 is confirmed by three read-only sources (kernel
DAI link `"Playback_1"` binds the DL1 memif; `/proc/asound/card0/pcm0p`
id; the UCM mapping) — the physical `speaker-test` probe remains.

**First ≥r59 boot verified 2026-08-23 (device r60):** the race fix held —
`alsa-restore` then `dc1-audio` executed in the same `sound.target`
transaction at 00:44:10, `alsactl store` persisted the calibrated 18/18 +
12/12 into `/var/lib/alsa/asound.state`, and WirePlumber adopted the
profile with the sink named "Internal Speakers". Two **new** defects
recorded the same night, neither being the old race: **(1) kernel-side
idle gain re-zeroing** — with no stream ever opened, `Headphone Volume`/
`Lineout Volume`/`ADDA_DL_GAIN` are silently reset to zero ~30–50 s after
being set; reproduced twice under a full journal capture (second time
exactly ~31 s after re-applying), with nothing in any userspace log at
the zeroing moment; the persisted state file keeps the correct values, so
only live hardware state is clobbered. **(2) WirePlumber drops the
profile on a transient PCM error** — a brief "playback open failed:
Resource busy" on `hw:0,0` errored the sink node, WirePlumber's
`alsa.lua:425` then crashed ("attempt to concatenate a nil value") and
the card fell back to Dummy Output; recovered by restarting wireplumber.

**Both were root-caused from source on 2026-08-23, and the kernel half is
fixed (linux r36, kernel `6e54631d`).** (1) The re-zeroing is not a jagar
bug but an upstream `mt6358` design flaw: `Headphone Volume`, `Lineout
Volume` and `Handset Volume` are declared `SOC_{DOUBLE,SINGLE}_EXT_TLV`
over `ZCD_CON2`/`CON1`/`CON3`, so a control read returns the raw register
— but the driver treats those registers as scratch, ramping them to the
-40 dB mute index (`0x1f`) in every DAPM power-down (`mtk_hp_disable`,
`mtk_hp_spk_disable`) and restoring the user value from its own
`priv->ana_gain[]` shadow on the next power-up. An idle card therefore
reports a mute nobody asked for — reproduced live here at 5 h uptime,
`Headphone`/`Lineout` reading 0,0 while the shadow still held +8 dB and
playback would have come up correct. The danger is not the reading but
`alsactl store`: a snapshot taken while the path is down persists the
mute, and the next restore feeds it back through `mtk358_put_volsw` as a
real request that overwrites the shadow, so playback comes up ~18 dB low.
dc1-audio's ordering after `alsa-restore` is what has been absorbing
that. The fix adds `mt6358_get_volsw`, which reports the shadow — what
the next power-up will actually apply — and leaves the write path alone;
it is upstreamable as-is. (2) The lua crash is an upstream WirePlumber
0.5.15 bug, exactly at `scripts/monitors/alsa.lua:425` (0.5.15 line
numbering; the guarded site sits near line 445 in Alpine's 0.5.16): the failure
handler builds its message as `"Failed to create ALSA node " ..
n:get_property("node.name") .. ": " .. tostring(err)`, and when the node
never bound, `get_property` returns nil, so the error path itself throws
"attempt to concatenate a nil value" and takes the monitor down with it —
which is why a transient `EBUSY` on `hw:0,0` ends as Dummy Output.
One-line fix upstream (`tostring()` around the property, or use the
`properties` table already in scope). Device pkgrel>=77 carries that
guard without forking the script (see the invariants above).

**Shadow-read fix hardware-verified 2026-08-26 (linux r37 boot, ~15 h
uptime, no stream ever opened):** `amixer` reports `Headphone` 18,18
(+8 dB) and `Lineout` 12,12 (+2 dB) live, in exact agreement with
`/var/lib/alsa/asound.state` (`Headphone Volume` / `Lineout Volume` both
persisted at those values). On ≤r35 builds the live controls legitimately
read 0,0 while no path is powered — that was the known defect; the
agreement here is the fix working. Remaining once-per-hardware item: the
physical `speaker-test -D hw:0,0 -c2` probe (needs explicit permission —
the speakers are loud), tracked in
[../roadmap.md](../roadmap.md).

**Speaker labeling (device pkgrel=57, verified on r76 2026-08-25):** the
package ships a real UCM2 profile
(`conf.d/mt6789-mt6366/mt6789-mt6366.conf` + `HiFi.conf`; the explicit
`File` include is mandatory — UCM auto-scan does not work on alsa-lib
1.2.16) whose EnableSequence mirrors `dc1-audio`'s proven amixer sequence
(Headphone 18,18 / Lineout 12,12 / ADDA_DL_GAIN 65535), plus a
WirePlumber `wireplumber.conf.d/55-dc1-audio.conf` fragment setting
`wireplumber.profiles.main.hardware.audio=required`, overriding
pulseaudio-wireplumber's audio-disabled default by later lexical merge
order. `PlaybackPCM hw:${CardId},0` assumes `pcmC0D0p Playback_1` is DL1
— since confirmed from kernel/procfs/UCM sources (see above); the
physical speaker-test probe remains the last confirmation. If the
wireplumber journal ever says `UCM not available for card`, apply the
fallback relabel rule (`node.description="Speakers"`, matched on
`alsa.card_name="mt6789-mt6366"`, never the numeric index) and bump the
device pkgrel again.

**Bluetooth audio:** the whole A2DP chain is assembled (bluez5 monitor +
SBC/LDAC/aptX/AAC codecs loaded); pairing and streaming remain
unexercised — see [wireless.md](wireless.md).
