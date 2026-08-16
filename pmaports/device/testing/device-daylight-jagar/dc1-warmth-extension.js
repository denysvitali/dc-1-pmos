// DC-1 frontlight warmth -- a second quick-settings slider for the amber
// frontlight, expressed as a colour temperature rather than a raw brightness.
//
// The DC-1 has two independent RT4539 frontlights on separate i2c buses:
// "lcd-backlight" (white, i2c-5) and "lcd-backlight-amber" (amber, i2c-2).
// GNOME models exactly one backlight per internal display: gsd-power resolves
// a single udev device (firmware > platform > raw, first match wins), which
// here is always the white one, and both the Settings brightness slider and
// the quick-settings one are views of that single device. Nothing upstream
// has a concept of a second backlight, so the amber channel is invisible.
//
// This extension does not add "a second brightness". Two channels over one
// panel are physically a luminance and a mix: white is how bright the panel
// is, amber is how warm it is. So the slider here is a *ratio* -- amber is
// held at `warmth` x the white channel's current value. Moving GNOME's own
// brightness slider then rescales both and the tint stays put; moving this
// one changes the tint at a fixed white level. A raw amber slider would have
// meant the colour drifted every time the brightness changed.
//
// Writes go through logind's Session.SetBrightness, which any process in an
// active seat session may call -- no root, no setuid helper, no udev rule, and
// no fight with gsd-backlight-helper over who owns the sysfs file.
//
// Blanking needs no handling here: dc1-screen-backlight mirrors the DRM
// connector's dpms state onto bl_power for *every* backlight device, and
// bl_power leaves the brightness value untouched, so the ratio survives a
// screen-off and comes back with it.

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const WHITE = 'lcd-backlight';
const AMBER = 'lcd-backlight-amber';
const SYSFS = '/sys/class/backlight';

// gsd's Brightness property changes before the helper has written sysfs; give
// the write time to land before reading the white level back.
const SETTLE_MS = 200;
// Drag emits notify::value per frame. The hardware follows every one of them;
// only the dconf write is debounced.
const PERSIST_MS = 400;

function readInt(path) {
    try {
        const [ok, bytes] = GLib.file_get_contents(path);
        if (!ok)
            return null;
        const value = Number.parseInt(new TextDecoder().decode(bytes).trim(), 10);
        return Number.isFinite(value) ? value : null;
    } catch {
        return null;
    }
}

function backlightValue(name, attribute) {
    return readInt(`${SYSFS}/${name}/${attribute}`);
}

// Drives the amber channel. Every path in here is best-effort: a DC-1 with one
// frontlight missing (or a kernel that renamed the devices) must degrade to
// "the slider does nothing", never to a broken shell.
class WarmthController {
    constructor() {
        this._whiteMax = backlightValue(WHITE, 'max_brightness') ?? 255;
        this._amberMax = backlightValue(AMBER, 'max_brightness') ?? 255;
        this._ratio = 0;
        this._sessionPath = null;
        this._writing = false;
        this._queued = null;
        this._written = null;
    }

    get available() {
        return backlightValue(AMBER, 'brightness') !== null;
    }

    setRatio(ratio) {
        this._ratio = Math.min(Math.max(ratio, 0), 1);
        this.apply();
    }

    // Recompute amber from whatever the white channel currently reads.
    apply() {
        const white = backlightValue(WHITE, 'brightness');
        if (white === null || this._whiteMax <= 0)
            return;

        const amber = Math.round((white / this._whiteMax) * this._ratio * this._amberMax);
        this._write(Math.min(Math.max(amber, 0), this._amberMax));
    }

    _write(value) {
        if (value === this._written)
            return;

        if (this._writing) {
            this._queued = value;
            return;
        }

        this._writing = true;
        this._setBrightness(value, retry => {
            this._writing = false;
            if (retry) {
                // Stale session path (VT switch, re-login): drop it and let
                // the next attempt resolve a fresh one.
                this._sessionPath = null;
                this._queued = value;
            } else {
                this._written = value;
            }

            const queued = this._queued;
            this._queued = null;
            if (queued !== null && queued !== this._written)
                this._write(queued);
        });
    }

    _setBrightness(value, done) {
        if (this._sessionPath === null) {
            this._resolveSession(path => {
                if (path === null) {
                    done(false);
                    return;
                }
                this._sessionPath = path;
                this._setBrightness(value, done);
            });
            return;
        }

        Gio.DBus.system.call(
            'org.freedesktop.login1', this._sessionPath,
            'org.freedesktop.login1.Session', 'SetBrightness',
            new GLib.Variant('(ssu)', ['backlight', AMBER, value]),
            null, Gio.DBusCallFlags.NONE, -1, null,
            (connection, result) => {
                try {
                    connection.call_finish(result);
                    done(false);
                } catch (e) {
                    logError(e, 'dc1-warmth: setting the amber frontlight failed');
                    done(true);
                }
            });
    }

    // The shell runs inside the user manager's slice, whose session carries no
    // seat, so login1's "self" object is not usable here. Ask seat0 which
    // session is active instead -- SetBrightness requires an active, seated
    // session and that is exactly the one it names.
    _resolveSession(done) {
        Gio.DBus.system.call(
            'org.freedesktop.login1', '/org/freedesktop/login1/seat/seat0',
            'org.freedesktop.DBus.Properties', 'Get',
            new GLib.Variant('(ss)', ['org.freedesktop.login1.Seat', 'ActiveSession']),
            new GLib.VariantType('(v)'), Gio.DBusCallFlags.NONE, -1, null,
            (connection, result) => {
                try {
                    const [wrapped] = connection.call_finish(result).deepUnpack();
                    const [, path] = wrapped.deepUnpack();
                    done(path ?? null);
                } catch (e) {
                    logError(e, 'dc1-warmth: no active session on seat0');
                    done(null);
                }
            });
    }
}

const WarmthSlider = GObject.registerClass(
class WarmthSlider extends QuickSettings.QuickSlider {
    _init(settings, controller) {
        super._init({iconName: 'night-light-symbolic'});

        this._settings = settings;
        this._controller = controller;
        this._persistId = 0;

        this.slider.accessible_name = 'Frontlight warmth';
        this._sliderId = this.slider.connect('notify::value',
            () => this._onSliderChanged());
        this._settingsId = this._settings.connect('changed::warmth',
            () => this._sync());

        this._sync();
    }

    // The hardware is asserted unconditionally, not only when the slider has
    // to move: at login the slider already reads 0, so an early return here
    // would leave the amber channel wherever it happened to be (the value the
    // last session left in the chip) instead of at the saved ratio.
    _sync() {
        const warmth = this._settings.get_double('warmth');
        if (this.slider.value !== warmth) {
            this.slider.block_signal_handler(this._sliderId);
            this.slider.value = warmth;
            this.slider.unblock_signal_handler(this._sliderId);
        }
        this._controller.setRatio(warmth);
    }

    _onSliderChanged() {
        const warmth = this.slider.value;
        this._controller.setRatio(warmth);

        if (this._persistId)
            GLib.source_remove(this._persistId);
        this._persistId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, PERSIST_MS, () => {
            this._persistId = 0;
            this._settings.set_double('warmth', warmth);
            return GLib.SOURCE_REMOVE;
        });
    }

    destroy() {
        if (this._persistId) {
            GLib.source_remove(this._persistId);
            this._persistId = 0;
        }
        if (this._settingsId) {
            this._settings.disconnect(this._settingsId);
            this._settingsId = 0;
        }
        super.destroy();
    }
});

const WarmthIndicator = GObject.registerClass(
class WarmthIndicator extends QuickSettings.SystemIndicator {
    _init(settings, controller) {
        super._init();
        this.quickSettingsItems.push(new WarmthSlider(settings, controller));
    }
});

export default class DC1WarmthExtension extends Extension {
    enable() {
        this._controller = new WarmthController();
        if (!this._controller.available) {
            console.warn(`dc1-warmth: no ${AMBER} backlight, not adding the slider`);
            this._controller = null;
            return;
        }

        this._settings = this.getSettings();
        this._indicator = new WarmthIndicator(this._settings, this._controller);
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);

        // Follow GNOME's own brightness: the tint is a ratio, so every change
        // to the white channel has to be answered with a new amber value.
        this._brightnessId = Gio.DBus.session.signal_subscribe(
            'org.gnome.SettingsDaemon.Power', 'org.freedesktop.DBus.Properties',
            'PropertiesChanged', '/org/gnome/SettingsDaemon/Power',
            'org.gnome.SettingsDaemon.Power.Screen', Gio.DBusSignalFlags.NONE,
            () => this._scheduleFollow());
    }

    disable() {
        // The amber value is left where the user put it: this runs on screen
        // lock too, and dimming the tint at the lock screen would read as a
        // hardware fault rather than a disabled extension.
        if (this._followId) {
            GLib.source_remove(this._followId);
            this._followId = 0;
        }
        if (this._brightnessId) {
            Gio.DBus.session.signal_unsubscribe(this._brightnessId);
            this._brightnessId = 0;
        }
        this._indicator?.quickSettingsItems.forEach(item => item.destroy());
        this._indicator?.destroy();
        this._indicator = null;
        this._controller = null;
        this._settings = null;
    }

    _scheduleFollow() {
        if (this._followId)
            GLib.source_remove(this._followId);
        this._followId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, SETTLE_MS, () => {
            this._followId = 0;
            this._controller?.apply();
            return GLib.SOURCE_REMOVE;
        });
    }
}
