import '../device_tools_service.dart';
import 'tool_family.dart';

/// 工具族：系统与远程执行。
///
/// 对外仅暴露 {action, params}：不传 action 返回子工具清单；仅传 action 返回该子工具用法；
/// 传 action + params 执行（无参子工具仅传 action 即执行）。
/// 内部转调 kelivo 现有的 native 工具（app.tools / app.python）。
class SystemTool extends ToolFamily {
  static final SystemTool instance = SystemTool();

  @override
  String get name => 'system_tool';

  @override
  final List<SubTool> subs = const [
    SubTool('shell', '执行 Shell 命令', 'shell: 参数 command = 要执行的 Shell 命令'),
    SubTool(
      'python',
      '执行 Python',
      'python: 参数 mode = code|script|pip|info（必填）；code（mode=code）、'
          'path（mode=script，脚本文件路径）、packages（mode=pip，空格分隔）',
    ),
    SubTool(
      'ssh',
      'SSH 远程执行与文件传输',
      'ssh: 参数 action = exec|upload|download（默认 exec）；host, port, username 必填；'
          'exec 需 command；upload/download 需 local_path, remote_path；'
          '认证传 password 或 private_key / private_key_path（三选一）',
    ),
  ];

  @override
  String get description =>
      '系统与远程执行。子工具：${subs.map((s) => s.name).join(' / ')}。';

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
          return DeviceToolsService.execute('execute_python', {
            ...p,
            'action': mode,
          });
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
          return unknownSubTool(action);
      }
    },
  );
}
