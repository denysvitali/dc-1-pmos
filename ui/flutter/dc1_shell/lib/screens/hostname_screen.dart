import 'package:flutter/material.dart';

import '../theme.dart';
import '../validation.dart';
import '../widgets.dart';

/// Screen 5 -- the hostname. Rules mirror installer/src/tui.sh, including
/// the trailing-dash rejection that comes before the pattern check.
class HostnameScreen extends StatefulWidget {
  const HostnameScreen({
    required this.initial,
    required this.onNext,
    required this.onBack,
    super.key,
  });

  final String initial;
  final ValueChanged<String> onNext;
  final VoidCallback onBack;

  @override
  State<HostnameScreen> createState() => _HostnameScreenState();
}

class _HostnameScreenState extends State<HostnameScreen> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String value = _controller.text.trim();
    final String? error = validateHostname(value);
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
      title: 'Hostname',
      subtitle: 'How this device names itself on the network.',
      body: ListView(
        children: <Widget>[
          Dc1TextField(
            controller: _controller,
            hintText: 'dc1',
            errorText: _error,
            autofocus: true,
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
          const Text(
            'Lowercase letters, digits and -; may not end with -; at most '
            '63 characters.',
            style: kSubtitleStyle,
          ),
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
