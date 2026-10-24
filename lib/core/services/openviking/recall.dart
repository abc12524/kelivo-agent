/// OpenViking 自动记忆的纯策略实现（对齐 android-agent 的 Recall.kt）：
///  - 召回块与 skill 名单的统一包裹格式
///  - 每步召回的 query 构造（仅 assistant 的 reasoning / content）
///  - 已注入 skill 名与记忆 URI 的解析（用于增量注入与会话内去重）
class Recall {
  const Recall._();

  static const String reminderOpen = '<system-reminder>';
  static const String reminderClose = '</system-reminder>';
  static const String skillMark = '<available_skills>';
  static const String skillMarkClose = '</available_skills>';
  static const String recallMarker = '## 相关记忆';
  static const String ovBlockOpen = '<available_openviking>';
  static const String ovBlockClose = '</available_openviking>';
  static const String userTipsOpen = '<user_tips>';
  static const String userTipsClose = '</user_tips>';
  static const String legacyRecallPrefix = '[自动检索的候选记忆';
  static const int minQueryLength = 3;

  /// 每步召回 query：只取 LLM 自己的 reasoning_content 与 content。
  static String buildStepQuery({
    required String reasoning,
    required String content,
  }) {
    final parts = <String>[
      reasoning.trim(),
      content.trim(),
    ].where((e) => e.isNotEmpty);
    return parts.join('\n').trim();
  }

  /// 只包 `<available_openviking>`，供合并进本轮统一 system-reminder 时使用。
  static String openvikingBlock(String block) {
    return '$ovBlockOpen\n$block\n$ovBlockClose';
  }

  /// 独立注入的召回块（如工具轮 step 召回）：整条 system-reminder 包裹。
  static String wrapRecallBlock(String block) {
    return '$reminderOpen\n${openvikingBlock(block)}\n$reminderClose';
  }

  /// skill 名单块（不含外层 system-reminder，由本轮统一包裹）。
  /// [delta] 为 true 时表示只追加新增项。
  static String buildSkillBlock(
    List<(String, String)> skills, {
    required bool delta,
  }) {
    final header = delta ? '以下为新增可用 skill：\n' : '';
    final items = skills
        .map((s) => '- `${s.$1}`: ${s.$2}')
        .join('\n');
    return '$skillMark\n$header$items\n$skillMarkClose';
  }

  /// 用户自定义提示块。
  static String buildUserTipsBlock(String tips) {
    return '$userTipsOpen\n${tips.trim()}\n$userTipsClose';
  }

  /// 把本轮所有注入块合并成一条 system-reminder 消息。
  static String buildTurnContext(List<String> blocks) {
    final parts = blocks.where((e) => e.trim().isNotEmpty).toList();
    return '$reminderOpen\n${parts.join('\n')}\n$reminderClose';
  }

  /// 从已落库的名单消息中解析 skill 名称（只看 available_skills 区块）。
  static List<String> parseSkillNames(String content) {
    final start = content.indexOf(skillMark);
    if (start < 0) return const <String>[];
    final closeIndex = content.indexOf(skillMarkClose, start);
    final end = closeIndex < 0 ? content.length : closeIndex;
    return _skillNameRe
        .allMatches(content.substring(start, end))
        .map((m) => m.group(1) ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 从已落库的召回块中解析记忆 URI，用于恢复会话内的去重记录。
  static List<String> parseRecallUris(String content) {
    return _recallUriRe
        .allMatches(content)
        .map((m) => (m.group(1) ?? '').trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 是否为注入内容（skill 名单 / 召回 / user_tips，含旧版 user 前缀格式）。
  static bool isInjectedContent(String text) {
    return text.startsWith(reminderOpen) ||
        text.startsWith(legacyRecallPrefix) ||
        text.contains(recallMarker) ||
        text.contains(skillMark) ||
        text.contains(ovBlockOpen) ||
        text.contains(userTipsOpen);
  }

  static final RegExp _skillNameRe = RegExp(r'`([A-Za-z0-9_\-]{1,64})`');
  static final RegExp _recallUriRe = RegExp(
    r'^-\s*\[([^\]]+)]\s*\(score=',
    multiLine: true,
  );
}
