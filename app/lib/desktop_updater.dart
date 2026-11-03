import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

/// Where desktop releases are published. Downloads are accepted only from this
/// repository's own release assets.
const updateRepository = 'rennerdo30/sim-bridge';
const _latestReleaseApi =
    'https://api.github.com/repos/$updateRepository/releases/latest';
const _downloadPrefix =
    'https://github.com/$updateRepository/releases/download/';
const _checksumsAsset = 'SHA256SUMS.txt';
// Served without the API's per-address rate limit; "latest" excludes drafts
// and prereleases.
const _latestChecksums =
    'https://github.com/$updateRepository/releases/latest/download/$_checksumsAsset';

/// Automatic checks run at most this often; "Check now" is always allowed.
const updateCheckInterval = Duration(days: 1);
const _metadataTimeout = Duration(seconds: 20);
const _downloadTimeout = Duration(minutes: 10);
const _maximumDownloadBytes = 300 * 1024 * 1024;

/// How an update reaches this installation.
enum UpdateMethod {
  /// Windows: the verified setup runs silently and restarts Sim Bridge.
  install,

  /// macOS and Linux: the verified package is downloaded for the user to open.
  download,
}

class DesktopRelease {
  const DesktopRelease({
    required this.version,
    required this.pageUrl,
    required this.assetName,
    required this.assetUrl,
    required this.checksumsUrl,
    required this.method,
  });

  final String version;
  final Uri pageUrl;
  final String assetName;
  final Uri assetUrl;
  final Uri checksumsUrl;
  final UpdateMethod method;
}

class UpdateException implements Exception {
  const UpdateException(this.reason);
  final String reason;
  @override
  String toString() => 'UpdateException($reason)';
}

/// The desktop package this installation updates with, or null where Sim Bridge
/// updates through an app store instead.
({String suffix, UpdateMethod method})? desktopPackage({
  String? operatingSystem,
  Abi? abi,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final current = abi ?? Abi.current();
  return switch (os) {
    'windows' => (
      suffix: 'windows-x64-setup.exe',
      method: UpdateMethod.install,
    ),
    'macos' => (
      suffix: current == Abi.macosX64 ? 'macos-x86_64.zip' : 'macos-arm64.zip',
      method: UpdateMethod.download,
    ),
    'linux' => (suffix: 'linux-x64.zip', method: UpdateMethod.download),
    _ => null,
  };
}

/// Compares `MAJOR.MINOR.PATCH` versions; a build suffix (`+6`) is ignored and a
/// prerelease (`-beta.1`) sorts before its release.
int compareVersions(String a, String b) {
  List<Object> parts(String value) {
    final core = value.split('+').first;
    final dash = core.indexOf('-');
    final numbers = (dash < 0 ? core : core.substring(0, dash))
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    while (numbers.length < 3) {
      numbers.add(0);
    }
    return [...numbers.take(3), dash < 0 ? '' : core.substring(dash + 1)];
  }

  final left = parts(a), right = parts(b);
  for (var i = 0; i < 3; i++) {
    final difference = (left[i] as int) - (right[i] as int);
    if (difference != 0) return difference.sign;
  }
  final leftPre = left[3] as String, rightPre = right[3] as String;
  if (leftPre == rightPre) return 0;
  if (leftPre.isEmpty) return 1;
  if (rightPre.isEmpty) return -1;
  return leftPre.compareTo(rightPre).sign;
}

class DesktopUpdater {
  DesktopUpdater({
    required this.currentVersion,
    http.Client? client,
    ({String suffix, UpdateMethod method})? package,
  }) : _client = client ?? http.Client(),
       _package = package ?? desktopPackage();

  final String currentVersion;
  final http.Client _client;
  final ({String suffix, UpdateMethod method})? _package;

  bool get supported => _package != null;

  /// The newest stable release if it is newer than this installation.
  Future<DesktopRelease?> check() async {
    final package = _package;
    if (package == null) return null;
    final response = await _client
        .get(
          Uri.parse(_latestReleaseApi),
          headers: {'accept': 'application/vnd.github+json'},
        )
        .timeout(_metadataTimeout);
    if (response.statusCode == 404) return null; // No release published yet.
    // The API allows few anonymous requests per address (shared networks hit
    // that quickly); the release's own checksum list is enough to find it.
    if (response.statusCode == 403 || response.statusCode == 429) {
      return _checkFromChecksums(package);
    }
    if (response.statusCode != 200) {
      throw UpdateException('metadata_${response.statusCode}');
    }
    final release = jsonDecode(response.body);
    if (release is! Map ||
        release['draft'] == true ||
        release['prerelease'] == true) {
      return null;
    }
    final tag = release['tag_name'];
    if (tag is! String || !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag)) {
      return null;
    }
    final version = tag.substring(1);
    if (compareVersions(version, currentVersion) <= 0) return null;
    final assets = release['assets'];
    if (assets is! List) return null;
    Uri? asset(String name) {
      for (final item in assets) {
        if (item is! Map || item['name'] != name) continue;
        final url = item['browser_download_url'];
        // Only the repository's own release downloads, never another host.
        if (url is String && url.startsWith('$_downloadPrefix$tag/')) {
          return Uri.parse(url);
        }
      }
      return null;
    }

    final assetName = 'Sim-Bridge-$version-${package.suffix}';
    final assetUrl = asset(assetName), checksumsUrl = asset(_checksumsAsset);
    if (assetUrl == null || checksumsUrl == null) return null;
    final page = release['html_url'];
    return DesktopRelease(
      version: version,
      pageUrl: Uri.parse(
        page is String && page.startsWith('https://github.com/')
            ? page
            : 'https://github.com/$updateRepository/releases/tag/$tag',
      ),
      assetName: assetName,
      assetUrl: assetUrl,
      checksumsUrl: checksumsUrl,
      method: package.method,
    );
  }

  Future<DesktopRelease?> _checkFromChecksums(
    ({String suffix, UpdateMethod method}) package,
  ) async {
    final response = await _client
        .get(Uri.parse(_latestChecksums))
        .timeout(_metadataTimeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw UpdateException('checksums_${response.statusCode}');
    }
    final pattern = RegExp(
      '^[0-9a-fA-F]{64}\\s+\\*?(Sim-Bridge-(\\d+\\.\\d+\\.\\d+)-'
      '${RegExp.escape(package.suffix)})\$',
    );
    for (final line in const LineSplitter().convert(response.body)) {
      final match = pattern.firstMatch(line.trim());
      if (match == null) continue;
      final version = match.group(2)!;
      if (compareVersions(version, currentVersion) <= 0) return null;
      final base =
          '$_downloadPrefix'
          'v$version/';
      return DesktopRelease(
        version: version,
        pageUrl: Uri.parse(
          'https://github.com/$updateRepository/releases/tag/v$version',
        ),
        assetName: match.group(1)!,
        assetUrl: Uri.parse('$base${match.group(1)}'),
        checksumsUrl: Uri.parse('$base$_checksumsAsset'),
        method: package.method,
      );
    }
    return null;
  }

  /// Downloads the package into [directory] and verifies it against the
  /// release's SHA256SUMS.txt. A file that does not match is deleted.
  Future<File> download(DesktopRelease release, Directory directory) async {
    final sums = await _client
        .get(release.checksumsUrl)
        .timeout(_metadataTimeout);
    if (sums.statusCode != 200) throw const UpdateException('checksums');
    final expected = _expectedDigest(sums.body, release.assetName);
    if (expected == null) throw const UpdateException('checksum_missing');

    final request = http.Request('GET', release.assetUrl);
    final response = await _client.send(request).timeout(_metadataTimeout);
    if (response.statusCode != 200) throw const UpdateException('download');
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}${release.assetName}',
    );
    final sink = file.openWrite();
    final hasher = Sha256().newHashSink();
    var bytes = 0;
    try {
      await for (final chunk in response.stream.timeout(_downloadTimeout)) {
        bytes += chunk.length;
        if (bytes > _maximumDownloadBytes) {
          throw const UpdateException('too_large');
        }
        hasher.add(chunk);
        sink.add(chunk);
      }
      await sink.close();
      hasher.close();
      final digest = (await hasher.hash()).bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      if (digest != expected) throw const UpdateException('checksum_mismatch');
      return file;
    } catch (_) {
      await sink.close().catchError((_) {});
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  static String? _expectedDigest(String sums, String name) {
    for (final line in const LineSplitter().convert(sums)) {
      final match = RegExp(
        r'^([0-9a-fA-F]{64})\s+\*?(.+)$',
      ).firstMatch(line.trim());
      if (match != null && match.group(2) == name) {
        return match.group(1)!.toLowerCase();
      }
    }
    return null;
  }

  /// Windows: starts the verified setup silently; it waits for Sim Bridge to
  /// close, installs, and starts the new version. The caller then quits.
  static Future<void> startWindowsInstaller(File setup) async {
    await Process.start(setup.path, const [
      '/S',
      '/RELAUNCH',
    ], mode: ProcessStartMode.detached);
  }

  void close() => _client.close();
}
