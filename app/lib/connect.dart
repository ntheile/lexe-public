import 'dart:convert';

import 'package:app_rs_dart/ffi/types.dart' show Scope;

/// The deliberately narrow, versioned Connect PoC contract.
class ConnectRequest {
  ConnectRequest._(
    this.rawUri,
    this.requestId,
    this.appName,
    this.label,
    this.scopes,
    this.redirect,
    this.publicKey,
    this.expiresAt,
    this.metadata,
  );

  final String rawUri;
  final String requestId;
  final String appName;
  final String label;
  final List<Scope> scopes;
  final Uri redirect;
  final String publicKey;
  final DateTime expiresAt;
  final String metadata;

  static const scopeIds = {
    'read_info': Scope.readInfo,
    'read_payments': Scope.readPayments,
    'receive': Scope.receive,
  };

  static bool isConnectUri(String raw) {
    final uri = Uri.tryParse(raw);
    return uri?.host == 'zaprite.bolt12.rocks' && uri?.path == '/lexe/connect';
  }

  factory ConnectRequest.parse(String raw, {DateTime? now}) {
    void require(bool condition, String message) {
      if (!condition) throw FormatException(message);
    }

    require(raw.length <= 8192, 'Connection request is too large.');
    final uri = Uri.parse(raw);
    require(
      isConnectUri(raw) &&
          uri.scheme == 'https' &&
          uri.userInfo.isEmpty &&
          !uri.hasPort &&
          !uri.hasFragment,
      'Invalid Lexe Connect URL.',
    );
    final params = uri.queryParametersAll;
    const allowed = {
      'v',
      'request_id',
      'app_name',
      'label',
      'scopes',
      'redirect_uri',
      'hpke_pubkey',
      'expires_at',
      'metadata',
    };
    require(
      params.keys.every(allowed.contains),
      'Unsupported parameter. Budgets, permissions and POST callbacks are not supported yet.',
    );
    require(
      params.values.every((values) => values.length == 1),
      'Duplicate request parameters.',
    );
    String field(String name) {
      final value = uri.queryParameters[name];
      require(value != null && value.isNotEmpty, 'Missing $name.');
      return value!;
    }

    require(field('v') == '2', 'Unsupported Connect version.');
    final id = field('request_id');
    require(
      RegExp(r'^[A-Za-z0-9_-]{22,128}$').hasMatch(id),
      'Invalid request ID.',
    );
    final name = uri.queryParameters['app_name'] ?? 'zaprite.bolt12.rocks';
    final label = uri.queryParameters['label'] ?? name;
    for (final text in [name, label]) {
      require(
        utf8.encode(text).length <= 64 &&
            text.trim().isNotEmpty &&
            !RegExp(
              r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]',
            ).hasMatch(text),
        'App name and label must be short, plain text.',
      );
    }
    final ids = field('scopes').split(',');
    require(
      ids.toSet().length == ids.length && ids.every(scopeIds.containsKey),
      'Only read_info, read_payments and receive are supported.',
    );
    final redirect = Uri.parse(field('redirect_uri'));
    require(
      redirect.scheme == 'https' &&
          redirect.host == 'zaprite.bolt12.rocks' &&
          redirect.path == '/lexe/callback' &&
          redirect.userInfo.isEmpty &&
          !redirect.hasPort &&
          !redirect.hasFragment,
      'Callback must be https://zaprite.bolt12.rocks/lexe/callback.',
    );
    require(
      !redirect.queryParameters.keys.any(
        {
          'credential',
          'credential_ciphertext',
          'request_id',
          'error',
          'metadata',
        }.contains,
      ),
      'Callback contains reserved response parameters.',
    );
    final key = field('hpke_pubkey');
    require(
      RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(key),
      'Invalid encryption key.',
    );
    final keyBytes = base64Url.decode(base64Url.normalize(key));
    require(
      keyBytes.length == 32 &&
          base64Url.encode(keyBytes).replaceAll('=', '') == key,
      'Invalid encryption key.',
    );
    final seconds = int.tryParse(field('expires_at'));
    final current = now ?? DateTime.now().toUtc();
    require(
      seconds != null &&
          seconds > current.millisecondsSinceEpoch ~/ 1000 &&
          seconds <= current.millisecondsSinceEpoch ~/ 1000 + 600,
      'Request must expire within the next 10 minutes.',
    );
    // State is independent of the public request ID. The requester must
    // generate these 32 bytes with a CSPRNG; syntax cannot prove entropy.
    final metadata = field('metadata');
    require(
      RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(metadata),
      'State must be 32 random bytes encoded as unpadded base64url.',
    );
    final stateBytes = base64Url.decode(base64Url.normalize(metadata));
    require(
      stateBytes.length == 32 &&
          base64Url.encode(stateBytes).replaceAll('=', '') == metadata &&
          metadata != id,
      'Invalid confidential state.',
    );
    return ConnectRequest._(
      raw,
      id,
      name,
      label,
      ids.map((id) => scopeIds[id]!).toList(),
      redirect,
      key,
      DateTime.fromMillisecondsSinceEpoch(seconds! * 1000, isUtc: true),
      metadata,
    );
  }

  /// Only public routing information and ciphertext leave the encrypted
  /// envelope. Preserve the callback query byte-for-byte.
  Uri callback({required String ciphertext}) {
    return this.redirect.replace(
      fragment: Uri(
        queryParameters: {
          'v': '2',
          'request_id': this.requestId,
          'credential_ciphertext': ciphertext,
        },
      ).query,
    );
  }
}
