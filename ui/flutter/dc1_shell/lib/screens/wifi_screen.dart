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
      error = 'Scan failed: $failure';
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
    if (_scanning) {
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
          trailing: signal == null ? null : '$signal%',
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
              label: 'Rescan',
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
