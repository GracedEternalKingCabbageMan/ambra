// Truth-table test for the pure rail router (the port of swap.js `findRoute`). Proves the composer
// classifies each pair into the right settlement route, so a single Review action can dispatch it.
//
//   cd app && flutter test test/swap_route_test.dart
import 'package:flutter_test/flutter_test.dart';

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

  test('BTC leg on Lightning + asset on-chain (submarine) is unbuilt -> degrades to cross', () {
    // Submarine BUY: pay BTC over Lightning, receive the asset on-chain. Not yet built on mobile, so
    // it must fall back to the proven on-chain cross rail — NEVER misroute to a sub-asset screen.
    final buy = route(btc, seqA, payRailLn: true, recvRailLn: false, lnAvailable: true);
    expect(buy.kind, SwapRouteKind.cross);
    expect(buy.payRail, 'chain');
    expect(buy.recvRail, 'chain');
    // Submarine SELL: pay the asset on-chain, receive BTC over Lightning. Same degradation.
    final sell = route(seqA, btc, payRailLn: false, recvRailLn: true, lnAvailable: true);
    expect(sell.kind, SwapRouteKind.cross);
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
