import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/agent/tools/builtin_tools.dart';
import 'package:xchat/core/python_packages.dart';
import 'package:xchat/core/python_runtime.dart';
import 'package:xchat/models/proxy_config.dart';
import 'package:xchat/models/shell_exec.dart';

void main() {
  group('pip 镜像链', () {
    test('默认顺序为 清华 → 阿里 → 官方', () {
      expect(kDefaultPipIndexUrls.length, 3);
      expect(kDefaultPipIndexUrls.map(pipIndexName).toList(),
          <String>['清华', '阿里', '官方']);
    });

    test('未知源点显示为自定义', () {
      expect(pipIndexName('https://example.com/simple'), '自定义');
    });
  });

  group('子进程环境', () {
    PythonRuntime runtime() => const PythonRuntime(
          executable: '/opt/python/bin/python3',
          home: '/opt/python',
          binDir: '/opt/python/bin',
          packagesDir: '/data/runtime/pypkgs',
          origin: PythonOrigin.builtin,
          version: '3.12.11',
        );

    test('PATH 前置内置解释器，PYTHONPATH 指向包目录', () {
      final env = runtime().childEnvironment();
      expect(env['PATH']!.startsWith('/opt/python/bin'), isTrue);
      expect(env['PYTHONPATH'], contains('/data/runtime/pypkgs'));
      expect(env['PYTHONNOUSERSITE'], '1');
    });

    test('代理与 pip 镜像写入环境变量', () {
      final env = runtime().childEnvironment(
        proxy: ProxyConfig(
          httpProxy: 'http://127.0.0.1:7890',
          httpsProxy: 'http://127.0.0.1:7890',
          noProxy: 'localhost,127.0.0.1',
        ),
        pipIndexes: kDefaultPipIndexUrls,
      );
      expect(env['HTTP_PROXY'], 'http://127.0.0.1:7890');
      expect(env['HTTPS_PROXY'], 'http://127.0.0.1:7890');
      expect(env['NO_PROXY'], 'localhost,127.0.0.1');
      expect(env['PIP_INDEX_URL'], kDefaultPipIndexUrls.first);
      expect(env['PIP_EXTRA_INDEX_URL'], contains(kDefaultPipIndexUrls[1]));
      expect(env['PIP_EXTRA_INDEX_URL'], contains(kDefaultPipIndexUrls[2]));
    });

    test('额外 PYTHONPATH 目录追加在包目录之后', () {
      final env = runtime().childEnvironment(extraPaths: <String>['/data/extra']);
      expect(env['PYTHONPATH'], '/data/runtime/pypkgs$kPathListSeparator/data/extra');
    });

    test('pip 缓存目录写入环境变量', () {
      final env = runtime().childEnvironment(pipCacheDir: '/data/runtime/pip-cache');
      expect(env['PIP_CACHE_DIR'], '/data/runtime/pip-cache');
    });

    test('PATH 沿用父环境的大小写写法，不会出现 PATH/Path 两条记录', () {
      final env = runtime().childEnvironment();
      final pathKeys = env.keys.where((k) => k.toUpperCase() == 'PATH').toList();
      expect(pathKeys.length, 1, reason: 'PATH 必须唯一，否则子进程取到哪一条不确定');
      expect(env[pathKeys.single]!.startsWith('/opt/python/bin'), isTrue);
    });
  });

  group('已安装包解析', () {
    test('METADATA 解析 Name/Version/Summary', () {
      final meta = PythonPackageStore.parseMetadata(
        'Metadata-Version: 2.1\n'
        'Name: pandas\n'
        'Version: 2.2.2\n'
        'Summary: Powerful data structures for data analysis\n'
        '\n'
        'Long description...\n',
      );
      expect(meta.name, 'pandas');
      expect(meta.version, '2.2.2');
      expect(meta.summary, contains('data analysis'));
    });

    test('RECORD 解析文件路径', () {
      final files = PythonPackageStore.parseRecord(
        'pandas/__init__.py,sha256=abc,12\n'
        'pandas-2.2.2.dist-info/RECORD,,\n',
      );
      expect(files.length, 2);
      expect(files.first, 'pandas/__init__.py');
    });

    test('内置中文说明命中词表', () {
      const pkg = PythonPackage(
        name: 'pandas',
        version: '2.2.2',
        summary: 'Powerful data structures',
        distInfoDir: '/tmp/pandas.dist-info',
      );
      expect(pkg.description, contains('表格数据处理'));
    });

    test('未收录的包回落到上游简介', () {
      const pkg = PythonPackage(
        name: 'xchat-私有的包',
        version: '0.1.0',
        summary: 'A private helper',
        distInfoDir: '/tmp/x.dist-info',
      );
      expect(pkg.description, contains('A private helper'));
    });
  });

  group('工具说明（发给 Agent 的内容）', () {
    test('shell 说明包含内置 Python 的版本、来源与用法', () {
      final tools = BuiltinTools.liveTools(
        pythonRuntime: const PythonRuntime(
          executable: '/opt/python/bin/python3',
          home: '/opt/python',
          binDir: '/opt/python/bin',
          packagesDir: '/data/runtime/pypkgs',
          origin: PythonOrigin.builtin,
          version: '3.12.13',
        ),
        pipIndexes: kDefaultPipIndexUrls,
      );
      final shell = tools.firstWhere((t) => t.name == 'shell');
      expect(shell.description, contains('3.12.13'));
      expect(shell.description, contains('内置'));
      expect(shell.description, contains('python3 xxx.py'));
      // 登录型 shell 可能重写 PATH，故说明里必须给出解释器绝对路径兜底。
      expect(shell.description, contains('/opt/python/bin/python3'));
      // 参数 schema 一并可读（工具管理页展示用）。
      expect(shell.parameters['properties'], isA<Map>());
    });

    test('每个内置工具都有可展示的说明', () {
      final tools = BuiltinTools.liveTools();
      expect(tools.length, BuiltinTools.descriptions.length);
      for (final tool in tools) {
        expect(tool.description, isNotEmpty, reason: tool.name);
      }
    });
  });

  group('shell 工具的 Python 环境注入', () {
    test('PYTHONPATH / PIP_CACHE_DIR / PIP_INDEX_URL 传给子进程', () async {
      if (Platform.isWindows) return; // Windows 无 POSIX shell
      final tools = BuiltinTools.build(
        sandbox: Directory.systemTemp.path,
        enabled: const <String>['shell'],
        shellExec: const ShellExecConfig(
          executable: '/bin/sh',
          argsTemplate: '-c $kShellCommandPlaceholder',
        ),
        pythonRuntime: const PythonRuntime(
          executable: '/usr/bin/python3',
          home: '/usr',
          binDir: '/usr/bin',
          packagesDir: '/data/runtime/pypkgs',
          origin: PythonOrigin.builtin,
          version: '3.12.13',
        ),
        pipIndexes: kDefaultPipIndexUrls,
        pythonExtraPaths: const <String>['/data/extra'],
        pipCacheDir: '/data/runtime/pip-cache',
      );
      final out = await tools.first.call(<String, Object?>{
        'command': 'env | grep -E "^(PYTHONPATH|PIP_CACHE_DIR|PIP_INDEX_URL|PATH)="',
      });
      final text = '$out';
      expect(text, contains('/data/runtime/pypkgs'));
      expect(text, contains('/data/extra'));
      expect(text, contains('/data/runtime/pip-cache'));
      expect(text, contains(kDefaultPipIndexUrls.first));
      // 内置解释器目录被前置到 PATH 首位。
      expect(RegExp(r'^PATH=/usr/bin[:;]', multiLine: true).hasMatch(text), isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
