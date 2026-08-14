// Pure picker-visibility + hidden-partition logic for the swap composer's asset
// sheets and the Balance tab (mirrors the web wallet's pickerMatches /
// partitionHidden in swap.js — SEMANTICS, not code).
//
// Default (empty query) picker view: ONLY assets this wallet actually HOLDS
// (a positive balance on-chain OR in Lightning) plus native BTC — the
// parent-chain asset is first-class and stays listed even at 0 — minus assets
// the user HID on the Balance tab. A typed query searches EVERY candidate
// (the full registry, hidden assets included) by ticker, name, or id; a 64-hex
// query that matches nothing known is still an asset id, so it synthesizes a
// selectable, TRADEABLE row (id-prefix ticker, chain-native precision 8 via
// SeqAssets.labelFor's unknown-asset fallback — the books key by raw hex, so
// no registry presence is needed, only a sane amount scale).
//
// 100% pure (no IO, no widgets) so the unit tests pin the real logic.

import 'config.dart';
import 'swap_route.dart' show kBtcSentinel;

/// One candidate row for an asset sheet. [held] means a positive balance
/// on-chain OR in Lightning; [hidden] means the user hid it on the Balance tab;
/// [pasted] marks a row synthesized from a 64-hex query (the caller registers
/// the pick for the session so validation never drops it).
class AssetPickerItem {
  const AssetPickerItem({
    required this.hex,
    required this.ticker,
    this.name,
    this.held = false,
    this.hidden = false,
    this.pasted = false,
  });
  final String hex;
  final String ticker;
  final String? name;
  final bool held;
  final bool hidden;
  final bool pasted;
}

final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

/// True when [s] is a well-formed 64-hex asset id.
bool isAssetIdHex(String s) => _hex64.hasMatch(s.trim());

/// Which rows a picker query shows.
///
/// EMPTY query: only held rows (minus hidden) plus native BTC — BTC is never
/// filtered out, held or not, hidden is impossible for it. TYPED query: search
/// every candidate (hidden included) by ticker, name, or id substring; when a
/// 64-hex query matches nothing, synthesize a tradeable row for that id
/// ([SeqAssets.labelFor] supplies real registry metadata when it can name the
/// id, else the id-prefix ticker at the 8-dp default the sheet then formats
/// amounts with).
List<AssetPickerItem> pickerMatches(List<AssetPickerItem> items, String query) {
  final q = query.trim();
  if (q.isEmpty) {
    return [
      for (final it in items)
        if (it.hex == kBtcSentinel || (it.held && !it.hidden)) it,
    ];
  }
  final ql = q.toLowerCase();
  final match = [
    for (final it in items)
      if ('${it.ticker} ${it.name ?? ''} ${it.hex}'.toLowerCase().contains(ql)) it,
  ];
  if (match.isEmpty && isAssetIdHex(q)) {
    final hex = ql; // asset ids are canonically lowercase hex
    final label = SeqAssets.labelFor(hex);
    match.add(AssetPickerItem(
      hex: hex,
      ticker: label.ticker,
      name: label.subtitle,
      pasted: true,
    ));
  }
  return match;
}

/// The Balance tab's visible/hidden split.
class HiddenPartition {
  const HiddenPartition(this.visible, this.hidden);
  final List<String> visible;
  final List<String> hidden;
}

/// Split balance-row asset ids into the visible main list and the collapsed
/// hidden section. Native BTC is never partitioned out. A hidden asset whose
/// total (per [totalOf], on-chain + Lightning) is zero appears in NEITHER: the
/// balance list already elides zero rows, and an invisible zero row has nothing
/// to unhide toward — it returns by itself (still hidden) when it holds a
/// balance again. Hiding is visual decluttering only: the caller computes the
/// headline reference-currency total BEFORE this split, over every asset.
HiddenPartition partitionHidden(
  Iterable<String> ids,
  Set<String> hiddenSet, {
  BigInt Function(String hex)? totalOf,
}) {
  final visible = <String>[];
  final hidden = <String>[];
  for (final h in ids) {
    if (h != kBtcSentinel && hiddenSet.contains(h)) {
      if ((totalOf?.call(h) ?? BigInt.one) > BigInt.zero) hidden.add(h);
    } else {
      visible.add(h);
    }
  }
  return HiddenPartition(visible, hidden);
}
