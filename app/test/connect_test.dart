import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lexeapp/connect.dart';
import 'package:lexeapp/route/connect.dart' show ConnectReplayStore;

void main() {
  final now = DateTime.utc(2026, 9, 18);
  String request([Map<String, String> overrides = const {}]) => Uri(
    scheme: 'https',
    host: 'zaprite.bolt12.rocks',
    path: '/lexe/connect',
    queryParameters: {
      'v': '2',
      'request_id': 'abcdefghijklmnopqrstuv',
      'app_name': 'Zaprite',
      'metadata': base64Url
          .encode(List.generate(32, (i) => i))
          .replaceAll('=', ''),
      'scopes': 'read_info,read_payments,receive',
      'redirect_uri':
          'https://zaprite.bolt12.rocks/lexe/callback?existing=one&existing=two',
      'hpke_pubkey': base64Url.encode(List.filled(32, 9)).replaceAll('=', ''),
      'expires_at': '${now.millisecondsSinceEpoch ~/ 1000 + 300}',
      ...overrides,
    },
  ).toString();

  test(
    'consumed requests survive reload and store no credential context',
    () async {
      final dir = await Directory.systemTemp.createTemp('lexe-connect-test');
      addTearDown(() => dir.delete(recursive: true));
      final current = DateTime.now();
      final parsed = ConnectRequest.parse(
        request({
          'expires_at': '${current.millisecondsSinceEpoch ~/ 1000 + 300}',
        }),
        now: current,
      );
      await ConnectReplayStore.consume(parsed, directory: dir);
      await expectLater(
        ConnectReplayStore.consume(parsed, directory: dir),
        throwsFormatException,
      );
      final saved = jsonDecode(
        await File('${dir.path}/lexe-connect-requests.json').readAsString(),
      );
      expect(saved, {
        parsed.requestId: parsed.expiresAt.millisecondsSinceEpoch,
      });
    },
  );

  test('preserves exact request for AAD and existing callback parameters', () {
    final raw = request();
    final parsed = ConnectRequest.parse(raw, now: now);
    expect(parsed.rawUri, raw);
    final callback = parsed.callback(ciphertext: 'encrypted');
    expect(callback.queryParametersAll['existing'], ['one', 'two']);
    expect(
      Uri.splitQueryString(callback.fragment)['credential_ciphertext'],
      'encrypted',
    );
    expect(callback.queryParameters['credential'], isNull);
    expect(callback.queryParameters['metadata'], isNull);
    expect(Uri.splitQueryString(callback.fragment)['metadata'], isNull);
    expect(callback.toString(), isNot(contains(parsed.metadata)));
  });

  for (final bad in <Map<String, String>>[
    {'v': '1'},
    {'scopes': 'spend'},
    {'scopes': 'full'},
    {'scopes': 'receive,receive'},
    {'scopes': ''},
    {'budget': '100'},
    {'permissions': 'pay_invoice'},
    {'post_url': 'https://example.com'},
    {'request_id': 'short'},
    {'expires_at': '0'},
    {'expires_at': '${now.millisecondsSinceEpoch ~/ 1000 + 601}'},
    {'hpke_pubkey': 'bad'},
    {'app_name': 'spoof\u202ename'},
    {'label': 'a' * 65},
    {'metadata': ''},
    {'metadata': 'short'},
    {'metadata': 'a' * 43},
    {'metadata': 'a' * 1025},
    {'redirect_uri': 'https://evil.example/lexe/callback'},
    {'redirect_uri': 'https://zaprite.bolt12.rocks/lexe/connect'},
    {
      'redirect_uri':
          'https://zaprite.bolt12.rocks/lexe/callback?credential=secret',
    },
    {'redirect_uri': 'https://zaprite.bolt12.rocks:444/lexe/callback'},
  ]) {
    test(
      'rejects invalid ${bad.keys.single}: ${bad.values.single.substring(0, bad.values.single.length.clamp(0, 30))}',
      () {
        expect(
          () => ConnectRequest.parse(request(bad), now: now),
          throwsFormatException,
        );
      },
    );
  }

  test('shared encrypted success and rejection callback fixtures', () {
    final fixture =
        jsonDecode(
              File('test/fixtures/lexe-connect-v2.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final parsed = ConnectRequest.parse(
      fixture['request_uri'] as String,
      now: DateTime.fromMillisecondsSinceEpoch(
        (fixture['parse_time_unix_seconds'] as int) * 1000,
        isUtc: true,
      ),
    );
    for (final raw in fixture['responses'] as List) {
      final response = raw as Map<String, dynamic>;
      expect(
        parsed
            .callback(ciphertext: response['credential_ciphertext'] as String)
            .toString(),
        response['callback_uri'],
      );
      final payload =
          jsonDecode(response['plaintext'] as String) as Map<String, dynamic>;
      expect(payload['metadata'], parsed.metadata);
      expect(payload['request_id'], parsed.requestId);
      if (payload['outcome'] == 'rejected') {
        expect(payload['credential'], isNull);
      }
    }
  });

  test('missing confidential state and legacy v1 requests are rejected', () {
    final uri = Uri.parse(request());
    final params = Map<String, String>.of(uri.queryParameters)
      ..remove('metadata');
    expect(
      () => ConnectRequest.parse(
        uri.replace(queryParameters: params).toString(),
        now: now,
      ),
      throwsFormatException,
    );
  });

  test('rejects duplicate fields and insecure transport', () {
    expect(
      () => ConnectRequest.parse('${request()}&v=1', now: now),
      throwsFormatException,
    );
    expect(
      () => ConnectRequest.parse(
        request().replaceFirst('https:', 'http:'),
        now: now,
      ),
      throwsFormatException,
    );
  });
}
