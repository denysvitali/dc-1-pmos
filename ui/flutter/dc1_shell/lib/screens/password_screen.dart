import 'package:flutter/material.dart';

import '../theme.dart';
import '../validation.dart';
import '../widgets.dart';

/// Screen 4 -- the password, twice. Both fields are obscured and neither
/// value is ever shown again: the confirm screen reports "set", not the
/// password. Hashing happens on the device, in the backend, from stdin --
/// never on an argv.
class PasswordScreen extends StatefulWidget {
  const PasswordScreen({
    required this.username,
    required this.onNext,
    required this.onBack,
    super.key,
  });

  final String username;
  final ValueChanged<String> onNext;
  final VoidCallback onBack;

  @override
  State<PasswordScreen> createState() => _PasswordScreenState();
}

class _PasswordScreenState extends State<PasswordScreen> {
  final TextEditingController _first = TextEditingController();
  final TextEditingController _second = TextEditingController();
  String? _firstError;
  String? _secondError;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    final String password = _first.text;
    final String repeat = _second.text;
    final String? passwordError = validatePassword(password);
    final String? repeatError = passwordError == null
        ? validatePasswordRepeat(password, repeat)
        : null;
    if (passwordError != null || repeatError != null) {
      setState(() {
        _firstError = passwordError;
        _secondError = repeatError;
      });
      return;
    }
    widget.onNext(password);
  }

  void _clearErrors() {
    if (_firstError != null || _secondError != null) {
      setState(() {
        _firstError = null;
        _secondError = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      title: 'Password',
      subtitle: 'For ${widget.username}.',
      body: ListView(
        children: <Widget>[
          Dc1TextField(
            controller: _first,
            hintText: 'Password',
            errorText: _firstError,
            obscureText: true,
            autofocus: true,
            onChanged: (String _) => _clearErrors(),
          ),
          const SizedBox(height: 20),
          Dc1TextField(
            controller: _second,
            hintText: 'Password (again)',
            errorText: _secondError,
            obscureText: true,
            onChanged: (String _) => _clearErrors(),
            onSubmitted: (String _) => _submit(),
          ),
          const SizedBox(height: 12),
          const Text(
            'Both entries must match. The password is hashed on the device.',
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
