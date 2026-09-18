import 'dart:io';

import 'package:flutter/foundation.dart';

/// Whether the primary way of pointing at this app is a finger.
///
/// A row wants to behave differently under a finger than under a mouse: a tap
/// is easy to make by accident, there is no hover to explain what a control
/// does, and long-press is the only gesture spare. So the phone opens notes in
/// place on a tap and keeps the full editor behind a double tap, while the
/// desktop keeps the single click it has always had.
///
/// Deliberately the platform rather than the window width, which is what the
/// sidebar breakpoint asks: a narrow desktop window still has a mouse, and a
/// tablet in landscape still has none.
class TouchInput {
  TouchInput._();

  static bool? _override;

  static bool get isPrimary =>
      _override ?? (Platform.isAndroid || Platform.isIOS);

  /// Lets a widget test ask for either behaviour, since the tests run on the
  /// desktop whichever one they are exercising. Pass null to put it back.
  @visibleForTesting
  static set debugOverride(bool? value) => _override = value;
}
