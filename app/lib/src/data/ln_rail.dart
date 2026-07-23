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
    // Only the wallet's OWN device-provisioned channels (which carry a node_key) count for rail
    // liquidity — never the shared/demo-topology channels /status also returns. Keeps the Swap tab
    // consistent with the Balance tab: a wallet can only pay/receive over Lightning with channels it
    // actually controls (a fresh wallet has none until it Moves funds in). Mirrors ln-rail.js:58.
    if ('${c['node_key'] ?? ''}'.isEmpty) continue;
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

/// The LSP's live JIT-fronting inventory from `/status.frontable` — the twin of ln-rail.js's
/// `frontable` shape. This is what lets a CHANNEL-LESS wallet still trade over Lightning: the LSP
/// opens/fronts the leg just-in-time from this inventory (spec §5). Modelled leg-and-direction-aware:
///   • BTC in_sat  — the LSP can RECEIVE the user's BTC over LN (a PAY-BTC leg).
///   • BTC out_sat — the LSP can DELIVER BTC over LN (a RECEIVE-BTC leg).
///   • assets[hexLower] — the LSP's on-chain inventory of an asset, to fund INBOUND for a RECEIVE leg;
///     ANY asset inventory being present means the LP node is up to service a PAY-asset leg.
class Frontable {
  const Frontable({required this.btcInSat, required this.btcOutSat, required this.assets});
  final BigInt btcInSat;
  final BigInt btcOutSat;
  final Map<String, BigInt> assets; // asset hex (lowercase) -> inventory atoms

  bool get hasAnyAssetInventory => assets.values.any((v) => v > BigInt.zero);

  /// Parse the `frontable` sub-object of a raw `/status` body, or null when absent (then callers must
  /// NOT pessimise — a missing snapshot means "provisionable", never "unfrontable"; see [legOption]).
  static Frontable? fromStatus(Map<String, dynamic> raw) {
    final f = raw['frontable'];
    if (f is! Map) return null;
    final btc = (f['btc'] is Map) ? Map<String, dynamic>.from(f['btc'] as Map) : const <String, dynamic>{};
    final assetsRaw = (f['assets'] is Map) ? Map<String, dynamic>.from(f['assets'] as Map) : const <String, dynamic>{};
    final assets = <String, BigInt>{};
    assetsRaw.forEach((k, v) => assets[k.toLowerCase()] = _big(v));
    return Frontable(btcInSat: _big(btc['in_sat'] ?? btc['inSat']), btcOutSat: _big(btc['out_sat'] ?? btc['outSat']), assets: assets);
  }
}

/// Can the LSP JIT-FRONT [target] in [direction] for a wallet that holds NO channel of its own? Reads
/// the LP's live [frontable] inventory. Any positive amount qualifies (the JIT channel is sized at
/// trade time); we only decide can-it-at-all. Mirrors ln-rail.js `lspCanFront`.
bool lspCanFront(RailTarget target, String direction, Frontable? frontable) {
  if (frontable == null) return false;
  if (target.isBtc) return direction == 'pay' ? frontable.btcInSat > BigInt.zero : frontable.btcOutSat > BigInt.zero;
  if (direction == 'recv') return (frontable.assets[target.hex.toLowerCase()] ?? BigInt.zero) > BigInt.zero;
  return frontable.hasAnyAssetInventory; // pay asset: the LP being up (any inventory) is enough
}

/// The per-leg verdict for offering the Lightning rail.
///   ok            true  -> the leg settles over the wallet's OWN channel (surface the LN button live)
///   reason        human-readable why-not (empty when ok)
///   cta           'move' -> route to Move-to-Lightning (no channel at all); 'add' -> a channel exists
///                 but this side has no room (add / rebalance); null when ok
///   provisionable no own channel, but the LSP CAN front it JIT when the order is placed (near-instant)
///   unfrontable   no own channel AND the LSP has no inventory to front it -> honestly unavailable over LN
class LegOption {
  const LegOption({
    required this.ok,
    required this.reason,
    required this.cta,
    required this.ctaLabel,
    required this.hint,
    required this.liquidity,
    this.provisionable = false,
    this.unfrontable = false,
  });
  final bool ok;
  final String reason;
  final String? cta;
  final String ctaLabel;
  final String hint;
  final LegLiquidity liquidity;
  final bool provisionable;
  final bool unfrontable;
}

/// [direction] is 'pay' (this leg SENDS over Lightning -> needs spendable) or 'recv' (RECEIVES ->
/// needs receivable). [provisioned] is the optional node-state map (assetHexLower ->
/// {connected, phase}); a provisioned-but-channel-less node changes only the wording of the fix.
/// [frontable] is the LSP's live JIT inventory (`/status.frontable`): when present it distinguishes a
/// channel-less leg the LSP CAN front (provisionable, near-instant) from one it CANNOT (unfrontable,
/// honestly unavailable). When absent, a channel-less leg is treated as provisionable (never pessimise
/// on a missing snapshot). A no-own-channel leg is always ok:false — it is not "ready" until the
/// provision/front step runs at placement. Mirrors ln-rail.js `legOption`.
LegOption legOption(List<Map> channels, RailTarget target, String direction,
    [Map<String, dynamic>? provisioned, Frontable? frontable]) {
  final l = legLiquidity(channels, target);
  final name = target.name;
  if (!l.active) {
    final key = target.isBtc ? null : target.hex.toLowerCase();
    final p = key == null ? null : provisioned?[key];
    final nodeUp = p is Map && p['connected'] == true;
    // We have frontable DATA and the LSP genuinely CANNOT front this leg -> honestly unavailable over LN.
    if (frontable != null && !lspCanFront(target, direction, frontable)) {
      return LegOption(
        ok: false,
        unfrontable: true,
        reason: 'Lightning isn\'t available for $name right now.',
        cta: 'move',
        ctaLabel: 'Move $name to Lightning',
        hint: nodeUp
            ? 'Your $name Lightning node is ready. Open a channel from the Balance tab to trade $name over Lightning.'
            : 'The service has no $name Lightning liquidity to front right now — use on-chain, or move $name into a channel from the Balance tab.',
        liquidity: l,
      );
    }
    // Otherwise the leg is PROVISIONABLE: the LSP fronts it JIT when the order is placed (near-instant).
    // Also the safe default when we have NO frontable snapshot (never pessimise on missing data).
    return LegOption(
      ok: false,
      provisionable: true,
      reason: 'No Lightning channel for $name yet.',
      cta: 'move',
      ctaLabel: 'Move $name to Lightning',
      hint: nodeUp
          ? 'Your $name Lightning node is ready — a channel is opened when you place the order.'
          : 'A $name Lightning channel is opened for you when you place the order (near-instant).',
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
  Frontable? frontable,
}) {
  final payLn = legOption(channels, payTarget, 'pay', provisioned, frontable);
  final recvLn = legOption(channels, recvTarget, 'recv', provisioned, frontable);
  return RailAvailability(payLn: payLn, recvLn: recvLn, pureLnOk: payLn.ok && recvLn.ok);
}
