// Compatibility patches for a 48-based mobile shell running against a
// GNOME >= 50 session/gdm stack. Both breaks below are version skew inside
// postmarketOS' systemd extra repo (gnome-shell-mobile stays on 48 while
// gnome-session/gdm moved to 50); drop this extension once
// gnome-shell-mobile rebases onto GNOME >= 50.

// 1. Power Off / Restart.
//
// gnome-session 50 changed org.gnome.SessionManager.CanShutdown from
// returning a boolean to a uint32 availability enum (0 = unavailable,
// 3 = available without authentication). The shell's bundled proxy XML
// still declares "(b)", so GDBus rejects the reply, _updateHaveShutdown
// catches the error, and both Power Off and Restart vanish from the power
// menu. Everything downstream is still compatible: Shutdown()/Reboot()
// kept their signatures, and gnome-session 50 calls the shell's
// EndSessionDialog with the same (uuu ao) Open call and the same
// Confirmed* signal names. Availability is the only break, so patching
// this one method is a complete fix.
//
// The replacement issues a raw connection-level call with no expected
// reply type and accepts either shape, so it stays correct if
// gnome-session is ever downgraded.

// 2. GDM session registration.
//
// gdm 50's org.gnome.DisplayManager.Manager.RegisterSession() takes no
// arguments -- live introspection on this device reads "RegisterSession();"
// with Version = '50.2'. The shell's bundled js/misc/loginManager.js still
// sends an empty dict:
//
//     GLib.Variant.new('(a{sv})', [{}])
//
// so GDBus rejects the call with INVALID_ARGS before it reaches gdm, and
// registerSessionWithGDM() only tolerates UNKNOWN_METHOD -- the error is
// logged and swallowed. Observed here on every user session:
//
//     Error registering session with GDM:
//     GDBus.Error:org.freedesktop.DBus.Error.InvalidArgs:
//     Type of message, "(a{sv})", does not match expected type "()"
//
// What gdm skips when that call never lands (gdm_manager_handle_register_session
// in daemon/gdm-manager.c): the session's display-device is never set, the
// login is never recorded (gdm_session_record (GDM_SESSION_RECORD_LOGIN, ...)),
// and the display's session-registered flag is never set. The last one is not
// cosmetic -- gdm_display_unmanage() turns an unregistered display FAILED
// instead of UNMANAGED, so remove_user_session() takes the
// "!= GDM_DISPLAY_FAILED" branch as false and skips gdm_display_finish() for
// it: on logout the display object and its greeter session are never finished.
// It is also what logs "GdmDisplay: Session never registered, failing".
//
// The call has to be re-issued from inside gnome-shell. gdm resolves the
// caller through get_display_and_details_for_bus_sender(), which maps the
// bus sender to a PID and then to a session; an extension runs in the shell
// process, so it resolves exactly as the shell's own attempt would have,
// including the tty that becomes the session's display-device.
//
// Calling it here also repairs the older signature if gdm is ever
// downgraded: a pre-50 gdm declares the (a{sv}) argument, answers
// INVALID_ARGS to the bare call, and gets the shell's original shape.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as SystemActions from 'resource:///org/gnome/shell/misc/systemActions.js';

// gdm answers "No display available" when it cannot yet map our bus sender
// to a display. That is transient while the session is still coming up, so
// retry a few times before giving up.
const REGISTER_RETRIES = 5;
const REGISTER_RETRY_DELAY_MS = 1000;

export default class Dc1SessionCompatExtension extends Extension {
    enable() {
        this._registerRetryId = 0;

        this._actions = SystemActions.getDefault();
        // Shadow the prototype method; every call site reaches it through
        // the instance, and disable() restores by deleting the shadow.
        this._actions._updateHaveShutdown = function () {
            Gio.DBus.session.call(
                'org.gnome.SessionManager',
                '/org/gnome/SessionManager',
                'org.gnome.SessionManager',
                'CanShutdown',
                null,
                null,
                Gio.DBusCallFlags.NONE,
                -1,
                null,
                (connection, res) => {
                    try {
                        const value = connection.call_finish(res)
                            .get_child_value(0);
                        this._canHavePowerOff =
                            value.get_type_string() === 'b'
                                ? value.get_boolean()
                                : value.get_uint32() !== 0;
                    } catch {
                        this._canHavePowerOff = false;
                    }
                    this._updatePowerOff();
                });
        };
        this._actions._updateHaveShutdown();

        this._registerSessionWithGdm();
    }

    disable() {
        if (this._registerRetryId) {
            GLib.source_remove(this._registerRetryId);
            this._registerRetryId = 0;
        }

        if (!this._actions)
            return;
        delete this._actions._updateHaveShutdown;
        this._actions._updateHaveShutdown();
        this._actions = null;
    }

    _registerSessionWithGdm(attempt = 0, legacySignature = false) {
        const onResult = (connection, res) => {
            try {
                connection.call_finish(res);
            } catch (e) {
                if (!legacySignature &&
                    e.matches(Gio.DBusError, Gio.DBusError.INVALID_ARGS)) {
                    // Pre-50 gdm: fall back to the shape the shell itself
                    // sends, so this stays correct across a downgrade.
                    this._registerSessionWithGdm(attempt, true);
                    return;
                }
                if (attempt < REGISTER_RETRIES &&
                    e.message.includes('No display available')) {
                    this._scheduleRegisterRetry(attempt, legacySignature);
                    return;
                }
                logError(e, 'dc1-session-compat: RegisterSession');
            }
        };

        Gio.DBus.system.call(
            'org.gnome.DisplayManager',
            '/org/gnome/DisplayManager/Manager',
            'org.gnome.DisplayManager.Manager',
            'RegisterSession',
            legacySignature ? GLib.Variant.new('(a{sv})', [{}]) : null,
            null,
            Gio.DBusCallFlags.NONE,
            -1,
            null,
            onResult);
    }

    _scheduleRegisterRetry(attempt, legacySignature) {
        if (this._registerRetryId)
            return;
        this._registerRetryId = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT,
            REGISTER_RETRY_DELAY_MS,
            () => {
                this._registerRetryId = 0;
                this._registerSessionWithGdm(attempt + 1, legacySignature);
                return GLib.SOURCE_REMOVE;
            });
    }
}
