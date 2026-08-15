import 'package:flutter/material.dart';

import 'backend.dart';
import 'theme.dart';

/// The build identity of the running shell, resolved once and handed to every
/// screen.
///
/// It is fetched rather than compiled in: the Flutter bundle is built inside
/// a chroot from a copy of `ui/flutter`, so the app itself has no way to know
/// which commit produced the release around it. `scripts/build-ui-payload.sh`
/// records that commit next to the bundle and dc1-backend serves it on
/// `GET /status`, which makes the panel a place you can read a build number
/// off -- a photograph of a device is then enough to say what is on it.
class InstallerVersionScope extends InheritedWidget {
  const InstallerVersionScope({
    required this.version,
    required super.child,
    super.key,
  });

  /// The commit, or null while it is still being fetched, or the empty
  /// string once it is known to be unavailable. The three are deliberately
  /// distinct: "not yet" must not render as "unknown".
  final String? version;

  static String? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<InstallerVersionScope>()
      ?.version;

  @override
  bool updateShouldNotify(InstallerVersionScope oldWidget) =>
      oldWidget.version != version;
}

/// Fetches the version once and provides it to [child].
///
/// Failure is not a state this widget has: [BackendClient.installerVersion]
/// answers with the empty string rather than throwing, because nothing about
/// a caption may block somebody setting up their tablet.
class InstallerVersion extends StatefulWidget {
  const InstallerVersion({
    required this.client,
    required this.child,
    super.key,
  });

  final BackendClient client;
  final Widget child;

  @override
  State<InstallerVersion> createState() => _InstallerVersionState();
}

class _InstallerVersionState extends State<InstallerVersion> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    widget.client.installerVersion().then((String value) {
      if (mounted) {
        setState(() => _version = value);
      }
    });
  }

  @override
  Widget build(BuildContext context) =>
      InstallerVersionScope(version: _version, child: widget.child);
}

/// The footer caption: a short, low-contrast line naming the build.
///
/// Renders nothing at all until the version is known, so the layout does not
/// shift under a finger that is already reaching for a button.
class VersionCaption extends StatelessWidget {
  const VersionCaption({super.key});

  /// Commit hashes are 40 characters and a panel line is not; the first 12
  /// are what a person reads out or types into `git show`, and are what the
  /// release titles already use.
  static String format(String version) {
    if (version.isEmpty) {
      return 'unknown build';
    }
    final String short = version.length > 12
        ? version.substring(0, 12)
        : version;
    // A local build carries a "-dirty" marker that must survive shortening:
    // it is the whole difference between a build you can look up and one you
    // cannot.
    return version.endsWith('-dirty') ? '$short-dirty' : short;
  }

  @override
  Widget build(BuildContext context) {
    final String? version = InstallerVersionScope.maybeOf(context);
    if (version == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        'DC-1 installer ${format(version)}',
        textAlign: TextAlign.center,
        style: kCaptionStyle,
      ),
    );
  }
}
