import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/agent/tools/builtin_tools.dart';
import 'package:xchat/models/shell_exec.dart';

void main() {
  group('ShellExecConfig.resolve', () {
    test('windows default is cmd /c', () {
      final resolved = const ShellExecConfig().resolve(isWindows: true);
      expect(resolved.executable, 'cmd');
      expect(resolved.argumentsFor('echo hi'), ['/c', 'echo hi']);
    });

    test('posix default is /bin/bash -lc', () {
      final resolved = const ShellExecConfig().resolve(isWindows: false);
      expect(resolved.executable, '/bin/bash');
      expect(resolved.argumentsFor('ls -la'), ['-lc', 'ls -la']);
    });

    test('empty args template is derived from the executable', () {
      final resolved =
          const ShellExecConfig(executable: r'C:\tools\pwsh.exe').resolve(isWindows: true);
      expect(resolved.executable, r'C:\tools\pwsh.exe');
      expect(resolved.argumentsFor('dir'), ['-NoProfile', '-NonInteractive', '-Command', 'dir']);
    });

    test('sh derives -c, wsl derives -e bash -lc', () {
      final sh = const ShellExecConfig(executable: '/bin/sh').resolve(isWindows: false);
      expect(sh.argsTemplate, '-c {command}');
      final wsl = const ShellExecConfig(executable: 'wsl').resolve(isWindows: true);
      expect(wsl.argsTemplate, '-e bash -lc {command}');
    });

    test('explicit template wins; command stays one argument', () {
      final resolved = const ShellExecConfig(
        executable: 'bash',
        argsTemplate: '-c {command} -x',
      ).resolve(isWindows: false);
      expect(resolved.argumentsFor('a b  c'), ['-c', 'a b  c', '-x']);
    });

    test('template without placeholder appends the command', () {
      final resolved = const ShellExecConfig(
        executable: 'wsl',
        argsTemplate: '-d Ubuntu',
      ).resolve(isWindows: true);
      expect(resolved.argumentsFor('whoami'), ['-d', 'Ubuntu', 'whoami']);
    });

    test('blank template falls back to the exe-derived one', () {
      final resolved = const ShellExecConfig(
        executable: 'cmd',
        argsTemplate: '   ',
      ).resolve(isWindows: true);
      expect(resolved.argsTemplate, '/c {command}');
    });

    test('isDefault reflects blank settings only', () {
      expect(const ShellExecConfig().isDefault, isTrue);
      expect(const ShellExecConfig(executable: '  ').isDefault, isTrue);
      expect(const ShellExecConfig(executable: 'x').isDefault, isFalse);
      expect(const ShellExecConfig(argsTemplate: '/c {command}').isDefault, isFalse);
    });
  });

  group('shellExecPresets', () {
    test('windows offers cmd / powershell / pwsh with full paths', () {
      final presets = shellExecPresets(isWindows: true);
      expect(presets.map((p) => p.id), ['default', 'cmd', 'powershell', 'pwsh']);
      expect(presets[1].executable, r'C:\Windows\System32\cmd.exe');
      expect(presets[2].executable, r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe');
      expect(presets[3].executable, r'C:\Program Files\PowerShell\7\pwsh.exe');
    });

    test('linux/macos offers /bin/bash', () {
      final presets = shellExecPresets(isWindows: false);
      expect(presets.map((p) => p.id), ['default', 'bash']);
      expect(presets[1].executable, '/bin/bash');
    });

    test('every candidate resolves into spawn parameters', () {
      for (final isWindows in [true, false]) {
        for (final preset in shellExecPresets(isWindows: isWindows)) {
          final resolved = ShellExecConfig(
            executable: preset.executable,
            argsTemplate: preset.argsTemplate,
          ).resolve(isWindows: isWindows);
          expect(resolved.argumentsFor('echo x'), isNotEmpty);
          expect(resolved.argumentsFor('echo x').last, isNotEmpty);
        }
      }
    });
  });

  group('shellFamilyFor', () {
    test('classifies by basename, case-insensitive, .exe optional', () {
      expect(shellFamilyFor(r'C:\Windows\System32\cmd.exe'), ShellFamily.cmd);
      expect(shellFamilyFor(r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'),
          ShellFamily.powershell);
      expect(shellFamilyFor(r'C:\Program Files\PowerShell\7\pwsh.exe'), ShellFamily.powershell);
      expect(shellFamilyFor('PowerShell'), ShellFamily.powershell);
      expect(shellFamilyFor('/bin/bash'), ShellFamily.posix);
      expect(shellFamilyFor('zsh'), ShellFamily.posix);
      expect(shellFamilyFor('wsl'), ShellFamily.posix);
      expect(shellFamilyFor('tcsh'), ShellFamily.unknown);
      expect(shellFamilyFor(''), ShellFamily.unknown);
    });
  });

  group('commandSyntaxNotes (LLM guidance)', () {
    test('cmd notes forbid double quotes and name %VAR% / caret', () {
      final notes = commandSyntaxNotes(ShellFamily.cmd);
      expect(notes, contains('严禁'));
      expect(notes, contains('双引号'));
      expect(notes, contains('%VAR%'));
      expect(notes, contains('短路径'));
    });

    test('powershell notes name the backtick as the escape character', () {
      final notes = commandSyntaxNotes(ShellFamily.powershell);
      expect(notes, contains('反引号'));
      expect(notes, contains(r'$env:'));
    });

    test('posix notes name single quotes and printf', () {
      final notes = commandSyntaxNotes(ShellFamily.posix);
      expect(notes, contains('单引号'));
      expect(notes, contains('printf'));
    });

    test('every family warns about non-interactive stdin', () {
      for (final family in ShellFamily.values) {
        expect(commandSyntaxNotes(family), contains('非交互'));
      }
    });

    test('shell description embeds the notes of the configured shell', () {
      final cmdTools = BuiltinTools.build(
        sandbox: '.',
        enabled: const ['shell'],
        shellExec: const ShellExecConfig(executable: 'cmd'),
      );
      expect(cmdTools.single.description, contains('严禁'));

      final psTools = BuiltinTools.build(
        sandbox: '.',
        enabled: const ['shell'],
        shellExec: const ShellExecConfig(executable: 'pwsh'),
      );
      expect(psTools.single.description, contains('反引号'));
    });
  });

  group('decodeShellOutput', () {
    test('decodes UTF-8 as-is', () {
      expect(decodeShellOutput(utf8.encode('abc 中文')), 'abc 中文');
    });

    test('non-UTF-8 bytes never throw and use the system encoding', () {
      // GBK bytes of `中文测试` as captured from `cmd /c echo 中文测试`.
      const gbk = <int>[214, 208, 206, 196, 178, 226, 202, 212, 13, 10];
      final text = decodeShellOutput(gbk);
      if (Platform.isWindows) {
        expect(text, contains('中文测试'));
      } else {
        expect(text, isNotEmpty);
      }
    });

    test('empty input stays empty', () {
      expect(decodeShellOutput(const <int>[]), '');
    });
  });

  group('BuiltinTools shell tool (LLM-facing metadata)', () {
    test('description and command schema name the configured shell', () {
      final tools = BuiltinTools.build(
        sandbox: '.',
        enabled: const ['shell'],
        shellExec: const ShellExecConfig(
          executable: 'pwsh',
          argsTemplate: '-Command {command}',
        ),
      );
      final shell = tools.single;
      expect(shell.name, 'shell');
      expect(shell.description, contains('pwsh'));
      expect(shell.description, contains('-Command {command}'));
      final schema = shell.parameters.toString();
      expect(schema, contains('pwsh'));
    });

    test('description falls back to the platform default shell', () {
      final tools = BuiltinTools.build(sandbox: '.', enabled: const ['shell']);
      final defaultExe = Platform.isWindows ? 'cmd' : '/bin/bash';
      expect(tools.single.description, contains(defaultExe));
    });
  });
}
