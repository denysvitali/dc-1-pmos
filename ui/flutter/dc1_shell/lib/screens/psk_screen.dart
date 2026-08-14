import 'package:flutter/material.dart';

import '../theme.dart';
import '../validation.dart';
import '../widgets.dart';

/// Screen 2 -- the WPA passphrase (8..63). Obscured by default, with an
/// explicit reveal for the "I cannot type this blind on a touch panel" case.
/// The value goes straight to the backend over the Unix socket; it is never
/// shown in a summary and never logged.
class PskScreen extends StatefulWidget {
  const PskScreen({
    required this.ssid,
    required this.initial,
    required this.onNext,
    required this.onBack,
    super.key,
  });

  final String ssid;
  final String initial;
  final ValueChanged<String> onNext;
  final VoidCallback onBack;

  @override
  State<PskScreen> createState() => _PskScreenState();
}

class _PskScreenState extends State<PskScreen> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  bool _reveal = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String value = _controller.text;
    final String? error = validatePsk(value);
    if (error != null) {
      setState(() {
        _error = error;
      });
      return;
    }
    widget.onNext(value);
  }

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      title: 'Passphrase',
      subtitle: widget.ssid.isEmpty ? null : 'Network: ${widget.ssid}',
      body: ListView(
        children: <Widget>[
          Dc1TextField(
            controller: _controller,
            hintText: 'WPA passphrase',
            errorText: _error,
            obscureText: !_reveal,
            autofocus: true,
            suffix: IconButton(
              icon: Icon(
                _reveal ? Icons.visibility_off : Icons.visibility,
                color: kMuted,
              ),
              onPressed: () => setState(() {
                _reveal = !_reveal;
              }),
            ),
            onChanged: (String _) {
              if (_error != null) {
                setState(() {
                  _error = null;
                });
              }
            },
            onSubmitted: (String _) => _submit(),
          ),
          const SizedBox(height: 12),
          const Text('8 to 63 characters.', style: kSubtitleStyle),
        ],
      ),
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PrimaryButton(label: 'Continue', onPressed: _submit),
          const SizedBox(height: 12),
          SecondaryButton(label: 'Back', onPressed: widget.onBack),
        ],
      ),
    );
  }
}
