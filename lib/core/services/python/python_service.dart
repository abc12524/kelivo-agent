import 'dart:convert';
import 'package:flutter/services.dart';

/// Dart 类币装用于调用 Android Python 引擎
class PythonService {
  static const _channel = MethodChannel('app.python');
  static bool _initialized = false;

  /// 初始化 Python 环境（异步解压）
  static Future<void> init() async {
    if (_initialized) return;
    try {
      await _channel.invokeMethod('init');
      _initialized = true;
    } catch (_) {}
  }

  /// 执行 Python 代码片段
  static Future<PythonResult> executeCode(String code, {int timeoutSec = 30}) async {
    try {
      final raw = await _channel.invokeMethod('execute', {
        'action': 'code',
        'code': code,
      });
      return PythonResult.fromJson(raw as String);
    } catch (e) {
      return PythonResult(success: false, output: '调用失败: ，e', exitCode: -1);
    }
  }

  /// pip install 安装包
  static Future<PythonResult> pipInstall(String packages, {int timeoutSec = 180}) async {
    try {
      final raw = await _channel.invokeMethod('execute', {
        'action': 'pip',
        'packages': packages,
      });
      return PythonResult.fromJson(raw as String);
    } catch (e) {
      return PythonResult(success: false, output: 'pip 失败: ，e', exitCode: -1);
    }
  }

  /// 查询 Python 环境信息
  static Future<PythonResult> getInfo() async {
    try {
      final raw = await _channel.invokeMethod('execute', {'action': 'info'});
      return PythonResult.fromJson(raw as String);
    } catch (e) {
      return PythonResult(success: false, output: '获取信息失败: ，e', exitCode: -1);
    }
  }
}

class PythonResult {
  final bool success;
  final String output;
  final int exitCode;
  PythonResult({required this.success, required this.output, required this.exitCode});

  factory PythonResult.fromJson(String json) {
    try {
      final map = Map<String, dynamic>.from(jsonDecode(json) as Map);
      return PythonResult(
        success: map['success'] as bool? ?? false,
        output: map['output'] as String? ?? '',
        exitCode: map['exit_code'] as int? ?? -1,
      );
    } catch (_) {
      return PythonResult(success: false, output: json, exitCode: -1);
    }
  }
}