import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../core/app_paths.dart';
import '../../models/agent_mode.dart';
import '../../models/session.dart';
import '../../models/session_message.dart';
import '../../models/session_params.dart';
import '../../models/token_usage.dart';
import 'cdata.dart';
import 'xml_writer.dart';

/// Session ⇄ XML codec. All element text is written as CDATA (no escaping).
class SessionXml {
  const SessionXml._();

  static const _paramsKeys = <String>[
    'temperature',
    'top_p',
    'max_tokens',
    'thinking',
    'reasoning_effort',
    'reasoning_budget',
  ];

  // ------------------------------------------------------------------ encode

  static String encode(Session session) {
    session.ensureSystem();
    final out = XmlOut();
    out.declaration();
    out.open('chat', {'sandbox': session.sandbox});

    // --- meta ---------------------------------------------------------
    out.open('meta');
    out.leafText('id', session.id);
    out.leafText('created_at', session.createdAt.toUtc().toIso8601String());
    out.leafText('updated_at', session.updatedAt.toUtc().toIso8601String());
    out.leafText('tool_calls', session.toolCalls.toString());
    out.leafText('tool_calls_limit', session.toolCallsLimit.toString());
    if (session.projectId.isNotEmpty) out.leafText('project', session.projectId);
    if (session.archivedAt != null) {
      out.leafText('archived_at', session.archivedAt!.toUtc().toIso8601String());
    }
    out.open('params');
    for (final key in _paramsKeys) {
      out.leafText(key, session.params.encode(key));
    }
    out.close('params');
    out.close('meta');

    // --- other session JSON fields ------------------------------------
    out.leaf('title', session.title);
    out.leaf('tags', session.tags.join(','));
    out.leafText('provider', session.provider);
    out.leafText('model', session.model);
    out.leafText('mode', session.mode.wire);
    out.leafText('thinking_reply_mode', session.thinkingReplyMode.wire);
    out.leafText('web_search_enabled', session.webSearchEnabled.toString());
    out.open('tools');
    for (final tool in session.tools) {
      out.leafText('tool', tool);
    }
    out.close('tools');

    // --- messages ------------------------------------------------------
    for (final message in session.messages) {
      switch (message.role) {
        case MessageRole.system:
          out.open(
            'system',
            _usageAttrs(session.cumulativeUsage, context: session.contextTokens),
          );
          out.leaf('content', message.content);
          out.close('system');
        case MessageRole.user:
          out.open('user', _attrs({'id': message.id}));
          out.leaf('content', message.content);
          out.close('user');
        case MessageRole.assistant:
          out.open('assistant', _attrs({'id': message.id, ..._usageAttrs(message.usage)}));
          if (message.hasReasoning) {
            out.leaf('reasoning', message.reasoning, _attrs({'mode': message.reasoningMode}));
          }
          out.leaf('content', message.content);
          if (message.hasToolCalls) {
            out.open('tool_calls');
            for (final call in message.toolCalls) {
              out.open('tool_call', {'id': call.id, 'name': call.name});
              out.leaf('arguments', call.arguments);
              out.close('tool_call');
            }
            out.close('tool_calls');
          }
          out.close('assistant');
        case MessageRole.tool:
          out.open(
            'tool',
            _attrs({
              'id': message.id,
              'tool_call_id': message.toolCallId,
              'name': message.toolName,
              'error': message.isError ? 'true' : null,
            }),
          );
          out.leaf('content', message.content);
          out.close('tool');
      }
    }

    out.close('chat');
    return out.build();
  }

  /// Builds usage attributes, omitting unknown (null) values.
  static Map<String, String> _usageAttrs(TokenUsage usage, {int? context}) {
    final attrs = <String, String>{};
    if (usage.input != null) attrs['input'] = usage.input.toString();
    if (usage.output != null) attrs['output'] = usage.output.toString();
    if (usage.cache != null) attrs['cache'] = usage.cache.toString();
    if (context != null) attrs['context'] = context.toString();
    return attrs;
  }

  static Map<String, String> _attrs(Map<String, String?> values) {
    final out = <String, String>{};
    values.forEach((key, value) {
      if (value != null && value.isNotEmpty) out[key] = value;
    });
    return out;
  }

  // ------------------------------------------------------------------ decode

  static Session decode(String xml, {required String filePath}) {
    final document = XmlDocument.parse(xml);
    final root = document.rootElement;
    if (root.name.local != 'chat') {
      throw FormatException('Root element must be <chat>, got <${root.name.local}>');
    }
    final rawSandbox = root.getAttribute('sandbox') ?? '';
    // A relative sandbox is resolved against the data directory's `projects/`.
    final String sandbox;
    if (rawSandbox.isEmpty) {
      sandbox = _dirname(filePath);
    } else if (!p.isAbsolute(rawSandbox) && AppPaths.isReady) {
      sandbox = AppPaths.instance.resolveSandbox(rawSandbox);
    } else {
      sandbox = rawSandbox;
    }

    final meta = root.getElement('meta');
    final id = _metaText(root, meta, 'id') ?? '';
    final createdAt = DateTime.tryParse(_metaText(root, meta, 'created_at') ?? '') ?? DateTime.now();
    final updatedAt = DateTime.tryParse(_metaText(root, meta, 'updated_at') ?? '') ?? createdAt;
    final toolCalls = int.tryParse(_metaText(root, meta, 'tool_calls') ?? '') ?? 0;
    final limit = int.tryParse(_metaText(root, meta, 'tool_calls_limit') ?? '') ?? 0;
    final params = _decodeParams(meta);

    final session = Session(
      id: id.isEmpty ? _basename(filePath) : id,
      sandbox: sandbox.isEmpty ? _dirname(filePath) : sandbox,
      createdAt: createdAt,
      updatedAt: updatedAt,
      toolCalls: toolCalls,
      toolCallsLimit: limit,
      title: readTextOrEmpty(root, 'title'),
      projectId: _metaText(root, meta, 'project') ?? '',
      archivedAt: DateTime.tryParse(_metaText(root, meta, 'archived_at') ?? ''),
      tags: (readText(root, 'tags') ?? '')
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList(),
      provider: readTextOrEmpty(root, 'provider'),
      model: readTextOrEmpty(root, 'model'),
      mode: AgentMode.parse(readText(root, 'mode')),
      thinkingReplyMode: ThinkingReplyMode.parse(readText(root, 'thinking_reply_mode')),
      webSearchEnabled: (readText(root, 'web_search_enabled') ?? 'true') != 'false',
      tools: _decodeTools(root),
      params: params,
    );

    for (final element in root.childElements) {
      switch (element.name.local) {
        case 'system':
          session.messages.add(SessionMessage(
            role: MessageRole.system,
            content: readTextOrEmpty(element, 'content'),
          ));
          session.cumulativeUsage = TokenUsage.fromAttrs(_attrsOf(element));
          final context = element.getAttribute('context');
          session.contextTokens = context == null ? null : int.tryParse(context);
        case 'user':
          session.messages.add(SessionMessage(
            role: MessageRole.user,
            id: element.getAttribute('id'),
            content: readTextOrEmpty(element, 'content'),
          ));
        case 'assistant':
          session.messages.add(_decodeAssistant(element));
        case 'tool':
          session.messages.add(SessionMessage(
            role: MessageRole.tool,
            id: element.getAttribute('id'),
            toolCallId: element.getAttribute('tool_call_id'),
            toolName: element.getAttribute('name'),
            isError: element.getAttribute('error') == 'true',
            content: readTextOrEmpty(element, 'content'),
          ));
      }
    }

    session.ensureSystem();
    return session;
  }

  static SessionMessage _decodeAssistant(XmlElement element) {
    final reasoningElement = element.getElement('reasoning');
    final toolCalls = <ToolCallData>[];
    final container = element.getElement('tool_calls');
    if (container != null) {
      for (final call in container.findElements('tool_call')) {
        toolCalls.add(ToolCallData(
          id: call.getAttribute('id') ?? '',
          name: call.getAttribute('name') ?? '',
          arguments: readTextOrEmpty(call, 'arguments'),
        ));
      }
    }
    return SessionMessage(
      role: MessageRole.assistant,
      id: element.getAttribute('id'),
      content: readText(element, 'content'),
      reasoning: reasoningElement?.innerText,
      reasoningMode: reasoningElement?.getAttribute('mode'),
      toolCalls: toolCalls,
      usage: TokenUsage.fromAttrs(_attrsOf(element)),
    );
  }

  static SessionParams _decodeParams(XmlElement? meta) {
    final paramsElement = meta?.getElement('params');
    if (paramsElement == null) return SessionParams();
    final elements = <String, String>{};
    for (final child in paramsElement.childElements) {
      elements[child.name.local] = child.innerText;
    }
    return SessionParams.fromElements(elements);
  }

  static List<String> _decodeTools(XmlElement root) {
    final container = root.getElement('tools');
    if (container == null) return <String>[];
    return container
        .findElements('tool')
        .map((e) => e.innerText.trim())
        .where((name) => name.isNotEmpty)
        .toList();
  }

  static String? _metaText(XmlElement root, XmlElement? meta, String name) {
    final value = readText(meta ?? root, name);
    if (value != null) return value;
    return readText(root, name);
  }

  static Map<String, String?> _attrsOf(XmlElement element) => <String, String?>{
        'input': element.getAttribute('input'),
        'output': element.getAttribute('output'),
        'cache': element.getAttribute('cache'),
      };

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final name = normalized.split('/').last;
    return name.endsWith('.xml') ? name.substring(0, name.length - 4) : name;
  }

  static String _dirname(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index <= 0 ? '' : normalized.substring(0, index);
  }
}
