/// Small, defensive helpers for reading untyped JSON payloads.
///
/// LLM gateways are notoriously sloppy about types (`"123"` where you expect
/// `123`, `null` where you expect `{}`), so every read goes through these.
library;

/// Coerces [value] into a `Map<String, Object?>` (empty map when impossible).
Map<String, Object?> asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, v) => MapEntry(key.toString(), v));
  }
  return const <String, Object?>{};
}

/// Coerces [value] into a `List<Object?>` (empty list when impossible).
List<Object?> asList(Object? value) {
  if (value is List<Object?>) return value;
  if (value is List) return value.cast<Object?>();
  return const <Object?>[];
}

/// Reads a string, tolerating numbers/bools.
String? asString(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return null;
}

/// Reads an int, tolerating doubles and numeric strings.
int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? double.tryParse(value)?.toInt();
  return null;
}

/// Reads a double, tolerating ints and numeric strings.
double? asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// Reads a bool with a fallback.
bool asBool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value == 'true' || value == '1';
  return fallback;
}

/// Reads a list of maps.
List<Map<String, Object?>> asMapList(Object? value) =>
    asList(value).map(asMap).toList(growable: false);

/// Deep-merges [override] on top of [base]; `null` values in [override] delete.
Map<String, Object?> deepMerge(Map<String, Object?> base, Map<String, Object?> override) {
  final result = Map<String, Object?>.from(base);
  override.forEach((key, value) {
    final existing = result[key];
    if (existing is Map<String, Object?> && value is Map) {
      result[key] = deepMerge(existing, asMap(value));
    } else {
      result[key] = value;
    }
  });
  return result;
}

/// Removes entries whose value is `null` (recursively) before serialising.
Map<String, Object?> pruneNulls(Map<String, Object?> input) {
  final out = <String, Object?>{};
  input.forEach((key, value) {
    if (value == null) return;
    if (value is Map) {
      final nested = pruneNulls(asMap(value));
      if (nested.isNotEmpty) out[key] = nested;
    } else {
      out[key] = value;
    }
  });
  return out;
}
