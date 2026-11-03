import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// How long a sensitive value (recovery code, verifier, OTP) may stay on the
/// clipboard before Sim Bridge clears it again.
const sensitiveClipboardLifetime = Duration(seconds: 180);

const _clipboardChannel = MethodChannel('app.simbridge/clipboard');
Timer? _clearTimer;

/// Copies [text] with the strongest protection each platform offers.
///
/// Android marks the clip sensitive and clears it later, iOS keeps it off
/// Universal Clipboard with an expiry, and macOS uses transient/concealed
/// markers. Windows and Linux have no such markers, so the value is cleared
/// after [sensitiveClipboardLifetime] if it is still on the clipboard.
Future<void> copySensitiveText(String text) async {
  if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    try {
      await _clipboardChannel.invokeMethod('copySensitive', {'text': text});
      return;
    } on MissingPluginException {
      // Flutter test hosts and older native runners may lack the channel.
    }
  }
  await Clipboard.setData(ClipboardData(text: text));
  _clearTimer?.cancel();
  _clearTimer = Timer(sensitiveClipboardLifetime, () => clearIfStill(text));
}

/// Clears the clipboard only while it still holds [text], so a value the user
/// copied afterwards is never discarded.
Future<void> clearIfStill(String text) async {
  try {
    final current = await Clipboard.getData(Clipboard.kTextPlain);
    if (current?.text == text) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  } on PlatformException {
    // A clipboard owned by another process may refuse access; nothing to do.
  }
}
