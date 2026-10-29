// Exercise the methods shipped in the patch with GJS and real GLib variants.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const here = Gio.File.new_for_uri(import.meta.url).get_parent();
const patch = here.get_parent().get_parent().resolve_relative_path(
    'pmaports/device/testing/gnome-shell-mobile/mobile-runtime-fixes.patch');
const [, bytes] = patch.load_contents(null);
const text = new TextDecoder().decode(bytes);

function section(path) {
    const start = text.indexOf(`+++ b/${path}\n`);
    if (start < 0)
        throw new Error(`Missing patch section: ${path}`);
    const end = text.indexOf('\n--- a/', start);
    return text.slice(start, end < 0 ? undefined : end).split('\n')
        .filter(line => line.startsWith(' ') ||
            (line.startsWith('+') && !line.startsWith('+++')))
        .map(line => line.slice(1)).join('\n');
}

function method(source, name) {
    const start = source.indexOf(`    ${name}(`);
    if (start < 0)
        throw new Error(`Missing method: ${name}`);
    let depth = 0;
    for (let i = source.indexOf('{', start); i < source.length; i++) {
        if (source[i] === '{')
            depth++;
        if (source[i] === '}' && --depth === 0)
            return source.slice(start, i + 1);
    }
    throw new Error(`Incomplete method: ${name}`);
}

function assert(condition, message) {
    if (!condition)
        throw new Error(message);
}

const brightness = section('js/misc/brightnessManager.js');
const MonitorId = Function(`return class {${method(brightness, 'constructor')}}`)();
const fields = ['vendor', 'product', 'serial', 'colorMode', 'connector'];
for (const identity of [
    {vendor: null, product: null, serial: null},
    {vendor: 'Test vendor', product: 'Panel', serial: '123'},
]) {
    const options = {...identity, colorMode: 'default', connector: 'DSI-1'};
    const id = new MonitorId(options);
    const tuple = fields.map(field => id[`_${field}`]);
    const saved = new GLib.Variant('a(sssssd)', [[...tuple, 0.4]]).deepUnpack()[0];
    for (let i = 0; i < fields.length; i++)
        assert(saved[i] === (options[fields[i]] ?? ''), 'Monitor identity changed');
    assert(saved[5] === 0.4, 'Brightness persistence changed');
}

const shield = section('js/ui/screenShield.js');
const ScreenShield = Function(`return class {${method(shield, '_displayConfigChanged')}}`)();
const screen = new ScreenShield();
let cancelled = 0;
screen.cancelUnlock = () => cancelled++;
for (const mode of [-1, 0, 1, 2, 3]) {
    const before = cancelled;
    screen._displayConfigChanged(null,
        new GLib.Variant('a{sv}', {PowerSaveMode: new GLib.Variant('i', mode)}));
    assert(cancelled - before === (mode > 0 ? 1 : 0), `Wrong power behavior: ${mode}`);
}
screen._displayConfigChanged(null, new GLib.Variant('a{sv}', {}));
assert(cancelled === 3, 'Unrelated properties cancelled the prompt');

const unlock = section('js/ui/unlockDialog.js');
const UnlockDialog = Function(`return class {
    ${method(unlock, 'cancel')}
    ${method(unlock, 'cancelUnlock')}
}`)();
const dialog = new UnlockDialog();
let clockShown = 0;
dialog._showClock = () => clockShown++;
dialog.cancel();
dialog.cancelUnlock();
assert(clockShown === 2, 'Idle and explicit cancellation must both return to the clock');
print('Mobile runtime: panel identity, display power changes and lock cancellation passed');
