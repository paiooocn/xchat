import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

/// Feeds [input] to a fresh parser one character at a time, mimicking the worst
/// case of a stream split at every possible boundary.
({String content, String reasoning}) parseCharByChar(
  String input, {
  bool startInReasoning = false,
}) {
  final parser = ThinkTagParser(startInReasoning: startInReasoning);
  final content = StringBuffer();
  final reasoning = StringBuffer();
  for (final char in input.split('')) {
    for (final segment in parser.add(char)) {
      (segment.isReasoning ? reasoning : content).write(segment.text);
    }
  }
  for (final segment in parser.flush()) {
    (segment.isReasoning ? reasoning : content).write(segment.text);
  }
  return (content: content.toString(), reasoning: reasoning.toString());
}

void main() {
  group('ThinkTagParser.split', () {
    test('separates an inline thinking block', () {
      final result = ThinkTagParser.split('hello  thinkingbecause reasons<｜end▁of▁thinking｜>\nworld');
      expect(result.content, 'hello \nworld');
      expect(result.reasoning, 'because reasons');
      expect(result.hasReasoning, isTrue);
    });

    test('handles the <analysis> spelling and multiple blocks', () {
      final result = ThinkTagParser.split('a<analysis>1</analysis>b<analysis>2</analysis>c');
      expect(result.content, 'abc');
      expect(result.reasoning, '12');
    });

    test('leaves plain text untouched', () {
      final result = ThinkTagParser.split('no tags here');
      expect(result.content, 'no tags here');
      expect(result.reasoning, isEmpty);
    });

    test('an unterminated block becomes reasoning by default', () {
      final result = ThinkTagParser.split('answer  thinkingtruncated by max_tokens');
      expect(result.content, 'answer ');
      expect(result.reasoning, 'truncated by max_tokens');
    });

    test('unterminatedAsReasoning: false demotes it to content', () {
      final parser = ThinkTagParser(unterminatedAsReasoning: false);
      final segments = <ThinkSegment>[...parser.add('a  thinkingb'), ...parser.flush()];
      expect(segments.map((s) => s.type),
          <ThinkSegmentType>[ThinkSegmentType.content, ThinkSegmentType.content]);
    });

    test('is disabled cleanly', () {
      const input = 'a  thinkingb<｜end▁of▁thinking｜> c';
      expect(ThinkTagParser.split(input, enabled: false).content, input);
    });
  });

  group('ThinkTagParser streaming', () {
    test('never emits half a tag', () {
      final parser = ThinkTagParser();
      expect(parser.add('visible <thi'), <ThinkSegment>[const ThinkSegment(ThinkSegmentType.content, 'visible ')]);
      expect(parser.add('nk>hidden'), <ThinkSegment>[const ThinkSegment(ThinkSegmentType.reasoning, 'hidden')]);
      expect(parser.add('</thi'), isEmpty);
      expect(parser.add('nk>shown'), <ThinkSegment>[const ThinkSegment(ThinkSegmentType.content, 'shown')]);
      expect(parser.flush(), isEmpty);
    });

    test('holds back a lone "<" until it is resolved', () {
      final parser = ThinkTagParser();
      expect(parser.add('2 < 3'), <ThinkSegment>[const ThinkSegment(ThinkSegmentType.content, '2 ')]);
      expect(parser.add(' is true'),
          <ThinkSegment>[const ThinkSegment(ThinkSegmentType.content, '< 3 is true')]);
      expect(parser.flush(), isEmpty);
    });

    test('flushes held-back text at end of stream', () {
      final parser = ThinkTagParser();
      expect(parser.add('trailing <thi'), isEmpty);
      expect(parser.flush(), <ThinkSegment>[
        const ThinkSegment(ThinkSegmentType.content, 'trailing <thi'),
      ]);
    });

    test('character-by-character equals whole-string parsing', () {
      const input = 'intro  thinkingstep one\nstep two<｜end▁of▁thinking｜>final';
      final result = parseCharByChar(input);
      expect(result.content, 'intro final');
      expect(result.reasoning, 'step one\nstep two');
      expect(result, ThinkTagParser.split(input));
    });

    test('reassembles text split at every offset', () {
      const input = 'A  thinkingB<｜end▁of▁thinking｜>C';
      for (var cut = 1; cut < input.length; cut++) {
        final parser = ThinkTagParser();
        final out = <ThinkSegment>[
          ...parser.add(input.substring(0, cut)),
          ...parser.add(input.substring(cut)),
          ...parser.flush(),
        ];
        expect(out.map((s) => s.text).join(), 'AC', reason: 'cut at $cut');
        expect(out.firstWhere((s) => s.isReasoning).text, 'B', reason: 'cut at $cut');
      }
    });

    test('drops a stray leading close tag (vLLM/SGLang prefill artefact)', () {
      final result = parseCharByChar('\n\nHello there');
      expect(result.content, '\n\nHello there');
      expect(result.reasoning, isEmpty);
    });

    test('keeps a stray close tag once real content has been emitted', () {
      final result = parseCharByChar('I will show you how  tags work');
      expect(result.reasoning, isEmpty);
      expect(result.content, contains(' tags work'));
    });

    test('startInReasoning handles a pre-filled thinking block', () {
      final result = parseCharByChar('reasoning here\n\nanswer', startInReasoning: true);
      expect(result.reasoning, 'reasoning here\n\n');
      expect(result.content, 'answer');
    });

    test('handles three blocks and mixed content', () {
      final result = parseCharByChar('a  thinkingb<｜end▁of▁thinking｜> c  thinkingd<｜end▁of▁thinking｜> e');
      expect(result.content, 'a  c  e');
      expect(result.reasoning, 'bd');
    });

    test('reset() clears state', () {
      final parser = ThinkTagParser()..add('x  thinkingy');
      expect(parser.inReasoning, isTrue);
      parser.reset();
      expect(parser.inReasoning, isFalse);
      expect(parser.bufferedLength, 0);
      expect(parser.add('z'), <ThinkSegment>[const ThinkSegment(ThinkSegmentType.content, 'z')]);
    });
  });

  group('ReasoningRouter', () {
    test('field source ignores tags', () {
      final router = ReasoningRouter(source: ReasoningSource.field);
      final events = <ChatEvent>[
        ...router.content(' literal'),
        ...router.reasoning('thinking'),
        ...router.finish(),
      ];
      expect(events.whereType<ReasoningDelta>().map((e) => e.text).join(), 'thinking');
      expect(events.whereType<ContentDelta>().map((e) => e.text).join(), ' literal');
    });

    test('inlineTags source ignores the reasoning field', () {
      final router = ReasoningRouter(source: ReasoningSource.inlineTags);
      final events = <ChatEvent>[
        ...router.reasoning('ignored'),
        ...router.content('a  thinkingb<｜end▁of▁thinking｜>c'),
        ...router.finish(),
      ];
      expect(events.whereType<ReasoningDelta>().map((e) => e.text).join(), 'b');
      expect(events.whereType<ContentDelta>().map((e) => e.text).join(), 'ac');
    });

    test('auto source merges both channels', () {
      final router = ReasoningRouter(source: ReasoningSource.auto);
      final events = <ChatEvent>[
        ...router.reasoning('from field '),
        ...router.content('answer  thinking'),
        ...router.content('from tag'),
        ...router.finish(),
      ];
      expect(router.sawReasoning, isTrue);
      expect(events.whereType<ReasoningDelta>().map((e) => e.text).join(), 'from field from tag');
      expect(events.whereType<ContentDelta>().map((e) => e.text).join(), 'answer ');
    });
  });
}
