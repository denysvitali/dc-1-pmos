#!/usr/bin/env gjs
// Test the production bridge's routing and lifecycle without a compositor.
import {NativeBrightnessBridge} from '../../pmaports/device/testing/device-daylight-jagar/dc1-frontlight-bridge.js';

function assert(value, message) {
    if (!value)
        throw new Error(message);
}
function scale(builtin) {
    return {
        monitor: {get_monitors: () => [{is_builtin: () => builtin}]},
        value: 0.7,
        writes: [],
        setBacklight(value) { this.writes.push(value); },
        syncWithBacklight() { return true; },
    };
}
const internal = scale(true);
const external = scale(false);
const originalWrite = internal.setBacklight;
const originalRead = internal.syncWithBacklight;
const callbacks = new Map();
let nextId = 1;
const manager = {
    scales: [external, internal],
    connect(signal, callback) {
        const id = nextId++;
        callbacks.set(id, {signal, callback});
        return id;
    },
    disconnect(id) { callbacks.delete(id); },
    emit(signal) {
        for (const entry of [...callbacks.values()]) {
            if (entry.signal === signal)
                entry.callback();
        }
    },
    _sync() {
        for (const item of this.scales)
            item.setBacklight(item.value);
    },
};
const mixed = [];
let migrations = 0;
const manual = [];
const bridge = new NativeBrightnessBridge(manager, {
    setLuminance(value) { mixed.push(value); },
}, {
    initialLuminance: 0.25,
    onMigrated() { migrations++; },
    onUserChange(value) { manual.push(value); },
});
assert(internal.value === 0.25 && mixed.at(-1) === 0.25,
    'migration must retain saved mixed luminance');
assert(internal.writes.length === 0, 'internal writes must use the mixer');
assert(external.writes.at(-1) === 0.7, 'external monitors must keep native writes');
assert(!internal.syncWithBacklight(), 'white channel echoes must not change the slider');
// These values come from native policy, including auto targets and idle dimming.
for (const value of [0.8, 0.1, 0, 1]) {
    internal.setBacklight(value);
    assert(mixed.at(-1) === value, 'native target must reach the mixer unchanged');
}
assert(manual.length === 0, 'automatic targets must not overwrite manual preference');
internal.value = 0.6;
manager.emit('user-update');
assert(manual.at(-1) === 0.6, 'manual slider preference must persist');
manager.scales = [];
manager.emit('changed');
assert(internal.setBacklight === originalWrite && internal.syncWithBacklight === originalRead,
    'monitor removal must restore its methods');
const replacement = scale(true);
manager.scales = [external, replacement];
manager.emit('changed');
assert(replacement.value === 0.7 && migrations === 1,
    'reconnection must use native preference, without repeating migration');
bridge.destroy();
assert(callbacks.size === 0, 'disable must release every manager signal');
replacement.setBacklight(0.3);
assert(replacement.writes.at(-1) === 0.3, 'disable must restore native writes');
bridge.destroy();
// If startup fails after binding, leave native methods and signals intact.
manager.scales = [internal];
const savedSync = manager._sync;
manager._sync = () => { throw new Error('simulated startup failure'); };
try {
    new NativeBrightnessBridge(manager, {setLuminance() {}});
    throw new Error('expected startup failure');
} catch (error) {
    assert(error.message === 'simulated startup failure', error.message);
}
assert(callbacks.size === 0 && internal.setBacklight === originalWrite,
    'failed enable must restore native methods and signals');
manager._sync = savedSync;
print('DC-1 native brightness bridge routing and lifecycle passed');
