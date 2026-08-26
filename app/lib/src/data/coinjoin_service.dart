/// The wallet's side of a seqcj CoinJoin round: choose coins, prove they are ours, hand
/// out fresh blinded addresses, and — the step everything else exists to protect — VERIFY
/// the coordinator's transaction before signing it. The round protocol itself is in
/// `coinjoin_protocol.dart`, ported from the module the browser wallet vendors.
///
/// WHY MIXING IS DIFFERENT HERE. On Bitcoin a CoinJoin must use equal, public
/// denominations, and the change output stays a permanent tag linking the mix back to you.
/// Sequentia has Confidential Transactions, so the round's outputs are commitments: the
/// chain sees a transaction and not one amount in it, and your change is blinded exactly
/// like your mixed coins.
///
/// WHAT IT BUYS, PLAINLY — the screen says the same and should never say more:
///   * the chain learns nothing about the amounts, yours or anyone's;
///   * the coordinator cannot link your inputs to your MIXED outputs. That is what the
///     blind signatures buy, and it is all they buy;
///   * the coordinator DOES see your amounts and your change. It is not a stranger to you;
///   * this phone does not hide its IP. Registering inputs and outputs over one connection
///     hands the coordinator the link the blind signature just removed. A serious mix needs
///     Tor, which this app does not arrange — Seqognito, the desktop client, does;
///   * your anonymity set is the round. Two participants means two.
///
/// FUND SAFETY. Nothing here can lose coins. The only irreversible act is a signature, and
/// it is produced solely by the verify-and-sign hook, which unblinds the transaction with
/// this wallet's own blinding key and throws unless the outputs paying us are exactly the
/// ones the round owed. A round we refuse simply never completes; the coins were never
/// spent.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import 'btc_state.dart';
import 'config.dart';
import 'coinjoin_protocol.dart';
import 'wallet_repository.dart';

class CoinjoinLane {
  const CoinjoinLane({
    required this.roundId,
    required this.index,
    required this.asset,
    required this.label,
    required this.denom,
    required this.coordFee,
    required this.maxCredentials,
    required this.participants,
    required this.minParticipants,
    required this.waiting,
  });
  final String roundId;
  final int index;
  final String asset;
  final String label;
  final BigInt denom;
  final BigInt coordFee;
  final int maxCredentials;
  final int participants;
  final int minParticipants;
  final bool waiting;

  /// What one denomination costs to mix, all in.
  BigInt get perDenomination => denom + coordFee;
}

class CoinjoinService {
  CoinjoinService._();
  static final instance = CoinjoinService._();

  String get base => Backend.coinjoin;

  Future<Map<String, dynamic>> _api(String path, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('$base$path');
    final res = body == null
        ? await http.get(uri, headers: {'cache-control': 'no-store'})
        : await http.post(uri,
            headers: {'content-type': 'application/json', 'cache-control': 'no-store'},
            body: jsonEncode(body));
    Map<String, dynamic> j;
    try {
      j = res.body.isEmpty ? <String, dynamic>{} : (jsonDecode(res.body) as Map).cast<String, dynamic>();
    } catch (_) {
      j = {'ok': false, 'error': res.body.isEmpty ? 'empty response' : res.body};
    }
    if (res.statusCode >= 400 || j['ok'] == false) {
      throw StateError('${j['error'] ?? 'coordinator HTTP ${res.statusCode}'}');
    }
    return j;
  }

  /// Which assets can be mixed right now, and on what terms. The screen offers exactly
  /// this and nothing else — an asset with no open lane cannot be mixed however much of it
  /// is held.
  Future<List<CoinjoinLane>> availableLanes() async {
    final rounds = ((await _api('/rounds'))['rounds'] as List?) ?? const [];
    final out = <CoinjoinLane>[];
    for (final r in rounds) {
      if (r['phase'] != 'input') continue;
      for (final lane in (r['lanes'] as List? ?? const [])) {
        out.add(CoinjoinLane(
          roundId: '${r['round_id']}',
          index: (lane['index'] as num).toInt(),
          asset: '${lane['asset']}',
          label: '${lane['label']}',
          denom: BigInt.parse('${lane['denom_atoms']}'),
          coordFee: BigInt.parse('${lane['coord_fee_atoms'] ?? '0'}'),
          maxCredentials: (r['max_credentials'] as num).toInt(),
          participants: (r['participants'] as num?)?.toInt() ?? 0,
          minParticipants: (r['min_participants'] as num?)?.toInt() ?? 0,
          waiting: r['waiting_for_participants'] == true,
        ));
      }
    }
    return out;
  }

  /// Run one round for [assetId], mixing [denominations] denominations.
  Future<RoundResult> mix({
    required String assetId,
    int denominations = 1,
    OnStatus? onStatus,
  }) async {
    final mnemonic = await WalletRepository.instance.readMnemonic();
    if (mnemonic == null) throw StateError('open your wallet first');

    // The coins we registered, kept for the signing step: the round must contain all of
    // them, and we sign nothing else.
    List<CoinjoinCoin> chosen = const [];
    final mixScripts = <String>[];
    String? changeScript;

    Future<String> scriptOf(String address) async =>
        (await core.addressScriptPubkey(address: address)).toLowerCase();

    return runRound(
      assetId: assetId,
      maxCredentials: denominations,
      onStatus: onStatus,
      fetchJson: _api,
      selectInputs: ({required asset, required denom, required coordFee, required maxCredentials}) async {
        final want = BigInt.from(maxCredentials) * (denom + coordFee);
        final all = await core.coinjoinUtxos(mnemonic: mnemonic, esploraUrl: Backend.esplora);
        final cands = all.where((u) => u.asset == asset).toList()
          ..sort((a, b) => BigInt.parse(b.atoms).compareTo(BigInt.parse(a.atoms)));
        final picked = <CoinjoinCoin>[];
        var sum = BigInt.zero;
        for (final u in cands) {
          if (sum >= want) break;
          picked.add(CoinjoinCoin(
            txid: u.txid,
            vout: u.vout,
            atoms: BigInt.parse(u.atoms),
            asset: u.asset,
            spkHex: u.spkHex,
            chain: u.chain,
            index: u.index,
          ));
          sum += BigInt.parse(u.atoms);
        }
        if (sum < denom + coordFee) {
          throw StateError('not enough transparent balance to mix one denomination '
              '(need ${denom + coordFee} atoms, have $sum)');
        }
        chosen = picked;
        return picked;
      },
      proveOwnership: (message, coin) async {
        final p = await core.coinjoinProveOwnership(
            mnemonic: mnemonic, message: message, chain: coin.chain, index: coin.index);
        return OwnershipSig(p.pubkey, p.sig);
      },
      // A CONFIDENTIAL address, freshly derived and never reused: the round's privacy
      // depends on these having existed nowhere before the output phase.
      freshAddress: () async {
        final info = await core.receiveAddressAt(
            mnemonic: mnemonic, index: await _nextFreshIndex(), confidential: true);
        return info.address;
      },
      // The gate. Unblind with our own key, check, and only then sign — and sign only our
      // own inputs, matched by outpoint, so the coordinator's shuffling cannot redirect a
      // signature onto a coin we did not choose.
      verifyAndSign: (txHex, ctx) async {
        for (final a in ctx.mixAddresses) {
          mixScripts.add(await scriptOf(a));
        }
        changeScript = ctx.changeAddress == null ? null : await scriptOf(ctx.changeAddress!);
        final mine = await core.coinjoinUnblindOutputs(mnemonic: mnemonic, txHex: txHex);
        verifyRoundOutputs(
          mine: [
            for (final o in mine)
              MineOutput(scriptPubkey: o.scriptPubkey, asset: o.asset, value: BigInt.parse(o.value))
          ],
          mixScripts: mixScripts,
          changeScript: changeScript,
          denom: ctx.denom,
          change: ctx.change,
          asset: '${ctx.lane['asset']}',
        );
        // Our coins must all be in the round, or this is not the round we registered for.
        final present = await core.coinjoinTxOutpoints(txHex: txHex);
        for (final u in chosen) {
          if (!present.contains('${u.txid}:${u.vout}')) {
            throw StateError('a coin I registered is missing from the round; refusing to sign');
          }
        }
        onStatus?.call('signing', {'outputs': mine.length});
        return core.coinjoinSignInputs(
          mnemonic: mnemonic,
          txHex: txHex,
          inputs: [
            for (final u in chosen)
              core.CoinjoinSignInput(
                txid: u.txid,
                vout: u.vout,
                value: u.atoms.toString(),
                spkHex: u.spkHex,
                chain: u.chain,
                index: u.index,
              )
          ],
        );
      },
    );
  }

  // Fresh receive indices for the round's addresses. The base is the wallet's own
  // next-unused index (shared across both chains, as everywhere else), and each draw
  // advances — two addresses in one round are never the same one, and none of them existed
  // before the output phase.
  int _fresh = 0;
  Future<int> _nextFreshIndex() async => BtcState.instance.unifiedNext + (_fresh++);
}
