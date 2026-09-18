import 'dart:io';

import 'package:path/path.dart' as p;

/// Thrown when a tool tries to touch a path outside the session sandbox.
class SandboxViolation implements Exception {
  SandboxViolation(this.message);

  final String message;

  @override
  String toString() => 'SandboxViolation: $message';
}

/// Resolves [candidate] inside [sandbox] and rejects escapes.
class PathGuard {
  PathGuard(this.sandbox);

  final String sandbox;

  String resolve(String candidate) {
    final base = p.normalize(p.absolute(sandbox));
    final raw = candidate.trim();
    if (raw.isEmpty) {
      throw SandboxViolation('empty path');
    }
    final joined = p.isAbsolute(raw) ? raw : p.join(base, raw);
    final normalized = p.normalize(p.absolute(joined));
    if (normalized != base && !p.isWithin(base, normalized)) {
      throw SandboxViolation('path "$candidate" escapes sandbox "$sandbox"');
    }
    return normalized;
  }

  /// Like [resolve] but also follows symlinks to catch link-based escapes.
  String resolveReal(String candidate) {
    final resolved = resolve(candidate);
    try {
      final file = File(resolved);
      if (file.existsSync() || Link(resolved).existsSync()) {
        final real = file.resolveSymbolicLinksSync();
        final base = p.normalize(p.absolute(sandbox));
        if (real != base && !p.isWithin(base, real)) {
          throw SandboxViolation('path "$candidate" escapes sandbox via symlink');
        }
        return real;
      }
    } catch (error) {
      if (error is SandboxViolation) rethrow;
    }
    return resolved;
  }
}
