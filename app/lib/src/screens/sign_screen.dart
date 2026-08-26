import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../data/openamp_service.dart';
import '../data/wallet_repository.dart';
import '../rust/api.dart' as core;
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// A neutral, two-mode OpenAMP TAGGED sign card. It signs a wallet-link/login
/// challenge (`openamp-challenge-v1`) or a document hash (`openamp-document-v1`)
/// with the on-device m/5/0 key. There is deliberately NO raw-digest / enclave-
/// spend mode: both paths tag their input before signing (see
/// [openampSignChallenge] / [openampSignDocument]), so this screen structurally
/// cannot authorize a transfer or move funds.
///
/// Reached from the More tab and from the `ambra://oamp-sign` deep link. When a
/// deep link supplies a [callback], the requesting origin is shown up front and
/// nothing is ever POSTed until the user presses `Send to <origin>` (consent-
/// gated transport).
class SignScreen extends StatefulWidget {
  const SignScreen({
    super.key,
    this.initialMode = SignMode.challenge,
    this.initialChallenge = '',
    this.initialDocHash = '',
    this.callback,
    this.label,
  });

  final SignMode initialMode;
  final String initialChallenge;
  final String initialDocHash;

  /// Optional requester callback URL (from a deep link). Its origin is disclosed;
  /// the signature is only sent here on an explicit, separate confirmation.
  final String? callback;

  /// Optional human label describing the request (from a deep link).
  final String? label;

  @override
  State<SignScreen> createState() => _SignScreenState();
}

enum SignMode { challenge, document }

class _SignScreenState extends State<SignScreen> {
  late SignMode _mode;
  final _challenge = TextEditingController();
  final _docHash = TextEditingController();

  bool _busy = false;
  String? _error;

  // Result of a successful local sign.
  String? _sig;
  String? _xonly;
  String? _aid;

  // Callback POST state.
  bool _sending = false;
  String? _sendMsg;
  bool _sendOk = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _challenge.text = widget.initialChallenge;
    _docHash.text = widget.initialDocHash;
  }

  @override
  void dispose() {
    _challenge.dispose();
    _docHash.dispose();
    super.dispose();
  }

  String _origin(String url) {
    try {
      final u = Uri.parse(url);
      return u.hasAuthority ? '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}' : url;
    } catch (_) {
      return url;
    }
  }

  Future<void> _sign() async {
    setState(() {
      _busy = true;
      _error = null;
      _sig = null;
    });
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('open your wallet first');
      final String sig;
      if (_mode == SignMode.challenge) {
        final c = _challenge.text;
        if (c.trim().isEmpty) throw Exception('enter the challenge text');
        // Tagged "openamp-challenge-v1" over the UTF-8 string — never a raw digest.
        sig = openampSignChallenge(mnemonic: m, challenge: c);
      } else {
        // Tagged "openamp-document-v1" over the 32 raw bytes of the 64-hex hash.
        sig = openampSignDocument(mnemonic: m, docHash: _docHash.text);
      }
      // Derive fresh (a local operation): signing here must work even if server
      // registration failed, so we don't depend on the cached AID/xonly.
      final xonly = core.openampXonlyPubkey(mnemonic: m);
      final aid = core.openampComputeAid(pubkeys: [xonly]);
      if (!mounted) return;
      setState(() {
        _sig = sig;
        _xonly = xonly;
        _aid = aid;
        _busy = false;
        _sendMsg = null;
        _sendOk = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _sendToCallback() async {
    final cb = widget.callback;
    final sig = _sig;
    if (cb == null || sig == null) return;
    setState(() {
      _sending = true;
      _sendMsg = null;
    });
    try {
      final body = jsonEncode({
        'mode': _mode == SignMode.challenge ? 'challenge' : 'document',
        if (_mode == SignMode.challenge) 'challenge': _challenge.text,
        if (_mode == SignMode.document) 'doc_hash': _docHash.text.trim().toLowerCase(),
        'signature': sig,
        'pubkey': _xonly,
        'aid': _aid,
      });
      final r = await http
          .post(Uri.parse(cb), headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 25));
      if (!mounted) return;
      final ok = r.statusCode >= 200 && r.statusCode < 300;
      setState(() {
        _sending = false;
        _sendOk = ok;
        _sendMsg = ok
            ? 'Sent to ${_origin(cb)}.'
            : 'The requester responded with HTTP ${r.statusCode}.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendOk = false;
        _sendMsg = 'Send failed: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  void _copy(String value, String note) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(ambraSnack(note));
  }

  @override
  Widget build(BuildContext context) {
    final cb = widget.callback;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Sign a request', style: AmbraText.title),
      ),
      body: AmbraBackground(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
          const AmbraCard(
            child: Text(
              'Sign a tagged, non-spending request with your account id (AID): a wallet-link or '
              'login challenge, or a document hash. This can never move funds or authorize a transfer.',
              style: AmbraText.muted,
            ),
          ),
          if (cb != null) ...[
            const SizedBox(height: 12),
            WarnCallout(
              '${_origin(cb)} is requesting this signature. Review it below; nothing is sent until '
              'you press Send after signing.',
            ),
          ],
          if (widget.label != null && widget.label!.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(widget.label!, style: AmbraText.sub),
          ],
          const SizedBox(height: 16),
          const SectionLabel('What are you signing'),
          const SizedBox(height: 8),
          _ModeToggle(mode: _mode, onChanged: (m) => setState(() => _mode = m)),
          const SizedBox(height: 16),
          if (_mode == SignMode.challenge)
            AmbraField(
              label: 'Challenge string',
              controller: _challenge,
              hint: 'the challenge text you were given',
              maxLines: 3,
            )
          else
            AmbraField(
              label: 'Document hash (32 bytes, 64-hex)',
              controller: _docHash,
              hint: '64-hex sha256 of the document',
              mono: true,
            ),
          const SizedBox(height: 18),
          PrimaryButton(label: 'Sign', icon: Icons.draw, busy: _busy, onPressed: _busy ? null : _sign),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: AmbraColors.red)),
          ],
          if (_sig != null) ...[
            const SizedBox(height: 20),
            _ResultBlock(label: 'Signature', value: _sig!, onCopy: () => _copy(_sig!, 'Signature copied')),
            const SizedBox(height: 14),
            _ResultBlock(label: 'Your x-only pubkey', value: _xonly ?? '—'),
            const SizedBox(height: 14),
            _ResultBlock(label: 'Your account id (AID)', value: _aid ?? '—'),
            if (cb != null) ...[
              const SizedBox(height: 18),
              PrimaryButton(
                label: 'Send to ${_origin(cb)}',
                icon: Icons.north_east,
                busy: _sending,
                onPressed: _sending ? null : _sendToCallback,
              ),
            ],
            if (_sendMsg != null) ...[
              const SizedBox(height: 10),
              Text(_sendMsg!, style: TextStyle(color: _sendOk ? AmbraColors.green : AmbraColors.red)),
            ],
          ],
          const SizedBox(height: 26),
          const ClassicSignCard(),
        ]),
      ),
    );
  }
}


/// The classic, key-derived signature — the counterpart to the tagged OpenAMP
/// one above. It proves control of an ADDRESS rather than of an enclave account
/// id, and anyone can check it with a node: `verifymessage`, on Sequentia or on
/// Bitcoin, with nothing to look up. Like the OpenAMP card it cannot move funds.
///
/// Verification is offered against the LEGACY form of the address, because a
/// node takes a PKHash destination there and rejects bech32 whatever key stands
/// behind it. The signing key is the one behind the address the Receive screen
/// hands out at the same index, so an address someone was given is an address
/// they can sign with.
class ClassicSignCard extends StatefulWidget {
  const ClassicSignCard({super.key});
  @override
  State<ClassicSignCard> createState() => _ClassicSignCardState();
}

class _ClassicSignCardState extends State<ClassicSignCard> {
  final _message = TextEditingController();
  final _index = TextEditingController(text: '0');
  bool _busy = false;
  String? _error;
  String? _address;        // the tb1 address at this index, shown before signing
  core.SignedMessage? _out;

  @override
  void initState() {
    super.initState();
    _index.addListener(_loadAddress);
    _loadAddress();
  }

  @override
  void dispose() {
    _message.dispose();
    _index.dispose();
    super.dispose();
  }

  int get _idx {
    final v = int.tryParse(_index.text.trim());
    return (v == null || v < 0) ? 0 : v;
  }

  Future<void> _loadAddress() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      final info = await core.receiveAddressAt(mnemonic: m, index: _idx, confidential: false);
      if (mounted) setState(() => _address = info.address);
    } catch (_) {
      if (mounted) setState(() => _address = null);
    }
  }

  Future<void> _sign() async {
    setState(() {
      _busy = true;
      _error = null;
      _out = null;
    });
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('open your wallet first');
      if (_message.text.isEmpty) throw Exception('enter the message you want to sign');
      final out = await core.signMessageClassic(mnemonic: m, index: _idx, message: _message.text);
      if (!mounted) return;
      setState(() {
        _out = out;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _copy(String text, String msg) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final out = _out;
    return AmbraCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionLabel('Sign a message with your wallet key'),
        const SizedBox(height: 10),
        const Text(
          'The classic signature: made with the private key behind one of your own addresses, and '
          'checkable by anyone running a node — verifymessage, on Sequentia or on Bitcoin, with '
          'nothing to look up and no account id involved. Use it to prove an address is yours. '
          'Like the signature above it cannot move funds.',
          style: AmbraText.muted,
        ),
        const SizedBox(height: 16),
        AmbraField(label: 'Message', controller: _message, hint: 'the text you want to sign', maxLines: 3),
        const SizedBox(height: 12),
        AmbraField(label: 'Address index', controller: _index, hint: '0', mono: true),
        if (_address != null) ...[
          const SizedBox(height: 8),
          Text(_address!, style: AmbraText.mono.copyWith(fontSize: 12, color: AmbraColors.dim)),
        ],
        const SizedBox(height: 18),
        PrimaryButton(label: 'Sign', icon: Icons.draw, busy: _busy, onPressed: _busy ? null : _sign),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: AmbraColors.red)),
        ],
        if (out != null) ...[
          const SizedBox(height: 20),
          _ResultBlock(
            label: 'Signature',
            value: out.signature,
            onCopy: () => _copy(out.signature, 'Signature copied'),
          ),
          const SizedBox(height: 14),
          _ResultBlock(label: 'Verify against this address', value: out.verifyAddress),
          const SizedBox(height: 8),
          const Text(
            'The same key as the address above, written the older way. A node accepts only that form '
            'here: it rejects a tb1 address whatever key stands behind it.',
            style: AmbraText.sub,
          ),
          const SizedBox(height: 14),
          SecondaryButton(
            label: 'Copy verify command',
            icon: Icons.copy,
            onPressed: () => _copy(
              'verifymessage "${out.verifyAddress}" "${out.signature}" '
                  '"${_message.text.replaceAll('"', r'\"')}"',
              'Verify command copied',
            ),
          ),
        ],
      ]),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.mode, required this.onChanged});
  final SignMode mode;
  final ValueChanged<SignMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: _seg('Challenge', SignMode.challenge)),
      const SizedBox(width: 10),
      Expanded(child: _seg('Document hash', SignMode.document)),
    ]);
  }

  Widget _seg(String label, SignMode m) {
    final on = mode == m;
    return InkWell(
      borderRadius: BorderRadius.circular(AmbraRadii.control),
      onTap: () => onChanged(m),
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? AmbraColors.buttonSurface : AmbraColors.panelDeep,
          border: Border.all(color: on ? AmbraColors.amber : AmbraColors.line),
          borderRadius: BorderRadius.circular(AmbraRadii.control),
        ),
        child: Text(label,
            style: TextStyle(
                color: on ? AmbraColors.txt : AmbraColors.dim, fontWeight: FontWeight.w600, fontSize: 14)),
      ),
    );
  }
}

class _ResultBlock extends StatelessWidget {
  const _ResultBlock({required this.label, required this.value, this.onCopy});
  final String label;
  final String value;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionLabel(label),
      const SizedBox(height: 8),
      SelectableText(value, style: AmbraText.mono),
      if (onCopy != null) ...[
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onCopy,
            icon: const Icon(Icons.copy, size: 16, color: AmbraColors.dim),
            label: const Text('Copy', style: TextStyle(color: AmbraColors.dim)),
          ),
        ),
      ],
    ]);
  }
}
