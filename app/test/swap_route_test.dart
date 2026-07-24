// Truth-table test for the pure rail router (the port of swap.js `findRoute`). Proves the composer
// classifies each pair into the right settlement route, so a single Review action can dispatch it.
//
//   cd app && flutter test test/swap_route_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/seqob_client.dart';
import 'package:ambra/src/data/swap_route.dart';

const seqA = '3a0f9192219db59f8d7f87d93ac6311095dfe1255d149727b87baaa7d2cc71a1'; // e.g. GOLD
const seqB = '2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de'; // e.g. USDX
const btc = kBtcSentinel;

void main() {
  test('both Sequentia assets -> same-chain covenant route', () {
    final r = route(seqA, seqB);
    expect(r.kind, SwapRouteKind.same);
    expect(r.seqAsset, isNull);
    expect(r.isValid, isTrue);
  });

  test('BTC -> asset, both legs on-chain -> cross (buy)', () {
    final r = route(btc, seqA); // rails default to chain
    expect(r.kind, SwapRouteKind.cross);
    expect(r.payIsBtc, isTrue);
    expect(r.seqAsset, seqA);
  });

  test('asset -> BTC, both legs on-chain -> reverse cross (sell)', () {
    final r = route(seqA, btc);
    expect(r.kind, SwapRouteKind.cross);
    expect(r.payIsBtc, isFalse, reason: 'the asset is the pay leg -> a SELL for Bitcoin');
    expect(r.seqAsset, seqA);
  });

  test('both legs over Lightning -> pure-LN route', () {
    final r = route(btc, seqA, payRailLn: true, recvRailLn: true, lnAvailable: true);
    expect(r.kind, SwapRouteKind.ln);
    expect(r.payIsBtc, isTrue);
    expect(r.seqAsset, seqA);
  });

  test('asset leg on Lightning + BTC on-chain -> mixed (sub-asset) route', () {
    // BUY: pay BTC on-chain, receive the asset over Lightning (sub-asset buy).
    final buy = route(btc, seqA, payRailLn: false, recvRailLn: true, lnAvailable: true);
    expect(buy.kind, SwapRouteKind.mixed);
    expect(buy.payIsBtc, isTrue);
    expect(buy.payRail, 'chain'); // BTC leg on-chain
    expect(buy.recvRail, 'ln'); // asset leg over Lightning
    // SELL: pay the asset over Lightning, receive BTC on-chain (sub-asset sell).
    final sell = route(seqA, btc, payRailLn: true, recvRailLn: false, lnAvailable: true);
    expect(sell.kind, SwapRouteKind.mixed);
    expect(sell.payIsBtc, isFalse);
    expect(sell.payRail, 'ln'); // asset leg over Lightning
    expect(sell.recvRail, 'chain'); // BTC leg on-chain
  });

  test('BTC leg on Lightning + asset on-chain -> mixed (submarine), NO silent degrade to cross', () {
    // Submarine BUY: pay BTC over Lightning, receive the asset on-chain. The route now returns the REAL
    // shape (mixed/submarine) for BOTH directions — no silent degrade to cross (which used to misroute a
    // submarine onto the on-chain cross rail). [isSubmarine] distinguishes it from the sub-asset shape.
    final buy = route(btc, seqA, payRailLn: true, recvRailLn: false, lnAvailable: true);
    expect(buy.kind, SwapRouteKind.mixed);
    expect(buy.isSubmarine, isTrue);
    expect(buy.isSubAsset, isFalse);
    expect(buy.payRail, 'ln'); // BTC leg over Lightning
    expect(buy.recvRail, 'chain'); // asset leg on-chain
    // Submarine SELL: pay the asset on-chain, receive BTC over Lightning.
    final sell = route(seqA, btc, payRailLn: false, recvRailLn: true, lnAvailable: true);
    expect(sell.kind, SwapRouteKind.mixed);
    expect(sell.isSubmarine, isTrue);
    expect(sell.payRail, 'chain'); // asset leg on-chain
    expect(sell.recvRail, 'ln'); // BTC leg over Lightning
  });

  test('chooseSettlementPath routes a submarine by the maker caps', () {
    final buy = route(btc, seqA, payRailLn: true, recvRailLn: false, lnAvailable: true); // submarine BUY
    // Interactive + accepts BTC-LN -> a DIRECT peer-to-peer submarine (ln_direction 1 = buy).
    final p2p = chooseSettlementPath(buy, makerInteractive: true, makerBtcLn: true);
    expect(p2p.path, SettlementPath.p2pSubmarine);
    expect(p2p.lnDirection, 1);
    expect(p2p.lnSide, 'payer');
    // Not BTC-LN-capable -> the LSP leg-bridge fallback (honest-disabled at dispatch).
    expect(chooseSettlementPath(buy, makerInteractive: true, makerBtcLn: false).path, SettlementPath.lspBridge);
    // The maker rests the asset over Lightning too -> the crossing has no on-chain asset leg -> unsupported.
    expect(
        chooseSettlementPath(buy, makerInteractive: true, makerBtcLn: true, makerAssetOnchain: false).path,
        SettlementPath.unsupported);
    // A SELL submarine -> ln_direction 0, receiver side.
    final sell = route(seqA, btc, payRailLn: false, recvRailLn: true, lnAvailable: true);
    final sp = chooseSettlementPath(sell, makerInteractive: true, makerBtcLn: true);
    expect(sp.path, SettlementPath.p2pSubmarine);
    expect(sp.lnDirection, 0);
    expect(sp.lnSide, 'receiver');
    // A non-submarine shape is native to the composer's proven paths.
    final subAsset = route(btc, seqA, payRailLn: false, recvRailLn: true, lnAvailable: true);
    expect(chooseSettlementPath(subAsset, makerInteractive: true, makerBtcLn: true).path, SettlementPath.native);
  });

  test('CrossOffer caps default conservative: btc_ln without interactive does NOT route P2P (Task 3)', () {
    final buy = route(btc, seqA, payRailLn: true, recvRailLn: false, lnAvailable: true); // submarine BUY
    // A cross offer whose SIGNED caps OMIT `interactive` must default it FALSE, so even WITH btc_ln the
    // route is the honest-disabled LSP leg-bridge, never a P2P submarine (mirror the web, where
    // caps.interactive undefined routes to the lsp-bridge).
    final noInteractive = CrossOffer(
      offerId: 'x', seqAsset: seqA, makerSellsAsset: true,
      assetAtoms: BigInt.from(100), btcSats: BigInt.from(1000), makerPubkey: '03aa',
      btcLn: true, // interactive OMITTED -> defaults false
    );
    expect(noInteractive.interactive, isFalse, reason: 'interactive defaults FALSE when the caps omit it');
    expect(
      chooseSettlementPath(buy, makerInteractive: noInteractive.interactive, makerBtcLn: noInteractive.btcLn).path,
      SettlementPath.lspBridge,
      reason: '{btc_ln:true} with no interactive must NOT navigate to a P2P submarine',
    );
    // EXPLICIT interactive:true + btc_ln:true -> the DIRECT P2P submarine.
    final both = CrossOffer(
      offerId: 'x', seqAsset: seqA, makerSellsAsset: true,
      assetAtoms: BigInt.from(100), btcSats: BigInt.from(1000), makerPubkey: '03aa',
      interactive: true, btcLn: true,
    );
    expect(
      chooseSettlementPath(buy, makerInteractive: both.interactive, makerBtcLn: both.btcLn).path,
      SettlementPath.p2pSubmarine,
    );
  });

  test('pure-LN route carries ln on both legs', () {
    final r = route(btc, seqA, payRailLn: true, recvRailLn: true, lnAvailable: true);
    expect(r.payRail, 'ln');
    expect(r.recvRail, 'ln');
  });

  test('BTC<->BTC, same asset, and empty legs are invalid', () {
    expect(route(btc, btc).kind, SwapRouteKind.invalid);
    expect(route(seqA, seqA).kind, SwapRouteKind.invalid);
    expect(route(null, seqA).kind, SwapRouteKind.invalid);
    expect(route(seqA, null).kind, SwapRouteKind.invalid);
    expect(route('', seqA).kind, SwapRouteKind.invalid);
  });

  test('LN rails are ignored when Lightning is unavailable -> proven cross route', () {
    final r = route(btc, seqA, payRailLn: true, recvRailLn: true, lnAvailable: false);
    expect(r.kind, SwapRouteKind.cross, reason: 'no Lightning -> both legs on-chain regardless of stale rail state');
  });

  group('same-chain asset<->asset pure-LN (priority D)', () {
    test('both legs Lightning + a known quote -> pure-LN asset<->asset route (not the covenant book)', () {
      // seqB is the canonical quote; seqA the base. Paying the base, both rails LN.
      final r = route(seqA, seqB, payRailLn: true, recvRailLn: true, lnAvailable: true, sameChainQuote: seqB);
      expect(r.kind, SwapRouteKind.ln);
      expect(r.assetAsset, isTrue);
      expect(r.seqAsset, seqA, reason: 'the base leg');
      expect(r.quoteAsset, seqB, reason: 'the counter asset takes BTC\'s structural place');
      expect(r.payIsBtc, isFalse, reason: 'paying the base = a SELL of the base for the quote');
      expect(r.payRail, 'ln');
      expect(r.recvRail, 'ln');
    });

    test('paying the QUOTE asset over LN -> payIsBtc true (structural BUY of the base)', () {
      final r = route(seqB, seqA, payRailLn: true, recvRailLn: true, lnAvailable: true, sameChainQuote: seqB);
      expect(r.kind, SwapRouteKind.ln);
      expect(r.payIsBtc, isTrue);
      expect(r.seqAsset, seqA);
      expect(r.quoteAsset, seqB);
    });

    test('only one leg Lightning -> stays same-chain covenant', () {
      expect(route(seqA, seqB, payRailLn: true, recvRailLn: false, lnAvailable: true, sameChainQuote: seqB).kind,
          SwapRouteKind.same);
    });

    test('both legs LN but no known quote -> stays same-chain covenant (never guesses the frame)', () {
      expect(route(seqA, seqB, payRailLn: true, recvRailLn: true, lnAvailable: true).kind, SwapRouteKind.same);
    });

    test('both legs LN but Lightning unavailable -> same-chain covenant', () {
      expect(route(seqA, seqB, payRailLn: true, recvRailLn: true, lnAvailable: false, sameChainQuote: seqB).kind,
          SwapRouteKind.same);
    });
  });
}
