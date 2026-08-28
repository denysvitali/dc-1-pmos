# Power and battery — the owner's guide

What to expect from the DC-1's battery and charging under this port, and
the levers you have. The measurement record behind every claim here is
[hw/power.md](hw/power.md); behavior of the headless charging mode is in
[installation.md](installation.md#charging-mode).

## Charging

Plug any USB-C source. Power Delivery is negotiated in the kernel (the
port declares 5 V/3 A, 9 V/3 A, 12 V/3 A sink capabilities; a 12 V
contract has been verified end-to-end), and the charger autonomously
runs CC/CV to the pack's 4.35 V limit — no userspace required. There is
no charging LED; check the battery icon once booted, or trust that a
dark powered-off device on a cable is charging (charging mode).

**Default rate:** ~2.94 A into the pack, roughly 40 %/h on the 8 Ah pack.
This is the hardware-measured result of the 3.15 A charger target, with the
hottest zone at 46 °C during the audit. Until the pack gauge answers, this
default cannot use live pack temperature as an independent control.

**Owner lever — charge rate.** Set the charge-current target as root:

```sh
# ~3 A into the pack ≈ 40 %/h (measured; stays within the 12 V/1.5 A
# input contract — hottest zone measured 46 °C):
echo 3150000 > /sys/class/power_supply/mt6375-charger/constant_charge_current

# back to the conservative setting:
echo 2000000 > /sys/class/power_supply/mt6375-charger/constant_charge_current
```

Values are microamps. `input_current_limit` next to it caps the input
side; a weak source simply delivers less (the charger folds back rather
than sagging). `2000000` gives the earlier conservative ~22 %/h rate. These
resets at boot — the default policy re-applies.

## The battery percentage

Real coulomb-counting from the PMIC (calibrated against the factory
5 mΩ shunt configuration), not a voltage guess. A clean shutdown records
the measured charge and a boot within ten minutes restores it before UPower,
so ordinary reboots do not manufacture a percentage jump. The record is
single-use and invalid, stale, crash, or long-power-off cases deliberately
fall back to voltage seeding. One caveat remains:

- the state of charge is measured against design capacity; nothing on this unit has
  learned the pack's real full-charge capacity yet (same missing gauge).

If a battery UI ever lists a second, permanently-empty battery
(`bq78z100-0`), that is a known cosmetic artifact of the silent pack
gauge, not a second battery.

## Battery life today

There is **no suspend** yet — by design, while the freezer/wake work is
unfinished — so idle drain is higher than the hardware is capable of.
The biggest lever you have today is the **power key**: a short press
blanks the panel (the reflective display uses ~nothing with the
frontlight off; the frontlight is the main draw). Suspend is the top
item on the feature track in [roadmap.md](roadmap.md).

## Thermal behavior

Charging and compute share thermal limits: all thirteen LVTS zones carry
hot/critical trips and the two board NTC zones actuate at 85/110 °C;
CPU and GPU throttle through cooling maps long before critical
shutdown. Nothing user-configurable here — it is recorded for
reassurance, in [hw/thermal.md](hw/thermal.md).
