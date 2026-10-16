import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../utils/app_directories.dart';
import 'skill_hub_store.dart';
import 'skill_tool.dart';
import 'tool_family.dart';

/// 工具族：skill_hub —— 从远程技能仓库（GitHub）查看 / 下载 / 下线或删除 skill。
///
/// 远程仓库根放 `index.json`（技能名 + 说明 + 平台 + 依赖索引），每个技能一个文件夹
/// （入口 `skill.py` 与可选 `_` 助手 / `config.example.json` 同目录）。安装时按 GitHub
/// contents API 列出该文件夹文件并逐个下载到本地 `skills/<名>/`，随后由 [SkillTool]
/// 按签名自动重新扫描注册（无需重启）。
///
/// 仓库地址默认内置 `abc12524/shell-skills@main`，可在「Skill 管理」页修改。
///
/// action 分发（两段式）：
///   - 不传 action                  → 子工具清单
///   - action=list                  → 列出远程技能（含平台 / 依赖 / 是否已装）
///   - action=install + params{name} → 下载安装（覆盖安装，保留本地 config.json）
///   - action=remove  + params{name} → 默认下线（# status: disable）；hard=true 才删除
///
/// 安全：下载即等价于信任该仓库的代码（会在内置 Python 进程内 import 执行）。
class SkillHubTool extends ToolFamily {
  SkillHubTool._();
  static final SkillHubTool instance = SkillHubTool._();

  @override
  String get name => 'skill_hub';

  @override
  List<SubTool> get subs => const [
    SubTool(
      'list',
      '列出远程可装技能',
      'list: 无参数，列出远程仓库技能（含平台 / 依赖 / 是否已装）',
      requiresParams: false,
    ),
    SubTool(
      'install',
      '下载并安装远程技能',
      'install: 需 params.name（远程技能名）；下载到 skills/<名>/ 并自动注册',
    ),
    SubTool(
      'remove',
      '下线或删除本地技能',
      'remove: 需 params.name；默认仅下线（# status: disable，保留文件）；params.hard=true 才真正删除',
    ),
  ];

  @override
  String get description =>
      '远程技能仓库（GitHub）。子工具：list / install / remove。'
      'list 查看可装技能；install + params{name} 下载安装；'
      'remove + params{name} 默认下线（可恢复），remove + params{name,hard=true} 才删除。'
      '下载即信任其代码（会在进程内执行）。仓库地址可在「Skill 管理」页修改。';

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    return dispatchFamily(
      tool: name,
      subs: subs,
      args: args,
      onRun: (action, params) async {
        try {
          switch (action) {
            case 'list':
              return await _list();
            case 'install':
              return await _install((params['name'] as String?)?.trim() ?? '');
            case 'remove':
              return await _remove(
                (params['name'] as String?)?.trim() ?? '',
                _asBool(params['hard']),
              );
            default:
              return jsonEncode({'status': 'error', 'error': '未知操作: $action'});
          }
        } catch (e) {
          return jsonEncode({
            'status': 'error',
            'error': 'skill_hub $action 失败: $e',
          });
        }
      },
    );
  }

  // ==================== 配置 ====================

  Future<String> _repo() async {
    final s = (await SkillHubStore.getRepo()).trim();
    return s.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
  }

  Future<String> _branch() async => (await SkillHubStore.getBranch()).trim();

  Future<String> _indexUrl() async =>
      'https://raw.githubusercontent.com/${await _repo()}/${await _branch()}/index.json';

  Future<String> _contentsUrl(String path) async =>
      'https://api.github.com/repos/${await _repo()}/contents/$path?ref=${await _branch()}';

  // ==================== HTTP ====================

  Future<String> _getText(String url) async {
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'kelivo-agent',
      },
    );
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}');
    }
    return resp.body;
  }

  Future<List<int>> _getBytes(String url) async {
    final resp = await http.get(
      Uri.parse(url),
      headers: {'User-Agent': 'kelivo-agent'},
    );
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }

  Future<Map<String, dynamic>> _fetchIndex() async {
    final body = await _getText(await _indexUrl());
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('index.json 不是 JSON 对象');
    }
    return decoded;
  }

  // ==================== 动作实现 ====================

  Future<String> _list() async {
    final index = await _fetchIndex();
    final raw = index['skills'];
    if (raw is! List) {
      return jsonEncode({'status': 'error', 'error': '索引缺少 skills 列表'});
    }
    final dir = await _skillsDir();
    final items = <Map<String, dynamic>>[];
    for (final el in raw) {
      if (el is! Map) continue;
      final m = Map<String, dynamic>.from(el);
      final n = (m['name'] ?? '').toString();
      final entry = _findEntryFile(dir, n);
      items.add({
        'name': n,
        'description': (m['description'] ?? '').toString(),
        'platform': _strList(m['platform']),
        'requires': _strList(m['requires']),
        'installed': entry != null,
        'enabled': entry == null ? false : _isEnabled(entry),
      });
    }
    return jsonEncode({
      'status': 'ok',
      'repo': await _repo(),
      'branch': await _branch(),
      'count': items.length,
      'skills': items,
      'note': 'install + params{name} 安装；remove + params{name} 下线（hard=true 删除）',
    });
  }

  Future<String> _install(String name) async {
    if (!_nameRe.hasMatch(name)) {
      return jsonEncode({'status': 'error', 'error': "非法技能名 '$name'"});
    }

    final index = await _fetchIndex();
    final raw = index['skills'];
    Map<String, dynamic>? entry;
    if (raw is List) {
      for (final el in raw) {
        if (el is Map && el['name'] == name) {
          entry = Map<String, dynamic>.from(el);
          break;
        }
      }
    }
    if (entry == null) {
      return jsonEncode({'status': 'error', 'error': "远程仓库没有技能 '$name'"});
    }

    final path = (entry['path'] ?? name)
        .toString()
        .trim()
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), '');
    if (path.isEmpty || path.contains('..')) {
      return jsonEncode({'status': 'error', 'error': '技能 path 非法'});
    }

    final listBody = await _getText(await _contentsUrl(path));
    final listDecoded = jsonDecode(listBody);
    if (listDecoded is! List) {
      return jsonEncode({'status': 'error', 'error': "技能 '$path' 不是文件夹"});
    }

    final dir = await _skillsDir();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final tmp = Directory('${dir.path}/$name.tmp');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);

    final written = <String>[];
    for (final el in listDecoded) {
      if (el is! Map) continue;
      if ((el['type'] ?? '') != 'file') continue;
      final fname = (el['name'] ?? '').toString();
      // 目录内文件都在同一层，拒绝任何路径穿越
      if (fname.isEmpty ||
          fname.contains('/') ||
          fname.contains('\\') ||
          fname.contains('..')) {
        continue;
      }
      final dl = (el['download_url'] ?? '').toString();
      if (dl.isEmpty) continue;
      final bytes = await _getBytes(dl);
      await File('${tmp.path}/$fname').writeAsBytes(bytes);
      written.add(fname);
    }

    if (written.isEmpty) {
      tmp.deleteSync(recursive: true);
      return jsonEncode({
        'status': 'error',
        'error': "技能 '$path' 目录为空或未找到文件",
      });
    }

    final dest = Directory('${dir.path}/$name');
    final overwrite =
        dest.existsSync() || File('${dir.path}/$name.py').existsSync();
    // 覆盖安装：备份本地 config.json（若有），避免被模板重置
    final configFile = File('${dest.path}/config.json');
    final savedConfig =
        configFile.existsSync() ? configFile.readAsBytesSync() : null;
    if (dest.existsSync()) dest.deleteSync(recursive: true);
    final flat = File('${dir.path}/$name.py');
    if (flat.existsSync()) flat.deleteSync(); // 清掉同名扁平脚本，避免并存
    try {
      tmp.renameSync(dest.path);
    } catch (_) {
      _copyDir(tmp, dest);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }

    // 配置：优先保留原有 config.json，否则用 config.example.json 生成待填
    var configCreated = false;
    var configKept = false;
    final real = File('${dest.path}/config.json');
    if (savedConfig != null) {
      real.writeAsBytesSync(savedConfig);
      configKept = true;
    } else {
      final example = File('${dest.path}/config.example.json');
      if (example.existsSync()) {
        example.copySync(real.path);
        configCreated = true;
      }
    }

    SkillTool.instance.invalidate();
    return jsonEncode({
      'status': 'ok',
      'result': {
        'name': name,
        'path': dest.path,
        'files': written,
        'overwritten': overwrite,
        'config_created': configCreated,
        'config_kept': configKept,
        'requires': _strList(entry['requires']),
        'note': '已安装并自动注册；如需配置请编辑 ${real.path}',
      },
    });
  }

  Future<String> _remove(String name, bool hard) async {
    if (!_nameRe.hasMatch(name)) {
      return jsonEncode({'status': 'error', 'error': "非法技能名 '$name'"});
    }
    final dir = await _skillsDir();
    final entry = _findEntryFile(dir, name);
    if (entry == null) {
      return jsonEncode({'status': 'error', 'error': "未安装技能 '$name'"});
    }

    if (hard) {
      try {
        final folder = Directory('${dir.path}/$name');
        final flat = File('${dir.path}/$name.py');
        if (folder.existsSync()) {
          folder.deleteSync(recursive: true);
        } else if (flat.existsSync()) {
          flat.deleteSync();
        } else {
          entry.deleteSync();
        }
      } catch (e) {
        return jsonEncode({'status': 'error', 'error': '删除失败: $e'});
      }
      SkillTool.instance.invalidate();
      return jsonEncode({
        'status': 'ok',
        'result': {'skill': name, 'removed': true, 'hard': true},
      });
    }

    // 默认：软下线（改头部 # status: disable，保留文件，可重新安装恢复）
    if (_setStatus(entry, 'disable')) {
      SkillTool.instance.invalidate();
      return jsonEncode({
        'status': 'ok',
        'result': {
          'skill': name,
          'disabled': true,
          'hard': false,
          'path': entry.path,
          'note': '已下线（文件保留，不对 LLM 披露）；重新 install 可恢复',
        },
      });
    }
    return jsonEncode({'status': 'error', 'error': '下线失败（无法写入 ${entry.path}）'});
  }

  // ==================== 工具方法 ====================

  Future<Directory> _skillsDir() async {
    final root = await AppDirectories.getAppDataDirectory();
    return Directory('${root.path}/skills');
  }

  /// 定位技能的入口文件：文件夹式 <name>/skill.py → 扁平 <name>.py → 按头部名匹配。
  File? _findEntryFile(Directory dir, String name) {
    final folderEntry = File('${dir.path}/$name/skill.py');
    if (folderEntry.existsSync()) return folderEntry;
    final flat = File('${dir.path}/$name.py');
    if (flat.existsSync()) return flat;
    if (!dir.existsSync()) return null;
    for (final e in dir.listSync()) {
      final seg = e.uri.pathSegments.last;
      if (seg.startsWith('_') || seg.startsWith('.')) continue;
      File? entry;
      if (e is Directory) {
        final f = File('${e.path}/skill.py');
        if (f.existsSync()) entry = f;
      } else if (e is File && seg.endsWith('.py')) {
        entry = e;
      }
      if (entry == null) continue;
      if (_headerSkillName(entry) == name) return entry;
    }
    return null;
  }

  String? _headerSkillName(File file) {
    try {
      for (final raw in file.readAsLinesSync().take(300)) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        if (!line.startsWith('#')) break;
        final m = _skillRe.firstMatch(line);
        if (m != null) return m.group(1);
      }
    } catch (_) {}
    return null;
  }

  /// 是否对 LLM 披露：头部 # status: 非 disable（缺省为启用）。
  bool _isEnabled(File file) {
    try {
      for (final raw in file.readAsLinesSync().take(300)) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        if (!line.startsWith('#')) break;
        final m = _statusRe.firstMatch(line);
        if (m != null) return !_disabled.contains(m.group(1)!.toLowerCase());
      }
    } catch (_) {}
    return true;
  }

  /// 改写入口头部 `# status:`（无则插入到 description / skill 之后）。
  bool _setStatus(File file, String value) {
    List<String> lines;
    try {
      lines = file.readAsLinesSync();
    } catch (_) {
      return false;
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
        return _writeLines(file, lines);
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
    return _writeLines(file, lines);
  }

  bool _writeLines(File file, List<String> lines) {
    try {
      file.writeAsStringSync('${lines.join('\n')}\n');
      return true;
    } catch (_) {
      return false;
    }
  }

  void _copyDir(Directory src, Directory dst) {
    if (!dst.existsSync()) dst.createSync(recursive: true);
    for (final e in src.listSync()) {
      final target = '${dst.path}/${e.uri.pathSegments.last}';
      if (e is Directory) {
        _copyDir(e, Directory(target));
      } else if (e is File) {
        e.copySync(target);
      }
    }
  }

  List<String> _strList(Object? v) {
    if (v is List) return v.map((e) => e.toString()).toList();
    return const [];
  }

  bool _asBool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      return const {'1', 'true', 'yes', 'on'}.contains(v.trim().toLowerCase());
    }
    return false;
  }

  static final RegExp _nameRe = RegExp(r'^[A-Za-z0-9_.\-]{1,64}$');
  static final RegExp _skillRe = RegExp(
    r'^#\s*skill\s*:\s*([A-Za-z0-9_\-]+)',
    caseSensitive: false,
  );
  static final RegExp _statusRe = RegExp(
    r'^#\s*status\s*:\s*([A-Za-z0-9_\-]+)',
    caseSensitive: false,
  );
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
