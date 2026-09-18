/// Streaming splitter for models that inline their thinking in the text
/// channel, e.g. `...<｜end▁of▁thinking｜>answer`.
///
/// The hard part is not finding the tags once the whole string is known — it is
/// doing it **incrementally**, when `<thi` arrives at the end of one SSE chunk
/// and `nk>` at the start of the next, and when a stream simply stops in the
/// middle of a thinking block because `max_tokens` was hit.
library;

/// Which channel a segment belongs to.
enum ThinkSegmentType { content, reasoning }

/// A contiguous run of text belonging to one channel.
class ThinkSegment {
  const ThinkSegment(this.type, this.text);

  final ThinkSegmentType type;
  final String text;

  bool get isReasoning => type == ThinkSegmentType.reasoning;

  @override
  bool operator ==(Object other) =>
      other is ThinkSegment && other.type == type && other.text == text;

  @override
  int get hashCode => Object.hash(type, text);

  @override
  String toString() => 'ThinkSegment(${type.name}, ${text.length} chars)';
}

/// The result of eagerly splitting a complete string.
class ThinkParseResult {
  const ThinkParseResult({required this.content, required this.reasoning});

  final String content;
  final String reasoning;

  bool get hasReasoning => reasoning.isNotEmpty;
}

/// Incremental ` thinking… response` state machine.
///
/// ```dart
/// final parser = ThinkTagParser();
/// for (final chunk in sseChunks) {
///   for (final segment in parser.add(chunk)) { … }
/// }
/// for (final segment in parser.flush()) { … } // don't forget this
/// ```
///
/// Guarantees:
/// * a tag is never split across two emissions (`<thi` is buffered, not printed);
/// * text is never reordered or duplicated;
/// * `flush()` releases whatever a partially-matched tag was holding back.
class ThinkTagParser {
  /// Creates a parser for the given tag [tags] (bare names such as `think`,
  /// or pre-bracketed forms such as `<thinking>` / `</thinking>`).
  ThinkTagParser({
    List<String> tags = const <String>['think', 'thinking', 'reasoning', 'analysis'],
    this.enabled = true,
    bool startInReasoning = false,
    this.stripLeadingCloseTags = true,
    this.unterminatedAsReasoning = true,
    this.initialBufferLimit = 64,
  })  : _openTokens = _buildTokens(tags, closing: false),
        _closeTokens = _buildTokens(tags, closing: true),
        _inReasoning = startInReasoning {
    _allTokens = <String>[..._openTokens, ..._closeTokens];
  }

  /// Turn the whole thing off: [add] then just forwards text as content.
  final bool enabled;

  /// Strip a `<｜end▁of▁thinking｜>` that shows up before any other output.
  ///
  /// Some serving stacks (vLLM/SGLang with a pre-filled assistant prefix, or
  /// gateways that re-emit the prompt tail) start the stream with a lone
  /// closing tag. Removing it only while nothing has been emitted yet avoids
  /// touching legitimate text that merely mentions think tags.
  final bool stripLeadingCloseTags;

  /// A thinking block that is still open when the stream ends: `true` counts it
  /// as reasoning (the usual case), `false` demotes it to content.
  final bool unterminatedAsReasoning;

  /// Upper bound for hold-back when no tag matched yet, in characters.
  final int initialBufferLimit;

  final List<String> _openTokens;
  final List<String> _closeTokens;
  late final List<String> _allTokens;

  final List<ThinkSegment> _out = <ThinkSegment>[];
  String _buffer = '';
  bool _inReasoning;
  bool _emittedAnything = false;

  /// `true` while inside a thinking block.
  bool get inReasoning => _inReasoning;

  /// Characters currently held back waiting for a possible tag completion.
  int get bufferedLength => _buffer.length;

  /// Feeds one chunk; returns the segments that became unambiguous.
  List<ThinkSegment> add(String chunk) {
    if (chunk.isEmpty) return const <ThinkSegment>[];
    if (!enabled) {
      _emittedAnything = true;
      return <ThinkSegment>[ThinkSegment(ThinkSegmentType.content, chunk)];
    }
    _buffer += chunk;
    _out.clear();
    _drain(atEnd: false);
    return List<ThinkSegment>.of(_out);
  }

  /// Releases everything still buffered. Call once per stream, after the last
  /// [add]; the parser is reusable afterwards.
  List<ThinkSegment> flush() {
    _out.clear();
    _drain(atEnd: true);
    _inReasoning = false;
    return List<ThinkSegment>.of(_out);
  }

  /// Forgets parser state without emitting.
  void reset({bool startInReasoning = false}) {
    _buffer = '';
    _inReasoning = startInReasoning;
    _emittedAnything = false;
    _out.clear();
  }

  // ---------------------------------------------------------------- internals

  void _drain({required bool atEnd}) {
    while (true) {
      if (_inReasoning) {
        final hit = _firstMatch(_closeTokens);
        if (hit != null) {
          _emit(ThinkSegmentType.reasoning, _buffer.substring(0, hit.index));
          _buffer = _buffer.substring(hit.index + hit.token.length);
          _inReasoning = false;
          continue;
        }
        if (atEnd) {
          _emit(
            unterminatedAsReasoning ? ThinkSegmentType.reasoning : ThinkSegmentType.content,
            _buffer,
          );
          _buffer = '';
          _inReasoning = false;
          return;
        }
        final keep = _holdBack(_closeTokens);
        if (keep >= _buffer.length) return; // everything may still be a tag
        _emit(ThinkSegmentType.reasoning, _buffer.substring(0, _buffer.length - keep));
        _buffer = _buffer.substring(_buffer.length - keep);
        return;
      }

      final open = _firstMatch(_openTokens);
      final close = _shouldStripStray() ? _firstMatch(_closeTokens) : null;
      if (close != null && (open == null || close.index < open.index)) {
        // Stray leading `<｜end▁of▁thinking｜>`: drop it, keep the state machine honest.
        _emit(ThinkSegmentType.content, _buffer.substring(0, close.index));
        _buffer = _buffer.substring(close.index + close.token.length);
        continue;
      }
      if (open != null) {
        _emit(ThinkSegmentType.content, _buffer.substring(0, open.index));
        _buffer = _buffer.substring(open.index + open.token.length);
        _inReasoning = true;
        continue;
      }
      if (atEnd) {
        _emit(ThinkSegmentType.content, _buffer);
        _buffer = '';
        return;
      }
      final keep = _holdBack(_shouldStripStray() ? _allTokens : _openTokens);
      if (keep >= _buffer.length) {
        // Nothing settlable yet. Guard against a pathological buffer (a model
        // emitting a long run of `<aaaaaaaa…`) by force-flushing it as content.
        if (_buffer.length > initialBufferLimit + _maxTokenLength) {
          _emit(ThinkSegmentType.content, _buffer);
          _buffer = '';
        }
        return;
      }
      _emit(ThinkSegmentType.content, _buffer.substring(0, _buffer.length - keep));
      _buffer = _buffer.substring(_buffer.length - keep);
      return;
    }
  }

  bool _shouldStripStray() => stripLeadingCloseTags && !_emittedAnything;

  void _emit(ThinkSegmentType type, String text) {
    if (text.isEmpty) return;
    _emittedAnything = true;
    _out.add(ThinkSegment(type, text));
  }

  int get _maxTokenLength =>
      _allTokens.fold<int>(0, (max, token) => token.length > max ? token.length : max);

  _TokenHit? _firstMatch(List<String> tokens) {
    _TokenHit? best;
    for (final token in tokens) {
      final index = _buffer.indexOf(token);
      if (index < 0) continue;
      if (best == null ||
          index < best.index ||
          (index == best.index && token.length > best.token.length)) {
        best = _TokenHit(index, token);
      }
    }
    return best;
  }

  /// Longest suffix of `_buffer` that is a *strict prefix* of one of [tokens].
  int _holdBack(List<String> tokens) {
    var best = 0;
    for (final token in tokens) {
      final limit = token.length - 1;
      final max = _buffer.length < limit ? _buffer.length : limit;
      for (var k = max; k > best; k--) {
        if (_matchesSuffix(_buffer, token, k)) {
          best = k;
          break;
        }
      }
    }
    return best;
  }

  static bool _matchesSuffix(String buffer, String token, int count) {
    if (count > buffer.length || count > token.length) return false;
    final start = buffer.length - count;
    for (var i = 0; i < count; i++) {
      if (buffer.codeUnitAt(start + i) != token.codeUnitAt(i)) return false;
    }
    return true;
  }

  static List<String> _buildTokens(List<String> tags, {required bool closing}) {
    final tokens = <String>[];
    for (final tag in tags) {
      final name = tag.trim().replaceAll(RegExp(r'^[<\s/|]+|[>\s|]+$'), '');
      if (name.isEmpty) continue;
      tokens.add('${closing ? '</' : '<'}$name>');
    }
    return tokens;
  }

  /// One-shot helper: splits a complete string.
  static ThinkParseResult split(
    String text, {
    List<String> tags = const <String>['think', 'thinking', 'reasoning', 'analysis'],
    bool startInReasoning = false,
    bool enabled = true,
  }) {
    final parser = ThinkTagParser(tags: tags, startInReasoning: startInReasoning, enabled: enabled);
    final content = StringBuffer();
    final reasoning = StringBuffer();
    for (final segment in <ThinkSegment>[...parser.add(text), ...parser.flush()]) {
      (segment.isReasoning ? reasoning : content).write(segment.text);
    }
    return ThinkParseResult(content: content.toString(), reasoning: reasoning.toString());
  }
}

class _TokenHit {
  const _TokenHit(this.index, this.token);

  final int index;
  final String token;
}
