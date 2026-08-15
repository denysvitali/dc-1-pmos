import 'package:flutter/material.dart';

import 'panel_frame.dart';
import 'theme.dart';

/// Phase 1 -- "first light": the smallest thing that proves the Flutter GTK
/// embedder got a Wayland surface, an EGL context and a frame on the panel.
/// Deliberately trivial: no backend, no networking, no state. If this does
/// not appear, nothing above it is worth debugging.
class FirstLightApp extends StatelessWidget {
  const FirstLightApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DC-1',
      debugShowCheckedModeBanner: false,
      // The same no-op-on-device frame as the onboarding preview, so the
      // ?firstlight=1 browser view is panel-shaped too.
      builder: (BuildContext context, Widget? child) =>
          PanelFrame(child: child!),
      home: const Scaffold(
        backgroundColor: kBackground,
        body: Center(child: Text('DC-1', style: kFirstLightStyle)),
      ),
    );
  }
}
