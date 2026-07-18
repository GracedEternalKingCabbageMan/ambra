import 'package:flutter/material.dart';

import '../data/bip39_wordlist.dart';
import '../rust/api.dart' as core;
import '../theme/theme.dart';
import '../widgets/widgets.dart';
import 'onboarding.dart' show ImportScreen, SecuritySetupScreen;

/// Keylogger-immune recovery-phrase import (Electrum style).
///
/// The user never touches the system keyboard: a full-screen custom keyboard
/// (plain Flutter buttons, no [TextField], so no IME is ever invoked) drives a
/// per-word letter buffer, and the word itself is chosen from the BIP39
/// dictionary as autocomplete suggestions. Because words are only ever SELECTED
/// from [kBip39Words], case and autocorrect cannot corrupt the phrase, and a
/// software keylogger sitting on the IME sees nothing.
///
/// The seed lives only as a `List<String>` in memory here; validation and
/// persistence go through the same [SecuritySetupScreen] path as every other
/// onboarding route. Nothing is logged, persisted, or sent from this screen.
class RecoverScreen extends StatefulWidget {
  const RecoverScreen({super.key});

  @override
  State<RecoverScreen> createState() => _RecoverScreenState();
}

class _RecoverScreenState extends State<RecoverScreen> {
  /// Phrase length the user is entering. BIP39 mnemonics are 12/15/18/21/24
  /// words; the two common lengths are offered as a toggle. The paste fallback
  /// (see [ImportScreen]) accepts any valid length.
  int _target = 12;

  /// Words committed so far, in order. The next empty slot is `_words.length`.
  final List<String> _words = <String>[];

  /// Letters tapped for the current (not-yet-committed) word. Always lowercase
  /// because the keyboard only emits lowercase a-z.
  String _buffer = '';

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Fail loudly in debug if the bundled wordlist was ever mis-edited; a wrong
    // list would silently break recovery. Stripped from release builds.
    assert(debugValidateBip39Words());
  }

  bool get _full => _words.length >= _target;

  /// BIP39 words that start with the current buffer, capped for display. The
  /// list is short (they narrow to one within ~4 letters), so a linear scan of
  /// 2048 entries per keystroke is trivial.
  List<String> get _suggestions {
    if (_buffer.isEmpty) return const <String>[];
    final out = <String>[];
    for (final w in kBip39Words) {
      if (w.startsWith(_buffer)) {
        out.add(w);
        if (out.length == 9) break;
      }
    }
    return out;
  }

  void _setTarget(int n) {
    if (n == _target) return;
    setState(() {
      _target = n;
      if (_words.length > n) _words.removeRange(n, _words.length);
      _buffer = '';
      _error = null;
    });
  }

  void _tapLetter(String ch) {
    // No active slot once every word is committed: the user must backspace into
    // the last word to edit. BIP39 words cap at 8 letters, so the buffer does.
    if (_full || _buffer.length >= 8) return;
    setState(() {
      _buffer += ch;
      _error = null;
    });
  }

  void _backspace() {
    setState(() {
      if (_buffer.isNotEmpty) {
        _buffer = _buffer.substring(0, _buffer.length - 1);
      } else if (_words.isNotEmpty) {
        // Empty buffer: pop the last committed word back for editing.
        _buffer = _words.removeLast();
      }
      _error = null;
    });
  }

  void _commit(String word) {
    if (_full) return;
    setState(() {
      _words.add(word);
      _buffer = '';
      _error = null;
    });
  }

  Future<void> _recover() async {
    if (!_full || _busy) return;
    final phrase = _words.join(' ');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await core.validateMnemonic(mnemonic: phrase);
      if (!mounted) return;
      setState(() => _busy = false);
      // Proceed exactly like the paste import: hand the phrase to the shared
      // security step, which validates the lock choice and persists the wallet.
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SecuritySetupScreen(mnemonic: phrase)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'That phrase is not valid; check the words. (${_short(e)})';
      });
    }
  }

  void _openPasteFallback() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ImportScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        title: const Text('Import wallet', style: AmbraText.title),
        iconTheme: const IconThemeData(color: AmbraColors.dim),
        actions: [
          TextButton(
            onPressed: _openPasteFallback,
            child: const Text('Paste phrase',
                style: TextStyle(color: AmbraColors.dim, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: AmbraBackground(
        child: SafeArea(
          child: Column(
            children: [
              // Fixed top: phrase-length toggle.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: Row(
                  children: [
                    const SectionLabel('LENGTH'),
                    const Spacer(),
                    _SegToggle(value: _target, onChanged: _busy ? null : _setTarget),
                  ],
                ),
              ),
              // Scrollable middle: the numbered slot grid + any error.
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Select each word from the suggestions. Ambra never opens '
                        'the system keyboard, so nothing can log your phrase.',
                        style: AmbraText.sub,
                      ),
                      const SizedBox(height: 14),
                      _SlotGrid(
                        words: _words,
                        buffer: _buffer,
                        target: _target,
                        activeIndex: _full ? -1 : _words.length,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Text(_error!, style: const TextStyle(color: AmbraColors.red, height: 1.4)),
                      ],
                    ],
                  ),
                ),
              ),
              // Fixed bottom: current word, suggestions, keyboard, primary CTA.
              // The body is already inside a SafeArea, so a plain inset is enough.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _CurrentWordStrip(
                      buffer: _buffer,
                      slotNumber: _words.length + 1,
                      target: _target,
                      full: _full,
                    ),
                    const SizedBox(height: 8),
                    _SuggestionRow(
                      buffer: _buffer,
                      suggestions: _suggestions,
                      slotNumber: _words.length + 1,
                      full: _full,
                      onPick: _commit,
                    ),
                    const SizedBox(height: 10),
                    _Keyboard(onLetter: _tapLetter, onBackspace: _backspace),
                    const SizedBox(height: 12),
                    PrimaryButton(
                      label: 'Recover wallet',
                      busy: _busy,
                      icon: Icons.lock_open,
                      onPressed: (_full && !_busy) ? _recover : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _short(Object e) {
  final s = e.toString();
  return s.length > 140 ? '${s.substring(0, 140)}…' : s;
}

/// The 12 / 24 segmented control.
class _SegToggle extends StatelessWidget {
  const _SegToggle({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AmbraColors.panelDeep,
        border: Border.all(color: AmbraColors.line),
        borderRadius: BorderRadius.circular(AmbraRadii.chip),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [_seg(12), _seg(24)]),
    );
  }

  Widget _seg(int n) {
    final selected = n == value;
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(n),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AmbraColors.amber : Colors.transparent,
          borderRadius: BorderRadius.circular(AmbraRadii.chip),
        ),
        child: Text(
          '$n',
          style: TextStyle(
            color: selected ? AmbraColors.onGold : AmbraColors.dim,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

/// Numbered grid of every slot: committed words, the active buffer (amber), and
/// the still-empty slots. Read-only; editing is via backspace on the keyboard.
class _SlotGrid extends StatelessWidget {
  const _SlotGrid({
    required this.words,
    required this.buffer,
    required this.target,
    required this.activeIndex,
  });
  final List<String> words;
  final String buffer;
  final int target;
  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: target,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.6,
      ),
      itemBuilder: (context, i) {
        final committed = i < words.length;
        final active = i == activeIndex;
        final text = committed ? words[i] : (active ? buffer : '');
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: AmbraColors.panelDeep,
            border: Border.all(color: active ? AmbraColors.amber : AmbraColors.line),
            borderRadius: BorderRadius.circular(AmbraRadii.chip),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              SizedBox(
                width: 20,
                child: Text('${i + 1}', style: const TextStyle(color: AmbraColors.dim, fontSize: 11)),
              ),
              Flexible(
                child: Text(
                  text.isEmpty ? (active ? '' : '·····') : text,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: TextStyle(
                    color: committed
                        ? AmbraColors.txt
                        : (active ? AmbraColors.amber2 : AmbraColors.line),
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    fontFamily: kMono,
                  ),
                ),
              ),
              if (active) ...[
                const SizedBox(width: 1),
                Container(width: 2, height: 16, color: AmbraColors.amber2),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The prominent "current word" line sitting just above the keyboard, so the
/// buffer is always in view next to the keys regardless of grid scroll.
class _CurrentWordStrip extends StatelessWidget {
  const _CurrentWordStrip({
    required this.buffer,
    required this.slotNumber,
    required this.target,
    required this.full,
  });
  final String buffer;
  final int slotNumber;
  final int target;
  final bool full;

  @override
  Widget build(BuildContext context) {
    if (full) {
      return Row(children: [
        const Icon(Icons.check_circle, color: AmbraColors.green, size: 18),
        const SizedBox(width: 8),
        Text('All $target words entered. Tap Recover wallet.', style: AmbraText.body),
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
      Text('WORD $slotNumber OF $target',
          style: AmbraText.label.copyWith(letterSpacing: 0.5, fontSize: 11)),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          buffer.isEmpty ? 'tap a letter…' : buffer,
          overflow: TextOverflow.fade,
          softWrap: false,
          style: TextStyle(
            fontFamily: kMono,
            fontSize: 20,
            letterSpacing: 1.0,
            fontWeight: FontWeight.w600,
            color: buffer.isEmpty ? AmbraColors.dim : AmbraColors.txt,
          ),
        ),
      ),
    ]);
  }
}

/// Horizontally scrolling BIP39 suggestions for the current buffer.
class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.buffer,
    required this.suggestions,
    required this.slotNumber,
    required this.full,
    required this.onPick,
  });
  final String buffer;
  final List<String> suggestions;
  final int slotNumber;
  final bool full;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    Widget hint(String t) => Align(
          alignment: Alignment.centerLeft,
          child: Text(t, style: AmbraText.sub),
        );

    Widget content;
    if (full) {
      content = hint('Backspace to edit the last word.');
    } else if (buffer.isEmpty) {
      content = hint('Suggestions for word $slotNumber appear here.');
    } else if (suggestions.isEmpty) {
      content = hint('No BIP39 word starts with "$buffer". Backspace to fix.');
    } else {
      content = ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: suggestions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => _SuggestionChip(word: suggestions[i], onTap: () => onPick(suggestions[i])),
      );
    }
    return SizedBox(height: 40, child: content);
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.word, required this.onTap});
  final String word;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: AmbraColors.buttonSurface,
          border: Border.all(color: AmbraColors.amber),
          borderRadius: BorderRadius.circular(AmbraRadii.chip),
        ),
        child: Text(
          word,
          style: const TextStyle(
              color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 15, fontFamily: kMono),
        ),
      ),
    );
  }
}

/// The alphabetical on-screen keyboard: a-z (in order) plus backspace. Plain
/// buttons only, never a [TextField], so no system IME is ever invoked.
class _Keyboard extends StatelessWidget {
  const _Keyboard({required this.onLetter, required this.onBackspace});
  final ValueChanged<String> onLetter;
  final VoidCallback onBackspace;

  static const _rows = <String>['abcdefg', 'hijklmn', 'opqrstu', 'vwxyz'];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in _rows)
          Row(
            children: [
              for (final ch in row.split(''))
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: _KeyCap(label: ch, onTap: () => onLetter(ch)),
                  ),
                ),
              // Backspace shares the last row, kept in the far bottom-right
              // corner (the conventional spot); the gap pads the row to a full
              // 7 columns so every key keeps a consistent width.
              if (row == _rows.last) ...[
                const Spacer(),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: _KeyCap(
                      onTap: onBackspace,
                      child: const Icon(Icons.backspace_outlined, size: 20, color: AmbraColors.txt),
                    ),
                  ),
                ),
              ],
            ],
          ),
      ],
    );
  }
}

/// A single tappable key with a brief press highlight (the global theme
/// disables ink splashes, so feedback is done here explicitly).
class _KeyCap extends StatefulWidget {
  const _KeyCap({this.label, this.child, required this.onTap});
  final String? label;
  final Widget? child;
  final VoidCallback onTap;

  @override
  State<_KeyCap> createState() => _KeyCapState();
}

class _KeyCapState extends State<_KeyCap> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) {
        setState(() => _down = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _down = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 70),
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _down ? AmbraColors.line : AmbraColors.buttonSurface,
          border: Border.all(color: AmbraColors.line),
          borderRadius: BorderRadius.circular(AmbraRadii.input),
        ),
        child: widget.child ??
            Text(
              widget.label!,
              style: const TextStyle(color: AmbraColors.txt, fontSize: 18, fontWeight: FontWeight.w600),
            ),
      ),
    );
  }
}
