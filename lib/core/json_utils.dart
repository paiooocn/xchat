/// Small, defensive helpers for reading untyped JSON payloads.
library;

///
/// LLM gateways and hand-edited config are sloppy about types, so every read
/// goes through these. Local copy (no dependency on the `llm_api` package).

Map<String, Object?> asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, v) => MapEntry(key.toString(), v));
  }
  return const <String, Object?>{};
}

List<Object?> asList(Object? value) {
  if (value is List<Object?>) return value;
  if (value is List) return value.cast<Object?>();
  return const <Object?>[];
}

String? asString(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return null;
}

int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    return int.tryParse(value) ?? double.tryParse(value)?.toInt();
  }
  return null;
}

double? asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

bool asBool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value == 'true' || value == '1';
  return fallback;
}

List<String> asStringList(Object? value) =>
    asList(value).map(asString).whereType<String>().toList(growable: false);

/// Removes entries whose value is `null`.
Map<String, Object?> pruneNulls(Map<String, Object?> json) {
  json.removeWhere((_, value) => value == null);
  return json;
}
