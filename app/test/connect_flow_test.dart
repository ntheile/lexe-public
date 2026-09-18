import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_rs_dart/ffi/api.dart';
import 'package:app_rs_dart/ffi/app.dart';
import 'package:app_rs_dart/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lexeapp/connect.dart';
import 'package:lexeapp/route/connect.dart';

class _App extends App {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Handle extends AppHandle {
  _Handle() : super(inner: _App());
  int creations = 0;

  @override
  Future<CreateClientResponse> createClient({
    required CreateClientRequest req,
  }) async {
    this.creations++;
    return const CreateClientResponse(
      pubkey: 'client-key',
      credentials: 'secret-credential',
    );
  }
}

class _Api implements AppRsApi {
  final List<String> plaintexts = [];

  @override
  Future<String> crateFfiConnectEncryptConnectResponse({
    required String recipientKey,
    required String requestUri,
    required String plaintext,
  }) async {
    this.plaintexts.add(plaintext);
    return 'encrypted-result';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = _Api();
  AppRs.initMock(api: api);
  tearDownAll(AppRs.dispose);
  for (final approve in [true, false]) {
    testWidgets(
      'failed delivery reuses encrypted ${approve ? 'success' : 'rejection'}',
      (tester) async {
        final dir = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('lexe-connect-flow'),
        ))!;
        addTearDown(() => dir.delete(recursive: true));
        api.plaintexts.clear();
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
        const urlChannel = MethodChannel('plugins.flutter.io/url_launcher');
        messenger.setMockMethodCallHandler(pathChannel, (_) async => dir.path);
        final attempts = [Completer<void>(), Completer<void>()];
        final urls = <String>[];
        messenger.setMockMethodCallHandler(urlChannel, (call) async {
          urls.add((call.arguments as Map)['url'] as String);
          attempts[urls.length - 1].complete();
          return false;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(pathChannel, null);
          messenger.setMockMethodCallHandler(urlChannel, null);
        });
        final request = ConnectRequest.parse(
          Uri.https('zaprite.bolt12.rocks', '/lexe/connect', {
            'v': '2',
            'request_id': 'abcdefghijklmnopqrstuv',
            'app_name': 'Zaprite',
            'metadata': base64Url
                .encode(List.generate(32, (i) => i))
                .replaceAll('=', ''),
            'scopes': 'read_info',
            'redirect_uri': 'https://zaprite.bolt12.rocks/lexe/callback',
            'hpke_pubkey': base64Url
                .encode(List.filled(32, 9))
                .replaceAll('=', ''),
            'expires_at':
                '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300}',
          }).toString(),
        );
        final handle = _Handle();
        await tester.pumpWidget(
          MaterialApp(
            home: ConnectPage(app: handle, request: request),
          ),
        );
        for (var i = 0; i < 2; i++) {
          final button = find.text(
            i == 0
                ? (approve ? 'Approve' : 'Reject')
                : 'Retry return to Zaprite',
          );
          await tester.ensureVisible(button);
          await tester.runAsync(() async {
            await tester.tap(button);
            await attempts[i].future.timeout(
              const Duration(seconds: 2),
              onTimeout: () {},
            );
          });
          await tester.pumpAndSettle();
          expect(
            urls.length,
            i + 1,
            reason:
                "created=${handle.creations}, encrypted=${api.plaintexts.length}, UI=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}",
          );
        }
        expect(handle.creations, approve ? 1 : 0);
        expect(api.plaintexts.length, 2); // Key validation, then one response.
        expect(urls[0], urls[1]);
        expect(urls[0], isNot(contains('secret-credential')));
        expect(urls[0], isNot(contains(request.metadata)));
        final payload = jsonDecode(api.plaintexts.last) as Map<String, dynamic>;
        expect(payload['metadata'], request.metadata);
        expect(payload['outcome'], approve ? 'success' : 'rejected');
        if (!approve) {
          expect(payload['credential'], isNull);
          expect(payload['error'], 'access_denied');
        }
        expect(
          Uri.splitQueryString(
            Uri.parse(urls[0]).fragment,
          )['credential_ciphertext'],
          'encrypted-result',
        );
      },
    );
  }
}
