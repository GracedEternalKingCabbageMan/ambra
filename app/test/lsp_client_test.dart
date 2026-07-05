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
}
