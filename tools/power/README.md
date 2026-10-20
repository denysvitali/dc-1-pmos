# Charging measurements

`charge-monitor.py` emits JSON lines with calibrated pack current, the
negotiated PD ceiling, the configured limits, and all board/SoC thermal
zones. It does not change charging, CPU or thermal policy. Output can include
device state: keep raw captures outside Git and summarize reviewed results.

```sh
python3 tools/power/charge-monitor.py --duration 600 --interval 15 > /tmp/charge.jsonl
```

On the DC-1, the optional `--adc` flag also reads the main MT6375 charger's
VBUS, VBAT, IBUS, IBAT and internal junction temperature. This requires root
and `i2ctransfer`. It issues single-shot channel selections on i2c5 `0x34`,
register `0xa6`, only when the ADC is already enabled and idle. It refuses
to enable the ADC or replace a busy conversion. Run only one ADC collector
at a time; do not combine it with another ADC diagnostic.

```sh
sudo python3 tools/power/charge-monitor.py --adc --duration 600 --interval 15 > /tmp/charge-adc.jsonl
```

`thermal_mc` values are millidegrees Celsius. Power-supply values retain
sysfs microvolt/microamp units; `adc` names carry their units explicitly.
An unreadable thermal sample is `null`, and an ADC failure is `adc_error`,
never a made-up zero. Board and charger temperatures are **not pack-cell
temperature**. This collector provides evidence, not a temperature-based
charging controller or permission to enable the RT9471 secondary path.

Read [power hardware](../../docs/hw/power.md) and
[thermal](../../docs/hw/thermal.md) before deliberately adding load. On the
live tablet use bounded load and stop that load if it heats the device;
do not defeat thermal protection or silently change the owner's charge rate.
