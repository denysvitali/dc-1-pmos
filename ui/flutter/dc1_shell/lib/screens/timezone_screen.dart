import 'package:flutter/material.dart';

import '../validation.dart';
import '../widgets.dart';

/// Screen 6 -- the timezone. The seven offered zones and their order are the
/// ones installer/src/tui.sh offers; "Type another" is the same escape hatch
/// as its `= Type another` menu entry.
class TimezoneScreen extends StatefulWidget {
  const TimezoneScreen({
    required this.initial,
    required this.onNext,
    required this.onBack,
    super.key,
  });

  final String initial;
  final ValueChanged<String> onNext;
  final VoidCallback onBack;

  @override
  State<TimezoneScreen> createState() => _TimezoneScreenState();
}

class _TimezoneScreenState extends State<TimezoneScreen> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  late final String _selected = widget.initial;
  bool _manual = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _choose(String value) {
    final String? error = validateTimezone(value);
    if (error != null) {
      setState(() {
        _error = error;
      });
      return;
    }
    // No setState for the accepted value: the flow replaces this screen.
    widget.onNext(value);
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> children = <Widget>[];
    final String? error = _error;
    if (error != null) {
      children.add(ErrorBanner(message: error));
    }
    if (_manual) {
      children.add(
        Dc1TextField(
          controller: _controller,
          hintText: 'Area/City, e.g. Europe/Rome',
          autofocus: true,
          onChanged: (String _) {
            if (_error != null) {
              setState(() {
                _error = null;
              });
            }
          },
          onSubmitted: (String value) => _choose(value.trim()),
        ),
      );
      children.add(const SizedBox(height: 16));
      children.add(
        PrimaryButton(
          label: 'Use this timezone',
          onPressed: () => _choose(_controller.text.trim()),
        ),
      );
      children.add(const SizedBox(height: 12));
      children.add(
        SecondaryButton(
          label: 'Back to the list',
          onPressed: () => setState(() {
            _manual = false;
            _error = null;
          }),
        ),
      );
    } else {
      for (final String zone in offeredTimezones) {
        children.add(
          OptionTile(
            label: zone,
            selected: zone == _selected,
            onTap: () => _choose(zone),
          ),
        );
      }
      children.add(
        SecondaryButton(
          label: 'Type another',
          onPressed: () => setState(() {
            _manual = true;
            _error = null;
          }),
        ),
      );
    }

    return StepScaffold(
      title: 'Timezone',
      subtitle: 'Used for the clock and for log timestamps.',
      body: ListView(children: children),
      footer: SecondaryButton(label: 'Back', onPressed: widget.onBack),
    );
  }
}
