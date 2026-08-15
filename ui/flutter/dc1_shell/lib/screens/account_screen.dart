import 'package:flutter/material.dart';

import '../theme.dart';
import '../validation.dart';
import '../widgets.dart';

/// Screen 3 -- the account, on one page: username, then the password twice.
/// Kept together because a username with no password -- or a password typed
/// with the wrong name above it -- is a mistake no later screen should have
/// to catch. Both password fields are obscured and the value is never shown
/// again; hashing happens in the backend, from stdin, never on an argv.
class AccountScreen extends StatefulWidget {
  const AccountScreen({
    required this.initialUsername,
    required this.onNext,
    required this.onBack,
    super.key,
  });

  final String initialUsername;
  final void Function(String username, String password) onNext;
  final VoidCallback onBack;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  late final TextEditingController _username = TextEditingController(
    text: widget.initialUsername,
  );
  final TextEditingController _password = TextEditingController();
  final TextEditingController _repeat = TextEditingController();
  String? _usernameError;
  String? _passwordError;
  String? _repeatError;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _submit() {
    final String username = _username.text.trim();
    final String password = _password.text;
    final String repeat = _repeat.text;
    final String? usernameError = validateUsername(username);
    final String? passwordError = validatePassword(password);
    final String? repeatError = passwordError == null
        ? validatePasswordRepeat(password, repeat)
        : null;
    if (usernameError != null || passwordError != null || repeatError != null) {
      setState(() {
        _usernameError = usernameError;
        _passwordError = passwordError;
        _repeatError = repeatError;
      });
      return;
    }
    widget.onNext(username, password);
  }

  void _clearUsernameError() {
    if (_usernameError != null) {
      setState(() {
        _usernameError = null;
      });
    }
  }

  void _clearPasswordErrors() {
    if (_passwordError != null || _repeatError != null) {
      setState(() {
        _passwordError = null;
        _repeatError = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      title: 'Account',
      subtitle: 'The user you will log in with.',
      body: ListView(
        children: <Widget>[
          Dc1TextField(
            controller: _username,
            hintText: 'user',
            errorText: _usernameError,
            autofocus: true,
            onChanged: (String _) => _clearUsernameError(),
            onSubmitted: (String _) => _submit(),
          ),
          const SizedBox(height: 12),
          const Text(
            'Lowercase letters, digits, - and _; must start with a letter '
            'or _; at most 32 characters.',
            style: kSubtitleStyle,
          ),
          const SizedBox(height: 20),
          Dc1TextField(
            controller: _password,
            hintText: 'Password',
            errorText: _passwordError,
            obscureText: true,
            onChanged: (String _) => _clearPasswordErrors(),
          ),
          const SizedBox(height: 20),
          Dc1TextField(
            controller: _repeat,
            hintText: 'Password (again)',
            errorText: _repeatError,
            obscureText: true,
            onChanged: (String _) => _clearPasswordErrors(),
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
