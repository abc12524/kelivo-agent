import '../device_tools_service.dart';
import 'tool_family.dart';

/// 工具族：手机功能。
///
/// 对外仅暴露 {action, params}：不传 action 返回清单；仅传 action 返回用法；
/// 传 action + params 执行（无参子工具仅传 action 即执行）。
/// 内部转调 kelivo 现有的 native 工具（app.tools）。
class PhoneTool extends ToolFamily {
  static final PhoneTool instance = PhoneTool();

  @override
  String get name => 'phone_tool';

  @override
  final List<SubTool> subs = const [
    SubTool('system_info', '设备系统信息', 'system_info: 无参数', requiresParams: false),
    SubTool('gps', '获取当前定位', 'gps: 无参数', requiresParams: false),
    SubTool('notify', '发送状态栏通知', 'notify: 参数 title, content 必填'),
    SubTool(
      'sound',
      '播放提示音/远程音频',
      'sound: 参数 mode = tone|audio_url 必填；tone 可选 frequency, duration_ms, volume, '
          'stream_type；audio_url 需 url',
    ),
    SubTool(
      'sensor',
      '读取传感器数据',
      'sensor: 可选参数 sensor（默认 all）。可传关键字（gyroscope/accelerometer/magnetic/'
          'light/pressure/proximity/gravity/linear_acceleration/rotation）或 all',
      requiresParams: false,
    ),
  ];

  @override
  String get description =>
      '手机功能。子工具：${subs.map((s) => s.name).join(' / ')}。';

  @override
  Future<String> execute(Map<String, dynamic> args) => dispatchFamily(
    tool: name,
    subs: subs,
    args: args,
    onRun: (action, p) async {
      switch (action) {
        case 'system_info':
          return DeviceToolsService.execute('get_system_info', const {});
        case 'gps':
          return DeviceToolsService.execute('get_gps_location', const {});
        case 'notify':
          return DeviceToolsService.execute('send_notification', p);
        case 'sound':
          return DeviceToolsService.execute('play_sound', p);
        case 'sensor':
          return DeviceToolsService.execute('get_sensor_data', {
            'sensor': p['sensor'] ?? 'all',
          });
        default:
          return unknownSubTool(action);
      }
    },
  );
}
