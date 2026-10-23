import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../utils/app_directories.dart';
import '../python/pip_mirror_store.dart';
import 'desktop_tool_env.dart';

/// 桌面端本地执行后端：替代 Android 的 `app.tools` / `app.python` 原生通道。
///
/// Windows 用 Git Bash，Linux 用系统 bash；Python 用显式配置或 PATH。
/// 支持 `execute_system_command` 与 `execute_python`（code/script/pip/info）。
/// 手机功能与桌面端未提供的工具返回明确错误。
class DesktopLocalTools {
  DesktopLocalTools._();

  static const int _maxOutput = 6000;
  static String get _noBash => Platform.isWindows
      ? '未找到 bash，请在 设置 → Agent 工具 中指定 Git Bash 的 bash.exe 路径'
      : '未找到 bash（需要 /bin/bash 或 PATH 中的 bash）';
  static String get _noPython => Platform.isWindows
      ? '未找到可用的 Python，请在 设置 → Agent 工具 中指定 python.exe 或虚拟环境目录'
      : '未找到 python3/python，请安装 python3 或加入 PATH（也可在 设置 → Agent 工具 指定虚拟环境）';

  static Future<String> execute(String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'execute_system_command':
        return _shell(args['command']);
      case 'execute_python':
        return _python(args);
      default:
        return jsonEncode({'error': '当前平台暂不支持该工具: $name'});
    }
  }

  static Future<String> _shell(Object? command) async {
    final cmd = (command is String ? command : '').trim();
    if (cmd.isEmpty) return jsonEncode({'error': '缺少 command 参数'});
    final bash = await DesktopToolEnv.resolveBash();
    if (bash == null) return jsonEncode({'error': _noBash});
    try {
      final r = await _run(
        bash,
        ['-lc', cmd],
        timeout: const Duration(seconds: 60),
      );
      final stdout = r.stdout.trim();
      final stderr = r.stderr.trim();
      final output = stdout.isNotEmpty
          ? stdout
          : (stderr.isNotEmpty ? 'Error: $stderr' : '命令执行成功（无输出）');
      return jsonEncode({
        'success': true,
        'exit_code': r.exitCode,
        'output': _truncate(output),
      });
    } catch (e) {
      return jsonEncode({'error': '执行失败 - $e'});
    }
  }

  static Future<String> _python(Map<String, dynamic> args) async {
    final action = (args['action'] as String?)?.trim() ?? '';
    final python = await DesktopToolEnv.resolvePython();
    if (python == null) {
      return jsonEncode({
        'success': false,
        'output': _noPython,
        'exit_code': -1,
      });
    }
    try {
      switch (action) {
        case 'code':
          final code = (args['code'] as String?) ?? '';
          if (code.trim().isEmpty) {
            return jsonEncode({
              'success': false,
              'output': '缺少 code 参数',
              'exit_code': -1,
            });
          }
          final file = await _writeTempScript(code);
          try {
            return await _runPython(
              python,
              [file.path],
              const Duration(seconds: 120),
            );
          } finally {
            try {
              file.deleteSync();
            } catch (_) {}
          }
        case 'script':
          final path = (args['path'] as String?)?.trim() ?? '';
          if (path.isEmpty || !File(path).existsSync()) {
            return jsonEncode({
              'success': false,
              'output': '脚本不存在: $path',
              'exit_code': -1,
            });
          }
          return await _runPython(
            python,
            [path],
            const Duration(seconds: 120),
          );
        case 'pip':
          final packages = ((args['packages'] as String?) ?? '')
              .trim()
              .split(RegExp(r'\s+'))
              .where((e) => e.isNotEmpty)
              .toList();
          if (packages.isEmpty) {
            return jsonEncode({
              'success': false,
              'output': '缺少 packages 参数',
              'exit_code': -1,
            });
          }
          final requested = ((args['index_url'] as String?) ?? '').trim();
          final index = requested.isNotEmpty
              ? requested
              : await PipMirrorStore.getIndex();
          final cmd = <String>['-m', 'pip', 'install', '-i', index];
          // 仅 http 源需要 trusted-host；https 源交给证书校验，不静默跳过。
          if (index.startsWith('http://')) {
            final host = Uri.tryParse(index)?.host ?? '';
            if (host.isNotEmpty) cmd.addAll(['--trusted-host', host]);
          }
          cmd.addAll(packages);
          return await _runPython(
            python,
            cmd,
            const Duration(seconds: 180),
          );
        case 'info':
          return await _runPython(
            python,
            ['-c', _infoCode],
            const Duration(seconds: 20),
          );
        default:
          return jsonEncode({
            'success': false,
            'output': '未知 python action: $action',
            'exit_code': -1,
          });
      }
    } catch (e) {
      return jsonEncode({
        'success': false,
        'output': 'Python 执行失败: $e',
        'exit_code': -1,
      });
    }
  }

  static Future<String> _runPython(
    String python,
    List<String> args,
    Duration timeout,
  ) async {
    final r = await _run(
      python,
      args,
      timeout: timeout,
      env: const {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'},
    );
    final output = [r.stdout, r.stderr]
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join('\n');
    return jsonEncode({
      'success': r.exitCode == 0,
      'output': output,
      'exit_code': r.exitCode,
    });
  }

  static Future<File> _writeTempScript(String code) async {
    final dir = await AppDirectories.getCacheDirectory();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File(
      '${dir.path}/agent_python_${DateTime.now().microsecondsSinceEpoch}.py',
    );
    file.writeAsStringSync(code, encoding: utf8);
    return file;
  }

  static Future<_RunResult> _run(
    String executable,
    List<String> args, {
    required Duration timeout,
    Map<String, String>? env,
  }) async {
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    final process = await Process.start(
      executable,
      args,
      workingDirectory: (home != null && home.isNotEmpty) ? home : null,
      environment: env,
      runInShell: false,
    );
    final stdoutFuture = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stderrFuture = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final exitFuture = process.exitCode;
    try {
      final values = await Future.wait<Object>([
        stdoutFuture,
        stderrFuture,
        exitFuture,
      ]).timeout(timeout);
      return _RunResult(
        values[0] as String,
        values[1] as String,
        values[2] as int,
      );
    } on TimeoutException {
      process.kill();
      throw TimeoutException('执行超时（${timeout.inSeconds}秒）');
    }
  }

  static String _truncate(String output) {
    if (output.length <= _maxOutput) return output;
    return '${output.substring(0, _maxOutput)}\n'
        '... (输出被截断，原长度 ${output.length} 字符)';
  }

  static const String _infoCode = '''
import sys, json, subprocess
info = {"python_version": sys.version, "platform": sys.platform}
try:
    r = subprocess.run([sys.executable, "-m", "pip", "list", "--format=json"],
        capture_output=True, text=True, timeout=15)
    info["pip_packages"] = json.loads(r.stdout) if r.returncode == 0 else []
except: info["pip_packages"] = []
print(json.dumps(info, ensure_ascii=False))
''';
}

class _RunResult {
  const _RunResult(this.stdout, this.stderr, this.exitCode);

  final String stdout;
  final String stderr;
  final int exitCode;
}
