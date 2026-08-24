// Keeps shell chrome out of the DC-1's bezel overlap. The bezel covers the
// outer ~10 device px of the 1200x1600 panel on every edge, and the lit area
// has ~30-40 px rounded corners (measured 2026-08-25 with on-glass
// calibration rulers), so edge-flush chrome -- the top bar and the OSK's
// outer key rows -- loses its first pixel rows under the glass frame.
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

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const BEZEL_DEVICE_PX = 10;

export default class Dc1SafeAreaExtension extends Extension {
    enable() {
        this._monitorsChangedId = Main.layoutManager.connect(
            'monitors-changed', () => this._apply());
        this._apply();
    }

    _apply() {
        const scale = Main.layoutManager.primaryMonitor?.geometry_scale ?? 1;
        const px = Math.ceil(BEZEL_DEVICE_PX / scale);
        Main.layoutManager.panelBox.style =
            `padding: ${px}px ${px}px 0 ${px}px;`;
        Main.layoutManager.keyboardBox.style =
            `padding: 0 ${px}px ${px}px ${px}px;`;
    }

    disable() {
        Main.layoutManager.disconnect(this._monitorsChangedId);
        Main.layoutManager.panelBox.style = null;
        Main.layoutManager.keyboardBox.style = null;
    }
}
