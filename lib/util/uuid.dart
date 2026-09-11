import 'dart:math';

String uuidV4() {
  final r = Random.secure();
  String hex(int len) {
    final s = List.generate(len, (_) => r.nextInt(16).toRadixString(16)).join();
    return s;
  }
  // 8-4-4-4-12
  return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
}
