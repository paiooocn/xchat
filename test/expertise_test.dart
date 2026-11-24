import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/expertise_repository.dart';
import 'package:xchat/data/xml/template_xml.dart';
import 'package:xchat/models/expertise.dart';
import 'package:xchat/models/session_template.dart';

Expertise _item(
  String id,
  int sort, {
  String name = '',
  String description = '',
  String prompt = '',
}) =>
    Expertise(
      id: id,
      name: name.isEmpty ? id : name,
      description: description.isEmpty ? '说明 $id' : description,
      prompt: prompt.isEmpty ? '提示词 $id' : prompt,
      sort: sort,
    );

void main() {
  group('专长库加载', () {
    test('内置资源可解析且按 sort 升序', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final tmp = Directory.systemTemp.createTempSync('xchat_expertise_repo');
      final paths = await AppPaths.init(overrideRoot: tmp.path);
      final items = await ExpertiseRepository(paths).load();
      expect(items, isNotEmpty);
      for (var i = 1; i < items.length; i++) {
        expect(items[i - 1].sort, lessThanOrEqualTo(items[i].sort));
      }
      expect(items.map((e) => e.id),
          containsAll(<String>['programming', 'data_analysis', 'devops', 'education', 'translation']));
      expect(items.every((e) => e.name.isNotEmpty && e.prompt.isNotEmpty), isTrue);
    });

    test('接受包装/数组两种结构，跳过缺字段条目', () {
      final parsed = ExpertiseRepository.parseExpertiseAsset(
        '{"expertises":['
        '{"id":"a","name":"A","prompt":"p","sort":2},'
        '{"id":"b","name":"B","prompt":"q","sort":1},'
        '{"id":"c","name":"C","description":"没有提示词"}'
        ']}',
      );
      expect(parsed.map((e) => e.id), <String>['b', 'a']);

      expect(
        ExpertiseRepository.parseExpertiseAsset('[{"id":"z","name":"Z","prompt":"p"}]')
            .map((e) => e.id),
        <String>['z'],
      );
      expect(ExpertiseRepository.parseExpertiseAsset('不是 JSON'), isEmpty);
      expect(ExpertiseRepository.parseExpertiseAsset(''), isEmpty);
      expect(ExpertiseRepository.parseExpertiseAsset('{"expertises":[]}'), isEmpty);
    });
  });

  group('composeExpertisePrompt', () {
    test('按专长库 sort 组合，与点击顺序无关', () {
      // 传入故意乱序的库，组合仍按 sort。
      final library = <Expertise>[
        _item('c', 30),
        _item('a', 10),
        _item('b', 20),
      ];
      final composed = composeExpertisePrompt(<String>['c', 'a', 'b'], library);
      expect(composed, '提示词 a\n\n---\n\n提示词 b\n\n---\n\n提示词 c');

      // 反着点得到完全相同的结果。
      expect(composeExpertisePrompt(<String>['b', 'c', 'a'], library), composed);
    });

    test('跳过未知 id 与空提示词，重复 id 只拼一次', () {
      final library = <Expertise>[
        _item('a', 10),
        _item('empty', 20, prompt: '   '),
      ];
      expect(composeExpertisePrompt(<String>['a', 'missing', 'a'], library), '提示词 a');
      expect(composeExpertisePrompt(<String>['empty'], library), isEmpty);
    });

    test('旧版本 id 通过别名命中当前专长', () {
      final library = <Expertise>[
        Expertise(
          id: 'programming',
          name: '编程开发',
          description: '',
          prompt: '提示词 programming',
          aliases: const <String>['code_review', 'debugging'],
        ),
      ];
      expect(composeExpertisePrompt(<String>{'debugging'}, library), '提示词 programming');
      expect(hasUsableExpertiseSelection(<String>{'code_review'}, library), isTrue);
      // 别名不参与排序，仍按本体 sort。
      expect(
        composeExpertisePrompt(<String>{'code_review', 'a'}, [
          _item('a', 5),
          ...library,
        ]),
        '提示词 programming\n\n---\n\n提示词 a',
      );
    });

    test('未选择任何专长返回空串', () {
      expect(composeExpertisePrompt(const <String>[], <Expertise>[]), isEmpty);
      expect(composeExpertisePrompt(const <String>['a'], const <Expertise>[]), isEmpty);
    });

    test('同 sort 时按 id 稳定排序', () {
      final library = <Expertise>[_item('b', 5), _item('a', 5)];
      expect(composeExpertisePrompt(<String>['b', 'a'], library), '提示词 a\n\n---\n\n提示词 b');
    });
  });

  group('模板 XML 往返', () {
    test('写出并读回模式 / 手动文本 / 已选专长', () {
      final template = SessionTemplate(
        id: 'tpl-1',
        name: '编码',
        systemPrompt: '提示词 a\n\n---\n\n提示词 b',
        manualPrompt: '我手写的提示词',
        promptMode: SystemPromptMode.expertise,
        expertiseIds: <String>['a', 'b'],
      );
      final decoded = TemplateXml.decode(TemplateXml.encode(template));
      expect(decoded.promptMode, SystemPromptMode.expertise);
      expect(decoded.manualPrompt, '我手写的提示词');
      expect(decoded.expertiseIds, <String>['a', 'b']);
      expect(decoded.systemPrompt, '提示词 a\n\n---\n\n提示词 b');
    });

    test('旧模板（无新字段）按文本模式读取', () {
      const old =
          '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<template id="old"><name><![CDATA[旧模板]]></name>'
          '<system_prompt><![CDATA[你好]]></system_prompt></template>';
      final decoded = TemplateXml.decode(old);
      expect(decoded.promptMode, SystemPromptMode.text);
      expect(decoded.manualPrompt, isEmpty);
      expect(decoded.expertiseIds, isEmpty);
      expect(decoded.systemPrompt, '你好');
    });

    test('复制模板保留新字段', () {
      final template = SessionTemplate(
        id: 'tpl-1',
        name: '原',
        manualPrompt: '手写',
        promptMode: SystemPromptMode.expertise,
        expertiseIds: <String>['a'],
      );
      final copy = template.copyWith(name: '副本');
      expect(copy.promptMode, SystemPromptMode.expertise);
      expect(copy.manualPrompt, '手写');
      expect(copy.expertiseIds, <String>['a']);
    });
  });

  group('专长库用户改动', () {
    test('保存完整列表后重载：编辑覆盖 / 新增 / 删除墓碑 / 停用保留', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final tmp = Directory.systemTemp.createTempSync('xchat_expertise_store');
      final paths = await AppPaths.init(overrideRoot: tmp.path);
      final repository = ExpertiseRepository(paths);
      final base = await repository.load();
      expect(base.length, greaterThanOrEqualTo(2));
      final first = base.first;
      final second = base[1];
      final edited = first.copyWith(name: '${first.name}（改）', enabled: false);
      const custom = Expertise(
        id: 'my_own',
        name: '我的专长',
        description: '说明',
        prompt: '自定义提示词',
        sort: 5,
      );
      await repository.save(<Expertise>[
        custom,
        edited,
        ...base.skip(1).where((item) => item.id != second.id),
      ]);

      final reloaded = await repository.load();
      expect(reloaded.map((e) => e.id), contains('my_own'));
      expect(reloaded.firstWhere((e) => e.id == first.id).name, '${first.name}（改）');
      expect(reloaded.firstWhere((e) => e.id == first.id).enabled, isFalse);
      expect(reloaded.any((e) => e.id == second.id), isFalse);
      // 停用项不出现在待选项，也不参与组合。
      expect(
        composeExpertisePrompt(<String>{first.id, 'my_own'}, reloaded),
        '自定义提示词',
      );
      expect(hasUsableExpertiseSelection(<String>{first.id}, reloaded), isFalse);
      expect(hasUsableExpertiseSelection(<String>{'my_own'}, reloaded), isTrue);
    });

    test('merge：同 id 覆盖、未知 id 追加、墓碑删除', () {
      final base = <Expertise>[_item('a', 10), _item('b', 20)];
      final overrides = <Expertise>[_item('a', 10, name: 'A2'), _item('c', 30)];
      final merged = ExpertiseRepository.mergeExpertiseLibraries(base, overrides, <String>{'b'});
      expect(merged.map((e) => e.id), <String>['a', 'c']);
      expect(merged.first.name, 'A2');
      expect(
        ExpertiseRepository.mergeExpertiseLibraries(base, overrides, const <String>{})
            .map((e) => e.id),
        <String>['a', 'b', 'c'],
      );
    });

    test('用户文件损坏时退化为纯内置库', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final tmp = Directory.systemTemp.createTempSync('xchat_expertise_bad');
      final paths = await AppPaths.init(overrideRoot: tmp.path);
      await File(paths.expertiseFile).writeAsString('不是 JSON');
      final reloaded = await ExpertiseRepository(paths).load();
      expect(reloaded, isNotEmpty);
    });
  });
}
