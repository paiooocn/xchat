import 'dart:io';

import 'package:path/path.dart' as p;

/// 已安装的 Python 包（由 `*.dist-info` 解析而来）。
class PythonPackage {
  const PythonPackage({
    required this.name,
    required this.version,
    required this.summary,
    required this.distInfoDir,
    this.files = const <String>[],
  });

  /// 包名（规范写法，如 `python-docx`）。
  final String name;

  /// 版本号。
  final String version;

  /// 包自带的英文简介（METADATA 的 Summary）。
  final String summary;

  /// `*.dist-info` 目录绝对路径。
  final String distInfoDir;

  /// RECORD 中登记的文件（相对包目录）。
  final List<String> files;

  String get key => name.toLowerCase();

  /// 中文说明：内置词表优先；未收录时回落到包自身的简介。
  String get description {
    final known = kPythonPackageDescriptions[key];
    if (known != null) return known;
    if (summary.isNotEmpty) return '$summary（上游简介，无内置中文说明）';
    return '第三方 Python 包（无内置说明）';
  }
}

/// 常见第三方库的中文说明（键为小写包名）。
const Map<String, String> kPythonPackageDescriptions = <String, String>{
  'pandas': '表格数据处理（DataFrame）：读写 CSV/Excel、筛选聚合、透视表',
  'numpy': '多维数值计算与数组运算，pandas 的底层依赖',
  'scipy': '科学计算工具箱：插值、优化、统计、信号处理',
  'matplotlib': '绘图（折线/柱状/散点/3D），可保存为 PNG/SVG',
  'seaborn': '基于 matplotlib 的统计图表，样式更美观',
  'plotly': '交互式网页图表（可缩放、悬停提示）',
  'pillow': '图片处理（缩放、裁剪、格式转换、合成）',
  'opencv-python': '计算机视觉图像处理（人脸、颜色、几何）',
  'imageio': '多格式图片/视频读写（GIF、MP4 等）',
  'requests': 'HTTP 网络请求（GET/POST、代理、超时控制）',
  'httpx': '新一代异步 HTTP 客户端，支持 HTTP/2',
  'aiohttp': '异步 HTTP 客户端/服务端框架',
  'beautifulsoup4': 'HTML/XML 解析，配合 CSS 选择器抽取网页结构',
  'lxml': '高性能 XML/HTML 解析与 XPath 查询',
  'html5lib': '符合 HTML5 规范的容错解析器',
  'selenium': '浏览器自动化（驱动 Chrome/Edge 操作页面）',
  'playwright': '浏览器自动化与截图，支持 Chromium/Firefox/WebKit',
  'scrapy': '爬虫框架：并发抓取、链接解析、数据管道',
  'openpyxl': '读写 Excel (.xlsx) 文件，保留公式与样式',
  'xlsxwriter': '生成 Excel/图表文件（只写、格式丰富）',
  'xlrd': '读取旧版 Excel (.xls) 文件',
  'python-docx': '读写 Word 文档 (.docx)',
  'python-pptx': '读写 PowerPoint 演示文稿 (.pptx)',
  'pypdf': 'PDF 读取、合并、拆分、提取文本',
  'pymupdf': 'PDF 解析与渲染（文本/图片提取、页面转图）',
  'reportlab': '生成 PDF 文件（报表、发票、图表导出）',
  'pyyaml': '解析与生成 YAML 配置',
  'toml': '解析 TOML 配置',
  'jinja2': '模板引擎，用于生成文本/配置/网页',
  'chardet': '检测文本编码（GBK/UTF-8 等），解决乱码',
  'charset-normalizer': '检测并统一文本编码，chardet 的替代品',
  'tqdm': '进度条，用于长耗时循环与下载',
  'rich': '终端富文本输出（表格、进度条、彩色日志）',
  'colorama': 'Windows 终端 ANSI 颜色支持',
  'loguru': '更好用的日志库（自动着色、滚动文件）',
  'click': '命令行参数解析，用于开发 CLI 工具',
  'typer': '基于类型注解的命令行框架',
  'argparse': '标准库命令行参数解析（内置）',
  'six': 'Python 2/3 兼容辅助库',
  'packaging': '版本号解析与比较（内置依赖）',
  'setuptools': 'Python 包安装与构建工具（内置）',
  'wheel': 'Python 打包格式（内置）',
  'pip': 'Python 包安装器（内置）',
  'virtualenv': '创建隔离的 Python 虚拟环境',
  'jieba': '中文分词，用于关键词提取与文本切分',
  'opencc': '简繁体转换与中英文替换',
  'regex': '功能更强的正则引擎（回溯控制更灵活）',
  'psutil': '查看系统/进程资源（CPU、内存、磁盘）',
  'watchdog': '监听文件系统变更（热重载、文件监控）',
  'faker': '生成随机测试数据（姓名、地址、身份证等）',
  'cryptography': '加解密与数字签名（国密/AES/RSA）',
  'pycryptodome': '另一套加解密库（Crypto.* 系列 API）',
  'tenacity': '重试装饰器，提升网络调用的健壮性',
  'retrying': '失败重试装饰器',
  'pydantic': '数据模型与校验（类型驱动的配置解析）',
  'sqlalchemy': 'SQL ORM：模型定义、查询与数据库迁移',
  'alembic': 'SQLAlchemy 的数据库版本迁移工具',
  'psycopg2-binary': 'PostgreSQL 数据库驱动',
  'pymysql': 'MySQL 数据库驱动',
  'redis': 'Redis 客户端（缓存/队列）',
  'flask': '轻量 Web 服务框架',
  'fastapi': '高性能异步 Web 框架，自动生成接口文档',
  'uvicorn': 'ASGI 服务器，运行 FastAPI 等应用',
  'django': '全栈 Web 框架（含 ORM、模板、后台）',
  'openai': '调用 OpenAI 兼容接口的官方 SDK',
  'anthropic': '调用 Anthropic Claude 接口的官方 SDK',
  'sentence-transformers': '文本向量嵌入与语义相似度检索',
  'transformers': 'HuggingFace 预训练模型（文本/多模态）',
  'torch': 'PyTorch 深度学习框架（张量、训练、推理）',
  'tensorflow': 'TensorFlow 深度学习框架',
  'onnxruntime': 'ONNX 模型推理引擎（跨平台、高性能）',
  'networkx': '图论与网络分析（社交网络、路径规划）',
  'sympy': '符号数学计算（公式推导、化简）',
  'statsmodels': '统计建模与时间序列分析',
  'duckdb': '嵌入式分析型数据库，直接查询 CSV/Parquet',
  'pyarrow': 'Apache Arrow 列式内存格式，支撑 Parquet',
  'tabulate': '把列表/字典对齐打印成表格',
  'prettytable': '带边框的 ASCII 表格输出',
  'markdown': 'Markdown 解析与渲染',
  'mistune': '轻量 Markdown 解析器',
  'pygments': '代码语法高亮',
  'docx2pdf': 'Word 转 PDF（依赖本机 Office）',
  'qrcode': '生成二维码图片',
  'barcode': '生成条形码图片',
  'pyautogui': '模拟键鼠操作与屏幕截图',
  'keyboard': '监听全局键盘输入',
  'pyperclip': '读写系统剪贴板',
  'appdirs': '获取系统标准的配置/数据/缓存目录',
  'platformdirs': '跨平台的目录位置工具',
  'user-agents': '随机生成浏览器 User-Agent',
  'fake-useragent': '随机 User-Agent 数据集',
  'xmltodict': 'XML 与 dict 互转',
  'dicttoxml': 'dict 转 XML',
  'simplejson': 'JSON 解析增强版（Decimal、注释支持）',
  'ujson': '更快的 JSON 编解码库',
  'orjson': '极速 JSON 编解码（Rust 实现）',
  'msgpack': '二进制紧凑序列化格式',
  'pycryptodomex': 'Cryptodome 的兼容命名空间包',
  'gunicorn': 'Linux 上的 WSGI 生产服务器',
  'supervisor': '进程守护与自动重启',
  'watchfiles': '高效文件变更监听（Rust 实现）',
  'joblib': '任务并行与结果缓存（scikit-learn 依赖）',
  'joblib-memory': 'joblib 的内存缓存扩展',
  'numba': '用 LLVM JIT 加速数值循环',
  'cython': '把 Python 编译成 C 扩展的工具链',
  'pyinstaller': '把 Python 程序打包成独立可执行文件',
  'nuitka': '把 Python 程序编译为可执行文件',
  'pyinstaller-hooks-contrib': 'PyInstaller 的第三方 hook 集合',
  'pywin32': 'Windows 专有 API（COM、注册表、窗口）',
  'pywin32-ctypes': 'pywin32 的 ctypes 子包',
  'comtypes': '通过 COM 调用 Windows 组件',
  'uiautomation': 'Windows UI 自动化（元素查找与点击）',
  'pyuiautomation': 'Windows UI 自动化库',
};

/// 读取 pip 包目录（`--target` 安装目录）里的已安装包。
class PythonPackageStore {
  const PythonPackageStore._();

  /// 列出 [packagesDir] 下所有 `*.dist-info` 对应的包。
  static Future<List<PythonPackage>> list(String packagesDir) async {
    final dir = Directory(packagesDir);
    if (!dir.existsSync()) return const <PythonPackage>[];
    final out = <PythonPackage>[];
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (!name.endsWith('.dist-info')) continue;
      final meta = parseMetadata(_read(p.join(entity.path, 'METADATA')));
      final record = parseRecord(_read(p.join(entity.path, 'RECORD')));
      out.add(PythonPackage(
        name: meta.name.isEmpty ? name.replaceFirst(RegExp(r'\.dist-info$'), '') : meta.name,
        version: meta.version,
        summary: meta.summary,
        distInfoDir: entity.path,
        files: record,
      ));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// 解析 METADATA（RFC822 风格），取 Name / Version / Summary。
  static ({String name, String version, String summary}) parseMetadata(String content) {
    var name = '';
    var version = '';
    var summary = '';
    for (final raw in content.split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty) break; // 空行之后是正文
      if (line.startsWith(' ')) continue; // 续行
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).trim().toLowerCase();
      final value = line.substring(idx + 1).trim();
      switch (key) {
        case 'name':
          name = value;
        case 'version':
          version = value;
        case 'summary':
          summary = value;
      }
    }
    return (name: name, version: version, summary: summary);
  }

  /// 解析 RECORD（CSV），取文件路径列。
  static List<String> parseRecord(String content) {
    final out = <String>[];
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final path = trimmed.split(',').first.trim();
      if (path.isNotEmpty) out.add(path);
    }
    return out;
  }

  /// 卸载一个包：按 RECORD 删除其文件，再删除 `*.dist-info`。
  ///
  /// 只删除位于 [packagesDir] 内的文件，避免误删外部路径。
  /// 返回被删除的文件数。
  static Future<int> uninstall(PythonPackage pkg, String packagesDir) async {
    final root = p.normalize(p.absolute(packagesDir));
    var removed = 0;
    for (final rel in pkg.files) {
      final target = p.normalize(p.absolute(p.join(root, rel)));
      if (!p.isWithin(root, target) && target != root) continue;
      final file = File(target);
      if (file.existsSync()) {
        try {
          await file.delete();
          removed++;
        } catch (_) {
          // 被占用或只读时跳过，最后再删 dist-info。
        }
      }
    }
    final dir = Directory(pkg.distInfoDir);
    if (dir.existsSync()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 忽略。
      }
    }
    return removed;
  }

  static String _read(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return '';
      return file.readAsStringSync();
    } catch (_) {
      return '';
    }
  }
}
