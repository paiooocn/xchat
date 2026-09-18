import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xml/xml.dart';

import '../../core/app_paths.dart';
import '../../state/app_state.dart';

/// Built-in XML editor for a session file (used when no external editor).
class XmlEditorPage extends StatefulWidget {
  const XmlEditorPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  State<XmlEditorPage> createState() => _XmlEditorPageState();
}

class _XmlEditorPageState extends State<XmlEditorPage> {
  final _controller = TextEditingController();
  String? _error;
  bool _dirty = false;

  String get _path => AppPaths.instance.sessionFile(widget.sessionId);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final file = File(_path);
    final text = await file.exists() ? await file.readAsString() : '';
    _controller.text = text;
    _controller.addListener(() {
      if (!_dirty) setState(() => _dirty = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      XmlDocument.parse(_controller.text);
    } on XmlException catch (error) {
      setState(() => _error = 'XML 语法错误：${error.message}');
      return;
    }
    await File(_path).writeAsString(_controller.text, flush: true);
    if (!mounted) return;
    setState(() {
      _error = null;
      _dirty = false;
    });
    await context.read<AppState>().refreshSessions();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('编辑 ${widget.sessionId.substring(0, 8)}.xml'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: Column(
        children: [
          if (_error != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Text(_error!),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
