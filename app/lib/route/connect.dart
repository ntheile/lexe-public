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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hasResult =
        this.created != null || this.callback != null || this.rejected;
    final spends = request.scopes.any((scope) => scope.name == 'spend');
    // Branding is bundled for our fixed, allowlisted callback destination.
    // Never use the requester-controlled app_name as verified app identity.
    return PopScope(
      canPop: !this.busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Connect App'),
          centerTitle: true,
          actions: [
            IconButton(
              tooltip: 'Close',
              onPressed: this.busy
                  ? null
                  : () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _ConnectAppIdentity(asset: 'lexe', label: 'Lexe'),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 38),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Divider(color: colors.outlineVariant),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  child: Icon(
                                    Icons.link,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                                Expanded(
                                  child: Divider(color: colors.outlineVariant),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const _ConnectAppIdentity(
                          asset: 'zaprite',
                          label: 'Zaprite P2P',
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    Text.rich(
                      const TextSpan(
                        children: [
                          TextSpan(
                            text: 'Zaprite P2P',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          TextSpan(text: ' is requesting access to your '),
                          TextSpan(
                            text: 'Lexe wallet.',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      request.redirect.host,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 32),
                    Card(
                      margin: EdgeInsets.zero,
                      elevation: 0,
                      color: colors.surfaceContainerHighest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Requested permissions',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 12),
                            for (final scope in request.scopes)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.check_circle_outline,
                                      size: 20,
                                      color: colors.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(switch (scope.name) {
                                        'readInfo' =>
                                          'Read wallet identity, balance and channels',
                                        'readPayments' =>
                                          'Read payment history',
                                        'receive' =>
                                          'Create invoices, offers and addresses; resync and cancel payments',
                                        'spend' =>
                                          'Pay invoices, offers and on-chain addresses; update payment notes',
                                        _ => 'Unsupported scope',
                                      }),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'You can revoke access at any time in Lexe’s Client credentials settings.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ExpansionTile(
                      title: const Text('Connection details'),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 16),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Credential label: ${request.label}'),
                        Text(
                          'Requester-supplied name (unverified): ${request.appName}',
                        ),
                        Text(
                          'Return destination: ${request.redirect.origin}${request.redirect.path}',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (this.failure != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          this.failure!,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    Text(
                      spends
                          ? 'Unlimited spending: Zaprite P2P can spend from your wallet without further approval in Lexe.'
                          : 'This connection does not grant spending access.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed:
                          this.busy || (this.attemptedCreation && !hasResult)
                          ? null
                          : () => this.submit(approve: !this.rejected),
                      child: Text(
                        this.busy
                            ? 'Working…'
                            : hasResult
                            ? 'Retry return to Zaprite'
                            : 'Confirm Connection',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (!this.attemptedCreation && !hasResult)
                      TextButton(
                        onPressed: this.busy
                            ? null
                            : () => this.submit(approve: false),
                        child: const Text('Reject'),
                      ),
                    Text(
                      'You’ll return to Zaprite P2P after confirming.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectAppIdentity extends StatelessWidget {
  const _ConnectAppIdentity({required this.asset, required this.label});
  final String asset;
  final String label;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 112,
    child: Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Container(
            width: 88,
            height: 88,
            color: const Color(0xffeff3f5),
            child: Image.asset(
              'assets/connect/$asset.png',
              excludeFromSemantics: true,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    ),
  );
}
