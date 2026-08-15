import 'dart:async';

import 'package:flutter/material.dart';

import '../backend.dart';
import '../theme.dart';
import '../validation.dart';
import '../widgets.dart';

/// Screen 1 -- pick a Wi-Fi network: scan, pick, type a hidden SSID by hand,
/// rescan, or continue without Wi-Fi (the installer permits an empty
/// SSID/PSK pair; provision.sh treats "both empty" as "no Wi-Fi").
class WifiScreen extends StatefulWidget {
  const WifiScreen({
    required this.client,
    required this.onSelected,
    required this.onSkip,
    super.key,
  });

  final BackendClient client;
  final ValueChanged<String> onSelected;
  final VoidCallback onSkip;

  @override
  State<WifiScreen> createState() => _WifiScreenState();
}

class _WifiScreenState extends State<WifiScreen> {
  final TextEditingController _ssidController = TextEditingController();

  List<WifiNetwork> _networks = const <WifiNetwork>[];
  bool _scanning = true;
  bool _manual = false;
  String? _scanError;
  String? _ssidError;

  @override
  void initState() {
    super.initState();
    // _scan() calls setState() synchronously; doing that during the first
    // build is an error, so the first scan starts after the first frame.
    // _scanning defaults to true, so the spinner is up from frame one.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      unawaited(_scan());
    });
  }

  @override
  void dispose() {
    _ssidController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    // A post-frame callback still fires if the screen was disposed first.
    if (!mounted) {
      return;
    }
    setState(() {
      _scanning = true;
      _scanError = null;
    });
    List<WifiNetwork> found = const <WifiNetwork>[];
    String? error;
    try {
      found = await widget.client.scanWifi();
    } catch (failure) {
      // BackendException carries a sentence worth showing; anything else is
      // a transport detail, and a raw socket dump helps nobody on a panel.
      error = failure is BackendException
          ? 'Could not scan for networks. ${failure.message}'
          : 'Could not scan for networks. Check that the setup service is '
                'running, then try again.';
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _networks = found;
      _scanError = error;
      _scanning = false;
    });
  }

  void _choose(String ssid) {
    final String? error = validateSsid(ssid);
    if (error != null) {
      setState(() {
        _ssidError = error;
      });
      return;
    }
    widget.onSelected(ssid);
  }

  Widget _buildBody() {
    // First scan: nothing to show yet, so the full-panel spinner is the
    // honest state. A rescan keeps the previous list under a small
    // "Rescanning" affordance instead of blanking it.
    if (_scanning && _networks.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(color: kAccent),
            SizedBox(height: 24),
            Text('Scanning for networks...', style: kBodyStyle),
          ],
        ),
      );
    }

    final List<Widget> children = <Widget>[];
    if (_scanning) {
      children.add(
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: kAccent,
                ),
              ),
              SizedBox(width: 12),
              Text('Rescanning...', style: kSubtitleStyle),
            ],
          ),
        ),
      );
    }
    final String? scanError = _scanError;
    if (scanError != null) {
      children.add(ErrorBanner(message: scanError));
    }
    if (_manual) {
      children.add(
        Dc1TextField(
          controller: _ssidController,
          hintText: 'Network name (SSID)',
          errorText: _ssidError,
          autofocus: true,
          onChanged: (String _) {
            if (_ssidError != null) {
              setState(() {
                _ssidError = null;
              });
            }
          },
          onSubmitted: _choose,
        ),
      );
      children.add(const SizedBox(height: 16));
      children.add(
        PrimaryButton(
          label: 'Use this network',
          onPressed: () => _choose(_ssidController.text),
        ),
      );
      children.add(const SizedBox(height: 12));
      children.add(
        SecondaryButton(
          label: 'Back to the network list',
          onPressed: () => setState(() {
            _manual = false;
            _ssidError = null;
          }),
        ),
      );
      return ListView(children: children);
    }

    if (_networks.isEmpty && scanError == null) {
      children.add(
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text('No networks found.', style: kSubtitleStyle),
        ),
      );
    }
    final String? ssidError = _ssidError;
    if (ssidError != null) {
      children.add(ErrorBanner(message: ssidError));
    }
    for (final WifiNetwork network in _networks) {
      final int? signal = network.signal;
      children.add(
        OptionTile(
          label: network.ssid,
          trailing: signal == null
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SignalBars(signal: signal),
                    const SizedBox(width: 8),
                    Text('$signal%', style: const TextStyle(fontSize: 18)),
                  ],
                ),
          onTap: () => _choose(network.ssid),
        ),
      );
    }
    return ListView(children: children);
  }

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      title: 'Wi-Fi',
      subtitle: 'Choose the network this device should join.',
      body: _buildBody(),
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (!_manual) ...<Widget>[
            SecondaryButton(
              label: _scanning ? 'Rescanning...' : 'Rescan',
              onPressed: _scanning ? null : () => unawaited(_scan()),
            ),
            const SizedBox(height: 12),
            SecondaryButton(
              label: 'Type network name',
              onPressed: () => setState(() {
                _manual = true;
                _ssidError = null;
              }),
            ),
            const SizedBox(height: 12),
          ],
          SecondaryButton(
            label: 'Continue without Wi-Fi',
            onPressed: widget.onSkip,
          ),
        ],
      ),
    );
  }
}

/// Signal strength as four bars, the way every phone shows it: percentages
/// ask the user to guess where "good" starts, bars do not.
class SignalBars extends StatelessWidget {
  const SignalBars({required this.signal, super.key});

  final int signal;

  static const List<double> _heights = <double>[8, 13, 18, 23];

  int get _filledBars {
    if (signal >= 75) {
      return 4;
    }
    if (signal >= 50) {
      return 3;
    }
    if (signal >= 25) {
      return 2;
    }
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 23,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          for (int i = 0; i < _heights.length; i++)
            Container(
              width: 5,
              height: _heights[i],
              decoration: BoxDecoration(
                color: i < _filledBars
                    ? kForeground
                    : kMuted.withValues(alpha: 0.35),
                borderRadius: const BorderRadius.all(Radius.circular(1)),
              ),
            ),
        ],
      ),
    );
  }
}
