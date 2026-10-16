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
      'SSH 远程执行命令',
      'ssh: 参数 host, port, username, command 必填；'
          '认证传 password 或 private_key / private_key_path（三选一）',
    ),
    SubTool(
      'scp',
      'SCP 上传/下载文件',
      'scp: 参数 direction = upload|download, host, port, username, local_path, '
          'remote_path 必填；认证传 password 或 private_key / private_key_path（三选一）',
    ),
    SubTool(
      'wait',
      '延时等待',
      'wait: 参数 duration_ms（毫秒，1000-300000，必填）',
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
          return DeviceToolsService.execute('ssh_execute', p);
        case 'scp':
          final direction = (p['direction'] as String?)?.trim();
          if (direction == null || direction.isEmpty) {
            return '{"error": "缺少 direction 参数"}';
          }
          return DeviceToolsService.execute('ssh_scp', {
            ...p,
            'action': direction,
          });
        case 'wait':
          return DeviceToolsService.execute('wait', p);
        default:
          return unknownSubTool(action);
      }
    },
  );
}
