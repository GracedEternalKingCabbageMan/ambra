// Unit test for the hosted-SeqLN LSP HTTP client. Pure HTTP (no native lib), so
// it runs standalone with a mocked http.Client and pins the contract the wallet
// shares with the web client's seqln.js:
//
//   GET  /status        -> node id + per-asset channels
//   POST /swap {side,asset,amount:<number>} -> final settle
//
//   cd app && flutter test test/lsp_client_test.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ambra/src/data/config.dart';
import 'package:ambra/src/data/lsp_client.dart';

void main() {
  setUp(() {
    Backend.origin = 'http://lsp.test';
    Backend.authHeader = null;
    Backend.lnToken = '';
  });

  tearDown(() {
    Backend.origin = Backend.defaultOrigin;
    LspClient.client = http.Client();
  });

  test('getStatus targets /lsp/status and parses node id + per-asset channels', () async {
    LspClient.client = MockClient((req) async {
      expect(req.method, 'GET');
      expect(req.url.toString(), 'http://lsp.test/lsp/status');
      return http.Response(
        jsonEncode({
          'ok': true,
          'node_id': '02aabbccddeeff00112233',
          'channels': [
            {'asset': 'GOLD', 'spendable': '1000', 'receivable': '500'},
            {'asset': 'USDX', 'spendable': '7', 'receivable': '0'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final st = await LspClient.getStatus();
    expect(st.nodeId, '02aabbccddeeff00112233');
    expect(st.assets, ['GOLD', 'USDX']);
    expect(st.channels.first.spendable, BigInt.from(1000));
    expect(st.channels.first.receivable, BigInt.from(500));
  });

  test('swap posts {side,asset,amount} (amount as a JSON number) and parses the final settle', () async {
    late Map<String, dynamic> sent;
    LspClient.client = MockClient((req) async {
      expect(req.method, 'POST');
      expect(req.url.toString(), 'http://lsp.test/lsp/swap');
      sent = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'ok': true,
          'preimage': 'deadbeef' * 8,
          'direction': 'bought',
          'asset': 'GOLD',
          'base_amount': '1.23',
          'quote_asset': 'BTC',
          'quote_amount': '0.5',
          'finality': 'final',
          'settled_ms': 420,
        }),
        200,
      );
    });

    final r = await LspClient.swap(side: 'buy', asset: 'GOLD', amount: 0.5);
    // Contract identical to seqln.js: side/asset strings + amount as a number.
    expect(sent['side'], 'buy');
    expect(sent['asset'], 'GOLD');
    expect(sent['amount'], 0.5);
    expect(sent['amount'], isA<num>());

    expect(r.preimage.length, 64);
    expect(r.isFinal, true);
    expect(r.direction, 'bought');
    expect(r.baseAmount, '1.23');
    expect(r.quoteAmount, '0.5');
    expect(r.settledMs, 420);
  });

  test('an LSP bearer token is sent when configured', () async {
    Backend.lnToken = 'sekret';
    LspClient.client = MockClient((req) async {
      expect(req.headers['authorization'], 'Bearer sekret');
      return http.Response(jsonEncode({'ok': true, 'channels': []}), 200);
    });
    await LspClient.getStatus();
  });

  test('a 200 with ok:false is treated as a failure', () async {
    LspClient.client = MockClient((req) async => http.Response(jsonEncode({'ok': false, 'error': 'no route'}), 200));
    await expectLater(
      LspClient.swap(side: 'sell', asset: 'GOLD', amount: 1),
      throwsA(predicate((e) => e.toString().contains('no route'))),
    );
  });

  test('a non-2xx status throws the server error', () async {
    LspClient.client = MockClient((req) async => http.Response(jsonEncode({'error': 'boom'}), 500));
    await expectLater(LspClient.getStatus(), throwsA(isA<Exception>()));
  });

  test('getStatus(nodes:) threads the device keys via ?nodes= (reload-survival readback)', () async {
    late Uri got;
    LspClient.client = MockClient((req) async {
      got = req.url;
      return http.Response(
          jsonEncode({
            'ok': true,
            'provisioned_nodes': [
              {'key': 'seq:aa:02bb'}
            ],
            'channels': [
              {'asset': 'aa', 'node_key': 'seq:aa:02bb', 'spendable': '4242', 'receivable': '0'},
            ],
          }),
          200);
    });
    final st = await LspClient.getStatus(nodes: ['seq:aa:02bb', 'btc:02cc']);
    expect(got.path, '/lsp/status');
    expect(got.queryParameters['nodes'], 'seq:aa:02bb,btc:02cc');
    expect(st.channels.single.asset, 'aa');
  });

  test('Move-to-Lightning lifecycle: provision -> deposit -> open(poll) -> close', () async {
    var openPolls = 0;
    final seen = <String, Map<String, dynamic>>{}; // path -> last posted body
    LspClient.client = MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'POST') seen[path] = jsonDecode(req.body) as Map<String, dynamic>;
      switch (path) {
        case '/lsp/node/provision':
          return http.Response(
              jsonEncode({
                'ok': true,
                'key': 'seq:aa:02bb',
                'asset_id': 'aa',
                'label': 'GOLD',
                'status': 'booting',
                'host_pubkey': 'ee' * 33,
                'public_ws_path': '/lsp-ws-node/GOLD-0',
                'ws_port': 18800,
                'network': 'sequentia-testnet',
              }),
              200);
        case '/lsp/channel/deposit':
          return http.Response(jsonEncode({'ok': true, 'address': 'tb1qdeposit'}), 200);
        case '/lsp/channel/open':
          return http.Response(
              jsonEncode({'ok': true, 'job_id': 'J1', 'poll': '/channel/open/J1', 'status': 'pending_deposit'}), 202);
        case '/lsp/channel/open/J1':
          openPolls++;
          return http.Response(
              jsonEncode(openPolls >= 2
                  ? {'ok': true, 'status': 'active', 'short_channel_id': '111x2x0', 'spendable_msat': '4242000'}
                  : {'ok': true, 'status': 'opening'}),
              200);
        case '/lsp/channel/close':
          return http.Response(
              jsonEncode({'ok': true, 'closing_txid': 'fc' * 32, 'type': 'mutual', 'scid': '111x2x0'}), 200);
        default:
          return http.Response(jsonEncode({'ok': false, 'error': 'unexpected $path'}), 404);
      }
    });

    // 1. provision the device's OWN node
    final node = await LspClient.provisionNode(deviceTransportPubkey: '02bb', asset: 'aa', label: 'GOLD');
    expect(node.key, 'seq:aa:02bb');
    expect(node.publicWsPath, '/lsp-ws-node/GOLD-0');
    expect(seen['/lsp/node/provision']!['device_transport_pubkey'], '02bb');
    expect(seen['/lsp/node/provision']!['asset'], 'aa');

    // 2. deposit address (threads the node key so it's the user's own node)
    final addr = await LspClient.channelDeposit(chain: 'seq', asset: 'aa', node: node.key);
    expect(addr, 'tb1qdeposit');

    // 3. open + poll to active (fundchannel targets the user's own node via `node`)
    final started = await LspClient.channelOpen(chain: 'seq', amount: 5, asset: 'aa', node: node.key);
    expect(seen['/lsp/channel/open']!['node'], 'seq:aa:02bb');
    expect(started.status, 'pending_deposit');
    var job = await LspClient.channelOpenPoll(started.poll!);
    expect(job.isActive, isFalse); // 'opening'
    job = await LspClient.channelOpenPoll(started.poll!);
    expect(job.isActive, isTrue);
    expect(job.shortChannelId, '111x2x0');

    // 4. close back to chain (device-signed), reclaiming to a wallet address
    final closed = await LspClient.channelClose(chain: 'seq', asset: 'aa', node: node.key, scid: '111x2x0', destination: 'tb1qback');
    expect(seen['/lsp/channel/close']!['scid'], '111x2x0');
    expect(seen['/lsp/channel/close']!['destination'], 'tb1qback');
    expect(closed.closingTxid, 'fc' * 32);
    expect(closed.type, 'mutual');
  });

  test('waitNodeReady polls /node/getinfo until ready', () async {
    var polls = 0;
    LspClient.client = MockClient((req) async {
      expect(req.url.path, '/lsp/node/getinfo');
      expect(req.url.queryParameters['node'], 'seq:aa:02bb');
      polls++;
      return http.Response(jsonEncode({'ok': true, 'ready': polls >= 2, 'node_id': '02ff', 'blockheight': 100, 'synced': true}), 200);
    });
    final info = await LspClient.waitNodeReady('seq:aa:02bb', poll: const Duration(milliseconds: 1));
    expect(info.ready, isTrue);
    expect(polls, greaterThanOrEqualTo(2));
  });
}
