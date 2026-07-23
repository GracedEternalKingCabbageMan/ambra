// Dart twin of the web wallet's ln-rail.test.mjs — proves the swap composer offers the Lightning
// rail for a leg ONLY when that asset/BTC has a real, usable channel with the liquidity the leg's
// DIRECTION needs, and otherwise reports WHY + the fix. Pure logic, no native lib.
//
//   cd app && flutter test test/ln_rail_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/ln_rail.dart';

const gold = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const usdx = 'bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc';

final btcT = RailTarget.btc();
final goldT = RailTarget.asset(hex: gold, ticker: 'GOLD');
final usdxT = RailTarget.asset(hex: usdx, ticker: 'USDX');

// A live BTC channel (both-sided), a live GOLD channel that is RECEIVE-only, a USDX channel OPENING.
// Each carries a node_key: they are the wallet's OWN device-provisioned channels (the only ones that
// count for rail liquidity — see the node_key filter in legLiquidity / ln-rail.js:58).
final channels = <Map>[
  {'peer_id': 'ln-btc', 'node_key': 'btc:pub', 'asset_label': 'BTC', 'spendable_units': 1000000, 'receivable_units': 500000, 'state': 'CHANNELD_NORMAL'},
  {'peer_id': 'ln-gold', 'node_key': 'seq:gold:pub', 'asset_label': 'GOLD', 'asset': gold, 'spendable_units': 0, 'receivable_units': 2000000, 'state': 'CHANNELD_NORMAL'},
  {'peer_id': 'ln-usdx', 'node_key': 'seq:usdx:pub', 'asset_label': 'USDX', 'asset': usdx, 'spendable_units': 9000, 'receivable_units': 9000, 'state': 'OPENINGD'},
];

void main() {
  test('channelMatches keys by BTC-tag / asset hex / ticker; only CHANNELD_* is usable', () {
    expect(channelMatches(channels[0], btcT), isTrue);
    expect(channelMatches(channels[0], goldT), isFalse);
    expect(channelMatches(channels[1], goldT), isTrue);
    expect(channelMatches({'asset_label': 'GOLD'}, goldT), isTrue, reason: 'ticker-only tagged channel matches by label');
    expect(channelMatches(channels[1], usdxT), isFalse);
    expect(channelActive(channels[0]), isTrue);
    expect(channelActive(channels[2]), isFalse, reason: 'OPENINGD is not usable');
  });

  test('legLiquidity aggregates only active channels', () {
    final btcL = legLiquidity(channels, btcT);
    expect([btcL.active, btcL.spendable, btcL.receivable, btcL.count], [true, BigInt.from(1000000), BigInt.from(500000), 1]);
    final goldL = legLiquidity(channels, goldT);
    expect([goldL.active, goldL.spendable, goldL.receivable], [true, BigInt.zero, BigInt.from(2000000)]);
    expect(legLiquidity(channels, usdxT).active, isFalse, reason: 'a still-OPENING channel is NOT usable liquidity');
  });

  test('shared/demo channels (no node_key) are excluded from rail liquidity', () {
    // A shared-topology channel the LSP /status also returns, but that this wallet does NOT control
    // (no node_key). It must NEVER count as usable liquidity, or the composer would flash the LN rail
    // off the demo node's channels for a wallet that has moved nothing in.
    final shared = <Map>[
      {'peer_id': 'demo-gold', 'asset_label': 'GOLD', 'asset': gold, 'spendable_units': 5000000, 'receivable_units': 5000000, 'state': 'CHANNELD_NORMAL'},
    ];
    expect(legLiquidity(shared, goldT).active, isFalse, reason: 'no node_key -> not the wallet\'s own channel');
    expect(canPayFrom(shared, goldT), isFalse);
  });

  test('pay-from needs spendable, receive-to needs receivable, opening channels excluded', () {
    expect(hasChannel(channels, btcT) && canPayFrom(channels, btcT) && canReceiveTo(channels, btcT), isTrue);
    expect(hasChannel(channels, goldT), isTrue);
    expect(canPayFrom(channels, goldT), isFalse, reason: 'GOLD cannot PAY (no spendable)');
    expect(canReceiveTo(channels, goldT), isTrue, reason: 'GOLD CAN receive');
    expect(hasChannel(channels, usdxT), isFalse);
    expect(canPayFrom(channels, usdxT), isFalse);
  });

  test('legOption distinguishes "no channel -> move" from "empty side -> add" and passes a real leg', () {
    final noChan = legOption(channels, usdxT, 'pay');
    expect(noChan.ok, isFalse);
    expect(noChan.cta, 'move');
    expect(noChan.reason, contains('No Lightning channel for USDX'));

    final provReady = legOption(channels, usdxT, 'pay', {usdx: {'connected': true}});
    expect(provReady.ok, isFalse);
    expect(provReady.cta, 'move');
    expect(provReady.hint, contains('node is ready'));

    final emptyPay = legOption(channels, goldT, 'pay');
    expect(emptyPay.ok, isFalse);
    expect(emptyPay.cta, 'add');
    expect(emptyPay.reason, contains('no spendable'));

    final okRecv = legOption(channels, goldT, 'recv');
    expect(okRecv.ok, isTrue);
    expect(okRecv.reason, '');
  });

  test('railAvailability reflects real per-leg channel liquidity, not "LSP configured"', () {
    // BUY GOLD: pay BTC (LN) + receive GOLD (LN) -> both sides real -> pure-LN OK.
    final buyGold = railAvailability(channels: channels, payTarget: btcT, recvTarget: goldT);
    expect(buyGold.payLn.ok && buyGold.recvLn.ok && buyGold.pureLnOk, isTrue);

    // SELL GOLD: pay GOLD (LN) — no spendable -> pure-LN gated.
    final sellGold = railAvailability(channels: channels, payTarget: goldT, recvTarget: btcT);
    expect(sellGold.payLn.ok, isFalse);
    expect(sellGold.recvLn.ok, isTrue);
    expect(sellGold.pureLnOk, isFalse);

    // Zero channels: nothing offerable — never a silent "LSP configured" yes.
    final none = railAvailability(channels: const [], payTarget: btcT, recvTarget: goldT);
    expect(none.payLn.ok || none.recvLn.ok || none.pureLnOk, isFalse);
  });

  // --- LSP JIT-fronting (spec §5, web D): a channel-less wallet can STILL trade over Lightning --------

  test('Frontable.fromStatus parses btc in/out + per-asset inventory; absent -> null', () {
    expect(Frontable.fromStatus({'node_id': 'x'}), isNull, reason: 'no frontable key -> null (do not pessimise)');
    final f = Frontable.fromStatus({
      'frontable': {
        'btc': {'in_sat': 200000, 'out_sat': 0},
        'assets': {gold.toUpperCase(): '5000000', usdx: 0},
      }
    });
    expect(f, isNotNull);
    expect(f!.btcInSat, BigInt.from(200000));
    expect(f.btcOutSat, BigInt.zero);
    expect(f.assets[gold], BigInt.from(5000000), reason: 'asset keys are lowercased');
    expect(f.hasAnyAssetInventory, isTrue);
  });

  test('lspCanFront is leg- and direction-aware', () {
    final f = Frontable(btcInSat: BigInt.from(200000), btcOutSat: BigInt.zero, assets: {gold: BigInt.from(5000000)});
    expect(lspCanFront(btcT, 'pay', f), isTrue, reason: 'in_sat>0 -> LSP can RECEIVE the user\'s BTC');
    expect(lspCanFront(btcT, 'recv', f), isFalse, reason: 'out_sat==0 -> LSP cannot DELIVER BTC over LN');
    expect(lspCanFront(goldT, 'recv', f), isTrue, reason: 'GOLD inventory -> can front INBOUND');
    expect(lspCanFront(usdxT, 'recv', f), isFalse, reason: 'no USDX inventory -> cannot front USDX inbound');
    expect(lspCanFront(usdxT, 'pay', f), isTrue, reason: 'pay-asset only needs the LP up (any inventory)');
    expect(lspCanFront(goldT, 'pay', null), isFalse, reason: 'no frontable snapshot -> lspCanFront is false');
  });

  test('legOption: frontable data distinguishes provisionable (near-instant) from unfrontable', () {
    final f = Frontable(btcInSat: BigInt.zero, btcOutSat: BigInt.zero, assets: {gold: BigInt.from(5000000)});
    // No own USDX channel, and the LSP has no USDX inventory to front inbound -> honestly unavailable.
    final unfront = legOption(channels, usdxT, 'recv', null, f);
    expect(unfront.ok, isFalse);
    expect(unfront.unfrontable, isTrue);
    expect(unfront.provisionable, isFalse);
    expect(unfront.reason, contains('isn\'t available'));

    // No own USDX channel, but pay-asset only needs the LP up (GOLD inventory present) -> provisionable.
    final prov = legOption(channels, usdxT, 'pay', null, f);
    expect(prov.ok, isFalse);
    expect(prov.provisionable, isTrue);
    expect(prov.unfrontable, isFalse);
    expect(prov.hint, contains('near-instant'));

    // With NO frontable snapshot at all, a channel-less leg stays provisionable (never pessimise).
    final noSnap = legOption(channels, usdxT, 'recv', null, null);
    expect(noSnap.provisionable, isTrue);
    expect(noSnap.unfrontable, isFalse);
  });
}
