/// Formats a date as MM/DD/YY (e.g. 07/06/26).
String formatShortDate(DateTime date) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(date.month)}/${two(date.day)}/${two(date.year % 100)}';
}

/// Formats an integer count with thousands separators (e.g. 1,234).
String formatCount(int n) {
  final digits = n.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '${n < 0 ? '-' : ''}$buffer';
}
