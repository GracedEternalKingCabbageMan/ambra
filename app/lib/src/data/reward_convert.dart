import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api/rewards.dart' as rust;
import 'swap_route.dart' show kBtcSentinel;

/// STAKING REWARD AUTO-CONVERSION — the phone's engine.
///
/// A staker is paid the transaction fees of the blocks it earns from, and under
/// the open fee market those arrive in whichever assets the payers chose. The
/// result is a long tail of small balances in assets nobody chose to hold. This
/// converts that tail into ONE asset the staker picked — native Bitcoin by
/// default and first in the picker, but not the only choice, because outside
/// staking no asset is privileged.
///
/// The two decisions that must not differ between wallets — which coins are
/// rewards, and which of them to sell — are NOT made here. Both come from the
/// kit through [rust], which is the same code the node's wallet, the web wallet
/// and the browser extension use. A phone that disagreed with a desktop about
/// which of a staker's coins were rewards would be a phone that sold the wrong
/// ones.
///
/// The specification is `doc/sequentia/reward-autoconvert-design.md` in the node
/// repo.
///
/// Settings and the conversion ledger are persisted in SharedPreferences, keyed
/// PER WALLET by a mnemonic fingerprint (the same idiom as [HiddenAssets]):
/// remove-and-recover of a different wallet must not inherit this one's
/// instruction to sell.
class RewardConvert extends ChangeNotifier {
  RewardConvert();
  static final RewardConvert instance = RewardConvert();

  static const _settingsPrefix = 'ambra.rewardConvert.';
  static const _ledgerPrefix = 'ambra.rewardConversions.';

  /// Native parent-chain BTC has no asset id, so it needs a sentinel. Never
  /// SBTC: a staker who asks for Bitcoin gets Bitcoin.
  static const btc = kBtcSentinel;

  String? _fp;

  // Off by default, always: converting rewards is irreversible and the staker
  // may have chosen those assets deliberately.
  bool enabled = false;
  String target = kBtcSentinel;
  List<String> exclude = <String>[];
  BigInt minReceive = BigInt.from(10000); // 0.0001 BTC, in the target's atoms
  int maxSlippageBp = 200;

  List<Map<String, dynamic>> _ledger = <Map<String, dynamic>>[];

  String _fingerprint(String mnemonic) =>
      sha256.convert(utf8.encode(mnemonic.trim())).toString().substring(0, 16);

  Future<void> loadFor(String mnemonic) async {
    _fp = _fingerprint(mnemonic);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_settingsPrefix$_fp');
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        enabled = m['enabled'] == true;
        target = (m['target'] as String?) ?? kBtcSentinel;
        exclude = ((m['exclude'] as List?) ?? const []).cast<String>().toList();
        minReceive = BigInt.parse((m['minReceive'] as String?) ?? '10000');
        maxSlippageBp = (m['maxSlippageBp'] as num?)?.toInt() ?? 200;
      } catch (_) {
        // A settings blob we cannot read is a settings blob we do not act on.
        enabled = false;
      }
    }
    final led = prefs.getString('$_ledgerPrefix$_fp');
    if (led != null) {
      try {
        _ledger = (jsonDecode(led) as List).cast<Map<String, dynamic>>();
      } catch (_) {
        _ledger = <Map<String, dynamic>>[];
      }
    }
    notifyListeners();
  }

  Future<void> save() async {
    if (_fp == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_settingsPrefix$_fp',
      jsonEncode(<String, dynamic>{
        'enabled': enabled,
        'target': target,
        'exclude': exclude,
        'minReceive': minReceive.toString(),
        'maxSlippageBp': maxSlippageBp,
      }),
    );
    notifyListeners();
  }

  List<Map<String, dynamic>> get conversions => List.unmodifiable(_ledger);

  /// Outpoints already committed to a conversion, pending or done.
  ///
  /// BOTH states hold their coins. Only a DEFINITE refusal releases them: an
  /// executor that threw may have paid before it threw, and releasing there is
  /// how a wallet sells the same reward twice.
  List<String> get convertedOutpoints => <String>[
        for (final c in _ledger)
          if (c['state'] == 'pending' || c['state'] == 'done')
            ...((c['inputs'] as List?) ?? const []).cast<String>(),
      ];

  Future<void> _writeLedger() async {
    if (_fp == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (_ledger.length > 200) {
      _ledger = _ledger.sublist(0, 200);
    }
    await prefs.setString('$_ledgerPrefix$_fp', jsonEncode(_ledger));
    notifyListeners();
  }

  String _settingsJson() => jsonEncode(<String, dynamic>{
        'enabled': enabled,
        // Native BTC is how the kit spells "no asset id".
        'target': target == kBtcSentinel ? null : target,
        'exclude': exclude,
        'minReceive': minReceive.toInt(),
        'maxSlippageBp': maxSlippageBp,
      });

  /// Every staking reward this wallet holds, as the kit attributes them.
  Future<List<Map<String, dynamic>>> attribute({
    required List<Map<String, dynamic>> walletTxs,
    required List<Map<String, dynamic>> stakingKeys,
    required int tipHeight,
  }) async {
    final json = await rust.attributeStakingRewards(
      txsJson: jsonEncode(walletTxs),
      stakingKeysJson: jsonEncode(stakingKeys),
      tipHeight: tipHeight,
      coinbaseMaturity: 100,
    );
    return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
  }

  /// One pass: batch what is convertible, quote it, take the kit's verdict, and
  /// dispatch what converts.
  ///
  /// With [dryRun] nothing is spent and nothing is recorded: the answer is what
  /// the wallet WOULD do, which is what the Stake screen shows.
  ///
  /// [quoteFor] returns `null` when there is no market for the pair — a WAIT,
  /// never an error. [execute] returns a txid on success; it must THROW when it
  /// cannot tell whether the sale happened, because a throw is what keeps the
  /// coins claimed.
  Future<RewardPassReport> runPass({
    required List<Map<String, dynamic>> rewards,
    required Future<Map<String, int>?> Function(String asset, BigInt atoms, String target) quoteFor,
    required Future<String?> Function(String asset, BigInt atoms, String target) execute,
    bool dryRun = false,
  }) async {
    final report = RewardPassReport();
    if (!enabled && !dryRun) return report;

    final batchesJson = await rust.planRewardBatches(
      rewardsJson: jsonEncode(rewards),
      settingsJson: _settingsJson(),
      alreadyConvertedJson: jsonEncode(convertedOutpoints),
    );
    final batches = (jsonDecode(batchesJson) as List).cast<Map<String, dynamic>>();
    report.ran = true;

    for (final batch in batches) {
      final asset = batch['asset'] as String;
      final value = BigInt.from((batch['value'] as num).toInt());

      Map<String, int>? quote;
      try {
        quote = await quoteFor(asset, value, target);
      } catch (e) {
        // A book we could not READ is not a book that said no.
        quote = null;
        report.errors.add('$asset: $e');
      }

      final decisionJson = await rust.decideRewardConversion(
        batchJson: jsonEncode(batch),
        quoteJson: quote == null ? 'null' : jsonEncode(quote),
        settingsJson: _settingsJson(),
      );
      final decision = jsonDecode(decisionJson) as Map<String, dynamic>;
      report.considered.add(RewardPassRow(batch: batch, quote: quote, decision: decision));
      if (decision['converts'] != true || dryRun) continue;

      // Commit to the coins BEFORE spending them.
      final id = '$asset:${((batch['inputs'] as List?) ?? const []).join(',')}';
      _ledger.insert(0, <String, dynamic>{
        'id': id,
        'state': 'pending',
        'at': DateTime.now().millisecondsSinceEpoch,
        'asset': asset,
        'value': value.toString(),
        'target': target,
        'inputs': ((batch['inputs'] as List?) ?? const []).cast<String>(),
      });
      await _writeLedger();

      try {
        final txid = await execute(asset, value, target);
        final i = _ledger.indexWhere((c) => c['id'] == id);
        if (txid != null) {
          if (i >= 0) _ledger[i] = {..._ledger[i], 'state': 'done', 'txid': txid};
          report.converted.add(asset);
        } else {
          // A definite refusal: the sale did not happen, so release the coins.
          if (i >= 0) _ledger[i] = {..._ledger[i], 'state': 'failed', 'error': 'no fill'};
          report.errors.add('$asset: nothing filled');
        }
        await _writeLedger();
      } catch (e) {
        // NOT a definite refusal. The record stays pending, so those coins are
        // never offered again and a human sees it stuck rather than the wallet
        // quietly double-selling.
        final i = _ledger.indexWhere((c) => c['id'] == id);
        if (i >= 0) _ledger[i] = {..._ledger[i], 'error': '$e'};
        await _writeLedger();
        report.errors.add('$asset: $e');
      }
    }
    return report;
  }

  /// How much of a batch a WHOLE-HTLC offer may take.
  ///
  /// The cross-chain rail rests whole offers and the one picked is the smallest
  /// that COVERS the request, which can be far larger than the batch. Taking it
  /// whole would sell coins staking never paid; selling less is normal, and the
  /// remainder waits. Zero means "no fill", never "take everything".
  static BigInt sliceForWholeHtlc(BigInt offerAtoms, BigInt batchAtoms) {
    if (offerAtoms <= BigInt.zero || batchAtoms <= BigInt.zero) return BigInt.zero;
    return offerAtoms < batchAtoms ? offerAtoms : batchAtoms;
  }
}

class RewardPassRow {
  RewardPassRow({required this.batch, required this.quote, required this.decision});
  final Map<String, dynamic> batch;
  final Map<String, int>? quote;
  final Map<String, dynamic> decision;

  bool get converts => decision['converts'] == true;
  String get reason => (decision['reason'] as String?) ?? '';
  String get asset => batch['asset'] as String;
  BigInt get value => BigInt.from((batch['value'] as num).toInt());
}

class RewardPassReport {
  bool ran = false;
  final List<RewardPassRow> considered = <RewardPassRow>[];
  final List<String> converted = <String>[];
  final List<String> errors = <String>[];
}

/// Per asset: what is spendable now, what is still maturing, and from where.
List<Map<String, dynamic>> rewardTotals(List<Map<String, dynamic>> rewards) {
  final by = <String, Map<String, dynamic>>{};
  for (final r in rewards) {
    final asset = r['asset'] as String;
    final t = by.putIfAbsent(
      asset,
      () => <String, dynamic>{
        'asset': asset,
        'mature': BigInt.zero,
        'immature': BigInt.zero,
        'outputs': 0,
        'sources': <String, int>{},
      },
    );
    t['outputs'] = (t['outputs'] as int) + 1;
    final src = (r['source'] as String?) ?? 'solo';
    final sources = t['sources'] as Map<String, int>;
    sources[src] = (sources[src] ?? 0) + 1;
    if (r['spent'] == true) continue;
    final v = BigInt.from((r['value'] as num).toInt());
    if (r['mature'] == true) {
      t['mature'] = (t['mature'] as BigInt) + v;
    } else {
      t['immature'] = (t['immature'] as BigInt) + v;
    }
  }
  return by.values.toList();
}
