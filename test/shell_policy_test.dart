import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/models/app_config.dart';
import 'package:xchat/models/shell_policy.dart';

void main() {
  final l1 = AppConfig.defaultShellLevel1Commands();
  final l2 = AppConfig.defaultShellLevel2Commands();
  final f = AppConfig.defaultShellDeniedCommands();

  ShellClassification classify(String command) => classifyShellCommand(
        command,
        level1: l1,
        level2: l2,
        denied: f,
        baseLevel: 3,
      );

  test('F级 regex blocks rm -rf / and variants', () {
    expect(classify('rm -rf /').denied, isTrue);
    expect(classify('rm -fr /').denied, isTrue);
    expect(classify('sudo rm -rf /').denied, isTrue);
    expect(classify('rm -rf /usr').denied, isTrue);
  });

  test('F级 regex blocks privilege escalation', () {
    expect(classify('sudo apt update').denied, isTrue);
    expect(classify('shutdown -h now').denied, isTrue);
  });

  test('2级 commands are not denied, level 2', () {
    final result = classify('rm -rf build/');
    expect(result.denied, isFalse);
    expect(result.level, 2);
    expect(classify('mv a b').level, 2);
  });

  test('1级 commands map to level 1', () {
    final result = classify('git status');
    expect(result.denied, isFalse);
    expect(result.level, 1);
  });

  test('unknown command falls back to base level', () {
    final result = classify('echo hello');
    expect(result.denied, isFalse);
    expect(result.level, 3);
  });

  test('git init is not denied (init removed from list)', () {
    expect(classify('git init').denied, isFalse);
  });
}
