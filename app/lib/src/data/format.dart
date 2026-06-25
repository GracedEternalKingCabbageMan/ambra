/// Format an atom amount (integer string) to a human decimal string at the
/// given asset precision, with thousands separators and trimmed trailing zeros.
String formatAtoms(String atoms, int precision) {
  final neg = atoms.startsWith('-');
  final digits = neg ? atoms.substring(1) : atoms;
  final value = BigInt.tryParse(digits) ?? BigInt.zero;
  final sign = neg ? '-' : '';
  if (precision <= 0) return '$sign${_group(value.toString())}';
  final base = BigInt.from(10).pow(precision);
  final whole = value ~/ base;
  final frac = (value % base).toString().padLeft(precision, '0').replaceFirst(RegExp(r'0+$'), '');
  final wholeStr = _group(whole.toString());
  return frac.isEmpty ? '$sign$wholeStr' : '$sign$wholeStr.$frac';
}

/// Parse a human decimal string to atoms at [precision]. Returns null on invalid
/// input or too many decimal places.
BigInt? parseAtoms(String input, int precision) {
  final s = input.trim().replaceAll(',', '');
  if (s.isEmpty || !RegExp(r'^\d*\.?\d*$').hasMatch(s)) return null;
  final parts = s.split('.');
  if (parts.length > 2) return null;
  final whole = parts[0].isEmpty ? '0' : parts[0];
  var frac = parts.length == 2 ? parts[1] : '';
  if (frac.length > precision) return null;
  frac = frac.padRight(precision, '0');
  return BigInt.tryParse(whole + frac);
}

/// Map a raw core/network error to a short, user-friendly message. Transient
/// connectivity failures (the common case on a flaky link) become a calm
/// "retry" message rather than a wall of Reqwest/hyper internals.
String friendlyError(Object e, {bool pullToRefresh = true}) {
  final low = e.toString().toLowerCase();
  const net = ['reqwest', 'connectionaborted', 'connection abort', 'connectionreset',
    'connect', 'timed out', 'timeout', 'dns', 'network', 'unreachable', 'broken pipe', 'os { code'];
  if (net.any(low.contains)) {
    return pullToRefresh
        ? "Couldn't reach the network. Check your connection and pull down to retry."
        : "Couldn't reach the network. Check your connection and try again.";
  }
  final s = e.toString().replaceFirst('Exception: ', '').replaceFirst(RegExp(r'AnyhowException\(?'), '');
  return s.length > 160 ? '${s.substring(0, 160)}…' : s;
}

String _group(String intStr) {
  final out = StringBuffer();
  for (var i = 0; i < intStr.length; i++) {
    if (i > 0 && (intStr.length - i) % 3 == 0) out.write(',');
    out.write(intStr[i]);
  }
  return out.toString();
}
