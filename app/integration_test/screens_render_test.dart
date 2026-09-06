// On-device proof that the screens this wallet gained actually render, taken through the
// Flutter engine rather than the emulator's screen capture — which returns black for
// Flutter's SurfaceView on a software GPU and so can neither confirm nor deny anything.
//
//   flutter test integration_test/screens_render_test.dart -d <device>
//
// Each case pumps a real screen on the device and asserts what a user would look for. The
// screenshots are a by-product: the assertions are what fails the run.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ambra/src/data/blindsig.dart';
import 'package:ambra/src/data/coinjoin_protocol.dart';
import 'package:ambra/src/data/wallet_repository.dart';
import 'package:ambra/src/rust/frb_generated.dart';
import 'package:ambra/src/screens/mix_screen.dart';
import 'package:ambra/src/screens/shell.dart';
import 'package:ambra/src/screens/sign_screen.dart';
import 'package:ambra/src/theme/theme.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child) => MaterialApp(theme: ambraTheme(), home: child);

  // Android renders Flutter into a SurfaceView, which the emulator's own screen capture
  // reads back as black — the reason this file exists rather than a screenshot script.
  // Converting the surface to an image is what makes a capture possible at all, here and
  // for anything else that wants to see this app on a device.
  setUpAll(() async {
    await binding.convertFlutterSurfaceToImage();
    // The cards that read a key do so through the Rust core, which the app
    // initialises at start and this suite must initialise itself.
    await RustLib.init();
  });

  testWidgets('the Mix screen renders, and says what a mix does not buy', (tester) async {
    await tester.pumpWidget(host(const MixScreen()));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Mix'), findsWidgets);
    // The honesty the screen exists to carry, on the device where a user reads it.
    expect(
      find.textContaining('the coordinator still sees your amounts', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('anonymity set is the round', findRichText: true), findsOneWidget);
    await binding.takeScreenshot('mix-screen');
  });

  testWidgets('the classic signing card renders on the Sign screen', (tester) async {
    await tester.pumpWidget(host(const Scaffold(body: SingleChildScrollView(child: ClassicSignCard()))));
    await tester.pump(const Duration(milliseconds: 300));

    // SectionLabel uppercases what it is given, so match what a user actually sees.
    expect(find.text('SIGN A MESSAGE WITH YOUR WALLET KEY'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'the text you want to sign'), findsOneWidget);
    expect(find.text('Sign'), findsWidgets);
    await binding.takeScreenshot('classic-sign-card');
  });

  testWidgets('the staking-key card signs on the device, with the key the wallet shows',
      (tester) async {
    // A phrase in the wallet's own store, so the card reads it the way it does
    // for a user; the staking key it shows comes back through the FFI.
    await WalletRepository.instance.persistNewWallet(
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about');
    try {
      await tester.pumpWidget(host(const Scaffold(body: SingleChildScrollView(child: StakerSignCard()))));
      // The key is read through the core after the first frame; give it a moment.
      for (var i = 0; i < 20 && find.textContaining('Staking key 0').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.text('SIGN A MESSAGE WITH YOUR STAKING KEY'), findsOneWidget);
      expect(find.textContaining('Staking key 0'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'the message the site asked you to sign'),
          'Sign in to Levo\nnonce: 0123456789abcdef\nThis authorises no payment.');
      await tester.tap(find.text('Sign'));
      for (var i = 0; i < 40 && find.byType(SelectableText).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      // A 65-byte recoverable signature is 88 characters of base64; the key beside it is
      // 33 bytes of hex. The conformance test in the core proves the key recovers.
      expect(find.byWidgetPredicate((w) => w is SelectableText && RegExp(r'^[A-Za-z0-9+/]{87}=$').hasMatch(w.data ?? '')),
          findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is SelectableText && RegExp(r'^0[23][0-9a-f]{64}$').hasMatch(w.data ?? '')),
          findsOneWidget);
      await binding.takeScreenshot('staker-sign-card');
    } finally {
      await WalletRepository.instance.removeWallet();
    }
  });

  testWidgets('the account key card starts collapsed, as a key that is not for sharing casually',
      (tester) async {
    await tester.pumpWidget(host(const Scaffold(body: SingleChildScrollView(child: AccountKeyCard()))));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Show account key (xpub)'), findsOneWidget);
    expect(find.text('ACCOUNT KEY'), findsNothing);
    await binding.takeScreenshot('account-key-collapsed');
  });

  testWidgets('the credential math runs on the device, not only on a laptop', (tester) async {
    // The same vector the unit test pins against the JavaScript the coordinator is proven
    // against — here on the phone's own arithmetic.
    const n = 'df85ffbe284766063dc2c61755a0c40f52b4ce140dfd71d3621323a5ee9189cd'
        'fe9b952dcb70a5eeb66d75502be45816636f7f1ee30200a06985b351d5b023b6'
        '3d407db0cd5a2891b35e1cb77be5dbdc054acbd1ab2bafe421ffaca757b03902'
        '4fdf3bb0b0bbf2ba48f21311a0483d99106b256dba1fdc3447c47ab193383a21';
    final m = fdh(List<int>.generate(32, (i) => i + 1), 128);
    expect(m.toRadixString(16).startsWith('8e6a307c879400d744b9032812db3a2e'), isTrue);
    expect(BlindKey(n, '010001').klen, 128);
  });

  testWidgets('the signing gate refuses a short-changed round on the device', (tester) async {
    final denom = BigInt.from(100000000);
    expect(
      () => verifyRoundOutputs(
        mine: [MineOutput(scriptPubkey: '0014aa', asset: 'aa', value: denom - BigInt.one)],
        mixScripts: const ['0014aa'],
        changeScript: null,
        denom: denom,
        change: BigInt.zero,
        asset: 'aa',
      ),
      throwsA(isA<StateError>()),
    );
  });
}
