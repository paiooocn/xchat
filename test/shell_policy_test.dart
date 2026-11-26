import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/models/agent_mode.dart';
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

  group('清理/删除类任务识别（当轮临时提级用）', () {
    test('动作词 + 对象词同时出现才算命中', () {
      expect(isCleanupDeleteTask('帮我清理一下临时文件'), isTrue);
      expect(isCleanupDeleteTask('删除 ~/Downloads 目录'), isTrue);
      expect(isCleanupDeleteTask('把这些邮件按年份归档后删除'), isTrue);
      expect(isCleanupDeleteTask('清空一下邮箱'), isTrue);
      expect(isCleanupDeleteTask('please delete the temp folder'), isTrue);
      expect(isCleanupDeleteTask('清理一下 session 的字段命名'), isFalse);
      expect(isCleanupDeleteTask('解释一下删除操作的实现'), isFalse);
      expect(isCleanupDeleteTask(''), isFalse);
      expect(isCleanupDeleteTask(null), isFalse);
      // 英文按词边界：profile 不算 file。
      expect(isCleanupDeleteTask('delete the profile key'), isFalse);
    });
  });

  group('清理/删除类任务的当轮提级', () {
    const userCmd = 'rm todel && ls -la todel 2>&1; echo "---"; ls | head';

    test('配置 2 级 + 清理/删除类消息 → 本轮 3 级；其它消息仍 2 级', () {
      final config = AppConfig();
      expect(config.shellBaseLevel, 2);
      expect(config.shellBaseLevelFor('删除 todel 目录'), 3);
      expect(config.shellBaseLevelFor('把这些临时文件清理掉'), 3);
      expect(config.shellBaseLevelFor('delete the temp folder'), 3);
      expect(config.shellBaseLevelFor('跑一下 rm todel 看看'), 2); // 无对象词
      expect(config.shellBaseLevelFor(userCmd), 2); // 命令文本不算任务描述
      expect(config.shellBaseLevelFor(null), 2);
    });

    test('配置已是 3 级时提级无副作用', () {
      final config = AppConfig()..toolApprovals['shell'] = 3;
      expect(config.shellBaseLevelFor('删除所有临时文件'), 3);
      expect(config.shellBaseLevelFor('你好'), 3);
    });

    test('提级后的 3 级在托管模式下确实需要审批', () {
      // 未登记命令：base 2 时托管模式不审批（这就是「直接执行」的机制）。
      expect(requiresApproval(2, AgentMode.managed), isFalse);
      // 提级到 3 级后，托管模式也必须审批。
      expect(requiresApproval(3, AgentMode.managed), isTrue);
    });
  });

  group('复合命令逐段判定（取最严）', () {
    // 用户实测的两条命令：rm 已从 2 级名单剔除，ls/file/true 在 1 级名单里。
    final l2WithoutRm =
        l2.where((entry) => entry.trim() != r'\brm\b').toList(growable: false);
    final l1Custom = <String>[r'\bls\b', r'\bfile\b', r'\btrue\b', r'\bgit\b'];

    ShellClassification classifyUser(String command, int baseLevel) =>
        classifyShellCommand(
          command,
          level1: l1Custom,
          level2: l2WithoutRm,
          denied: const <String>[r'\bsudo\b'],
          baseLevel: baseLevel,
        );

    test('splitShellSegments 不把 2>&1 当分隔符', () {
      expect(
        splitShellSegments('ls -la todel 2>&1 || true'),
        <String>['ls -la todel 2>&1', 'true'],
      );
      expect(
        splitShellSegments('rm -f a && ls b; echo c | head'),
        <String>['rm -f a', 'ls b', 'echo c', 'head'],
      );
    });

    test('提级轮次：rm 段未登记 → 整体 3 级（不被 1 级的 ls/true 压低）', () {
      final rmCmd = classifyUser('rm -f todel && ls -la todel 2>&1 || true', 3);
      expect(rmCmd.denied, isFalse);
      expect(rmCmd.level, 3);
      expect(rmCmd.match, ShellMatch.base);
      // 托管模式（3）下必须审批 —— 这才是「提级」应有的效果。
      expect(requiresApproval(rmCmd.level, AgentMode.managed), isTrue);
    });

    test('只提「未登记」命令：全部命中 1 级名单的复合命令仍是 1 级', () {
      final lsCmd =
          classifyUser('ls -la todel 2>/dev/null; file todel 2>/dev/null', 3);
      expect(lsCmd.match, ShellMatch.level1);
      expect(lsCmd.level, 1);
      expect(requiresApproval(lsCmd.level, AgentMode.managed), isFalse);
    });

    test('普通轮次：未登记段按 base 2 级，登记段仍按名单', () {
      expect(classifyUser('rm -f todel && ls -la', 2).level, 2);
      expect(classifyUser('git status', 2).level, 1);
      // 未登记段（myscript.sh）把整体抬到 base 2；纯 1 级段组合仍是 1。
      expect(classifyUser('git status && ./myscript.sh', 2).level, 2);
      expect(classifyUser('git status && ls', 2).level, 1);
    });

    test('任一段命中 F 级 → 整条拒绝', () {
      expect(classifyUser('echo hi; sudo rm -rf /', 3).denied, isTrue);
    });
  });

  group('shell 基础等级配置', () {
    test('默认 2 级，可设 3 级，越界值被夹到 [2,3]', () {
      final config = AppConfig();
      expect(config.shellBaseLevel, 2);
      config.toolApprovals['shell'] = 3;
      expect(config.shellBaseLevel, 3);
      config.toolApprovals['shell'] = 0;
      expect(config.shellBaseLevel, 2);
    });

    test('JSON 往返保留 3 级，旧值 0/1 读出为 2', () {
      final config = AppConfig()..toolApprovals['shell'] = 3;
      expect(AppConfig.fromJson(config.toJson()).shellBaseLevel, 3);
      final legacy = config.toJson()
        ..['tool_approvals'] = <String, Object?>{'shell': 1};
      expect(AppConfig.fromJson(legacy).shellBaseLevel, 2);
    });
  });
}
