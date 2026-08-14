import 'package:flutter/material.dart';

import '../theme.dart';
import '../validation.dart';
import '../widgets.dart';

/// Screen 3 -- the account name. Same rules as installer/src/tui.sh, shown
/// next to the field so a typo never reaches a destructive step.
class UsernameScreen extends StatefulWidget {
  const UsernameScreen({
    required this.initial,
    required this.onNext,
    required this.onBack,
    super.key,
  });

  final String initial;
  final ValueChanged<String> onNext;
  final VoidCallback onBack;

  @override
  State<UsernameScreen> createState() => _UsernameScreenState();
}

class _UsernameScreenState extends State<UsernameScreen> {
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
    final String? error = validateUsername(value);
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
      title: 'Username',
      subtitle: 'The account you will log in with.',
      body: ListView(
        children: <Widget>[
          Dc1TextField(
            controller: _controller,
            hintText: 'user',
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
            'Lowercase letters, digits, - and _; must start with a letter '
            'or _; at most 32 characters.',
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
