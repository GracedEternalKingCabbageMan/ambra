import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ambra/src/screens/recover_screen.dart';

// Drives the Electrum-style recovery UI purely through its on-screen keyboard
// (no system IME) to prove the core interaction: letters build a buffer, BIP39
// autocomplete filters the wordlist, tapping a suggestion commits the word and
// advances the slot, and backspace pops the last committed word. Stops before
// `validateMnemonic` (an FFI needing the native lib), which is the same handoff
// the already-working paste import uses.
void main() {
  Future<void> tapKeys(WidgetTester tester, String letters) async {
    for (final ch in letters.split('')) {
      await tester.tap(find.text(ch)); // each on-screen key is a Text(<letter>)
      await tester.pump();
    }
  }

  testWidgets('keyboard + autocomplete commits a word and advances', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RecoverScreen()));
    await tester.pumpAndSettle();

    expect(find.textContaining('WORD 1 OF 12'), findsOneWidget);

    await tapKeys(tester, 'aba'); // only 'abandon' starts with 'aba'
    expect(find.text('abandon'), findsWidgets); // the suggestion chip is present

    await tester.tap(find.text('abandon').last); // tap the chip
    await tester.pumpAndSettle();

    // Word 1 committed, now on word 2, buffer cleared.
    expect(find.textContaining('WORD 2 OF 12'), findsOneWidget);
    expect(find.text('abandon'), findsOneWidget); // now only the committed slot

    // Backspace with an empty buffer pops word 1 back for editing -> word 1 again.
    await tester.tap(find.byIcon(Icons.backspace_outlined));
    await tester.pumpAndSettle();
    expect(find.textContaining('WORD 1 OF 12'), findsOneWidget);
  });

  testWidgets('24-word toggle sets 24 slots', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RecoverScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('24'));
    await tester.pumpAndSettle();
    expect(find.textContaining('WORD 1 OF 24'), findsOneWidget);
  });
}
