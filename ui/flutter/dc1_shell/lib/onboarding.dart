import 'package:flutter/material.dart';

import 'backend.dart';
import 'draft.dart';
import 'screens/confirm_screen.dart';
import 'screens/hostname_screen.dart';
import 'screens/password_screen.dart';
import 'screens/progress_screen.dart';
import 'screens/psk_screen.dart';
import 'screens/timezone_screen.dart';
import 'screens/username_screen.dart';
import 'screens/wifi_screen.dart';
import 'theme.dart';

/// The onboarding screens, in the order installer/src/tui.sh asks them.
enum OnboardStep {
  wifi,
  psk,
  username,
  password,
  hostname,
  timezone,
  confirm,
  progress,
}

class OnboardingApp extends StatelessWidget {
  const OnboardingApp({required this.client, super.key});

  final BackendClient client;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DC-1 setup',
      debugShowCheckedModeBanner: false,
      theme: dc1Theme(),
      home: OnboardingFlow(client: client),
    );
  }
}

class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({required this.client, super.key});

  final BackendClient client;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final OnboardingDraft _draft = OnboardingDraft();
  OnboardStep _step = OnboardStep.wifi;

  void _go(OnboardStep step) {
    setState(() {
      _step = step;
    });
  }

  @override
  Widget build(BuildContext context) {
    return switch (_step) {
      OnboardStep.wifi => _wifi(),
      OnboardStep.psk => _psk(),
      OnboardStep.username => _username(),
      OnboardStep.password => _password(),
      OnboardStep.hostname => _hostname(),
      OnboardStep.timezone => _timezone(),
      OnboardStep.confirm => _confirm(),
      OnboardStep.progress => _progress(),
    };
  }

  Widget _wifi() {
    return WifiScreen(
      client: widget.client,
      onSelected: (String ssid) {
        _draft.ssid = ssid;
        _go(OnboardStep.psk);
      },
      onSkip: () {
        _draft.clearWifi();
        _go(OnboardStep.username);
      },
    );
  }

  Widget _psk() {
    return PskScreen(
      ssid: _draft.ssid ?? '',
      initial: _draft.psk,
      onNext: (String psk) {
        _draft.psk = psk;
        _go(OnboardStep.username);
      },
      onBack: () => _go(OnboardStep.wifi),
    );
  }

  Widget _username() {
    return UsernameScreen(
      initial: _draft.username,
      onNext: (String user) {
        _draft.username = user;
        _go(OnboardStep.password);
      },
      onBack: () => _go(_draft.hasWifi ? OnboardStep.psk : OnboardStep.wifi),
    );
  }

  Widget _password() {
    return PasswordScreen(
      username: _draft.username,
      onNext: (String password) {
        _draft.password = password;
        _go(OnboardStep.hostname);
      },
      onBack: () => _go(OnboardStep.username),
    );
  }

  Widget _hostname() {
    return HostnameScreen(
      initial: _draft.hostname,
      onNext: (String hostname) {
        _draft.hostname = hostname;
        _go(OnboardStep.timezone);
      },
      onBack: () => _go(OnboardStep.password),
    );
  }

  Widget _timezone() {
    return TimezoneScreen(
      initial: _draft.timezone,
      onNext: (String timezone) {
        _draft.timezone = timezone;
        _go(OnboardStep.confirm);
      },
      onBack: () => _go(OnboardStep.hostname),
    );
  }

  Widget _confirm() {
    return ConfirmScreen(
      draft: _draft,
      onConfirm: () => _go(OnboardStep.progress),
      onBack: () => _go(OnboardStep.timezone),
    );
  }

  Widget _progress() {
    return ProgressScreen(
      client: widget.client,
      draft: _draft,
      onRetry: () => _go(OnboardStep.confirm),
    );
  }
}
