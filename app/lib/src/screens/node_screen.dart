import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../data/format.dart';
import '../data/node_config.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// Switch the backend node Ambra syncs from. The default is the public Sequentia
/// testnet node; users can point it at their own.
class NodeScreen extends StatefulWidget {
  const NodeScreen({super.key});
  @override
  State<NodeScreen> createState() => _NodeScreenState();
}

class _NodeScreenState extends State<NodeScreen> {
  final _url = TextEditingController(text: NodeConfig.instance.origin);
  bool _testing = false;
  bool _saving = false;
  bool _testOk = false;
  String? _testMsg;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  String _normalized() {
    var s = _url.text.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  bool _valid(String s) {
    final u = Uri.tryParse(s);
    return u != null && (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty;
  }

  Future<void> _test() async {
    final origin = _normalized();
    if (!_valid(origin)) {
      setState(() => _error = 'Enter a valid http(s) URL.');
      return;
    }
    setState(() {
      _testing = true;
      _testMsg = null;
      _error = null;
    });
    try {
      final r = await http.get(Uri.parse('$origin/api/blocks/tip/height')).timeout(const Duration(seconds: 15));
      final h = int.tryParse(r.body.trim());
      setState(() {
        _testOk = r.statusCode == 200 && h != null;
        _testMsg = _testOk
            ? 'Reachable — chain tip at block $h.'
            : 'Reached the host, but it didn\'t return a Sequentia tip (HTTP ${r.statusCode}).';
      });
    } catch (e) {
      setState(() {
        _testOk = false;
        _testMsg = 'Not reachable: ${friendlyError(e)}';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final origin = _normalized();
    if (!_valid(origin)) {
      setState(() => _error = 'Enter a valid http(s) URL.');
      return;
    }
    setState(() => _saving = true);
    await NodeConfig.instance.setOrigin(origin);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Node updated — pull to refresh your balance.')));
  }

  Future<void> _reset() async {
    await NodeConfig.instance.resetToDefault();
    if (!mounted) return;
    setState(() {
      _url.text = NodeConfig.instance.origin;
      _testMsg = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Node', style: AmbraText.title),
        iconTheme: const IconThemeData(color: AmbraColors.dim),
      ),
      body: AmbraBackground(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          const Text(
            'Ambra syncs balances, history, fees and prices from this node. The default is the '
            'public Sequentia testnet node — point it at your own for privacy or reliability.',
            style: AmbraText.muted,
          ),
          const SizedBox(height: 18),
          AmbraField(label: 'Node URL', controller: _url, hint: 'http://your-node:port', mono: true),
          const SizedBox(height: 8),
          const Text(
            'Must serve the Sequentia Esplora API at /api. Fee selection, prices and the in-app '
            'faucet also use /feerates, /prices and /faucet on the same host.',
            style: AmbraText.sub,
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: const TextStyle(color: AmbraColors.red)),
            ),
          if (_testMsg != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_testMsg!,
                  style: TextStyle(color: _testOk ? AmbraColors.green : AmbraColors.red, fontSize: 13, height: 1.4)),
            ),
          SecondaryButton(
            label: _testing ? 'Testing…' : 'Test connection',
            icon: Icons.wifi_tethering,
            onPressed: _testing ? null : _test,
          ),
          const SizedBox(height: 10),
          PrimaryButton(label: 'Save node', icon: Icons.check, busy: _saving, onPressed: _saving ? null : _save),
          const SizedBox(height: 10),
          ListenableBuilder(
            listenable: NodeConfig.instance,
            builder: (_, _) => NodeConfig.instance.isDefault
                ? const SizedBox.shrink()
                : GhostButton(label: 'Reset to default node', onPressed: _reset),
          ),
        ]),
      ),
    );
  }
}
