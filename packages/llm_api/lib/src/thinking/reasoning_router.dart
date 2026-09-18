/// Bridges provider-specific reasoning channels onto [ChatEvent]s.
library;

import '../core/chat_events.dart';
import 'think_tag_parser.dart';

/// Where a provider keeps its thinking text.
enum ReasoningSource {
  /// Dedicated response field: DeepSeek `reasoning_content`, OpenRouter
  /// `reasoning`, Qwen `reasoning_content`, …
  field,

  /// Inlined in the content between ` thinking…<｜end▁of▁thinking｜>` markers.
  inlineTags,

  /// Prefer the field, but also strip tags out of the content (safe default:
  /// gateways are inconsistent about which of the two you get).
  auto,

  /// Pass everything through untouched.
  none;

  bool get readsField => this == ReasoningSource.field || this == ReasoningSource.auto;

  bool get parsesTags => this == ReasoningSource.inlineTags || this == ReasoningSource.auto;
}

/// Normalises the two reasoning channels into a single event stream.
///
/// One instance per request: it owns the [ThinkTagParser] state.
class ReasoningRouter {
  ReasoningRouter({
    this.source = ReasoningSource.auto,
    List<String> tags = const <String>['think', 'thinking', 'reasoning', 'analysis'],
    bool startInReasoning = false,
  }) : _parser = ThinkTagParser(
          tags: tags,
          enabled: source.parsesTags,
          startInReasoning: startInReasoning,
        );

  final ReasoningSource source;
  final ThinkTagParser _parser;

  /// `true` once any thinking text was produced (useful for UI toggles).
  bool get sawReasoning => _sawReasoning;
  bool _sawReasoning = false;

  /// Feed a content delta (raw text channel).
  List<ChatEvent> content(String? delta) {
    if (delta == null || delta.isEmpty) return const <ChatEvent>[];
    if (!source.parsesTags) return <ChatEvent>[ContentDelta(delta)];
    final events = <ChatEvent>[];
    for (final segment in _parser.add(delta)) {
      if (segment.isReasoning) {
        _sawReasoning = true;
        events.add(ReasoningDelta(segment.text));
      } else {
        events.add(ContentDelta(segment.text));
      }
    }
    return events;
  }

  /// Feed a reasoning delta read from a dedicated field.
  List<ChatEvent> reasoning(String? delta) {
    if (delta == null || delta.isEmpty) return const <ChatEvent>[];
    if (!source.readsField) return const <ChatEvent>[];
    _sawReasoning = true;
    return <ChatEvent>[ReasoningDelta(delta)];
  }

  /// Feed an Anthropic-style signature fragment.
  List<ChatEvent> signature(String? delta) {
    if (delta == null || delta.isEmpty) return const <ChatEvent>[];
    return <ChatEvent>[ReasoningSignatureDelta(delta)];
  }

  /// End of stream: release held-back characters.
  List<ChatEvent> finish() {
    if (!source.parsesTags) return const <ChatEvent>[];
    final events = <ChatEvent>[];
    for (final segment in _parser.flush()) {
      if (segment.isReasoning) {
        _sawReasoning = true;
        events.add(ReasoningDelta(segment.text));
      } else {
        events.add(ContentDelta(segment.text));
      }
    }
    return events;
  }
}
