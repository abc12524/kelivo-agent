import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart' show rootBundle;

import '../../../utils/app_directories.dart';
import '../device_tools_service.dart';
import 'tool_family.dart';

/// 已注册 skill 的元信息（解析脚本头部得到）。
class SkillMeta {
  final String name;
  final String description;
  final bool enabled;
  final String status;
  final String usage;
  final String path;

  const SkillMeta({
    required this.name,
    required this.description,
    required this.enabled,
    required this.status,
    required this.usage,
    required this.path,
  });
}

/// 工具族：skill —— 调用已注册的自建 Python 工具（不负责创建）。
///
/// 复刻 android-agent 的 skill 机制：`skills/<名>/skill.py` 按头部元信息
/// （`# skill` / `# description` / `# status` / `# usage`）自动注册；入口同目录可放
/// `_` 助手模块与 `config.json`。新增即生效、删除即注销，`_`/`.` 开头的目录不参与扫描。
/// 与内置工具族一样按「两段式」披露：
///
///   - 不传 action                    → 返回已注册 skill 清单（名称 + 简短说明）；
///   - action = <skill 名>             → 返回该 skill 的用法；
///   - action = <skill 名> + params    → 执行，params 即传给 run() 的参数字典；
///   - action = delete + params{skill} → 删除（注销）某个 skill 脚本。
///
/// 运行在 Android 内嵌 Python 3.13 或 Windows 配置的 Python（§设置 → Agent 工具）；
/// 其他桌面端暂不支持。
class SkillTool extends ToolFamily {
  SkillTool._();
  static final SkillTool instance = SkillTool._();

  /// skills 目录（AppData/skills）；每个子目录的 `skill.py` 会被自动注册
  /// （`_` / `.` 开头的目录除外）。
  Directory? _dir;

  /// 注册缓存：用「文件名 + 修改时间 + 大小」做签名，签名未变则复用。
  List<SkillMeta> _cache = const [];
  String _cachedSignature = '';
  bool _assetsDeployed = false;

  @override
  String get name => 'skill';

  @override
  List<SubTool> get subs => const [
    SubTool('delete', '删除（注销）某个 skill 脚本', 'delete: 需 params.skill = 要删除的 skill 名'),
  ];

  // 工具 schema 必须完全静态：不包含任何 skill 名称/说明，避免安装/删除 skill 时破坏前缀缓存。
  @override
  String get description =>
      '调用已注册的自建 Python 工具。'
      '不传 action 返回清单；action=<skill 名> 查看用法；'
      'action=<skill 名> + params 执行；action=delete 删除。';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'description': 'skill 名，或管理动作 delete；省略则返回已注册清单',
      },
      'params': {
        'type': 'object',
        'description': '执行时传给 skill run() 的参数字典；action=delete 时用 {skill: 名称}',
        'additionalProperties': true,
      },
    },
    'required': <String>[],
  };

  /// 已注册（启用）skill 名称，自动反映新增/删除。
  List<String> registeredSkillNames() =>
      _cache.where((s) => s.enabled).map((s) => s.name).toList();

  /// 全部已扫描 skill 元信息（含 disable），供设置页管理展示。
  List<SkillMeta> get skills => List.unmodifiable(_cache);

  /// skills 目录路径（未初始化时返回 null）。
  String? get directoryPath => _dir?.path;

  /// 扫描并缓存（幂等，按签名复用）。请求构建 / 启动时调用一次即可。
  Future<void> ensureScanned() async {
    final dir = await _skillsDir();
    await _deployAssets(dir);

    // 每个技能是一个目录：skills/<名>/skill.py 为入口
    final entries = <File>[];
    final children = dir.listSync()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final e in children) {
      if (e is! Directory) continue;
      final seg = e.uri.pathSegments.last;
      if (seg.startsWith('_') || seg.startsWith('.')) continue;
      final entry = File('${e.path}/skill.py');
      if (entry.existsSync()) entries.add(entry);
    }

    final signature = entries
        .map(
          (f) =>
              '${f.path}:${f.lastModifiedSync().millisecondsSinceEpoch}:${f.lengthSync()}',
        )
        .join(';');
    if (signature == _cachedSignature) return;
    _cache = entries.map(_parseHeader).whereType<SkillMeta>().toList();
    _cachedSignature = signature;
  }

  /// 使扫描缓存失效，下一次 [ensureScanned] 强制重扫（安装/删除 skill 后调用）。
  void invalidate() {
    _cachedSignature = '';
  }

  /// 改写某个 skill 入口脚本头部的 `# status:`（隐藏=disable / 取消隐藏=enable）。
  /// 返回 null 表示成功；否则为失败原因（找不到入口文件 / 读写失败）。
  String? setStatus(String path, String value) {
    final file = File(path);
    if (!file.existsSync()) return '找不到入口文件: $path';
    List<String> lines;
    try {
      lines = file.readAsLinesSync();
    } catch (_) {
      return '无法读取入口文件: $path';
    }
    // 头部块结束位置（首个非注释、非空行）
    var end = 0;
    while (end < lines.length) {
      final s = lines[end].trim();
      if (s.isNotEmpty && !s.startsWith('#')) break;
      end++;
    }
    var insertAt = -1;
    for (var i = 0; i < end; i++) {
      final t = lines[i].trim();
      if (_statusHeadRe.hasMatch(t)) {
        lines[i] = '# status: $value';
        return _writeHeader(file, lines);
      }
      if (insertAt < 0 && _descHeadRe.hasMatch(t)) insertAt = i + 1;
    }
    if (insertAt < 0) {
      for (var i = 0; i < end; i++) {
        if (_skillHeadRe.hasMatch(lines[i].trim())) {
          insertAt = i + 1;
          break;
        }
      }
    }
    if (insertAt < 0) insertAt = end;
    lines.insert(insertAt, '# status: $value');
    return _writeHeader(file, lines);
  }

  String? _writeHeader(File file, List<String> lines) {
    try {
      file.writeAsStringSync('${lines.join('\n')}\n');
      return null;
    } catch (e) {
      return '写入失败: $e';
    }
  }

  Future<Directory> _skillsDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final root = await AppDirectories.getAppDataDirectory();
    final dir = Directory('${root.path}/skills');
    _dir = dir;
    return dir;
  }

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    await ensureScanned();
    final action = (args['action'] as String?)?.trim() ?? '';

    // 未指定 action：返回已注册 skill 清单（仅名称 + 简短说明，逐步披露）
    if (action.isEmpty) return _manifest();

    // 管理动作：删除（注销）脚本
    if (action == 'delete') {
      final skill = (familyParams(args)['skill'] as String?)?.trim() ?? '';
      return _delete(skill);
    }

    final meta = _findByName(action);
    if (meta == null) {
      final available = _cache
          .where((s) => s.enabled)
          .map((s) => s.name)
          .join(', ');
      return jsonEncode({
        'status': 'error',
        'error': "未知 skill '$action'，可用: ${available.isEmpty ? '(空)' : available}",
      });
    }

    // 指定了 skill 名但未给 params：返回用法
    final hasParams =
        args.containsKey('params') ||
        args.keys.any((k) => k != 'action' && k != 'params');
    if (!hasParams) {
      return jsonEncode({
        'status': 'ok',
        'skill': meta.name,
        'description': meta.description,
        'enabled': meta.enabled,
        'usage': meta.usage,
        'path': meta.path,
      });
    }

    // 执行 skill
    return _run(action, familyParams(args));
  }

  SkillMeta? _findByName(String name) {
    for (final s in _cache) {
      if (s.name == name) return s;
    }
    return null;
  }

  String _manifest() {
    final visible = _cache.where((s) => s.enabled).toList();
    final items = <String, dynamic>{};
    for (final s in visible) {
      items[s.name] = {'description': s.description, 'status': 'enable'};
    }
    return jsonEncode({
      'status': 'ok',
      'tool': name,
      'dir': _dir?.path ?? '',
      'count': visible.length,
      'skills': items,
      'note':
          '传 action=<skill 名> 查看用法；action=<skill 名> + params 执行；action=delete + params{skill} 删除',
    });
  }

  String _delete(String skill) {
    final dir = _dir;
    if (dir == null || !_nameRe.hasMatch(skill)) {
      return jsonEncode({'status': 'error', 'error': '非法 skill 名称'});
    }
    final folder = Directory('${dir.path}/$skill');
    try {
      if (folder.existsSync()) {
        folder.deleteSync(recursive: true);
      } else {
        return jsonEncode({'status': 'error', 'error': "skill '$skill' 不存在"});
      }
    } catch (e) {
      return jsonEncode({'status': 'error', 'error': '删除失败: $e'});
    }
    // 删除后立即失效缓存，便于下一轮刷新
    invalidate();
    return jsonEncode({
      'status': 'ok',
      'result': {'skill': skill, 'deleted': true},
    });
  }

  Future<String> _run(String skill, Map<String, dynamic> arguments) async {
    final dir = await _skillsDir();
    final runner = File('${dir.path}/_skill_runner.py');
    if (!runner.existsSync()) {
      return jsonEncode({'status': 'error', 'error': 'skill runner 未部署'});
    }
    final reqFile = File('${dir.path}/.request.json');
    reqFile.writeAsStringSync(
      jsonEncode({'action': 'run', 'skill': skill, 'arguments': arguments}),
    );

    final code =
        'import sys, runpy\n'
        'sys.argv = [${jsonEncode(runner.path)}, ${jsonEncode(reqFile.path)}]\n'
        "runpy.run_path(${jsonEncode(runner.path)}, run_name='__main__')\n";

    String raw;
    try {
      raw = await DeviceToolsService.execute('execute_python', {
        'action': 'code',
        'code': code,
      });
    } catch (e) {
      return jsonEncode({'status': 'error', 'error': 'Python 执行失败: $e'});
    }

    // execute_python 返回 {success, output, exit_code}；runner 把信封打印到 stdout。
    final output = _extractOutput(raw);
    if (output.isEmpty) {
      return jsonEncode({'status': 'error', 'error': 'skill runner 无输出'});
    }
    return output;
  }

  String _extractOutput(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is Map) {
        final out = (m['output'] ?? '').toString().trim();
        if (out.isNotEmpty) return out;
        final err = m['error'];
        if (err != null) {
          return jsonEncode({'status': 'error', 'error': err.toString()});
        }
      }
    } catch (_) {}
    final trimmed = raw.trim();
    return trimmed;
  }

  // ---- 部署运行时文件与内置默认 skill（每进程一次）----

  Future<void> _deployAssets(Directory dir) async {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    if (_assetsDeployed) return;

    // `_` 开头的运行时/辅助文件每次覆盖，保持与应用版本一致。
    const overwrite = {
      'assets/skills/skill_runner.py': '_skill_runner.py',
      'assets/skills/skill_envelope.py': '_envelope.py',
    };
    // 普通文件仅在缺失时写入，避免覆盖使用者改动。
    const ifMissing = {'assets/skills/skill_README.md': 'README.md'};

    for (final e in overwrite.entries) {
      try {
        final content = await rootBundle.loadString(e.key);
        File('${dir.path}/${e.value}').writeAsStringSync(content);
      } catch (_) {}
    }
    for (final e in ifMissing.entries) {
      final target = File('${dir.path}/${e.value}');
      if (target.existsSync()) continue;
      try {
        final content = await rootBundle.loadString(e.key);
        target.writeAsStringSync(content);
      } catch (_) {}
    }
    _removeRetiredBundledSkills(dir);
    _assetsDeployed = true;
  }

  /// 清理已下线的内置 skill：仅在文件内容与随包版本一致（未被用户改动）时删除，
  /// 避免误删本地修改。远程仓库仍可安装同名的 script skill。
  void _removeRetiredBundledSkills(Directory dir) {
    for (final entry in _retiredBundled.entries) {
      final file = File('${dir.path}/${entry.key}');
      if (!file.existsSync()) continue;
      try {
        final digest = crypto.sha256.convert(file.readAsBytesSync()).toString();
        if (digest == entry.value) file.deleteSync();
      } catch (_) {}
    }
  }

  /// 已下线内置 skill 的 SHA-256（内容未变才删除）。
  static const Map<String, String> _retiredBundled = {
    'script.py':
        'a9b123eb54d82de5012e48b0a41f557ae1dc57ade46c5637230a54506a8a07a3',
    '_script_impl.py':
        '45f051c97dae96260bf53b216b40a967b0fd89b8d81d19877c02fe926f28937c',
  };

  // ---- 头部解析（容忍重复/粘连的 skill·status 行，重复块后者覆盖）----

  SkillMeta? _parseHeader(File file) {
    List<String> lines;
    try {
      lines = file.readAsLinesSync();
    } catch (_) {
      return null;
    }
    String? name;
    var description = '';
    var status = 'enable';
    var inUsage = false;
    final usageLines = <String>[];

    for (final raw in lines.take(300)) {
      final line = raw.trim().replaceFirst('\uFEFF', '');
      if (line.isEmpty) {
        if (name != null && inUsage) usageLines.add('');
        continue;
      }
      if (!line.startsWith('#')) break;

      // 重复的 # skill: 块：后者覆盖前者，重开一个干净的头部。
      final mSkill = _skillRe.firstMatch(line);
      if (mSkill != null) {
        name = mSkill.group(1);
        description = '';
        status = 'enable';
        inUsage = false;
        usageLines.clear();
        continue;
      }
      if (name == null) continue;

      // status 在头部块内任意位置都生效（允许尾随内容）。
      final mStatus = _statusRe.firstMatch(line);
      if (mStatus != null) {
        status = mStatus.group(1)!.toLowerCase();
        continue;
      }
      if (!inUsage) {
        final mDesc = _descRe.firstMatch(line);
        if (mDesc != null) {
          description = mDesc.group(1)!.trim();
          continue;
        }
      }
      final mUsage = _usageRe.firstMatch(line);
      if (mUsage != null) {
        inUsage = true;
        final rest = mUsage.group(1)!.trim();
        if (rest.isNotEmpty) usageLines.add(rest);
        continue;
      }
      if (inUsage) {
        // 混入 usage 的元信息行不计入用法，避免污染。
        if (_skillRe.hasMatch(line) ||
            _statusRe.hasMatch(line) ||
            _descRe.hasMatch(line)) {
          continue;
        }
        usageLines.add(line.replaceFirst(_hashRe, ''));
      }
    }
    final skillName = name;
    if (skillName == null) return null;
    return SkillMeta(
      name: skillName,
      description: description,
      enabled: !_disabled.contains(status.toLowerCase()),
      status: status,
      usage: usageLines.join('\n').trim(),
      path: file.path,
    );
  }

  static final RegExp _skillRe = RegExp(
    r'^#\s*skill\s*:\s*([A-Za-z0-9_\-]+)',
    caseSensitive: false,
  );
  static final RegExp _descRe = RegExp(
    r'^#\s*description\s*:\s*(.*)$',
    caseSensitive: false,
  );
  static final RegExp _statusRe = RegExp(
    r'^#\s*status\s*:\s*([A-Za-z0-9_\-]+)',
    caseSensitive: false,
  );
  static final RegExp _usageRe = RegExp(
    r'^#\s*usage\s*:\s*(.*)$',
    caseSensitive: false,
  );
  static final RegExp _hashRe = RegExp(r'^#\s?');
  static final RegExp _nameRe = RegExp(r'^[A-Za-z0-9_\-]{1,64}$');
  static final RegExp _statusHeadRe = RegExp(
    r'^#\s*status\s*:',
    caseSensitive: false,
  );
  static final RegExp _descHeadRe = RegExp(
    r'^#\s*description\s*:',
    caseSensitive: false,
  );
  static final RegExp _skillHeadRe = RegExp(
    r'^#\s*skill\s*:',
    caseSensitive: false,
  );
  static const Set<String> _disabled = {
    'disable',
    'disabled',
    'off',
    'false',
    '0',
  };
}
