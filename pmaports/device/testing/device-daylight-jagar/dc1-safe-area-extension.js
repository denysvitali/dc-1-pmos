// Keeps shell chrome out of the DC-1's bezel overlap and out of the
// on-screen keyboard.
//
// 1. Bezel. The bezel covers the outer ~10 device px of the 1200x1600 panel
// on every edge, and the lit area has ~30-40 px rounded corners (measured
// 2026-08-25 with on-glass calibration rulers), so edge-flush chrome -- the
// top bar and the OSK's outer key rows -- loses its first pixel rows under
// the glass frame.
//
// The Panel actor cannot be padded directly: its vfunc_allocate spans
// children over the full allocation (y1 = 0 .. allocHeight) and never
// consults the theme node, so CSS padding on #panel moves nothing. Instead
// pad the two layout-manager boxes, which are ordinary St.BoxLayouts and do
// honor their content box: panelBox (top + sides) drops the bar into the
// visible area, and keyboardBox (bottom + sides) lifts the OSK. Struts and
// the work area track the boxes' allocations, so windows keep clearing the
// chrome. The uncovered strips left behind sit inside the bezel overlap and
// are not visible.
//
// The inset is specified in device pixels and divided by the monitor scale,
// so the on-glass clearance stays put if the user changes the display scale.
//
// 2. On-screen keyboard over the lock screen. gnome-shell never lifts the
// lock screen's unlock sheet for the OSK: keyboard.js holds no unlock /
// screenShield reference at all, and unlockDialog.js only asks whether a
// click landed inside the keyboard box. The sheet is `y_align: END` in the
// lock dialog's Shell.Stack and gnome-shell-mobile expects the in-sheet PIN
// pad (`_pinUnlockKeyboard`, only shown when `Main.layoutManager.isPhone`)
// to occupy the space below it -- with the pad hidden the sheet sits flush
// on the panel's bottom edge. The DC-1 cannot satisfy `_checkIsPhone()` (it
// wants <500x<1000 logical px; 1200x1600 at the 1.25 scale is 960x1280), so
// the pad is always hidden and the sheet is always at the bottom edge: the
// OSK then covers it outright -- avatar, user name and password entry alike
// -- exactly while the user is typing into it.
//
// keyboardBox cannot supply the height to lift by: it carries
// MonitorConstraint({primary: true}), so it is monitor-sized rather than
// keyboard-sized. Main.keyboard.keyboardActor can.
//
// The lift is applied as CSS padding on the lock dialog's main box, which is
// the parent of that stack. It is a plain St.BoxLayout, so its content box
// honours padding -- the same mechanism, and the same class of actor, the
// bezel inset above already relies on. A margin on the sheet itself would be
// the more obvious lever, but Shell.Stack allocates children with its own
// custom vfunc_allocate (src/shell-stack.c) and makes no promise about child
// margins, whereas padding on a St.BoxLayout is what this extension already
// does on hardware. The dialog animates `translation_y` on the sheet to
// slide it in and out, so translating it here is not an option either.

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const BEZEL_DEVICE_PX = 10;

export default class Dc1SafeAreaExtension extends Extension {
    enable() {
        this._keyboardActor = null;
        this._keyboardHeightId = 0;

        this._monitorsChangedId = Main.layoutManager.connect(
            'monitors-changed', () => this._apply());
        this._keyboardVisibilityId = Main.keyboard.connect(
            'visibility-changed', () => this._onKeyboardVisibilityChanged());
        this._apply();
    }

    _apply() {
        this._applyBezel();
        this._applyLockSheet();
    }

    _applyBezel() {
        const scale = Main.layoutManager.primaryMonitor?.geometry_scale ?? 1;
        const px = Math.ceil(BEZEL_DEVICE_PX / scale);
        Main.layoutManager.panelBox.style =
            `padding: ${px}px ${px}px 0 ${px}px;`;
        Main.layoutManager.keyboardBox.style =
            `padding: 0 ${px}px ${px}px ${px}px;`;
    }

    _applyLockSheet() {
        const mainBox = this._lockDialogMainBox();
        if (!mainBox)
            return;
        const height = this._keyboardHeight();
        mainBox.style = height ? `padding-bottom: ${height}px;` : null;
    }

    _lockDialogMainBox() {
        // The dialog adds exactly one child: the St.BoxLayout holding the
        // clock/prompt stack and the switch-user button.
        return Main.screenShield?._dialog?.get_first_child() ?? null;
    }

    _keyboardHeight() {
        const keyboard = Main.keyboard;
        if (!keyboard?.visible)
            return 0;
        return keyboard.keyboardActor?.height ?? 0;
    }

    _onKeyboardVisibilityChanged() {
        this._watchKeyboardActor();
        this._applyLockSheet();
    }

    // The OSK also changes height while it stays visible -- a layout switch
    // to the symbols or emoji page resizes it without any visibility change,
    // which would leave the sheet behind the keys again. Re-subscribe
    // whenever the actor is (re)created.
    _watchKeyboardActor() {
        const actor = Main.keyboard?.keyboardActor ?? null;
        if (actor === this._keyboardActor)
            return;

        if (this._keyboardHeightId && this._keyboardActor)
            this._keyboardActor.disconnect(this._keyboardHeightId);
        this._keyboardHeightId = 0;
        this._keyboardActor = actor;
        if (actor)
            this._keyboardHeightId = actor.connect(
                'notify::height', () => this._applyLockSheet());
    }

    disable() {
        Main.layoutManager.disconnect(this._monitorsChangedId);
        Main.keyboard.disconnect(this._keyboardVisibilityId);
        if (this._keyboardHeightId && this._keyboardActor)
            this._keyboardActor.disconnect(this._keyboardHeightId);
        this._keyboardActor = null;
        this._keyboardHeightId = 0;

        Main.layoutManager.panelBox.style = null;
        Main.layoutManager.keyboardBox.style = null;

        const mainBox = this._lockDialogMainBox();
        if (mainBox)
            mainBox.style = null;
    }
}
