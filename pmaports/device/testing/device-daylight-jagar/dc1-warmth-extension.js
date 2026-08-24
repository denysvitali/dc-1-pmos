// DC-1 frontlight temperature -- a second quick-settings slider that mixes
// the two frontlights as a colour temperature over one shared luminance.
//
// The DC-1 has two independent RT4539 frontlights on separate i2c buses:
// "lcd-backlight" (white, i2c-5) and "lcd-backlight-amber" (amber, i2c-2).
// GNOME models exactly one backlight per internal display: gsd-power resolves
// a single udev device (firmware > platform > raw, first match wins), which
// here is always the white one, and both the Settings brightness slider and
// the quick-settings one are views of that single device. Nothing upstream
// has a concept of a second backlight, so the amber channel is invisible.
//
// Two channels over one panel are physically a luminance and a mix, so the
// controls are factored that way: GNOME's brightness slider is the luminance,
// this slider is the temperature. The temperature is a crossfade -- the lower
// half ramps the amber channel up over an untouched white channel, the upper
// half dims the white channel, reaching pure amber with the white ("blue")
// light fully OFF at the top:
//
//   amber = clamp(2t * L, 0, 1) * amberMax
//   white = clamp(min(2(1-t), 1) * L, 0, 1) * whiteMax
//
// One formula covers both halves, and through the upper half the channel SUM
// is constant at 2L: every count the white channel loses, the amber channel
// gains. Without that compensation (amber capped at L) the top of the slider
// halved the total light and read as "the backlight turned off" rather than
// "the light turned amber" -- measured 2026-08-25, L=0.384: white 98 + amber
// 98 at mid, amber 98 alone at max; now amber reaches 196 at max. When
// 2L > 1 the amber channel saturates before the top and the total dips over
// the last stretch; that is the hardware ceiling, not a bug. t above 0.98
// snaps to 1 because slider drags rarely land exactly on the end stop, and a
// residual white of 1-2 counts defeats the whole point of "white off".
//
// The luminance L cannot simply be read back from the white channel: once the
// upper half of the slider scales white down, the sysfs value is L*whiteShare,
// not L. So L is state, persisted in dconf next to the temperature. GNOME's
// brightness controls still work as "set the luminance": gsd writes its
// percentage into the white sysfs file, the extension adopts that as the new
// L, and re-asserts both channels from it.
//
// Measured 2026-08-24: gsd-power's Brightness property FOLLOWS external sysfs
// writes (the backlight core emits a change uevent on every sysfs store, and
// gsd tracks it). Every white write this extension makes therefore comes back
// as a PropertiesChanged echo. Echoes are told apart from genuine gsd writes
// by value: if the white sysfs file still holds a value we recently wrote,
// the signal is our own reflection and is dropped; anything else means gsd
// (slider, brightness keys) wrote it and carries a new luminance. While our
// own white writes are still in flight the comparison is meaningless, so the
// follow pass defers until the queue drains. Two costs
// follow from gsd's echo-tracking and are accepted: with the temperature past
// half, GNOME's slider displays the scaled white value rather than L, and at
// full amber a GNOME brightness change flashes white for ~SETTLE_MS before
// the follow-up write turns it back off.
//
// Writes go through logind's Session.SetBrightness, which any process in an
// active seat session may call -- no root, no setuid helper, no udev rule, and
// no fight with gsd-backlight-helper over who owns the sysfs file.
//
// Blanking needs no handling here: dc1-screen-backlight mirrors the DRM
// connector's dpms state onto bl_power for *every* backlight device, and
// bl_power leaves the brightness value untouched, so both channels survive a
// screen-off and come back with it.

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
// only the dconf writes are debounced.
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

function clamp01(value) {
    return Math.min(Math.max(value, 0), 1);
}

// One backlight channel driven over logind, with a single-slot write queue so
// a drag never stacks D-Bus calls. Session resolution is shared through the
// controller; a failed write drops the cached session path so the next
// attempt resolves a fresh one (VT switch, re-login).
class Channel {
    constructor(controller, name) {
        this._controller = controller;
        this.name = name;
        this.max = backlightValue(name, 'max_brightness') ?? 255;
        this.written = null;
        this._writing = false;
        this._queued = null;
        // Values we recently stored, kept so their uevent echoes can be told
        // apart from genuine external writes. Each echo consumes its entry;
        // the cap only bounds leftovers from coalesced echoes.
        this._recent = [];
    }

    get busy() {
        return this._writing || this._queued !== null;
    }

    consumeEcho(value) {
        const index = this._recent.indexOf(value);
        if (index < 0)
            return false;
        this._recent.splice(index, 1);
        return true;
    }

    write(value) {
        if (value === this.written)
            return;

        if (this._writing) {
            this._queued = value;
            return;
        }

        this._writing = true;
        this._controller.setBrightness(this.name, value, retry => {
            this._writing = false;
            if (retry) {
                this._queued = value;
            } else {
                this.written = value;
                this._recent.push(value);
                if (this._recent.length > 16)
                    this._recent.shift();
            }

            const queued = this._queued;
            this._queued = null;
            if (queued !== null && queued !== this.written)
                this.write(queued);
        });
    }
}

// Drives both channels from (luminance, temperature). Every path in here is
// best-effort: a DC-1 with one frontlight missing (or a kernel that renamed
// the devices) must degrade to "the slider does nothing", never to a broken
// shell.
class WarmthController {
    constructor() {
        this.white = new Channel(this, WHITE);
        this.amber = new Channel(this, AMBER);
        this._temperature = 0;
        this._luminance = 0;
        this._sessionPath = null;
        this.onLuminanceAdopted = null;
    }

    get available() {
        return backlightValue(AMBER, 'brightness') !== null;
    }

    get luminance() {
        return this._luminance;
    }

    setLuminance(luminance) {
        this._luminance = clamp01(luminance);
        this.apply();
    }

    setTemperature(temperature) {
        this._temperature = clamp01(temperature);
        this.apply();
    }

    // Take the luminance from whatever the white channel currently reads.
    // Only correct while the white channel is unscaled (sysfs == L), which is
    // true at first migration -- the previous, ratio-based extension never
    // touched white -- and whenever gsd has just written it.
    adoptLuminanceFromWhite() {
        const white = backlightValue(WHITE, 'brightness');
        if (white === null || this.white.max <= 0)
            return;
        this._luminance = clamp01(white / this.white.max);
        this.onLuminanceAdopted?.(this._luminance);
        this.apply();
    }

    // A gsd Brightness change landed. Either it is the echo of our own white
    // write coming back through the backlight uevent, or gsd really wrote the
    // white channel and the value is the user's new luminance. Returns true
    // when the caller should try again later: while our own writes are in
    // flight the sysfs value proves nothing.
    followGsd() {
        if (this.white.busy)
            return true;
        const white = backlightValue(WHITE, 'brightness');
        if (white === null)
            return false;
        if (white === this.white.written || this.white.consumeEcho(white))
            return false;
        // Genuine external write. Forget our stale last-written value, or a
        // recomputed white that happens to equal it would be skipped and
        // gsd's value would be left standing.
        this.white.written = null;
        this.adoptLuminanceFromWhite();
        return false;
    }

    apply() {
        // Drags rarely land exactly on the end stop; a residual white of a
        // count or two defeats "white off at max".
        const t = this._temperature > 0.98 ? 1 : this._temperature;
        const L = this._luminance;

        // Constant-sum crossfade (see the header): amber gains every count
        // white loses, so warmth never reads as the light dying.
        const amber = Math.round(clamp01(2 * t * L) * this.amber.max);
        const white = Math.round(clamp01(Math.min(2 * (1 - t), 1) * L) * this.white.max);
        this.amber.write(Math.min(amber, this.amber.max));
        this.white.write(Math.min(white, this.white.max));
    }

    setBrightness(name, value, done) {
        if (this._sessionPath === null) {
            this._resolveSession(path => {
                if (path === null) {
                    done(false);
                    return;
                }
                this._sessionPath = path;
                this.setBrightness(name, value, done);
            });
            return;
        }

        Gio.DBus.system.call(
            'org.freedesktop.login1', this._sessionPath,
            'org.freedesktop.login1.Session', 'SetBrightness',
            new GLib.Variant('(ssu)', ['backlight', name, value]),
            null, Gio.DBusCallFlags.NONE, -1, null,
            (connection, result) => {
                try {
                    connection.call_finish(result);
                    done(false);
                } catch (e) {
                    logError(e, `dc1-warmth: setting ${name} failed`);
                    // Stale session path (VT switch, re-login): drop it and
                    // let the next attempt resolve a fresh one.
                    this._sessionPath = null;
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

        this.slider.accessible_name = 'Frontlight temperature';
        this._sliderId = this.slider.connect('notify::value',
            () => this._onSliderChanged());
        this._settingsId = this._settings.connect('changed::temperature',
            () => this._sync());

        this._sync();
    }

    // The hardware is asserted unconditionally, not only when the slider has
    // to move: at login the slider already reads 0, so an early return here
    // would leave the channels wherever the last session left them in the
    // chips instead of at the saved mix.
    _sync() {
        const temperature = this._settings.get_double('temperature');
        if (this.slider.value !== temperature) {
            this.slider.block_signal_handler(this._sliderId);
            this.slider.value = temperature;
            this.slider.unblock_signal_handler(this._sliderId);
        }
        this._controller.setTemperature(temperature);
    }

    _onSliderChanged() {
        const temperature = this.slider.value;
        this._controller.setTemperature(temperature);

        if (this._persistId)
            GLib.source_remove(this._persistId);
        this._persistId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, PERSIST_MS, () => {
            this._persistId = 0;
            this._settings.set_double('temperature', temperature);
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
        this._migrate();

        // Adopted luminance is persisted so later sessions do not misread a
        // scaled-down white channel as the real luminance.
        this._controller.onLuminanceAdopted = () => this._persistLuminance();

        const saved = this._settings.get_double('luminance');
        if (saved >= 0)
            this._controller.setLuminance(saved);
        else
            this._controller.adoptLuminanceFromWhite();

        this._indicator = new WarmthIndicator(this._settings, this._controller);
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);

        // Follow GNOME's own brightness: gsd writes the white channel, the
        // extension adopts it as the new luminance (followGsd drops the
        // echoes of our own writes).
        this._brightnessId = Gio.DBus.session.signal_subscribe(
            'org.gnome.SettingsDaemon.Power', 'org.freedesktop.DBus.Properties',
            'PropertiesChanged', '/org/gnome/SettingsDaemon/Power',
            'org.gnome.SettingsDaemon.Power.Screen', Gio.DBusSignalFlags.NONE,
            () => this._scheduleFollow());
    }

    disable() {
        // Both channels are left where the user put them: this runs on screen
        // lock too, and shifting the light at the lock screen would read as a
        // hardware fault rather than a disabled extension.
        if (this._followId) {
            GLib.source_remove(this._followId);
            this._followId = 0;
        }
        if (this._persistId) {
            GLib.source_remove(this._persistId);
            this._persistId = 0;
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

    // The pre-temperature extension stored a ratio: amber = warmth * white,
    // white never scaled. temperature = warmth / 2 lands in the lower half of
    // the crossfade with amberShare == warmth and whiteShare == 1 -- the
    // exact same light the old value produced.
    _migrate() {
        if (this._settings.get_double('temperature') >= 0)
            return;
        const warmth = this._settings.get_double('warmth');
        this._settings.set_double('temperature', clamp01(warmth / 2));
    }

    _persistLuminance() {
        if (this._persistId)
            GLib.source_remove(this._persistId);
        this._persistId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, PERSIST_MS, () => {
            this._persistId = 0;
            this._settings?.set_double('luminance', this._controller?.luminance ?? 0);
            return GLib.SOURCE_REMOVE;
        });
    }

    _scheduleFollow() {
        if (this._followId)
            GLib.source_remove(this._followId);
        this._followId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, SETTLE_MS, () => {
            this._followId = 0;
            if (this._controller?.followGsd())
                this._scheduleFollow();
            return GLib.SOURCE_REMOVE;
        });
    }
}
