import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 桌面端（Windows / Linux）Agent 工具的运行环境配置。
///
/// - Windows：Git Bash 与 python.exe / venv，键 `windows_*_v1`（沿用旧键，不影响已有配置）。
/// - Linux：bash 自动探测（无设置项），python3 或 venv，键 `linux_python_path_v1`。
class DesktopToolEnv {
  DesktopToolEnv._();

  static const String bashKey = 'windows_bash_path_v1';
  static const String pythonKey = 'windows_python_path_v1';
  static const String linuxPythonKey = 'linux_python_path_v1';

  static Future<String> getBashPath() async {
    final prefs = await SharedPreferences.getInstance();
    return _normalize(prefs.getString(bashKey) ?? '');
  }

  static Future<void> setBashPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final value = path.trim();
    if (value.isEmpty) {
      await prefs.remove(bashKey);
    } else {
      await prefs.setString(bashKey, value);
    }
  }

  static Future<String> getPythonPath() async {
    final prefs = await SharedPreferences.getInstance();
    final key = Platform.isWindows ? pythonKey : linuxPythonKey;
    return _normalize(prefs.getString(key) ?? '');
  }

  static Future<void> setPythonPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final key = Platform.isWindows ? pythonKey : linuxPythonKey;
    final value = path.trim();
    if (value.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }

  /// 解析可用的 bash.exe：Windows 显式配置优先，其次常见 Git/MSYS2 安装位置与 PATH；
  /// Linux 直接使用系统 bash。
  static Future<String?> resolveBash() async {
    if (!Platform.isWindows) {
      for (final c in ['/bin/bash', '/usr/bin/bash']) {
        if (File(c).existsSync()) return c;
      }
      return _whichPath('bash');
    }
    final configured = await getBashPath();
    if (configured.isNotEmpty) {
      return File(configured).existsSync() ? configured : null;
    }
    final candidates = <String>[
      r'C:\Program Files\Git\bin\bash.exe',
      r'C:\Program Files\Git\usr\bin\bash.exe',
      r'C:\Program Files (x86)\Git\bin\bash.exe',
      r'C:\msys64\usr\bin\bash.exe',
    ];
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      candidates.add(p.join(localAppData, 'Programs', 'Git', 'bin', 'bash.exe'));
    }
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    final fromPath = await _whichWindows('bash.exe');
    // System32 下的 bash.exe 是 WSL，路径语义不同，不作为 Git Bash 使用。
    if (fromPath != null && !fromPath.toLowerCase().contains(r'\system32\')) {
      return fromPath;
    }
    return null;
  }

  /// 解析可用的 Python：显式配置（exe 或 venv 目录）优先，否则使用 PATH。
  static Future<String?> resolvePython() async {
    final configured = await getPythonPath();
    if (configured.isNotEmpty) {
      final type = FileSystemEntity.typeSync(configured);
      if (type == FileSystemEntityType.directory) {
        final candidates = Platform.isWindows
            ? [
                p.join(configured, 'Scripts', 'python.exe'),
                p.join(configured, 'python.exe'),
              ]
            : [
                p.join(configured, 'bin', 'python3'),
                p.join(configured, 'bin', 'python'),
              ];
        for (final c in candidates) {
          if (File(c).existsSync()) return c;
        }
        return null;
      }
      return File(configured).existsSync() ? configured : null;
    }
    if (!Platform.isWindows) {
      return _whichPath('python3') ?? _whichPath('python');
    }
    final fromPath = await _whichWindows('python.exe');
    if (fromPath == null) return null;
    // WindowsApps 下的是应用商店占位程序，无法执行脚本。
    if (fromPath.toLowerCase().contains(r'\windowsapps\')) return null;
    return fromPath;
  }

  /// 去掉用户粘贴时可能带上的成对引号。
  static String _normalize(String value) {
    var v = value.trim();
    if (v.length >= 2) {
      final first = v[0];
      final last = v[v.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        v = v.substring(1, v.length - 1).trim();
      }
    }
    return v;
  }

  static Future<String?> _whichWindows(String exe) async {
    try {
      final r = await Process.run(
        'where.exe',
        [exe],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (r.exitCode != 0) return null;
      for (final line in (r.stdout as String).split(RegExp(r'\r?\n'))) {
        final t = line.trim();
        if (t.isNotEmpty && File(t).existsSync()) return t;
      }
    } catch (_) {}
    return null;
  }

  static Future<String?> _whichPath(String exe) async {
    final pathEnv = Platform.environment['PATH'] ?? '';
    for (final dir in pathEnv.split(':')) {
      if (dir.isEmpty) continue;
      final candidate = p.join(dir, exe);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }
}
