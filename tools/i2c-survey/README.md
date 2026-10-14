# Read-only I2C survey for open power and sensor parts

`dc1-i2c-survey.sh` gathers the evidence the [roadmap](../../docs/roadmap.md#remaining-features)
needs before any driver is enabled for three parts: the RT9471 secondary
charger (i2c7 `0x53`), the BQ78Z100 pack gauge (i2c7 `0x55`), and the
unidentified ambient-light/proximity part (i2c1 `0x49`). It needs root
because `/dev/i2c-*` and debugfs are root-only:

```sh
sudo sh tools/i2c-survey/dc1-i2c-survey.sh battery  > /tmp/survey-battery.txt
sudo sh tools/i2c-survey/dc1-i2c-survey.sh charging > /tmp/survey-charging.txt
sh tools/i2c-survey/dc1-i2c-survey.sh --dry-run battery   # list commands only
```

Run it once on battery and once at least 30 seconds after attaching a
charger. Keep reports out of Git and review them before sharing.

## What it issues

| Target | Operations | Not issued |
| --- | --- | --- |
| GPIO151 (RT9471 active-low CE) | debugfs `pinctrl/*/pins` read; `gpioinfo -c gpiochip0 151` | `gpioget`/`gpioset`: requesting the line changes its direction and can release CE |
| RT9471 `0x53` | `i2cget` byte reads of `0x00`–`0x12`, ID first | IRQ flags `0x20`–`0x23` (clear-on-read), vendor/test space `0x40`+, any write |
| Pack gauge | `i2cdetect -r` scan of i2c7; `0x0b`/`0x55` on the other buses; word reads of i2c7 `0x55` registers `0x08 0x06 0x0a 0x2c 0x12 0x3c` | `i2cdetect -q` (SMBus quick write), ManufacturerAccess subcommands, seal/unseal |
| `0x49` | two 512-sample `dc1-mn29-probe` current-address captures | any register write |
| `0x49`, opt-in `--mn29-pointer-select` | one `i2ctransfer w1 0x00 r16`: a register-select write with no data byte | other pointer values, two-byte writes |

The register reads write only a register pointer, as any SMBus read does.
`installer/tests/test-dc1-i2c-survey.sh` checks the dry-run command list
against this table offline.

## Reading the results

- **RT9471:** `0x0b` bits 6:3 identify the part (`0x68` RT9471, `0x70`
  RT9471D). `0x02` bit 0 is `CHG_EN`; `0x0f` low nibble is charge state (4 =
  fast charge); `0x10` bit 7 is VBUS-good. VBUS-good tracking the charger
  supports a shared input. Fast charge (state 4) means a second
  charge path is already active; record the battery current alongside it.
  Keep the driver unbound either way ([power hardware](../../docs/hw/power.md)).
- **Pack gauge:** an answer at `0x55`, with voltage (`0x08`, mV) close to
  `mt6358-fg`, is the ACK the roadmap requires before re-enabling the node.
  Answering only while charging points at a sleep or power-path problem.
  Silence on every bus leaves a 100 kHz test-overlay boot, then the pack
  connector at the next teardown.
- **`0x49`:** confirm the 256-byte period across both captures. With the
  opt-in select, a NAK reproduces the bit-banged result and ends register
  access; 16 bytes matching a run of the captures anchor the window's
  register addresses for an ID search ([sensors](../../docs/hw/sensors.md)).
