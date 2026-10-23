import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../device_tools_service.dart';
import '../python/pip_mirror_store.dart';
import 'tool_family.dart';

/// 工具族：系统与远程执行。
///
/// 对外仅暴露 {action, params}：不传 action 返回子工具清单；仅传 action 返回该子工具用法；
/// 传 action + params 执行（无参子工具仅传 action 即执行）。
/// 内部转调 kelivo 现有的 native 工具（app.tools / app.python）；
/// 桌面端（Windows / Linux）由 Dart 本地实现替代。
/// Windows / Linux 精简为 shell + python（SSH 通过 shell 调用）。
class SystemTool extends ToolFamily {
  static final SystemTool instance = SystemTool();

  static const SubTool _shell = SubTool(
    'shell',
    '执行 Shell 命令',
    'shell: 参数 command = 要执行的 Shell 命令',
  );
  static const SubTool _python = SubTool(
    'python',
    '执行 Python 代码/脚本，或 pip 安装依赖',
    'python: 参数 mode = code|script|pip|info（必填）；code（mode=code）、'
        'path（mode=script，脚本文件路径）、packages（mode=pip，空格分隔）、'
        'index_url（mode=pip，可选镜像源，默认中科大；设置后后续 pip 沿用）',
  );
  static const SubTool _ssh = SubTool(
    'ssh',
    'SSH 远程执行与文件传输',
    'ssh: 参数 action = exec|upload|download（默认 exec）；host, port, username 必填；'
        'exec 需 command；upload/download 需 local_path, remote_path；'
        '认证传 password 或 private_key / private_key_path（三选一）',
  );

  @override
  String get name => 'system_tool';

  // Windows / Linux 精简：SSH 直接用 shell 调 ssh/scp，不再单独暴露子工具。
  @override
  List<SubTool> get subs => defaultTargetPlatform == TargetPlatform.android
      ? const [_shell, _python, _ssh]
      : const [_shell, _python];

  @override
  String get description => '系统与远程执行。子工具：${subsBrief(subs)}。';

  @override
  Future<String> execute(Map<String, dynamic> args) => dispatchFamily(
    tool: name,
    subs: subs,
    args: args,
    onRun: (action, p) async {
      switch (action) {
        case 'shell':
          final cmd = p['command'] as String?;
          if (cmd == null || cmd.trim().isEmpty) {
            return '{"error": "缺少 command 参数"}';
          }
          return DeviceToolsService.execute('execute_system_command', {
            'command': cmd,
          });
        case 'python':
          final mode = (p['mode'] as String?)?.trim();
          if (mode == null || mode.isEmpty) {
            return '{"error": "缺少 mode 参数"}';
          }
          final args = <String, dynamic>{...p, 'action': mode};
          if (mode == 'pip') {
            final requested = (p['index_url'] as String?)?.trim() ?? '';
            if (requested.isNotEmpty &&
                !requested.startsWith('http://') &&
                !requested.startsWith('https://')) {
              return '{"error": "index_url 需以 http:// 或 https:// 开头"}';
            }
            args['index_url'] = requested.isNotEmpty
                ? requested
                : await PipMirrorStore.getIndex();
            final raw = await DeviceToolsService.execute('execute_python', args);
            // 仅在安装成功后才记住模型指定的源，避免把不可用的地址固化
            if (requested.isNotEmpty && _pipSucceeded(raw)) {
              await PipMirrorStore.setIndex(requested);
            }
            return raw;
          }
          return DeviceToolsService.execute('execute_python', args);
        case 'ssh':
          final action = (p['action'] as String?)?.trim().toLowerCase() ?? '';
          if (action.isEmpty || action == 'exec') {
            return DeviceToolsService.execute('ssh_execute', p);
          }
          if (action == 'upload' || action == 'download') {
            return DeviceToolsService.execute('ssh_scp', {
              ...p,
              'action': action,
            });
          }
          return '{"error": "未知 ssh action: $action（可用 exec/upload/download）"}';
        default:
          return unknownSubTool(name, action, subs);
      }
    },
  );

  static bool _pipSucceeded(String raw) {
    try {
      final m = jsonDecode(raw);
      return m is Map && m['success'] == true;
    } catch (_) {
      return false;
    }
  }
}
