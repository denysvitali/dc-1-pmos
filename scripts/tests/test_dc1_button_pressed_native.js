#!/usr/bin/env gjs
// Optional device check: run in a private D-Bus session and runtime directory.
// It creates a headless Mutter context, never replaces the owner compositor.
import Meta from 'gi://Meta?version=16';
import St from 'gi://St?version=16';
import GObject from 'gi://GObject';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';

if (GLib.getenv('DC1_BUTTON_NATIVE_TEST') !== '1')
    throw new Error('Use test_dc1_button_pressed_native.sh for an isolated session');

const Plugin = GObject.registerClass(class ButtonTestPlugin extends Meta.Plugin {});
const context = Meta.create_context('DC1 isolated button check');
context.set_plugin_gtype(Plugin.$gtype);
context.configure(['dc1-button-check', '--headless', '--wayland', '--virtual-monitor=800x600']);
context.setup();

let criticals = 0;
const handler = GLib.log_set_handler('Clutter', GLib.LogLevelFlags.LEVEL_CRITICAL,
    (_domain, _level, message) => {
        if (message.includes('clutter_press_gesture_get_pressed'))
            criticals++;
        else
            throw new Error(message);
    });
const button = new St.Button();
button.get_pressed();
void button.pressed;
const before = criticals;

const source = Gio.File.new_for_uri(import.meta.url).get_parent().get_parent()
    .get_parent().resolve_relative_path(
        'pmaports/device/testing/device-daylight-jagar/dc1-session-compat-extension.js');
const [, bytes] = source.load_contents(null);
const code = new TextDecoder().decode(bytes).split('\n')
    .filter(line => !line.startsWith('import ')).join('\n')
    .replace('export default class Dc1SessionCompatExtension',
        'class Dc1SessionCompatExtension');
const actions = Object.create({_updateHaveShutdown() {}});
const Compat = new Function('Gio', 'GLib', 'St', 'Extension', 'SystemActions',
    `${code}\nreturn Dc1SessionCompatExtension;`)(
    {DBus: {session: {call() {}}}, DBusCallFlags: {NONE: 0}},
    GLib, St, class {}, {getDefault: () => actions});
Compat.prototype._registerSessionWithGdm = function () {};
const extension = new Compat();
extension.enable();
const pressed = button.get_click_gesture().get_pressed();
if (button.get_pressed() !== pressed || button.pressed !== pressed)
    throw new Error('button reads disagree with the actual click gesture');
if (criticals !== before)
    throw new Error('patched getters still emit Clutter criticals');
extension.disable();
button.destroy();
GLib.log_remove_handler('Clutter', handler);
print(`PASS: native baseline criticals=${before}; patched method/property correct with no new criticals`);
