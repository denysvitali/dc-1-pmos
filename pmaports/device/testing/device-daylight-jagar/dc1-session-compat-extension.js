// Restores Power Off / Restart on the 48-based mobile shell when it runs
// against gnome-session >= 50.
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
// gnome-session is ever downgraded. Drop this extension when
// gnome-shell-mobile rebases onto GNOME >= 50.

import Gio from 'gi://Gio';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as SystemActions from 'resource:///org/gnome/shell/misc/systemActions.js';

export default class Dc1SessionCompatExtension extends Extension {
    enable() {
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
    }

    disable() {
        if (!this._actions)
            return;
        delete this._actions._updateHaveShutdown;
        this._actions._updateHaveShutdown();
        this._actions = null;
    }
}
