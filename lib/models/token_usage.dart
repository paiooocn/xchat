import '../core/json_utils.dart';

/// Token accounting in XChat's own vocabulary: `input` / `output` / `cache`.
///
/// Each field is nullable because providers report different subsets; a missing
/// value is *unknown*, not zero, and is never written to disk as `0`.
class TokenUsage {
  const TokenUsage({this.input, this.output, this.cache});

  final int? input;
  final int? output;

  /// Input tokens served from the provider-side prompt cache.
  final int? cache;

  static const empty = TokenUsage();

  bool get isEmpty => input == null && output == null && cache == null;

  bool get isNotEmpty => !isEmpty;

  /// `input + output` when at least one is known (used for `context`).
  int? get contextTotal {
    if (input == null && output == null) return null;
    return (input ?? 0) + (output ?? 0);
  }

  TokenUsage merge(TokenUsage other) => TokenUsage(
        input: _add(input, other.input),
        output: _add(output, other.output),
        cache: _add(cache, other.cache),
      );

  TokenUsage diff(TokenUsage other) => TokenUsage(
        input: _sub(input, other.input),
        output: _sub(output, other.output),
        cache: _sub(cache, other.cache),
      );

  static int? _add(int? a, int? b) =>
      (a == null && b == null) ? null : (a ?? 0) + (b ?? 0);

  static int? _sub(int? a, int? b) {
    if (a == null && b == null) return null;
    final value = (a ?? 0) - (b ?? 0);
    return value < 0 ? 0 : value;
  }

  /// Reads from XML attributes (`input` / `output` / `cache`).
  factory TokenUsage.fromAttrs(Map<String, String?> attrs) => TokenUsage(
        input: _int(attrs['input']),
        output: _int(attrs['output']),
        cache: _int(attrs['cache']),
      );

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'input': input,
        'output': output,
        'cache': cache,
      });

  factory TokenUsage.fromJson(Object? value) {
    final json = asMap(value);
    return TokenUsage(
      input: asInt(json['input']),
      output: asInt(json['output']),
      cache: asInt(json['cache']),
    );
  }

  static int? _int(String? value) {
    if (value == null || value.isEmpty) return null;
    return int.tryParse(value);
  }

  @override
  String toString() =>
      'TokenUsage(in: ${input ?? '-'}, out: ${output ?? '-'}, cache: ${cache ?? '-'})';
}
