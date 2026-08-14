import 'package:flutter/material.dart';

import '../draft.dart';
import '../theme.dart';
import '../widgets.dart';

/// Screen 7 -- the summary. It shows what will be applied and deliberately
/// shows neither the password nor the passphrase, only that they are set.
class ConfirmScreen extends StatelessWidget {
  const ConfirmScreen({
    required this.draft,
    required this.onConfirm,
    required this.onBack,
    super.key,
  });

  final OnboardingDraft draft;
  final VoidCallback onConfirm;
  final VoidCallback onBack;

  static Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: kSubtitleStyle),
          const SizedBox(height: 4),
          Text(value, style: kBodyStyle),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      title: 'Ready',
      subtitle: 'Check the settings, then apply them.',
      body: ListView(
        children: <Widget>[
          _row('Username', draft.username),
          _row('Password', 'set (hidden)'),
          _row('Hostname', draft.hostname),
          _row('Timezone', draft.timezone),
          _row(
            'Wi-Fi',
            draft.hasWifi ? '${draft.ssid} (passphrase set)' : 'not configured',
          ),
        ],
      ),
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PrimaryButton(label: 'Apply settings', onPressed: onConfirm),
          const SizedBox(height: 12),
          SecondaryButton(label: 'Back', onPressed: onBack),
        ],
      ),
    );
  }
}
