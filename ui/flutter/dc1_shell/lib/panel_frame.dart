import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'keyboard.dart';
import 'theme.dart';

/// Letterboxes the web preview into a panel-shaped rectangle.
///
/// The shell is laid out for the DC-1's 2176x1600 touch panel. In a desktop
/// browser the window is whatever the visitor's machine happens to have, so
/// without this the same screens stretch to a 16:9 monitor: list rows and
/// text fields designed for an arm's length end up a metre wide, and nothing
/// about the preview says "this is what the tablet shows". So:
///
///  * a phone -- portrait or landscape, however tall -- always full-bleed,
///    pixel for pixel what the device draws. The window's `shortestSide` is
///    what tells a phone from a desktop: a tall portrait phone exceeds the
///    height cap but is still a phone, and framing it would shrink the panel
///    to a postage stamp;
///  * anything larger: the UI is fitted, aspect-true, into a rectangle no
///    taller than [_maxPanelHeight], centered on a darker surround with a
///    thin bezel, and captioned as a preview.
///
/// On the device this widget is [child], unchanged -- not hidden, absent:
/// `kIsWeb` is a compile-time constant, so the aarch64 build tree-shakes
/// everything below it and the real experience is untouched.
class PanelFrame extends StatelessWidget {
  const PanelFrame({required this.child, super.key});

  final Widget child;

  /// The native panel: 2176x1600.
  static const double _panelAspectRatio = 2176 / 1600;

  /// The largest panel the preview draws. At the panel's own scale the touch
  /// targets are finger-sized; letting the preview grow without a cap would
  /// make them palm-sized on a big monitor and shrink nothing else.
  static const double _maxPanelHeight = 880;

  /// The shortest side below which the window is treated as a phone. This is
  /// the Flutter convention for the compact-vs-medium breakpoint; a phone's
  /// narrow dimension stays under it in both orientations, a desktop window's
  /// does not.
  static const double _phoneShortestSide = 600;

  /// Whether the window is worth framing: not a phone, and bigger than the
  /// cap in some dimension. The phone check must come first -- a tall portrait
  /// phone (CSS height > [_maxPanelHeight]) satisfies the size clauses alone
  /// and would otherwise be framed into an unreadably small panel.
  static bool _frames(Size window) =>
      window.shortestSide >= _phoneShortestSide &&
      (window.height > _maxPanelHeight ||
          window.width > _maxPanelHeight * _panelAspectRatio);

  /// The largest aspect-true panel that fits [avail]. This is the one place
  /// the rectangle is decided; the [SizedBox] that draws it and the
  /// [MediaQuery] the app reads both take it from here, so what the app
  /// believes about its size is what is on screen.
  static Size _panelSize(Size avail) {
    double height = math.min(avail.height, _maxPanelHeight);
    double width = height * _panelAspectRatio;
    if (width > avail.width) {
      width = avail.width;
      height = width / _panelAspectRatio;
    }
    return Size(width, height);
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) {
      return child;
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size window = constraints.biggest;
        if (!_frames(window)) {
          return child;
        }
        return ColoredBox(
          color: const Color(0xFF070A0D),
          child: Column(
            children: <Widget>[
              Expanded(
                // LayoutBuilder rather than reading MediaQuery: this box's
                // constraints are what is left of the window after the
                // Column laid out the caption, which is exactly the space
                // the panel has to fit.
                child: LayoutBuilder(
                  builder: (
                    BuildContext context,
                    BoxConstraints constraints,
                  ) {
                    final Size panel = _panelSize(constraints.biggest);
                    return Center(
                      child: SizedBox.fromSize(
                        size: panel,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: kBackground,
                            borderRadius: const BorderRadius.all(
                              Radius.circular(20),
                            ),
                            border: Border.all(
                              color: kMuted.withValues(alpha: 0.4),
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: const BorderRadius.all(
                              Radius.circular(19),
                            ),
                            // The size the app sees must be the panel it is
                            // drawn into, not the browser window: the touch
                            // keyboard, for one, sizes itself off
                            // MediaQuery and would otherwise grow past the
                            // bezel on a tall window.
                            child: MediaQuery(
                              data: MediaQuery.of(
                                context,
                              ).copyWith(size: panel),
                              child: child,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(_caption(), style: kCaptionStyle),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Names the preview, and advertises the one URL flag a visitor cannot
  /// otherwise guess. Says the opposite when that flag is already set, so
  /// the demo is explained rather than re-offered.
  static String _caption() {
    if (touchKeyboardMode() == TouchKeyboardMode.demo) {
      return 'DC-1 web preview · keyboard demo: only the on-screen '
          'keyboard types';
    }
    return 'DC-1 web preview · add ?keyboard=1 to try the on-screen keyboard';
  }
}
