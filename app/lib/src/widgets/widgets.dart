import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// The official Sequentia mark — gold two-stroke "S" on the near-black disc.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 56});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icon/sequentia-s.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// A subtle "built on Sequentia" endorsement (the real gold "S" mark + wordmark
/// text) for the welcome / lock screens. Sequentia has no standalone wordmark
/// asset — only the "S" — so the wordmark is set typographically.
class SequentiaWordmark extends StatelessWidget {
  const SequentiaWordmark({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text('BUILT ON', style: AmbraText.label.copyWith(letterSpacing: 3, fontSize: 10)),
      const SizedBox(height: 10),
      Row(mainAxisSize: MainAxisSize.min, children: [
        const BrandMark(size: 22),
        const SizedBox(width: 9),
        const Text('Sequentia',
            style: TextStyle(color: AmbraColors.txt, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
      ]),
      const SizedBox(height: 10),
      Text('by Concatena Labs', style: AmbraText.sub.copyWith(fontSize: 11)),
    ]);
  }
}

/// Panel-fill card; depth comes from fill contrast, not elevation.
class AmbraCard extends StatelessWidget {
  const AmbraCard({super.key, required this.child, this.padding = const EdgeInsets.all(20)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AmbraColors.panel,
        border: Border.all(color: AmbraColors.line),
        borderRadius: BorderRadius.circular(AmbraRadii.card),
      ),
      child: child,
    );
  }
}

/// Uppercase micro-label above fields/sections.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: AmbraText.label);
}

/// The one gold CTA per screen.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, this.onPressed, this.busy = false, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AmbraRadii.control),
          onTap: enabled ? onPressed : null,
          child: Ink(
            decoration: BoxDecoration(
              gradient: AmbraColors.goldGradient,
              borderRadius: BorderRadius.circular(AmbraRadii.control),
            ),
            child: Container(
              height: 52,
              alignment: Alignment.center,
              child: busy
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: AmbraColors.onGold))
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      if (icon != null) ...[Icon(icon, size: 18, color: AmbraColors.onGold), const SizedBox(width: 8)],
                      Text(label,
                          style: const TextStyle(color: AmbraColors.onGold, fontWeight: FontWeight.w700, fontSize: 15)),
                    ]),
            ),
          ),
        ),
      ),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  const SecondaryButton({super.key, required this.label, this.onPressed, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 18, color: AmbraColors.txt),
        label: Text(label, style: const TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 15)),
        style: OutlinedButton.styleFrom(
          backgroundColor: AmbraColors.buttonSurface,
          side: const BorderSide(color: AmbraColors.line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AmbraRadii.control)),
        ),
      ),
    );
  }
}

class GhostButton extends StatelessWidget {
  const GhostButton({super.key, required this.label, this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onPressed,
        child: Text(label, style: const TextStyle(color: AmbraColors.dim, fontWeight: FontWeight.w600)),
      );
}

class DangerButton extends StatelessWidget {
  const DangerButton({super.key, required this.label, this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AmbraColors.dangerBorder),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AmbraRadii.control)),
          ),
          child: Text(label, style: const TextStyle(color: AmbraColors.red, fontWeight: FontWeight.w700)),
        ),
      );
}

/// Amber caution callout — distinct from a red error.
class WarnCallout extends StatelessWidget {
  const WarnCallout(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AmbraColors.warnFill,
        border: Border.all(color: AmbraColors.warnBorder),
        borderRadius: BorderRadius.circular(AmbraRadii.input),
      ),
      child: Text(text, style: const TextStyle(color: AmbraColors.warnText, fontSize: 13, height: 1.45)),
    );
  }
}

/// Inset text field with an uppercase label.
class AmbraField extends StatelessWidget {
  const AmbraField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.mono = false,
    this.maxLines = 1,
    this.onChanged,
  });
  final String label;
  final TextEditingController? controller;
  final String? hint;
  final bool mono;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(label),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          onChanged: onChanged,
          maxLines: maxLines,
          style: mono ? AmbraText.mono.copyWith(color: AmbraColors.txt) : AmbraText.body,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: AmbraColors.dim),
            filled: true,
            fillColor: AmbraColors.panelDeep,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AmbraRadii.input),
              borderSide: const BorderSide(color: AmbraColors.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AmbraRadii.input),
              borderSide: const BorderSide(color: AmbraColors.amber),
            ),
          ),
        ),
      ],
    );
  }
}

/// 3-column numbered word grid for the recovery phrase.
class MnemonicWordGrid extends StatelessWidget {
  const MnemonicWordGrid({super.key, required this.words});
  final List<String> words;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: words.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 2.7),
      itemBuilder: (context, i) => Container(
        decoration: BoxDecoration(
          color: AmbraColors.panelDeep,
          border: Border.all(color: AmbraColors.line),
          borderRadius: BorderRadius.circular(AmbraRadii.chip),
        ),
        alignment: Alignment.center,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic, children: [
          Text('${i + 1} ', style: const TextStyle(color: AmbraColors.dim, fontSize: 11)),
          Text(words[i],
              style: const TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 14)),
        ]),
      ),
    );
  }
}

/// Bottom-pinned action bar holding the primary CTA above the safe area.
class BottomActionBar extends StatelessWidget {
  const BottomActionBar({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}
