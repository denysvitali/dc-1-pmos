#!/usr/bin/env gjs
// Regression test for the dc1-safe-area lock-screen lift (device r102).
//
// The extension imports resource:///org/gnome/shell/ui/main.js, which only
// exists inside gnome-shell, so a standalone gjs cannot load the module
// directly. As scripts/tests/test_gpu_settings_poll.py does for its GI
// imports, strip the import statements and evaluate the production class in
// a scope that provides a mock Main. Every other line of the extension --
// the resolver, the padding logic, the signal bookkeeping -- runs unmodified.
//
// The mocked dialog reproduces the child order gnome-shell-mobile's
// unlockDialog.js builds: _backgroundGroup is added first and the main
// St.BoxLayout (parent of the clock/prompt _stack) after it. Device r101
// resolved the lift target as dialog.get_first_child() and therefore padded
// the background; every padding assertion here fails against that resolver.

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';

const scriptDir = Gio.File.new_for_uri(import.meta.url).get_parent().get_path();

// DC1_EXT_PATH overrides the production file so the suite can be pointed at
// an older revision to prove it catches the r101 wrong-child bug.
const extensionPath = GLib.getenv('DC1_EXT_PATH') ?? GLib.build_filenamev([
    scriptDir, '..', '..',
    'pmaports', 'device', 'testing', 'device-daylight-jagar',
    'dc1-safe-area-extension.js',
]);

const [, bytes] = GLib.file_get_contents(extensionPath);
let code = new TextDecoder().decode(bytes);

// Strip the two resource imports; the evaluation scope provides both
// bindings. De-export the class so it can be returned to this scope.
code = code
    .split('\n')
    .filter(line => !line.startsWith('import '))
    .join('\n')
    .replace('export default class Dc1SafeAreaExtension',
             'class Dc1SafeAreaExtension');
if (/\bexport\b/.test(code))
    throw new Error('unexpected export left after de-exporting the class');

// The class is built once against a single, mutable Main that each shell
// below re-points to its own mocks; the extension resolves Main.* per call.
const Main = {};
const Dc1SafeAreaExtension = new Function(
    'Main', 'Extension', `${code}\nreturn Dc1SafeAreaExtension;`)(Main, class {});

let failures = 0;
function check(name, cond) {
    if (cond)
        print(`PASS: ${name}`);
    else {
        failures += 1;
        print(`FAIL: ${name}`);
    }
}

function connectable() {
    const handlers = new Map();
    let next = 1;
    return {
        connect(_signal, fn) {
            const id = next++;
            handlers.set(id, fn);
            return id;
        },
        disconnect(id) { handlers.delete(id); },
        emit(...args) {
            for (const fn of [...handlers.values()]) fn(...args);
        },
        get handlerCount() { return handlers.size; },
    };
}

function makeActor(name, style = null) {
    const actor = connectable();
    actor._name = name;
    actor.style = style;
    actor.get_parent = () => null;
    return actor;
}

// Build the shell shape: background added first, then the auth-stack parent.
function makeShell(scale = 1.25) {
    const background = makeActor('backgroundGroup', 'stock');
    const stack = makeActor('stack');
    const mainBox = makeActor('mainBox');
    stack.get_parent = () => mainBox;
    const dialog = makeActor('dialog');
    dialog._stack = stack;
    dialog.get_first_child = () => background;

    const layoutManager = connectable();
    layoutManager.primaryMonitor = { geometry_scale: scale };
    layoutManager.panelBox = makeActor('panelBox');
    layoutManager.keyboardBox = makeActor('keyboardBox');

    const keyboard = connectable();
    keyboard.visible = false;
    keyboard.keyboardActor = null;

    Object.assign(Main, { layoutManager, keyboard,
                          screenShield: { _dialog: dialog } });
    return {
        Main, background, stack, mainBox, dialog, layoutManager, keyboard,
        ext: new Dc1SafeAreaExtension(),
    };
}

// Resolver: the background is get_first_child(); the lift must land on the
// authentication stack's parent instead.
{
    const { ext, mainBox, background } = makeShell();
    check('resolver returns the auth-stack parent, not the first child',
          ext._lockDialogMainBox() === mainBox && mainBox !== background);
}

// The bezel inset is ceil(device px / scale) on the two layout boxes only.
{
    const { ext, layoutManager } = makeShell(1.25);
    ext.enable();
    check('bezel pads panelBox by ceil(10/1.25)',
          layoutManager.panelBox.style === 'padding: 8px 8px 0 8px;');
    check('bezel pads keyboardBox by ceil(10/1.25)',
          layoutManager.keyboardBox.style === 'padding: 0 8px 8px 8px;');
    ext.disable();
    check('disable clears the bezel insets',
          layoutManager.panelBox.style === null &&
          layoutManager.keyboardBox.style === null);
}
{
    const { ext, layoutManager } = makeShell(2);
    ext.enable();
    check('bezel inset follows a larger scale',
          layoutManager.panelBox.style === 'padding: 5px 5px 0 5px;');
    ext.disable();
}

// Hidden keyboard: enable() pads nothing and leaves the background alone.
{
    const { ext, background, mainBox } = makeShell();
    ext.enable();
    check('no padding with the keyboard hidden', mainBox.style === null);
    check('background untouched with the keyboard hidden',
          background.style === 'stock');
    ext.disable();
    check('disable clears the lock-sheet padding', mainBox.style === null);
}

// Visible keyboard: padding on the auth-stack parent, never the background.
{
    const { ext, background, mainBox, keyboard } = makeShell();
    ext.enable();
    keyboard.visible = true;
    keyboard.keyboardActor = makeActor('keyboardActor');
    keyboard.keyboardActor.height = 270;
    ext._onKeyboardVisibilityChanged();
    check('visible keyboard pads the auth-stack parent',
          mainBox.style === 'padding-bottom: 270px;');
    check('background still untouched with the keyboard up',
          background.style === 'stock');
    ext.disable();
}

// A height change while staying visible (symbols page) must retune the lift
// through the notify::height watcher, without any visibility change.
{
    const { ext, mainBox, keyboard } = makeShell();
    ext.enable();
    keyboard.visible = true;
    const actor = makeActor('keyboardActor');
    actor.height = 270;
    keyboard.keyboardActor = actor;
    ext._onKeyboardVisibilityChanged();
    actor.height = 340;
    actor.emit('notify::height');
    check('notify::height retunes the padding',
          mainBox.style === 'padding-bottom: 340px;');

    // Re-subscription: replacing the actor moves the watcher to the new one
    // and disconnects it from the old.
    const replacement = makeActor('keyboardActor');
    replacement.height = 300;
    keyboard.keyboardActor = replacement;
    ext._onKeyboardVisibilityChanged();
    check('old keyboard actor watcher disconnected',
          actor.handlerCount === 0);
    replacement.emit('notify::height');
    check('replacement actor watcher applies its height',
          mainBox.style === 'padding-bottom: 300px;');
    ext.disable();
}

// Hiding the keyboard clears the padding again.
{
    const { ext, mainBox, keyboard } = makeShell();
    ext.enable();
    keyboard.visible = true;
    keyboard.keyboardActor = makeActor('keyboardActor');
    keyboard.keyboardActor.height = 270;
    ext._onKeyboardVisibilityChanged();
    keyboard.visible = false;
    ext._onKeyboardVisibilityChanged();
    check('hiding the keyboard clears the padding', mainBox.style === null);
    ext.disable();
}

// Visible keyboard with no actor yet: zero height, no padding, no throw.
{
    const { ext, mainBox, keyboard } = makeShell();
    ext.enable();
    keyboard.visible = true;
    ext._onKeyboardVisibilityChanged();
    check('no keyboard actor means no padding', mainBox.style === null);
    ext.disable();
}

// A missing screenShield must be safe in every entry point.
{
    const { Main, ext } = makeShell();
    ext.enable();
    Main.screenShield = null;
    let threw = false;
    try {
        ext._applyLockSheet();
        ext._lockDialogMainBox();
        ext.disable();
    } catch (e) {
        threw = true;
        print(`  exception: ${e.message ?? e}`);
    }
    check('null screenShield is safe', !threw);
}

// Dialogs without a stack (or a shield without a dialog) resolve to null.
{
    const { Main, ext } = makeShell();
    delete Main.screenShield._dialog._stack;
    check('dialog without a stack resolves to null',
          ext._lockDialogMainBox() === null);
    Main.screenShield = {};
    check('shield without a dialog resolves to null',
          ext._lockDialogMainBox() === null);
}

print(failures === 0
    ? 'dc1-safe-area lock-sheet test passed'
    : `${failures} check(s) failed`);
if (failures > 0)
    throw new Error(`${failures} check(s) failed`);
