import 'dart:convert';
import 'dart:math';

import '../rust/api.dart' as core;
import 'config.dart';
import 'seqdex_client.dart';

/// A priced, oriented same-chain swap ready to execute: what the taker pays
/// (assetP/amountP) and receives (assetR/amountR), the fee, and the market/side
/// the daemon needs. Amounts are atoms.
class SwapQuote {
  SwapQuote({
    required this.market,
    required this.side, // 'BUY' | 'SELL'
    required this.assetP,
    required this.amountP,
    required this.assetR,
    required this.amountR,
    required this.feeAsset,
    required this.feeAmount,
    required this.feeRate,
  });
  final Market market;
  final String side;
  final String assetP;
  final BigInt amountP;
  final String assetR;
  final BigInt amountR;
  final String feeAsset;
  final BigInt feeAmount;
  // The fee asset's published exchange rate (atoms of feeAsset per 1e8 native),
  // used only for the dust threshold when funding the fee output.
  final BigInt feeRate;
}

/// Orchestrates a SeqDEX same-chain swap: build the taker SwapRequest (Rust) →
/// propose (daemon) → sign the SwapAccept (Rust: add_details → sign → strip) →
/// complete (daemon), with a self-broadcast fallback if CompleteTrade fails.
class SwapService {
  SwapService._();

  static String _randId() {
    final r = Random.secure();
    return List<int>.generate(8, (_) => r.nextInt(256)).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Execute [q] with the wallet's [mnemonic]; returns the settled txid.
  static Future<String> execute(String mnemonic, SwapQuote q) async {
    final out = await core.seqdexBuildSwapRequest(
      mnemonic: mnemonic,
      esploraUrl: Backend.esplora,
      assetP: q.assetP,
      amountP: q.amountP,
      assetR: q.assetR,
      amountR: q.amountR,
      // The taker funds the network fee itself: lwk adds a fee input + an explicit
      // fee output in feeAsset to the swap PSET. feeRate is only for the dust fold.
      feeAsset: q.feeAsset,
      feeAmount: q.feeAmount,
      feeRate: q.feeRate,
    );
    final swapReq = jsonDecode(out.swapRequestJson) as Map<String, dynamic>;
    // The network fee now lives in the PSET (taker-funded); the wire fee_amount is
    // the market COMMISSION channel only — send 0 so the daemon doesn't double the
    // fee or shift the maker's receive amount.
    final accept = await SeqdexClient.propose(q.market, q.side, swapReq, BigInt.zero, q.feeAsset);
    final stripped = await core.seqdexSignAccept(mnemonic: mnemonic, esploraUrl: Backend.esplora, acceptPset: accept.transaction);
    try {
      return await SeqdexClient.complete(_randId(), accept.id, stripped);
    } catch (_) {
      // Daemon couldn't finalize/relay; the stripped PSET keeps both parties'
      // signatures, so we can finalize + broadcast it ourselves.
      return await core.finalizeAndBroadcast(mnemonic: mnemonic, esploraUrl: Backend.esplora, pset: stripped);
    }
  }
}
