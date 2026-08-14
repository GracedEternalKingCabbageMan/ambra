// Unit tests for the picker-visibility + hidden-assets logic (mirrors the web
// wallet's picker-hidden suite):
//
//   - pickerMatches: the DEFAULT (empty-search) view is held-assets-plus-native-BTC
//     minus hidden; a typed search sweeps EVERY candidate (registry-only and hidden
//     included) by ticker/name/id; a pasted 64-hex id that matches nothing known
//     synthesizes a selectable, TRADEABLE row (id-prefix ticker, precision 8 via
//     SeqAssets.labelFor's unknown fallback — the scale every composer amount uses).
//   - partitionHidden: the Balance tab's visible/hidden split — BTC never partitioned
//     out, a zero-total hidden asset in neither list.
//   - HiddenAssets: persists per wallet fingerprint, round-trips through a fresh
//     load, never blends two wallets' sets, and REFUSES to hide native BTC.
//
//   cd app && flutter test test/picker_hidden_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ambra/src/data/asset_picker.dart';
import 'package:ambra/src/data/config.dart';
import 'package:ambra/src/data/hidden_assets.dart';
import 'package:ambra/src/data/swap_route.dart' show kBtcSentinel;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A well-formed 64-hex id that is neither built-in nor registry-known.
  const unknownHex = 'deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb';

  List<AssetPickerItem> candidates() => const [
        AssetPickerItem(hex: kBtcSentinel, ticker: 'BTC', name: 'Bitcoin'),
        AssetPickerItem(hex: 'aaaa000000000000000000000000000000000000000000000000000000000001', ticker: 'GOLD', name: 'Gold (troy ounce)', held: true),
        AssetPickerItem(hex: 'aaaa000000000000000000000000000000000000000000000000000000000002', ticker: 'USDX', name: 'USD Stablecoin', held: true, hidden: true),
        AssetPickerItem(hex: 'aaaa000000000000000000000000000000000000000000000000000000000003', ticker: 'EURX', name: 'Euro Stablecoin'),
        AssetPickerItem(hex: 'aaaa000000000000000000000000000000000000000000000000000000000004', ticker: 'SILVR', name: 'Silver (troy ounce)'),
      ];

  group('pickerMatches — default (empty search) view', () {
    test('shows only held assets plus native BTC, minus hidden', () {
      final shown = pickerMatches(candidates(), '');
      expect(shown.map((it) => it.ticker), ['BTC', 'GOLD']);
    });

    test('native BTC is listed even when not held (first-class at 0)', () {
      final shown = pickerMatches(candidates(), '  ');
      expect(shown.any((it) => it.hex == kBtcSentinel), isTrue);
    });

    test('registry-only (unheld) assets are not rendered eagerly', () {
      final shown = pickerMatches(candidates(), '');
      expect(shown.any((it) => it.ticker == 'EURX' || it.ticker == 'SILVR'), isFalse);
    });
  });

  group('pickerMatches — typed search sweeps every candidate', () {
    test('finds a registry-only asset the wallet does not hold', () {
      final shown = pickerMatches(candidates(), 'EURX');
      expect(shown.map((it) => it.ticker), ['EURX']);
    });

    test('finds a HIDDEN asset (hiding declutters, never removes standing)', () {
      final shown = pickerMatches(candidates(), 'usdx');
      expect(shown.map((it) => it.ticker), ['USDX']);
      expect(shown.single.hidden, isTrue);
    });

    test('matches by name, case-insensitive', () {
      final shown = pickerMatches(candidates(), 'stablecoin');
      expect(shown.map((it) => it.ticker).toSet(), {'USDX', 'EURX'});
    });

    test('matches by id substring', () {
      final shown = pickerMatches(candidates(), 'aaaa0000');
      expect(shown.length, 4);
    });
  });

  group('pickerMatches — pasted 64-hex asset id', () {
    test('an unknown id synthesizes a selectable, pasted-marked row', () {
      final shown = pickerMatches(candidates(), unknownHex);
      expect(shown.length, 1);
      final it = shown.single;
      expect(it.pasted, isTrue);
      expect(it.hex, unknownHex);
      // Honest id-prefix ticker (SeqAssets.labelFor's unknown fallback: 6…4 elision).
      expect(it.ticker, '${unknownHex.substring(0, 6)}…${unknownHex.substring(60)}');
    });

    test('an UPPERCASE pasted id is canonicalized to lowercase hex', () {
      final shown = pickerMatches(candidates(), unknownHex.toUpperCase());
      expect(shown.single.hex, unknownHex);
      expect(shown.single.pasted, isTrue);
    });

    test('the unknown-id fallback meta the composer scales amounts with is precision 8', () {
      // The sheet + composer both read SeqAssets.labelFor(hex).precision; for an
      // unregistered id it must be the chain-native 8 so typed amounts scale
      // correctly (precision 0 would mis-scale every amount by 1e8).
      expect(SeqAssets.labelFor(unknownHex).precision, 8);
    });

    test('a pasted id that matches an existing candidate selects it, no synthesis', () {
      final shown = pickerMatches(candidates(), 'aaaa000000000000000000000000000000000000000000000000000000000003');
      expect(shown.single.ticker, 'EURX');
      expect(shown.single.pasted, isFalse);
    });

    test('a non-hex or short query never synthesizes a row', () {
      expect(pickerMatches(candidates(), 'zz' * 32), isEmpty); // 64 chars, not hex
      expect(pickerMatches(candidates(), 'deadbeef'), isEmpty); // hex, not 64
    });
  });

  group('partitionHidden — Balance tab split', () {
    final ids = [kBtcSentinel, 'g1', 'u2', 'e3'];
    test('hidden ids move to the hidden list; the rest stay visible', () {
      final p = partitionHidden(ids, {'u2'});
      expect(p.visible, [kBtcSentinel, 'g1', 'e3']);
      expect(p.hidden, ['u2']);
    });

    test('native BTC is NEVER partitioned out, even if storage claims it hidden', () {
      final p = partitionHidden(ids, {kBtcSentinel, 'u2'});
      expect(p.visible.first, kBtcSentinel);
      expect(p.hidden, ['u2']);
    });

    test('a hidden asset with zero total appears in NEITHER list', () {
      final p = partitionHidden(ids, {'u2', 'e3'}, totalOf: (h) => h == 'e3' ? BigInt.zero : BigInt.one);
      expect(p.visible, [kBtcSentinel, 'g1']);
      expect(p.hidden, ['u2']); // e3: zero balance, elided — comes back (still hidden) with a balance
    });

    test('an empty hidden set leaves everything visible', () {
      final p = partitionHidden(ids, <String>{});
      expect(p.visible, ids);
      expect(p.hidden, isEmpty);
    });
  });

  group('HiddenAssets — per-wallet persistence', () {
    const mnemonicA = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    const mnemonicB = 'legal winner thank year wave sausage worth useful legal winner thank yellow';
    const assetX = 'aaaa000000000000000000000000000000000000000000000000000000000002';

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('hide persists and round-trips through a FRESH load (new instance)', () async {
      final a = HiddenAssets();
      await a.loadFor(mnemonicA);
      await a.setHidden(assetX, true);
      expect(a.isHidden(assetX), isTrue);

      final fresh = HiddenAssets(); // simulates a relaunch: same storage, new state
      await fresh.loadFor(mnemonicA);
      expect(fresh.isHidden(assetX), isTrue);
      expect(fresh.hidden, {assetX});
    });

    test('unhide persists too', () async {
      final a = HiddenAssets();
      await a.loadFor(mnemonicA);
      await a.setHidden(assetX, true);
      await a.setHidden(assetX, false);
      final fresh = HiddenAssets();
      await fresh.loadFor(mnemonicA);
      expect(fresh.isHidden(assetX), isFalse);
      expect(fresh.hidden, isEmpty);
    });

    test('two wallets never blend their hidden sets', () async {
      final a = HiddenAssets();
      await a.loadFor(mnemonicA);
      await a.setHidden(assetX, true);

      final b = HiddenAssets();
      await b.loadFor(mnemonicB);
      expect(b.isHidden(assetX), isFalse);

      // Switching one instance BACK to wallet A restores A's set.
      await b.loadFor(mnemonicA);
      expect(b.isHidden(assetX), isTrue);
    });

    test('native BTC REFUSES hiding', () async {
      final a = HiddenAssets();
      await a.loadFor(mnemonicA);
      await a.setHidden(kBtcSentinel, true);
      expect(a.isHidden(kBtcSentinel), isFalse);
      expect(a.hidden, isEmpty);
      // And isHidden shields against a poisoned store regardless.
      await a.setHidden(assetX, true);
      expect(a.isHidden(kBtcSentinel), isFalse);
    });

    test('setHidden before loadFor is a safe no-op (no wallet to key by)', () async {
      final a = HiddenAssets();
      await a.setHidden(assetX, true);
      expect(a.hidden, isEmpty);
    });

    test('fingerprint is stable and ignores surrounding whitespace', () {
      expect(HiddenAssets.fingerprintOf(' $mnemonicA '), HiddenAssets.fingerprintOf(mnemonicA));
      expect(HiddenAssets.fingerprintOf(mnemonicA), isNot(HiddenAssets.fingerprintOf(mnemonicB)));
      expect(HiddenAssets.fingerprintOf(mnemonicA).length, 16);
    });
  });
}
