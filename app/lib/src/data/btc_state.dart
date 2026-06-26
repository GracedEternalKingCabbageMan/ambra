import 'package:flutter/foundation.dart';

import '../rust/api.dart' as core;

/// Shared Bitcoin parent-chain state.
///
/// Holds the last scan result and the cross-chain **unified** next-unused receive
/// index. The wallet's single `tb1` address serves both chains, so it cycles past
/// any index used on EITHER Bitcoin or Sequentia — discouraging (not preventing)
/// address reuse. The index is monotonic within a session: it never moves
/// backward, so a manual "New address" or a higher chain index always sticks.
class BtcState extends ChangeNotifier {
  BtcState._();
  static final BtcState instance = BtcState._();

  core.BtcBalance? last;
  int _unifiedNext = 0;
  int get unifiedNext => _unifiedNext;

  /// Record a fresh scan and advance the unified index from both chains:
  /// [btc] (this scan's Bitcoin external next) and [seqNext] (the Sequentia
  /// wallet's next-unused index from `WalletSync.nextIndex`).
  void observe({core.BtcBalance? btc, int? seqNext}) {
    if (btc != null) last = btc;
    final btcNext = btc?.externalNext ?? last?.externalNext ?? 0;
    final candidate = [btcNext, seqNext ?? 0, _unifiedNext].reduce((a, b) => a > b ? a : b);
    final changed = candidate != _unifiedNext || btc != null;
    _unifiedNext = candidate;
    if (changed) notifyListeners();
  }

  /// Bump the unified index forward (e.g. the user requested a new address).
  void bumpTo(int index) {
    if (index > _unifiedNext) {
      _unifiedNext = index;
      notifyListeners();
    }
  }
}
