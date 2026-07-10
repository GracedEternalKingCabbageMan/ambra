// Pure-Dart port of the web wallet's ln-rail.js — HONEST per-asset Lightning-rail gating for the
// swap composer. The composer may only OFFER the Lightning settlement rail for a leg when there is a
// REAL, usable channel for THAT asset (or BTC) — never merely because "the LSP is configured". This
// turns a live LSP `/status` snapshot (its per-asset channels, leg-tagged with spendable/receivable)
// plus the provisioned-node state into a per-leg decision (can this leg PAY / RECEIVE over Lightning?
// and if not, WHY + what to do). 100% pure (no IO), so it is unit-testable and the composer just
// reads its verdict. Kept in lockstep with ln-rail.js.

/// A swap leg for rail gating: BTC (the parent chain) or a Sequentia asset (hex id + ticker).
class RailTarget {
  const RailTarget._(this.isBtc, this.hex, this.ticker);
  factory RailTarget.btc() => const RailTarget._(true, '', '');
  factory RailTarget.asset({required String hex, String ticker = ''}) => RailTarget._(false, hex, ticker);
  final bool isBtc;
  final String hex;
  final String ticker;
  String get name => isBtc ? 'BTC' : (ticker.isNotEmpty ? ticker : 'this asset');
}

BigInt _big(Object? v) {
  if (v == null) return BigInt.zero;
  if (v is BigInt) return v;
  if (v is int) return BigInt.from(v);
  final s = '$v';
  return BigInt.tryParse(s) ?? BigInt.from(num.tryParse(s)?.truncate() ?? 0);
}

/// Does channel [c] belong to leg [target]? A channel is BTC-tagged when its asset_label is 'BTC' or
/// it carries a btc leg/chain tag; otherwise it is an asset channel, matched by asset id (hex) OR ticker.
bool channelMatches(Map c, RailTarget target) {
  final isBtc = c['asset_label'] == 'BTC' || c['leg'] == 'btc' || c['chain'] == 'btc';
  if (target.isBtc) return isBtc;
  if (isBtc) return false;
  final hex = target.hex.toLowerCase();
  final tkr = target.ticker.toUpperCase();
  final cHex = '${c['asset'] ?? c['asset_id'] ?? c['channel_asset'] ?? ''}'.toLowerCase();
  final cLbl = '${c['asset_label'] ?? c['ticker'] ?? ''}'.toUpperCase();
  return (hex.isNotEmpty && cHex == hex) || (tkr.isNotEmpty && cLbl == tkr);
}

/// A channel is USABLE for a swap leg only while it is in a normal operating state (CHANNELD_*).
/// An opening/closing/onchain channel carries no live routable liquidity, so it must NOT enable the rail.
bool channelActive(Map c) => '${c['state'] ?? ''}'.toUpperCase().startsWith('CHANNELD');

/// Aggregate liquidity across every ACTIVE channel matching [target].
class LegLiquidity {
  const LegLiquidity({required this.active, required this.spendable, required this.receivable, required this.count});
  final bool active;
  final BigInt spendable;
  final BigInt receivable;
  final int count;
}

LegLiquidity legLiquidity(List<Map> channels, RailTarget target) {
  var active = false;
  var spendable = BigInt.zero;
  var receivable = BigInt.zero;
  var count = 0;
  for (final c in channels) {
    if (!channelMatches(c, target) || !channelActive(c)) continue;
    active = true;
    count++;
    spendable += _big(c['spendable_units'] ?? c['spendable'] ?? 0);
    receivable += _big(c['receivable_units'] ?? c['receivable'] ?? 0);
  }
  return LegLiquidity(active: active, spendable: spendable, receivable: receivable, count: count);
}

bool hasChannel(List<Map> channels, RailTarget t) => legLiquidity(channels, t).active;
bool canPayFrom(List<Map> channels, RailTarget t) {
  final l = legLiquidity(channels, t);
  return l.active && l.spendable > BigInt.zero;
}

bool canReceiveTo(List<Map> channels, RailTarget t) {
  final l = legLiquidity(channels, t);
  return l.active && l.receivable > BigInt.zero;
}

/// The per-leg verdict for offering the Lightning rail.
///   ok       true  -> the leg may settle over Lightning (surface the LN button live)
///   reason   human-readable why-not (empty when ok)
///   cta      'move' -> route to Move-to-Lightning (no channel at all); 'add' -> a channel exists
///            but this side has no room (add / rebalance); null when ok
class LegOption {
  const LegOption({required this.ok, required this.reason, required this.cta, required this.ctaLabel, required this.hint, required this.liquidity});
  final bool ok;
  final String reason;
  final String? cta;
  final String ctaLabel;
  final String hint;
  final LegLiquidity liquidity;
}

/// [direction] is 'pay' (this leg SENDS over Lightning -> needs spendable) or 'recv' (RECEIVES ->
/// needs receivable). [provisioned] is the optional node-state map (assetHexLower ->
/// {connected, phase}); a provisioned-but-channel-less node changes only the wording of the fix.
LegOption legOption(List<Map> channels, RailTarget target, String direction, [Map<String, dynamic>? provisioned]) {
  final l = legLiquidity(channels, target);
  final name = target.name;
  if (!l.active) {
    final key = target.isBtc ? null : target.hex.toLowerCase();
    final p = key == null ? null : provisioned?[key];
    final nodeUp = p is Map && p['connected'] == true;
    return LegOption(
      ok: false,
      reason: 'No Lightning channel for $name yet.',
      cta: 'move',
      ctaLabel: 'Move $name to Lightning',
      hint: nodeUp
          ? 'Your $name Lightning node is ready — open a channel from the Balance tab to trade it instantly.'
          : 'Move $name into a Lightning channel from the Balance tab first, then this rail turns on.',
      liquidity: l,
    );
  }
  final enough = direction == 'pay' ? l.spendable > BigInt.zero : l.receivable > BigInt.zero;
  if (!enough) {
    return direction == 'pay'
        ? LegOption(
            ok: false,
            reason: 'Your $name Lightning channel has no spendable balance to pay from.',
            cta: 'add',
            ctaLabel: 'Add $name to Lightning',
            hint: 'Top up the $name channel from the Balance tab.',
            liquidity: l)
        : LegOption(
            ok: false,
            reason: 'Your $name Lightning channel has no inbound room to receive.',
            cta: 'add',
            ctaLabel: 'Rebalance $name',
            hint: 'Receive to on-chain, or rebalance the $name channel.',
            liquidity: l);
  }
  return LegOption(ok: true, reason: '', cta: null, ctaLabel: '', hint: '', liquidity: l);
}

/// The composite verdict for a BTC<->asset pair: whether EACH leg's LN option is real, and whether
/// the pure-LN (both legs on Lightning) route is genuinely available.
class RailAvailability {
  const RailAvailability({required this.payLn, required this.recvLn, required this.pureLnOk});
  final LegOption payLn;
  final LegOption recvLn;
  final bool pureLnOk;
}

RailAvailability railAvailability({
  required List<Map> channels,
  required RailTarget payTarget,
  required RailTarget recvTarget,
  Map<String, dynamic>? provisioned,
}) {
  final payLn = legOption(channels, payTarget, 'pay', provisioned);
  final recvLn = legOption(channels, recvTarget, 'recv', provisioned);
  return RailAvailability(payLn: payLn, recvLn: recvLn, pureLnOk: payLn.ok && recvLn.ok);
}
