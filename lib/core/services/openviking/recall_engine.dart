import '../../models/chat_message.dart';
import 'openviking_service.dart';
import 'recall.dart';

/// OpenViking 自动召回：同一会话内强制去重，切会话从零开始。
///
/// 对齐 android-agent 的 RecallEngine：每轮从已落库的注入消息重建去重记录，
/// 因此回滚历史后不会继续沿用被回滚的记忆。
class RecallEngine {
  RecallEngine({
    required this.service,
    required this.findThreshold,
    required this.findLimit,
  });

  final OpenVikingService service;
  final double findThreshold;
  final int findLimit;

  final Set<String> _seen = <String>{};

  /// 以当前会话历史为准重建已注入记录。
  void seed(Iterable<ChatMessage> history) {
    _seen.clear();
    for (final m in history) {
      if (m.role != ChatMessage.roleInjectUser) continue;
      for (final uri in Recall.parseRecallUris(m.content)) {
        if (uri.isNotEmpty) _seen.add(uri);
      }
    }
  }

  /// 基于 query 召回相关记忆，返回可注入的块（含 `## 📖 相关记忆` 标记）。
  /// 未命中、条数为 0、query 过短或全部已注入时返回 null。
  Future<String?> recall(String query) async {
    if (findLimit <= 0) return null;
    final q = query.trim();
    if (q.length < Recall.minQueryLength) return null;
    final result = await service.find(
      q,
      scoreThreshold: findThreshold,
      limit: findLimit,
    );
    if (result.hits.isEmpty) return null;

    final sb = StringBuffer(Recall.recallMarker);
    var added = 0;
    for (final hit in result.hits) {
      if (added >= findLimit) break;
      final key = hit.uri.trim().isNotEmpty
          ? hit.uri.trim()
          : hit.snippet.trim();
      if (key.isNotEmpty && _seen.contains(key)) continue;
      final abstract = hit.snippet.trim();
      if (abstract.isEmpty) continue;
      sb
        ..write('\n- [${hit.uri}] (score=')
        ..write(hit.score.toStringAsFixed(2));
      if (hit.category.isNotEmpty) sb.write(', ${hit.category}');
      sb
        ..write(')\n  ')
        ..write(
          abstract.length > 300 ? abstract.substring(0, 300) : abstract,
        );
      if (key.isNotEmpty) _seen.add(key);
      added++;
    }
    return added == 0 ? null : sb.toString();
  }
}
