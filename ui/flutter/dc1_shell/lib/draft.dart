/// What the user has answered so far.
///
/// The password and the PSK are held here only until the backend has
/// accepted them; they are never rendered, never logged and never written
/// anywhere by this process. Dart strings are immutable, so they cannot be
/// wiped in place -- the backend is the component that owns zeroing
/// secrets, which is why it takes them as a request body and applies them
/// itself.
class OnboardingDraft {
  /// null means "no Wi-Fi configured", which the installer permits.
  String? ssid;
  String psk = '';

  /// Defaults mirror the prefills in installer/src/tui.sh.
  String username = 'user';
  String password = '';
  String hostname = 'dc1';
  String timezone = 'UTC';

  bool get hasWifi {
    final String? value = ssid;
    return value != null && value.isNotEmpty;
  }

  void clearWifi() {
    ssid = null;
    psk = '';
  }
}
