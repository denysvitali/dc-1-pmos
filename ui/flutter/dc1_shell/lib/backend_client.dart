/// Compile-time transport selection.
///
/// The DC-1 shell runs against a real backend over a Unix socket on the
/// device, and against an in-browser mock on the web (GitHub Pages), where
/// `dart:io` does not exist. A conditional export is the standard Flutter
/// way to keep one source tree that compiles for both.
///
/// `backend.dart` is the shared platform-neutral surface (types + parsing);
/// this file re-exports the transport chosen for the current build target.
export 'backend_io.dart' if (dart.library.js_interop) 'backend_web.dart';
