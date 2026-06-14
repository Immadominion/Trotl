/// usd6 (1e6 fixed-point int) → "+$12.34" / "−$5.00" / "$0.00" (real U+2212 minus).
String fmtMoney6(int usd6) {
  final v = usd6 / 1e6;
  final sign = v > 0
      ? '+'
      : v < 0
      ? '−'
      : '';
  return '$sign\$${v.abs().toStringAsFixed(2)}';
}

/// A plain dollar amount, e.g. "$162.40".
String fmtUsd(double v) => '\$${v.toStringAsFixed(2)}';

/// Thousands separators for an int (no intl dependency), e.g. 1284 → "1,284".
String groupInt(int n) {
  final s = n.abs().toString();
  final buf = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
