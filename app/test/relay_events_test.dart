import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sim_bridge/api.dart';

const session = Session(
  server: 'http://127.0.0.1:18798',
  token: 'synthetic-secret',
  deviceId: 'client',
  bridgeId: 'bridge',
  key: [],
);

void main() {
  test(
    'authenticated SSE handles fragmented UTF8, CRLF and comment liveness',
    () async {
      final body = StreamController<List<int>>();
      final received = <RelayEvent>[];
      final done = Completer<void>();
      final connection = BridgeApi(session.server).events(
        session,
        clientFactory: () => MockClient.streaming((request, _) async {
          expect(request.url.path, '/v1/events');
          expect(request.url.query, isEmpty);
          expect(request.headers['authorization'], 'Bearer synthetic-secret');
          expect(request.followRedirects, false);
          return http.StreamedResponse(
            body.stream,
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          );
        }),
      );
      final subscription = connection.stream.listen((event) {
        received.add(event);
        if (received.length == 4) done.complete();
      });
      final bytes = utf8.encode(
        'data: {"type":"ready"}\r\n\r\n'
        ': heartbeat\n\ndata: {"type":"messages","note":"旅"}\n\n'
        'data: {"type":\ndata: "devices"}\n\n',
      );
      for (final byte in bytes) {
        body.add([byte]);
      }
      await done.future.timeout(const Duration(seconds: 2));
      expect(received, [
        RelayEvent.ready,
        RelayEvent.heartbeat,
        RelayEvent.messages,
        RelayEvent.devices,
      ]);
      await subscription.cancel();
      await connection.close();
      await body.close();
    },
  );

  test(
    'reconnect delivers ready for catch-up; idle stream performs no extra requests',
    () async {
      var requests = 0;
      final bodies = <StreamController<List<int>>>[];
      final readyTwice = Completer<void>();
      var ready = 0;
      final connection = BridgeApi(session.server).events(
        session,
        retryBase: const Duration(milliseconds: 5),
        retryMaximum: const Duration(milliseconds: 20),
        clientFactory: () => MockClient.streaming((_, _) async {
          requests++;
          final body = StreamController<List<int>>();
          bodies.add(body);
          body.add(utf8.encode('data: {"type":"ready"}\n\n'));
          return http.StreamedResponse(
            body.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final firstReady = Completer<void>();
      final subscription = connection.stream.listen((event) {
        if (event == RelayEvent.ready && ++ready == 1) firstReady.complete();
        if (event == RelayEvent.ready && ready == 2) readyTwice.complete();
      }, onError: (Object _) {});
      await firstReady.future.timeout(const Duration(seconds: 2));
      await bodies.first.close();
      await readyTwice.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(requests, 2);
      await subscription.cancel();
      await connection.close();
      for (final body in bodies) {
        await body.close();
      }
    },
  );

  test(
    '401 terminates reconnect and retains enrollment for explicit re-pairing',
    () async {
      var requests = 0;
      final done = Completer<void>();
      final failures = <Object>[];
      final connection = BridgeApi(session.server).events(
        session,
        retryBase: const Duration(milliseconds: 5),
        clientFactory: () => MockClient.streaming((_, _) async {
          requests++;
          return http.StreamedResponse(const Stream.empty(), 401);
        }),
      );
      connection.stream.listen(
        (_) {},
        onError: failures.add,
        onDone: done.complete,
      );
      await done.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(requests, 1);
      expect((failures.single as RelayRequestException).status, 401);
      await connection.close();
    },
  );

  test(
    'oversized unfinished SSE line is rejected and cancellation stops retries',
    () async {
      final body = StreamController<List<int>>();
      final rejected = Completer<void>();
      var requests = 0;
      final connection = BridgeApi(session.server).events(
        session,
        retryBase: const Duration(milliseconds: 50),
        clientFactory: () => MockClient.streaming((_, _) async {
          requests++;
          return http.StreamedResponse(
            body.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final subscription = connection.stream.listen(
        (_) {},
        onError: (Object error) {
          expect(error, isA<FormatException>());
          rejected.complete();
        },
      );
      body.add(List.filled(2049, 97));
      await rejected.future.timeout(const Duration(seconds: 2));
      await subscription.cancel();
      await connection.close();
      await body.close();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(requests, 1);
    },
  );

  test(
    'a planned stream rotation resumes at once, marked, without an error',
    () async {
      final bodies = <StreamController<List<int>>>[];
      final resumeHeaders = <String?>[];
      final errors = <Object>[], received = <RelayEvent>[];
      final resumed = Completer<void>();
      final connection = BridgeApi(session.server).events(
        session,
        // A failure path would wait an hour; only a planned rotation is immediate.
        retryBase: const Duration(hours: 1),
        retryMaximum: const Duration(hours: 1),
        clientFactory: () => MockClient.streaming((request, _) async {
          resumeHeaders.add(request.headers['x-simbridge-resume']);
          final body = StreamController<List<int>>();
          bodies.add(body);
          body.add(utf8.encode('data: {"type":"ready"}\n\n'));
          return http.StreamedResponse(
            body.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final subscription = connection.stream.listen((event) {
        received.add(event);
        if (event == RelayEvent.resumed) resumed.complete();
      }, onError: errors.add);
      while (!received.contains(RelayEvent.ready)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      bodies.first.add(utf8.encode('data: {"type":"reconnect"}\n\n'));
      unawaited(bodies.first.close());
      await resumed.future.timeout(const Duration(seconds: 2));
      expect(resumeHeaders, [null, 'rotation']);
      // The first connection is a full ready; the planned reconnect resumes.
      expect(received.where((e) => e != RelayEvent.heartbeat), [
        RelayEvent.ready,
        RelayEvent.resumed,
      ]);
      expect(errors, isEmpty);
      await subscription.cancel();
      await connection.close();
      for (final body in bodies) {
        unawaited(body.close());
      }
    },
  );
}
