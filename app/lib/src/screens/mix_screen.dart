import 'package:flutter/material.dart';

import '../data/coinjoin_protocol.dart';
import '../data/coinjoin_service.dart';
import '../data/config.dart';
import '../data/format.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// Mix — one round of a seqcj CoinJoin.
///
/// The screen says exactly what a round buys and no more. On Sequentia the outputs are
/// confidential, so the chain sees a transaction without amounts in it and the change is
/// blinded like everything else; what the blind signatures buy is that the coordinator
/// cannot link the coins going in to the mixed coins coming out. It still sees the amounts
/// and the change, and this phone still connects from one address — which is said here
/// rather than left for a user to discover.
class MixScreen extends StatefulWidget {
  const MixScreen({super.key});
  @override
  State<MixScreen> createState() => _MixScreenState();
}

class _MixScreenState extends State<MixScreen> {
  List<CoinjoinLane>? _lanes;
  CoinjoinLane? _lane;
  int _count = 1;
  bool _busy = false;
  String? _error;
  String? _phase;
  RoundResult? _done;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _lanes = null;
      _error = null;
    });
    try {
      final lanes = await CoinjoinService.instance.availableLanes();
      if (!mounted) return;
      setState(() {
        _lanes = lanes;
        _lane = lanes.isEmpty ? null : lanes.first;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lanes = const [];
        _error = 'Could not reach the mixing coordinator: $e';
      });
    }
  }

  String _ticker(String asset) => SeqAssets.labelFor(asset).ticker;
  int _precision(String asset) => SeqAssets.labelFor(asset).precision;

  Future<void> _run() async {
    final lane = _lane;
    if (lane == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
      _phase = 'starting';
    });
    try {
      final res = await CoinjoinService.instance.mix(
        assetId: lane.asset,
        denominations: _count,
        onStatus: (phase, detail) {
          if (mounted) setState(() => _phase = phase);
        },
      );
      if (!mounted) return;
      setState(() {
        _done = res;
        _busy = false;
        _phase = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _phase = null;
        _error = '$e'.replaceFirst('Bad state: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final lanes = _lanes;
    final lane = _lane;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Mix', style: AmbraText.title),
      ),
      body: AmbraBackground(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
          const AmbraCard(
            child: Text(
              'A mix joins your coins with other people\'s in one transaction. On Sequentia the '
              'amounts are confidential, so the chain sees a transaction and not what moved in it, '
              'and your change is hidden exactly like your mixed coins.',
              style: AmbraText.muted,
            ),
          ),
          const SizedBox(height: 12),
          const WarnCallout(
            'What this does not do: the coordinator still sees your amounts and your change, and '
            'this phone connects from one address, which hands it back the link the mix removed. '
            'Your anonymity set is the round — two participants means two. For a serious mix, use '
            'Seqognito over Tor.',
          ),
          const SizedBox(height: 18),
          if (lanes == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)),
            )
          else if (lanes.isEmpty)
            const AmbraCard(
              child: Text('No round is open right now. A mix needs other participants; try again shortly.',
                  style: AmbraText.sub),
            )
          else ...[
            const SectionLabel('Round'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AmbraColors.panelDeep,
                border: Border.all(color: AmbraColors.line),
                borderRadius: BorderRadius.circular(AmbraRadii.input),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<CoinjoinLane>(
                  value: lane,
                  isExpanded: true,
                  dropdownColor: AmbraColors.panel,
                  iconEnabledColor: AmbraColors.dim,
                  style: const TextStyle(color: AmbraColors.txt, fontSize: 15, fontWeight: FontWeight.w600),
                  items: [
                    for (final l in lanes)
                      DropdownMenuItem(
                        value: l,
                        child: Text('${_ticker(l.asset)} · '
                            '${formatAtoms('${l.denom}', _precision(l.asset))} per denomination'),
                      )
                  ],
                  onChanged: _busy ? null : (v) => setState(() => _lane = v),
                ),
              ),
            ),
            if (lane != null) ...[
              const SizedBox(height: 14),
              AmbraCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _kv('Denomination',
                      '${formatAtoms('${lane.denom}', _precision(lane.asset))} ${_ticker(lane.asset)}'),
                  _kv('Coordinator fee',
                      '${formatAtoms('${lane.coordFee}', _precision(lane.asset))} ${_ticker(lane.asset)}'),
                  _kv('Participants',
                      lane.waiting ? 'waiting for more' : '${lane.participants} of ${lane.minParticipants} needed'),
                  _kv('Most you can mix', '${lane.maxCredentials} denominations'),
                ]),
              ),
              const SizedBox(height: 14),
              const SectionLabel('How many denominations'),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Slider(
                    value: _count.toDouble().clamp(1, lane.maxCredentials.toDouble()),
                    min: 1,
                    max: lane.maxCredentials.toDouble(),
                    divisions: lane.maxCredentials > 1 ? lane.maxCredentials - 1 : null,
                    activeColor: AmbraColors.amber,
                    label: '$_count',
                    onChanged: _busy ? null : (v) => setState(() => _count = v.round()),
                  ),
                ),
                SizedBox(
                  width: 120,
                  child: Text(
                    '${formatAtoms('${lane.perDenomination * BigInt.from(_count)}', _precision(lane.asset))} '
                    '${_ticker(lane.asset)}',
                    textAlign: TextAlign.right,
                    style: AmbraText.mono,
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Text(
                'You need that much in TRANSPARENT coins of ${_ticker(lane.asset)}. Confidential coins '
                'cannot join a round: blinding it would need their blinding factors, and handing those '
                'over would undo the privacy of every transaction those coins have ever been in.',
                style: AmbraText.sub,
              ),
              const SizedBox(height: 18),
              PrimaryButton(
                label: _busy ? (_phase ?? 'Mixing…') : 'Mix',
                icon: Icons.shuffle,
                busy: _busy,
                onPressed: _busy ? null : _run,
              ),
            ],
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: const TextStyle(color: AmbraColors.red)),
          ],
          if (_done != null) ...[
            const SizedBox(height: 20),
            AmbraCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('Mixed'),
                const SizedBox(height: 10),
                _kv('Denominations', '${_done!.denominations}'),
                _kv('Transaction', _done!.txid),
                const SizedBox(height: 8),
                const Text(
                  'Your mixed coins are in fresh confidential addresses of this wallet. They spend '
                  'like any other coins — but spending them together, or straight back into one '
                  'address, undoes what the round bought.',
                  style: AmbraText.sub,
                ),
              ]),
            ),
          ],
          const SizedBox(height: 20),
          SecondaryButton(label: 'Refresh rounds', icon: Icons.refresh, onPressed: _busy ? null : _load),
        ]),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 150, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, style: AmbraText.mono, textAlign: TextAlign.right)),
        ]),
      );
}
