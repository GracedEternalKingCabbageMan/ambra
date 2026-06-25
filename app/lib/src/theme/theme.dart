import 'package:flutter/material.dart';

/// Ambra design tokens — ported 1:1 from the Sequentia web wallet.
class AmbraColors {
  AmbraColors._();
  static const bg = Color(0xFF0D1014);
  static const glowTop = Color(0xFF1A212B);
  static const panel = Color(0xFF161B22);
  static const panelDeep = Color(0xFF0B0E12);
  static const line = Color(0xFF262D36);
  static const txt = Color(0xFFE6EDF3);
  static const dim = Color(0xFF8B949E);
  static const amber = Color(0xFFF0A500);
  static const amber2 = Color(0xFFFFB733);
  static const green = Color(0xFF27AE60);
  static const red = Color(0xFFE0564B);
  static const blue = Color(0xFF4AA3DF);
  static const buttonSurface = Color(0xFF1D242D);
  static const onGold = Color(0xFF1A1200);
  static const warnFill = Color(0xFF2A1D0A);
  static const warnBorder = Color(0xFF6B4E12);
  static const warnText = Color(0xFFFFCF7A);
  static const mono = Color(0xFFC9D4DF);
  static const dangerBorder = Color(0xFF5A2A26);

  /// The single brand accent + the only gradient in the app.
  static const goldGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [amber, amber2],
  );
}

class AmbraRadii {
  AmbraRadii._();
  static const card = 16.0;
  static const control = 12.0;
  static const input = 10.0;
  static const chip = 8.0;
}

/// Platform monospace — used for ALL machine-precise values (addresses, asset
/// ids, txids, atom amounts). The sans/mono split is the trust signal.
const String kMono = 'monospace';

class AmbraText {
  AmbraText._();
  static const hero = TextStyle(
      fontSize: 42, fontWeight: FontWeight.w800, letterSpacing: -0.84, color: AmbraColors.txt, height: 1.0);
  static const h1 = TextStyle(fontSize: 21, fontWeight: FontWeight.w700, letterSpacing: -0.21, color: AmbraColors.txt);
  static const title = TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AmbraColors.txt);
  static const body = TextStyle(fontSize: 14, color: AmbraColors.txt, height: 1.45);
  static const muted = TextStyle(fontSize: 14, color: AmbraColors.dim, height: 1.45);
  static const sub = TextStyle(fontSize: 13, color: AmbraColors.dim, height: 1.4);
  static const label =
      TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.72, color: AmbraColors.dim);
  static const mono = TextStyle(fontFamily: kMono, fontSize: 13, color: AmbraColors.mono, height: 1.4);
}

ThemeData ambraTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  const cs = ColorScheme.dark(
    primary: AmbraColors.amber,
    onPrimary: AmbraColors.onGold,
    surface: AmbraColors.panel,
    onSurface: AmbraColors.txt,
    error: AmbraColors.red,
    outline: AmbraColors.line,
  );
  return base.copyWith(
    scaffoldBackgroundColor: AmbraColors.bg,
    colorScheme: cs,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    textSelectionTheme: const TextSelectionThemeData(cursorColor: AmbraColors.amber2),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AmbraColors.buttonSurface,
    ),
  );
}

/// The app canvas: near-black with the brand glow floating out of the top.
class AmbraBackground extends StatelessWidget {
  const AmbraBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -1.1),
          radius: 1.25,
          colors: [AmbraColors.glowTop, AmbraColors.bg],
          stops: [0.0, 0.62],
        ),
      ),
      child: child,
    );
  }
}
