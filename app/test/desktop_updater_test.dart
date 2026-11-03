import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sim_bridge/desktop_updater.dart';

const _windows = (
  suffix: 'windows-x64-setup.exe',
  method: UpdateMethod.install,
);
const _download = 'https://github.com/rennerdo30/sim-bridge/releases/download';

Map<String, Object?> _release({
  String tag = 'v1.1.0',
  bool draft = false,
  bool prerelease = false,
  String? assetUrl,
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'html_url': 'https://github.com/rennerdo30/sim-bridge/releases/tag/$tag',
  'assets': [
    {
      'name': 'Sim-Bridge-${tag.substring(1)}-windows-x64-setup.exe',
      'browser_download_url':
          assetUrl ??
          '$_download/$tag/Sim-Bridge-${tag.substring(1)}-windows-x64-setup.exe',
    },
    {
      'name': 'SHA256SUMS.txt',
      'browser_download_url': '$_download/$tag/SHA256SUMS.txt',
    },
  ],
};

Future<String> _sha256(List<int> bytes) async => (await Sha256().hash(
  bytes,
)).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('versions compare by MAJOR.MINOR.PATCH, ignoring build numbers', () {
    expect(compareVersions('1.1.0', '1.0.9'), 1);
    expect(compareVersions('1.0.0', '1.0.0+6'), 0);
    expect(compareVersions('1.0.0-beta.1', '1.0.0'), -1);
    expect(compareVersions('2.0.0', '10.0.0'), -1);
  });

  test('each desktop platform updates with its own package', () {
    expect(
      desktopPackage(operatingSystem: 'windows')!.method,
      UpdateMethod.install,
    );
    expect(desktopPackage(operatingSystem: 'linux')!.suffix, 'linux-x64.zip');
    expect(desktopPackage(operatingSystem: 'android'), isNull);
    expect(desktopPackage(operatingSystem: 'ios'), isNull);
  });

  test(
    'offers only a newer stable release from the repository downloads',
    () async {
      Future<DesktopRelease?> check(
        Map<String, Object?> release,
        String current,
      ) {
        final updater = DesktopUpdater(
          currentVersion: current,
          package: _windows,
          client: MockClient(
            (_) async => http.Response(jsonEncode(release), 200),
          ),
        );
        return updater.check();
      }

      final newer = await check(_release(), '1.0.0');
      expect(newer!.version, '1.1.0');
      expect(newer.assetName, 'Sim-Bridge-1.1.0-windows-x64-setup.exe');
      expect(newer.method, UpdateMethod.install);
      expect(await check(_release(tag: 'v1.0.0'), '1.0.0'), isNull);
      expect(await check(_release(prerelease: true), '1.0.0'), isNull);
      expect(await check(_release(draft: true), '1.0.0'), isNull);
      expect(
        await check(
          _release(
            assetUrl:
                'https://example.com/Sim-Bridge-1.1.0-windows-x64-setup.exe',
          ),
          '1.0.0',
        ),
        isNull,
        reason: 'a download outside the repository releases is never offered',
      );
    },
  );

  test('a downloaded package must match SHA256SUMS.txt', () async {
    final package = utf8.encode('synthetic setup bytes');
    final digest = await _sha256(package);
    final folder = await Directory.systemTemp.createTemp('sim-bridge-update-');
    addTearDown(() => folder.delete(recursive: true));

    DesktopUpdater updater(String sums) => DesktopUpdater(
      currentVersion: '1.0.0',
      package: _windows,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return http.Response(jsonEncode(_release()), 200);
        }
        if (request.url.path.endsWith('SHA256SUMS.txt')) {
          return http.Response(sums, 200);
        }
        return http.Response.bytes(package, 200);
      }),
    );

    final good = updater('$digest  Sim-Bridge-1.1.0-windows-x64-setup.exe\n');
    final release = (await good.check())!;
    final file = await good.download(release, folder);
    expect(await file.readAsBytes(), package);

    final tampered = updater(
      '${'0' * 64}  Sim-Bridge-1.1.0-windows-x64-setup.exe\n',
    );
    await expectLater(
      tampered.download(release, folder),
      throwsA(isA<UpdateException>()),
    );
    expect(
      await file.exists(),
      isFalse,
      reason: 'a mismatching file is deleted',
    );

    final missing = updater('$digest  some-other-file.zip\n');
    await expectLater(
      missing.download(release, folder),
      throwsA(isA<UpdateException>()),
    );
  });
}
