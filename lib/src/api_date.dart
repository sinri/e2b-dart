/// API timestamps exposed as JavaScript Date values have millisecond precision.
DateTime parseApiDate(String value) => DateTime.fromMillisecondsSinceEpoch(
    DateTime.parse(value).millisecondsSinceEpoch,
    isUtc: true);

DateTime? tryParseApiDate(String? value) {
  final parsed = value == null ? null : DateTime.tryParse(value);
  return parsed == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(parsed.millisecondsSinceEpoch,
          isUtc: true);
}
