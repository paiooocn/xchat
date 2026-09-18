import 'package:xml/xml.dart';

import '../../models/session_message.dart';
import '../../models/session_params.dart';
import '../../models/session_template.dart';
import 'cdata.dart';
import 'xml_writer.dart';

/// SessionTemplate ⇄ XML codec (CDATA text, mirrors the session format).
class TemplateXml {
  const TemplateXml._();

  static const _paramsKeys = <String>[
    'temperature',
    'top_p',
    'max_tokens',
    'thinking',
    'reasoning_effort',
    'reasoning_budget',
  ];

  static String encode(SessionTemplate template) {
    final out = XmlOut();
    out.declaration();
    out.open('template', {'id': template.id});
    out.leaf('name', template.name);
    out.leaf('description', template.description);
    out.leafText('provider', template.provider);
    out.leafText('model', template.model);
    out.leafText('thinking_reply_mode', template.thinkingReplyMode.wire);
    out.leafText('tool_calls_limit', template.toolCallsLimit.toString());
    out.leaf('system_prompt', template.systemPrompt);
    out.leaf('tags', template.tags.join(','));
    out.open('params');
    for (final key in _paramsKeys) {
      out.leafText(key, template.params.encode(key));
    }
    out.close('params');
    out.open('tools');
    for (final tool in template.tools) {
      out.leafText('tool', tool);
    }
    out.close('tools');
    out.close('template');
    return out.build();
  }

  static SessionTemplate decode(String xml) {
    final document = XmlDocument.parse(xml);
    final root = document.rootElement;
    if (root.name.local != 'template') {
      throw FormatException('Root element must be <template>, got <${root.name.local}>');
    }
    final paramsElement = root.getElement('params');
    final elements = <String, String>{};
    if (paramsElement != null) {
      for (final child in paramsElement.childElements) {
        elements[child.name.local] = child.innerText;
      }
    }
    final toolsElement = root.getElement('tools');
    return SessionTemplate(
      id: root.getAttribute('id') ?? '',
      name: readTextOrEmpty(root, 'name'),
      description: readTextOrEmpty(root, 'description'),
      provider: readTextOrEmpty(root, 'provider'),
      model: readTextOrEmpty(root, 'model'),
      thinkingReplyMode: ThinkingReplyMode.parse(readText(root, 'thinking_reply_mode')),
      toolCallsLimit: int.tryParse(readText(root, 'tool_calls_limit') ?? '') ?? 0,
      systemPrompt: readTextOrEmpty(root, 'system_prompt'),
      params: SessionParams.fromElements(elements),
      tags: (readText(root, 'tags') ?? '')
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList(),
      tools: toolsElement == null
          ? <String>[]
          : toolsElement
              .findElements('tool')
              .map((e) => e.innerText.trim())
              .where((name) => name.isNotEmpty)
              .toList(),
    );
  }
}
