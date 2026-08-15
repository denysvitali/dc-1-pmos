import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../backend.dart';
import '../draft.dart';
import '../theme.dart';
import '../widgets.dart';

/// Screen 8 -- progress, driven by the backend's NDJSON `GET /events`
/// stream. The states are the installer's free-form uppercase vocabulary
/// (FETCHING / DOWNLOADING / VERIFYING / WRITING / COMPLETE / FAILED and
/// friends); this screen renders whatever the backend says rather than
/// mapping it through an enum that would silently drop unknown states.
///
/// The stream is a progress channel, not the result: the POST /onboard
/// response is what decides success, so the screen still terminates
/// correctly if the backend ships no events at all.
class ProgressScreen extends StatefulWidget {
  const ProgressScreen({
    required this.client,
    required this.draft,
    required this.onRetry,
    this.onRestarted,
    super.key,
  });

  final BackendClient client;
  final OnboardingDraft draft;
  final VoidCallback onRetry;

  /// Called after `finish()` resolves in the web preview, where there is
  /// nothing to reboot: restarting the flow is the closest honest
  /// simulation of the fresh boot. Dead code on the device -- the real
  /// reboot replaces the whole session, and `kIsWeb` is false there.
  final VoidCallback? onRestarted;

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  StreamSubscription<ProgressEvent>? _events;
  String _state = 'STARTING';
  String _message = 'Applying your settings.';
  double? _fraction;
  bool _finished = false;
  bool _restarting = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
    // Not in initState directly: _apply() reports its first state
    // synchronously, and setState() during the first build is an error.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      unawaited(_apply());
    });
  }

  @override
  void dispose() {
    unawaited(_events?.cancel() ?? Future<void>.value());
    _events = null;
    super.dispose();
  }

  /// The last step of onboarding. The account, hostname and network the user
  /// just chose only take effect on a fresh boot -- this session is still
  /// running as the pre-onboarding user -- so "Done" has to lead here rather
  /// than leaving them on a screen with no way forward.
  Future<void> _restart() async {
    setState(() {
      _restarting = true;
    });
    try {
      await widget.client.finish();
    } on Object {
      // Expected: the backend reboots moments after replying, so the socket
      // frequently dies mid-response. There is nothing useful to report and
      // nothing to retry -- the device is on its way down either way.
    }
    if (kIsWeb) {
      widget.onRestarted?.call();
    }
  }

  void _subscribe() {
    try {
      _events = widget.client.events().listen(
        _onEvent,
        onError: (Object _) {
          // The event stream is optional; POST /onboard reports the result.
        },
        cancelOnError: false,
      );
    } catch (_) {
      _events = null;
    }
  }

  void _onEvent(ProgressEvent event) {
    if (_finished && !event.isFailure) {
      return;
    }
    _set(event.state, event.message ?? _message, event.progress);
  }

  Future<void> _apply() async {
    try {
      final String? ssid = widget.draft.ssid;
      if (ssid != null && ssid.isNotEmpty) {
        _set('CONNECTING', 'Joining $ssid');
        await widget.client.connectWifi(ssid, widget.draft.psk);
      }
      _set('PROVISIONING', 'Writing the system configuration');
      await widget.client.onboard(
        user: widget.draft.username,
        password: widget.draft.password,
        hostname: widget.draft.hostname,
        timezone: widget.draft.timezone,
      );
      if (!_finished) {
        _set('COMPLETE', 'Setup finished.', 1.0);
      }
    } catch (failure) {
      _set('FAILED', '$failure');
    }
  }

  void _set(String state, String message, [double? fraction]) {
    if (!mounted) {
      return;
    }
    setState(() {
      _state = state;
      _message = message;
      _fraction = fraction;
      _finished = stateIsTerminal(state);
    });
  }

  Color get _stateColor {
    if (stateIsFailure(_state)) {
      return kError;
    }
    if (stateIsComplete(_state)) {
      return kOk;
    }
    return kAccent;
  }

  /// The checklist mirrors _apply()'s order. Items are checked off by
  /// substring against the live state -- the same free-form vocabulary the
  /// terminal states are matched with -- so a step lights up as soon as the
  /// stream or _apply() moves past it.
  bool _wifiJoined(String state) {
    if (!widget.draft.hasWifi) {
      return true; // Wi-Fi was skipped, so there is nothing to join.
    }
    // The join itself is the honest signal, and it now arrives with the
    // address attached; the states below are the later steps, kept so a
    // stream that skips straight past the join still ticks the box.
    return state.contains('WI-FI CONNECTED') ||
        state.contains('PROVISIONING') ||
        state.contains('HASHING') ||
        state.contains('APPLYING') ||
        state.contains('COMPLETE') ||
        state.contains('ALREADY');
  }

  bool _userCreated(String state) =>
      state.contains('APPLYING HOSTNAME') ||
      state.contains('COMPLETE') ||
      state.contains('ALREADY');

  bool _hostApplied(String state) =>
      state.contains('COMPLETE') || state.contains('ALREADY');

  Widget _step(String label, bool done) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            color: done ? kOk : kMuted,
            size: 26,
          ),
          const SizedBox(width: 12),
          Text(label, style: done ? kBodyStyle : kSubtitleStyle),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double? fraction = _fraction;
    final bool failed = stateIsFailure(_state);
    final bool complete = stateIsComplete(_state);
    return StepScaffold(
      title: complete ? 'Done' : (failed ? 'Failed' : 'Setting up'),
      body: ListView(
        children: <Widget>[
          if (widget.draft.hasWifi)
            _step('Wi-Fi joined', _wifiJoined(_state)),
          _step('User created', _userCreated(_state)),
          _step('Hostname and timezone applied', _hostApplied(_state)),
          const SizedBox(height: 24),
          Text(
            _state,
            style: TextStyle(
              color: _stateColor,
              fontSize: 30,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 16),
          Text(_message, style: kBodyStyle),
          const SizedBox(height: 32),
          if (!complete && !failed)
            LinearProgressIndicator(
              value: fraction,
              minHeight: 10,
              color: kAccent,
              backgroundColor: kSurface,
            ),
        ],
      ),
      footer: failed
          ? SecondaryButton(label: 'Back', onPressed: widget.onRetry)
          : complete
          ? PrimaryButton(
              label: _restarting ? 'Restarting...' : 'Restart now',
              onPressed: _restarting ? null : _restart,
            )
          : null,
    );
  }
}
