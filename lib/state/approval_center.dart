import 'dart:async';

import 'package:flutter/foundation.dart';

/// One pending tool-approval request, owned by [ApprovalCenter].
///
/// The awaiting agent engine holds [future]; the global approval window calls
/// [ApprovalCenter.resolve] (or the request is dropped with
/// [ApprovalCenter.dropForSession]) to answer it.
class ApprovalRequest {
  ApprovalRequest({
    required this.id,
    required this.sessionId,
    required this.sessionTitle,
    required this.tool,
    required this.arguments,
    required this.note,
    required this.createdAt,
  });

  final String id;
  final String sessionId;

  /// Snapshot of the session title when the request was created (untitled
  /// sessions may be auto-named later).
  final String sessionTitle;

  final String tool;
  final String arguments;

  /// Why approval was asked (e.g. which shell list matched), for the UI.
  final String? note;

  final DateTime createdAt;

  final Completer<bool> _completer = Completer<bool>();

  Future<bool> get future => _completer.future;

  /// Display title for the list column.
  String get displayTitle =>
      sessionTitle.trim().isEmpty ? '未命名会话' : sessionTitle.trim();
}

/// Global queue of pending tool approvals across all sessions.
///
/// Sessions run concurrently: switching from session A to B must not strand
/// A's approval prompt — a per-session dialog dies with its panel (the engine
/// then silently denies the call). The engine awaits [request]; the global
/// approval window lists every pending request and resolves the selected one,
/// no matter which session is currently visible.
class ApprovalCenter extends ChangeNotifier {
  final List<ApprovalRequest> _pending = <ApprovalRequest>[];

  /// All pending approvals, oldest first.
  List<ApprovalRequest> get pending => List<ApprovalRequest>.unmodifiable(_pending);

  bool get hasPending => _pending.isNotEmpty;

  /// Queues an approval ask and completes when the user resolves it.
  Future<bool> request({
    required String sessionId,
    required String sessionTitle,
    required String tool,
    required String arguments,
    String? note,
  }) {
    final req = ApprovalRequest(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      sessionId: sessionId,
      sessionTitle: sessionTitle,
      tool: tool,
      arguments: arguments,
      note: note,
      createdAt: DateTime.now(),
    );
    _pending.add(req);
    notifyListeners();
    return req.future;
  }

  /// Answers the request with [id]: `true` runs the tool, `false` denies it.
  void resolve(String id, bool approved) {
    final index = _pending.indexWhere((r) => r.id == id);
    if (index < 0) return;
    final req = _pending.removeAt(index);
    if (!req._completer.isCompleted) req._completer.complete(approved);
    notifyListeners();
  }

  /// Drops every pending request of [sessionId], answering them as denied so
  /// the awaiting engine wakes up. Used when the session's turn is stopped or
  /// the session is deleted while an approval is still pending.
  void dropForSession(String sessionId) {
    final doomed = _pending.where((r) => r.sessionId == sessionId).toList();
    if (doomed.isEmpty) return;
    for (final req in doomed) {
      _pending.remove(req);
      if (!req._completer.isCompleted) req._completer.complete(false);
    }
    notifyListeners();
  }
}
