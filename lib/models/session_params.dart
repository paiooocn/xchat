import '../core/json_utils.dart';

/// Reasoning effort options shared by the template editor and the session
/// wizard ('' = not sent to the endpoint).
const List<String> kReasoningEffortOptions = <String>[
  '',
  'max',
  'xhigh',
  'high',
  'medium',
  'low',
  'minimal',
  'none',
];

/// Whether thinking is requested from the model.
enum ThinkingSwitch {
  /// Let the model decide (vendor default).
  auto,

  /// Explicitly ask for thinking.
  on,

  /// Explicitly disable thinking.
  off;

  static ThinkingSwitch parse(String? value) => switch (value) {
        'on' => ThinkingSwitch.on,
        'off' => ThinkingSwitch.off,
        _ => ThinkingSwitch.auto,
      };

  String get wire => name;
}

/// Per-session model parameters (serialised as `meta/params/*` elements).
class SessionParams {
  SessionParams({
    this.temperature,
    this.topP,
    this.maxTokens,
    this.thinking = ThinkingSwitch.auto,
    this.reasoningEffort,
    this.reasoningBudget,
  });

  double? temperature;
  double? topP;
  int? maxTokens;
  ThinkingSwitch thinking;
  String? reasoningEffort; // minimal|low|medium|high
  int? reasoningBudget;

  bool get thinkingEnabled => thinking != ThinkingSwitch.off;

  SessionParams copyWith({
    double? temperature,
    double? topP,
    int? maxTokens,
    ThinkingSwitch? thinking,
    String? reasoningEffort,
    int? reasoningBudget,
  }) =>
      SessionParams(
        temperature: temperature ?? this.temperature,
        topP: topP ?? this.topP,
        maxTokens: maxTokens ?? this.maxTokens,
        thinking: thinking ?? this.thinking,
        reasoningEffort: reasoningEffort ?? this.reasoningEffort,
        reasoningBudget: reasoningBudget ?? this.reasoningBudget,
      );

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'temperature': temperature,
        'top_p': topP,
        'max_tokens': maxTokens,
        'thinking': thinking.wire,
        'reasoning_effort': reasoningEffort,
        'reasoning_budget': reasoningBudget,
      });

  factory SessionParams.fromJson(Object? value) {
    final json = asMap(value);
    return SessionParams(
      temperature: asDouble(json['temperature']),
      topP: asDouble(json['top_p']),
      maxTokens: asInt(json['max_tokens']),
      thinking: ThinkingSwitch.parse(asString(json['thinking'])),
      reasoningEffort: asString(json['reasoning_effort']),
      reasoningBudget: asInt(json['reasoning_budget']),
    );
  }

  /// Serialises one parameter to its CDATA text; `null` becomes empty text.
  String encode(String key) {
    switch (key) {
      case 'temperature':
        return temperature?.toString() ?? '';
      case 'top_p':
        return topP?.toString() ?? '';
      case 'max_tokens':
        return maxTokens?.toString() ?? '';
      case 'thinking':
        return thinking.wire;
      case 'reasoning_effort':
        return reasoningEffort ?? '';
      case 'reasoning_budget':
        return reasoningBudget?.toString() ?? '';
    }
    return '';
  }

  static double? _readDouble(String raw) =>
      raw.isEmpty ? null : double.tryParse(raw);

  static int? _readInt(String raw) => raw.isEmpty ? null : int.tryParse(raw);

  static String? _readString(String raw) => raw.isEmpty ? null : raw;

  /// Builds from the `meta/params` child elements (name → CDATA text).
  factory SessionParams.fromElements(Map<String, String> elements) => SessionParams(
        temperature: _readDouble(elements['temperature'] ?? ''),
        topP: _readDouble(elements['top_p'] ?? ''),
        maxTokens: _readInt(elements['max_tokens'] ?? ''),
        thinking: ThinkingSwitch.parse(elements['thinking']),
        reasoningEffort: _readString(elements['reasoning_effort'] ?? ''),
        reasoningBudget: _readInt(elements['reasoning_budget'] ?? ''),
      );
}
