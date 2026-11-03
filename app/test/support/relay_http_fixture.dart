import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sim_bridge/api.dart';
import 'authorization_fixture.dart';
import 'package:sim_bridge/device_authorization.dart';

/// Keeps an authenticated mock SSE response open, unlike a finite JSON mock.
class RelayFixtureClient extends http.BaseClient {
  RelayFixtureClient(
    this.rest, {
    this.eventStatus = 200,
    this.eventCode,
    this.requireCertificate = false,
  });
  final String? eventCode;
  final bool requireCertificate;
  final int eventStatus;
  final http.Client rest;
  final _streams = <MultiStreamController<List<int>>>[];
  int connections = 0;
  int get activeConnections => _streams.length;

  /// The `x-simbridge-resume` header of every event-stream request.
  final resumeHeaders = <String?>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/v1/auth/challenge') {
      final body =
          jsonDecode((request as http.Request).body) as Map<String, dynamic>;
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(await fixtureChallenge(body)))),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.url.path == '/v1/bridges/join' &&
        request is http.Request &&
        jsonDecode(request.body)['payloadJson'] is String) {
      final payload =
          jsonDecode(jsonDecode(request.body)['payloadJson'])
              as Map<String, dynamic>;
      final normalized = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..body = jsonEncode(payload);
      final response = await http.Response.fromStream(
        await rest.send(normalized),
      );
      if (response.statusCode != 200 && response.statusCode != 201) {
        return http.StreamedResponse(
          Stream.value(response.bodyBytes),
          response.statusCode,
          headers: response.headers,
        );
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      data['certificate'] = fixtureCertificate(
        DeviceSigningIdentity('', payload['devicePublicKey']),
        deviceId: data['device']['id'],
        bridgeId: payload['bridgeId'],
        authority: false,
      );
      data['bootId'] = 'fixture-boot';
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(data))),
        response.statusCode,
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.url.path != '/v1/events') return rest.send(request);
    connections++;
    resumeHeaders.add(request.headers['x-simbridge-resume']);
    final legacy =
        requireCertificate && request.headers['x-device-certificate'] == null;
    if (eventStatus != 200 || legacy) {
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'error': 'Event stream unavailable',
              'code': legacy ? 'legacy_upgrade_required' : eventCode,
            }),
          ),
        ),
        legacy ? 401 : eventStatus,
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.multi((controller) {
        _streams.add(controller);
        controller.onCancel = () => _streams.remove(controller);
        controller.add(utf8.encode('data: {"type":"ready"}\n\n'));
      }),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }

  void emit(RelayEvent event) {
    final text = event == RelayEvent.heartbeat
        ? ': heartbeat\n\n'
        : 'data: {"type":"${event.name}"}\n\n';
    for (final controller in List.of(_streams)) {
      controller.add(utf8.encode(text));
    }
  }

  /// A hosted relay's planned stream rotation: a reconnect hint, then the end.
  void rotate() {
    for (final controller in List.of(_streams)) {
      controller.add(utf8.encode('data: {"type":"reconnect"}\n\n'));
      controller.close();
    }
  }

  void end() {
    for (final controller in List.of(_streams)) {
      controller.close();
    }
  }

  @override
  void close() {
    end();
    rest.close();
  }
}
