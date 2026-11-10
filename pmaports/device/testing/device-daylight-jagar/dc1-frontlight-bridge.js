// Adapt GNOME 51's native brightness targets to the DC-1's two frontlights.
// GNOME retains the slider, automatic target, dimming and persistence. Only
// the final write is routed through the existing colour-temperature mixer.
export class NativeBrightnessBridge {
    constructor(manager, controller, options = {}) {
        this._manager = manager;
        this._controller = controller;
        this._initialLuminance = options.initialLuminance ?? null;
        this._onMigrated = options.onMigrated ?? (() => {});
        this._onUserChange = options.onUserChange ?? (() => {});
        this._changedId = manager.connect('changed', () => this._bind());
        this._userId = manager.connect('user-update', () => {
            if (this._scale)
                this._onUserChange(this._scale.value);
        });
        try {
            this._bind();
        } catch (error) {
            this.destroy();
            throw error;
        }
    }

    _bind() {
        this._restore();
        const scale = this._manager.scales.find(candidate =>
            candidate.monitor.get_monitors().some(monitor => monitor.is_builtin()));
        if (!scale)
            return;

        this._scale = scale;
        this._setBacklight = scale.setBacklight;
        this._syncWithBacklight = scale.syncWithBacklight;
        scale.setBacklight = value => this._controller.setLuminance(value);
        // White is only one component of the mixed output. Reading it as
        // the total brightness would feed our own writes back into the slider.
        scale.syncWithBacklight = () => false;

        const migrating = this._initialLuminance !== null;
        if (migrating)
            scale.value = this._initialLuminance;
        this._manager._sync({showOSD: false});
        if (migrating) {
            this._initialLuminance = null;
            this._onMigrated();
        }
    }

    _restore() {
        if (!this._scale)
            return;
        this._scale.setBacklight = this._setBacklight;
        this._scale.syncWithBacklight = this._syncWithBacklight;
        this._scale = null;
    }

    destroy() {
        if (this._changedId)
            this._manager.disconnect(this._changedId);
        if (this._userId)
            this._manager.disconnect(this._userId);
        this._changedId = this._userId = 0;
        this._restore();
    }
}
