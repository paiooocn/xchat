enum RunKind { done, blockedLayerA, blockedExceptionYolo, error }

class RunResult {
  final RunKind kind;
  final String? message;
  RunResult(this.kind, {this.message});
}
