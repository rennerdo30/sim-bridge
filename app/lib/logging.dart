import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Severity levels, ordered from most to least severe.
enum LogLevel { error, warn, info, debug }

const _logFileName = 'sim-bridge.log';
const _maxLogBytes = 512 * 1024;
const _idPreviewLength = 8;

/// Console + file logging for the app.
///
/// Sim Bridge handles other people's text messages, so the logger is
/// deliberately hostile to sensitive data: message bodies, phone numbers,
/// verification codes, bridge keys, and device tokens must never be passed to
/// it. Use [preview] for identifiers and [redactNumber] when a phone number is
/// genuinely needed to make an entry useful.
class Log {
  static LogLevel level = kReleaseMode ? LogLevel.info : LogLevel.debug;
  static File? _file;
  static Future<void> _pending = Future.value();
  static bool _fileUsable = true;

  /// Entries written before the file is open. Startup is exactly when the
  /// most useful lines are produced, so they are held rather than dropped.
  static final List<String> _buffered = [];
  static const _maxBuffered = 200;

  /// Prepares the log file. Failure is non-fatal — console logging continues.
  static Future<void> initialize({String fileName = _logFileName}) async {
    try {
      final directory = await getApplicationSupportDirectory();
      final file = File('${directory.path}/$fileName');
      if (await file.exists() && await file.length() > _maxLogBytes) {
        await file.delete();
      }
      _file = await file.create(recursive: true);
      if (_buffered.isNotEmpty) {
        final backlog = _buffered.join();
        _buffered.clear();
        await file.writeAsString(backlog, mode: FileMode.append);
      }
    } catch (error) {
      _fileUsable = false;
      _buffered.clear();
      developer.log('Log file unavailable: $error', name: 'sim_bridge');
    }
  }

  /// Truncates an identifier so logs stay correlatable without being a target.
  static String preview(Object? value) {
    final text = value?.toString() ?? '';
    return text.length > _idPreviewLength
        ? '${text.substring(0, _idPreviewLength)}…'
        : text;
  }

  /// Keeps only the last two digits of a phone number.
  static String redactNumber(Object? value) {
    final digits = (value?.toString() ?? '').replaceAll(RegExp(r'\D'), '');
    return digits.length <= 2
        ? '••'
        : '••••${digits.substring(digits.length - 2)}';
  }

  static void error(String message, [Object? cause]) =>
      _write(LogLevel.error, message, cause);
  static void warn(String message, [Object? cause]) =>
      _write(LogLevel.warn, message, cause);
  static void info(String message) => _write(LogLevel.info, message);
  static void debug(String message) => _write(LogLevel.debug, message);

  static void _write(LogLevel entryLevel, String message, [Object? cause]) {
    if (entryLevel.index > level.index) return;
    final line =
        '${DateTime.now().toIso8601String()} '
        '${entryLevel.name.toUpperCase().padRight(5)} $message'
        '${cause == null ? '' : ' | $cause'}';
    developer.log(line, name: 'sim_bridge');
    if (!_fileUsable) return;
    final file = _file;
    if (file == null) {
      // Not open yet: hold the line for the flush in initialize().
      if (_buffered.length < _maxBuffered) _buffered.add('$line\n');
      return;
    }
    _pending = _pending
        .then((_) => file.writeAsString('$line\n', mode: FileMode.append))
        .catchError((Object error) {
          _fileUsable = false;
          developer.log('Log file write failed: $error', name: 'sim_bridge');
          return file;
        });
  }
}
