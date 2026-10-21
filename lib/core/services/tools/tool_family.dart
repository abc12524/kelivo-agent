import 'dart:convert';

/// 工具族子工具元信息：名称、简短说明、用法、是否需要参数。
///
/// [requiresParams] = false 表示该子工具无需参数，仅传 action 即可执行
/// （否则仅传 action 时返回用法）。对齐 android-agent 的 `SubTool`。
class SubTool {
  final String name;
  final String brief;
  final String usage;
  final bool requiresParams;

  const SubTool(
    this.name,
    this.brief,
    this.usage, {
    this.requiresParams = true,
  });
}

/// 从调用参数中取出指定子对象（去空值）。
///
/// 兼容模型把子对象二次编码成 JSON 字符串的情况（如 `"params": "{\"x\":1}"`）。
Map<String, dynamic> subArgs(Map<String, dynamic> args, String key) {
  Object? obj = args[key];
  if (obj is String) {
    final text = obj.trim();
    if (text.startsWith('{')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) obj = decoded;
      } on FormatException {
        // 非法 JSON：按未提供参数处理，让调用方返回用法提示
      }
    }
  }
  if (obj is! Map) return const <String, dynamic>{};
  final out = <String, dynamic>{};
  obj.forEach((k, v) {
    if (k is String && v != null) out[k] = v;
  });
  return out;
}

/// 取子工具参数：优先 params 子对象，回退到除 action/params 外的顶层键。
Map<String, dynamic> familyParams(Map<String, dynamic> args) {
  final nested = subArgs(args, 'params');
  if (nested.isNotEmpty) return nested;
  final out = <String, dynamic>{};
  args.forEach((k, v) {
    if (k != 'action' && k != 'params') out[k] = v;
  });
  return out;
}

/// 子工具一览（静态）：`名（一句话说明）`，供工具 description 直接展示。
String subsBrief(List<SubTool> subs) =>
    subs.map((s) => '${s.name}（${s.brief}）').join(' / ');

/// 工具族通用 parameters schema：{ action, params }。
Map<String, dynamic> familyParameters(List<SubTool> subs) => {
  'type': 'object',
  'properties': {
    'action': {
      'type': 'string',
      'description':
          '子工具名：${subs.map((s) => s.name).join(' / ')}；'
          '省略（或 list/help）则返回全部子工具清单',
    },
    'params': {
      'type': 'object',
      'description': '子工具参数（键值对）。仅传 action 不传 params 时返回该子工具的用法',
      'additionalProperties': true,
    },
  },
  'required': <String>[],
};

/// 未指定 action 时返回的全部子工具清单（名称 + 简短说明）。
String manifestOf(String tool, List<SubTool> subs) => jsonEncode({
  'status': 'ok',
  'tool': tool,
  'subtools': subs.map((s) => {'name': s.name, 'brief': s.brief}).toList(),
  'note': '仅传 action 返回该子工具用法；传 action + params 执行',
});

/// 指定 action 但未给参数时返回的该子工具用法。
String usageOf(String tool, SubTool sub) => jsonEncode({
  'status': 'ok',
  'tool': tool,
  'action': sub.name,
  'usage': sub.usage,
});

/// 未知子工具错误信封：附可用子工具清单，便于模型直接纠正。
String unknownSubTool(String tool, String action, List<SubTool> subs) =>
    jsonEncode({
      'status': 'error',
      'tool': tool,
      'error': '未知子工具: $action',
      'available': subs.map((s) => s.name).toList(),
      'hint': '省略 action（或 action=list）返回全部子工具清单',
    });

SubTool? _findSub(List<SubTool> subs, String action) {
  for (final s in subs) {
    if (s.name == action) return s;
  }
  return null;
}

/// 工具族统一的两段式分发：不传 action（或 list/help）→ 清单；仅 action → 用法；
/// action + params → 执行。
Future<String> dispatchFamily({
  required String tool,
  required List<SubTool> subs,
  required Map<String, dynamic> args,
  required Future<String> Function(String action, Map<String, dynamic> params)
  onRun,
}) async {
  final action = (args['action'] as String?)?.trim() ?? '';
  if (action.isEmpty) return manifestOf(tool, subs);
  final sub = _findSub(subs, action);
  if (sub == null) {
    final lower = action.toLowerCase();
    // list / help 作为清单别名；真实存在同名子工具时不拦截（如 skill_hub 的 list）
    if (lower == 'list' || lower == 'help') return manifestOf(tool, subs);
    return unknownSubTool(tool, action, subs);
  }
  final params = familyParams(args);
  if (sub.requiresParams && params.isEmpty) return usageOf(tool, sub);
  return onRun(action, params);
}

/// 工具族抽象。Dart 侧复刻 android-agent `ToolRegistry` 的 {action, params} 工具族。
abstract class ToolFamily {
  String get name;
  String get description;
  List<SubTool> get subs;
  Map<String, dynamic> get parameters => familyParameters(subs);
  Future<String> execute(Map<String, dynamic> args);
}
