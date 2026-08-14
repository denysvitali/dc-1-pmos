import 'dart:async';

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
    super.key,
  });

  final BackendClient client;
  final OnboardingDraft draft;
  final VoidCallback onRetry;

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  StreamSubscription<ProgressEvent>? _events;
  String _state = 'STARTING';
  String _message = 'Applying your settings.';
  double? _fraction;
  bool _finished = false;

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

  @override
  Widget build(BuildContext context) {
    final double? fraction = _fraction;
    final bool failed = stateIsFailure(_state);
    final bool complete = stateIsComplete(_state);
    return StepScaffold(
      title: complete ? 'Done' : (failed ? 'Failed' : 'Setting up'),
      body: ListView(
        children: <Widget>[
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
          : null,
    );
  }
}
