#!/usr/bin/env gjs
// Exercise the shipped compatibility extension without a running shell.
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';

const root = Gio.File.new_for_uri(import.meta.url).get_parent().get_parent().get_parent();
const path = root.resolve_relative_path(
    'pmaports/device/testing/device-daylight-jagar/dc1-session-compat-extension.js');
const [, bytes] = path.load_contents(null);
const code = new TextDecoder().decode(bytes).split('\n')
    .filter(line => !line.startsWith('import ')).join('\n')
    .replace('export default class Dc1SessionCompatExtension',
        'class Dc1SessionCompatExtension');
const nativeGetter = function () { throw new Error('broken native getter called'); };
class Button {
    constructor() {
        this._pressed = false;
        this.gesture = {get_pressed: () => this._pressed};
    }
    get_click_gesture() { return this.gesture; }
}
Button.prototype.get_pressed = nativeGetter;
// GJS's introspection optimization routes property reads to the native
// getter too, despite the C GObject property handler being correct.
Object.defineProperty(Button.prototype, 'pressed', {
    get: nativeGetter, configurable: true, enumerable: true,
});
const actions = Object.create({_updateHaveShutdown() {}});
const fakeGio = {DBus: {session: {call() {}}}, DBusCallFlags: {NONE: 0}};
const Compat = new Function('Gio', 'GLib', 'St', 'Extension', 'SystemActions',
    `${code}\nreturn Dc1SessionCompatExtension;`)(
    fakeGio, GLib, {Button}, class {}, {getDefault: () => actions});
Compat.prototype._registerSessionWithGdm = function () {};

function check(condition, message) {
    if (!condition)
        throw new Error(message);
}

// Both states must reflect the live property; the broken native getter
// always returned false even while a real gesture was pressed.
const extension = new Compat();
extension.enable();
const button = new Button();
check(button.get_pressed() === false, 'unpressed state');
check(button.pressed === false, 'unpressed property');
button._pressed = true;
check(button.get_pressed() === true, 'pressed state');
check(button.pressed === true, 'pressed property');
button.gesture = null;
check(button.get_pressed() === false, 'removed gesture');
extension.disable();
check(Button.prototype.get_pressed === nativeGetter, 'disable restores native method');
check(Object.getOwnPropertyDescriptor(Button.prototype, 'pressed').get === nativeGetter,
    'disable restores native property');

// An older shell without the new gesture API must retain its own getter.
delete Button.prototype.get_click_gesture;
extension.enable();
check(Button.prototype.get_pressed === nativeGetter, 'older shell unchanged');
check(Object.getOwnPropertyDescriptor(Button.prototype, 'pressed').get === nativeGetter,
    'older shell property unchanged');
extension.disable();
check(Button.prototype.get_pressed === nativeGetter, 'older shell disable unchanged');
print('PASS: button pressed state, extension cleanup and older-shell compatibility');
