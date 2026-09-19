import 'dart:convert';
import 'dart:io';

import 'package:app_rs_dart/ffi/api.dart'
    show CreateClientRequest, CreateClientResponse;
import 'package:app_rs_dart/ffi/app.dart' show AppHandle;
import 'package:app_rs_dart/ffi/connect.dart' show encryptConnectResponse;
import 'package:flutter/material.dart';
import 'package:lexeapp/connect.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Stores only consumed request IDs and expirations, never credentials or URLs.
class ConnectReplayStore {
  static Future<void> consume(
    ConnectRequest request, {
    Directory? directory,
  }) async {
    final dir = directory ?? await getApplicationSupportDirectory();
    final file = File('${dir.path}/lexe-connect-requests.json');
    final now = DateTime.now().millisecondsSinceEpoch;
    final records = <String, int>{};
    if (await file.exists()) {
      final existing =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      for (final entry in existing.entries) {
        final expiry = entry.value as int;
        if (expiry > now) records[entry.key] = expiry;
      }
    }
    if (records.containsKey(request.requestId)) {
      throw const FormatException(
        'This request was already handled. Start a new connection from Zaprite.',
      );
    }
    if (records.length >= 1000) {
      throw const FormatException(
        'Too many recent connection requests. Try again later.',
      );
    }
    records[request.requestId] = request.expiresAt.millisecondsSinceEpoch;
    await dir.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(records), flush: true);
    await temporary.rename(file.path);
  }
}

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key, required this.app, required this.request});
  final AppHandle app;
  final ConnectRequest request;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  bool busy = false;
  bool attemptedCreation = false;
  bool rejected = false;
  CreateClientResponse? created;
  Uri? callback;
  String? failure;

  Future<void> submit({required bool approve}) async {
    if (this.busy) return;
    setState(() {
      this.busy = true;
      this.failure = null;
    });
    final request = this.widget.request;
    try {
      if (this.callback == null && this.created == null && !this.rejected) {
        if (this.attemptedCreation) {
          throw const FormatException(
            'Credential creation may have completed. Check Client credentials before starting a new request.',
          );
        }
        if (!DateTime.now().isBefore(request.expiresAt)) {
          throw const FormatException(
            'This request expired. Start again from Zaprite.',
          );
        }
        // Validate the X25519 key, including low-order points, before minting.
        {
          await encryptConnectResponse(
            recipientKey: request.publicKey,
            requestUri: request.rawUri,
            plaintext: '',
          );
        }
        await ConnectReplayStore.consume(request);
        if (approve) {
          this.attemptedCreation = true;
          this.created = await this.widget.app.createClient(
            req: CreateClientRequest(
              label: request.label,
              scopes: request.scopes,
            ),
          );
        } else {
          this.rejected = true;
        }
      }
      if (this.callback == null) {
        final ciphertext = await encryptConnectResponse(
          recipientKey: request.publicKey,
          requestUri: request.rawUri,
          plaintext: jsonEncode({
            'v': 2,
            'outcome': this.rejected ? 'rejected' : 'success',
            'metadata': request.metadata,
            'request_id': request.requestId,
            if (this.rejected) 'error': 'access_denied',
            if (!this.rejected) 'credential': this.created!.credentials,
            if (!this.rejected) 'client_pubkey': this.created!.pubkey,
            if (!this.rejected)
              'scopes': request.scopes
                  .map(
                    (scope) => ConnectRequest.scopeIds.entries
                        .firstWhere((e) => e.value == scope)
                        .key,
                  )
                  .toList(),
          }),
        );
        this.callback = request.callback(ciphertext: ciphertext);
      }
      // Do not fall back to a browser or log the callback URL.
      final opened = await launchUrl(
        this.callback!,
        mode: LaunchMode.externalNonBrowserApplication,
      );
      if (!opened) {
        throw const FormatException(
          'Could not open Zaprite. Check that its development app is installed, then retry.',
        );
      }
      if (this.mounted) Navigator.of(this.context).pop();
    } on FormatException catch (error) {
      if (this.mounted) {
        setState(() {
          this.failure = error.message;
        });
      }
    } catch (_) {
      if (this.mounted) {
        setState(() {
          this.failure = this.created != null
              ? 'Credentials were created. Retry returning to Zaprite, or revoke them from Client credentials.'
              : this.attemptedCreation
              ? 'Could not confirm credential creation. Check Client credentials before starting a new request.'
              : 'Could not prepare this connection. No credentials were created.';
        });
      }
    } finally {
      if (this.mounted) {
        setState(() {
          this.busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = this.widget.request;
    final hasResult =
        this.created != null || this.callback != null || this.rejected;
    return PopScope(
      canPop: !this.busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Connect to Lexe')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              request.redirect.host,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            const Text(
              'Credentials will be returned to this verified app-link destination:',
            ),
            Text('${request.redirect.origin}${request.redirect.path}'),
            Text('Requester-supplied name (unverified): ${request.appName}'),
            const SizedBox(height: 24),
            const Text('Requested access'),
            for (final scope in request.scopes)
              ListTile(
                title: Text(switch (scope.name) {
                  'readInfo' => 'Read wallet identity, balance and channels',
                  'readPayments' => 'Read payment history',
                  'receive' =>
                    'Create invoices, offers and addresses; resync and cancel payments',
                  'spend' =>
                    'Pay invoices, offers and on-chain addresses; update payment notes',
                  _ => 'Unsupported scope',
                }),
              ),
            Text('Credential label: ${request.label}'),
            const SizedBox(height: 12),
            Text(
              request.scopes.any((scope) => scope.name == 'spend')
                  ? 'Unlimited spending: this app can spend from your wallet without further approval in Lexe. There is no amount limit or renewal interval. Access remains active until you revoke it from Client credentials.'
                  : 'Access remains active until you revoke it from Client credentials. This request does not grant spending access.',
            ),
            if (this.failure != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  this.failure!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: this.busy || (this.attemptedCreation && !hasResult)
                  ? null
                  : () => this.submit(approve: !this.rejected),
              child: Text(
                this.busy
                    ? 'Working…'
                    : hasResult
                    ? 'Retry return to Zaprite'
                    : 'Approve',
              ),
            ),
            if (!this.attemptedCreation && !hasResult)
              TextButton(
                onPressed: this.busy ? null : () => this.submit(approve: false),
                child: const Text('Reject'),
              ),
          ],
        ),
      ),
    );
  }
}
