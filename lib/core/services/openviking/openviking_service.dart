import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../models/chat_message.dart';

class OpenVikingService {
  final String baseUrl;
  final String apiKey;
  final String user;
  final http.Client _client;
  OpenVikingService({
    required this.baseUrl,
    required this.apiKey,
    required this.user,
    http.Client? client,
  }) : _client = client ?? http.Client();

  // 会话级捕获状态（跨实例保留，对齐 android-agent 的 ovSessions / 去重）
  static final Map<String, String> _ovSessions =
      {}; // conversationId -> ov session_id
  static final Map<String, Set<String>> _capturedIds =
      {}; // conversationId -> 已捕获消息 id

  static const String _recallMarker = '[自动检索的候选记忆';

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
    'X-OpenViking-Account': 'default',
    'X-OpenViking-Peer': 'default',
  };

  Uri _endpoint(String path) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/\$/'), '')}$path');

  /// 合并 memories / resources / skills 三段检索结果，按 uri 去重并按分数降序。
  List<OvMemoryHit> _parseHits(Map<String, dynamic> body, int limit) {
    final result = body['result'] as Map<String, dynamic>?;
    final segments = <dynamic>[
      result?['memories'],
      result?['resources'],
      result?['skills'],
    ];
    final seen = <String>{};
    final hits = <OvMemoryHit>[];
    for (final seg in segments) {
      final list = seg as List<dynamic>?;
      if (list == null) continue;
      for (final item in list) {
        final obj = item as Map<String, dynamic>;
        final uri = (obj['uri'] as String? ?? '');
        if (uri.isNotEmpty && !seen.add(uri)) continue;
        hits.add(
          OvMemoryHit(
            uri: uri,
            score: (obj['score'] as num?)?.toDouble() ?? 0.0,
            snippet: (obj['abstract'] as String? ?? ''),
            category: (obj['category'] as String? ?? '') ?? '',
          ),
        );
      }
    }
    if (hits.isEmpty) return const [];
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }

  /// 带阈值兜底放宽的搜索：阈值过高吞掉相关记忆时放宽到 0 再试一次，取结果更多的一次。
  Future<OvSearchResult> _searchByEndpoint({
    required String path,
    required String query,
    required double scoreThreshold,
    required int limit,
    String targetUri = '',
  }) async {
    if (baseUrl.isEmpty) return OvSearchResult.empty;
    try {
      final payload = <String, dynamic>{
        'query': query,
        'score_threshold': scoreThreshold,
        'limit': limit,
      };
      if (targetUri.isNotEmpty) payload['target_uri'] = targetUri;

      var hits = await _postSearch(path, payload, limit);
      if (scoreThreshold > 0 &&
          (hits.isEmpty || (hits.length <= 1 && scoreThreshold >= 0.3))) {
        final fallbackPayload =
            {
                  'query': query,
                  'score_threshold': 0.0,
                  'limit': limit,
                  if (targetUri.isNotEmpty) 'target_uri': targetUri,
                }
                as Map<String, dynamic>;
        final fb = await _postSearch(path, fallbackPayload, limit);
        if (fb.length > hits.length) hits = fb;
      }
      return OvSearchResult(hits: hits);
    } catch (_) {
      return OvSearchResult.empty;
    }
  }

  Future<List<OvMemoryHit>> _postSearch(
    String path,
    Map<String, dynamic> payload,
    int limit,
  ) async {
    try {
      final response = await _client
          .post(_endpoint(path), headers: _headers, body: jsonEncode(payload))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return const [];
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return _parseHits(body, limit);
    } catch (_) {
      return const [];
    }
  }

  /// search 接口（上下文感知：会结合 session 上下文召回）。
  Future<OvSearchResult> search(
    String query, {
    double scoreThreshold = 0.35,
    int limit = 5,
  }) async {
    return _searchByEndpoint(
      path: '/api/v1/search/search',
      query: query,
      scoreThreshold: scoreThreshold,
      limit: limit,
    );
  }

  /// find 接口（纯向量语义搜索，无会话上下文，低延迟；支持 target_uri 限定范围）。
  Future<OvSearchResult> find(
    String query, {
    double scoreThreshold = 0.4,
    int limit = 3,
    String targetUri = '',
  }) async {
    return _searchByEndpoint(
      path: '/api/v1/search/find',
      query: query,
      scoreThreshold: scoreThreshold,
      limit: limit,
      targetUri: targetUri,
    );
  }

  Future<String> loadContext(
    String query, {
    double scoreThreshold = 0.4,
    int displayCount = 3,
  }) async {
    if (displayCount <= 0 || baseUrl.isEmpty) return '';
    final result = await find(
      query,
      scoreThreshold: scoreThreshold,
      limit: displayCount,
    );
    if (result.hits.isEmpty) return '';
    return result.hits
        .map((h) {
          final scoreStr = h.score > 0 ? '(${h.score.toStringAsFixed(2)})' : '';
          return '> 📚 [${h.uri}] $scoreStr\n  ${h.snippet}';
        })
        .join('\n');
  }

  // ========== 对话自动上传（捕获到 OV Session 并提取长期记忆） ==========

  /// 把一段对话捕获到 OpenViking Session 并提取长期记忆（对齐 android-agent 的
  /// captureSession）。按 conversationId 复用同一个 OV session，只追加尚未捕获的新消息
  /// （带噪音过滤，跳过自动注入的检索/记忆块与短回复）。失败静默，不影响主对话。
  Future<void> captureSession(
    String conversationId,
    List<ChatMessage> messages,
  ) async {
    if (baseUrl.isEmpty || messages.isEmpty) return;
    try {
      final captured = _capturedIds.putIfAbsent(
        conversationId,
        () => <String>{},
      );
      final newMessages = messages
          .where((m) => !captured.contains(m.id))
          .toList();
      if (newMessages.isEmpty) return;

      final ovSession =
          _ovSessions[conversationId] ?? await _createSessionRaw();
      if (ovSession == null) return;
      _ovSessions[conversationId] = ovSession;

      final ovMessages = _toOvMessages(newMessages);
      if (ovMessages.isEmpty) return;

      await _client
          .post(
            _endpoint('/api/v1/sessions/$ovSession/messages/batch'),
            headers: _headers,
            body: jsonEncode({'messages': ovMessages}),
          )
          .timeout(const Duration(seconds: 15));
      await _client
          .post(
            _endpoint('/api/v1/sessions/$ovSession/commit'),
            headers: _headers,
            body: jsonEncode({'keep_recent_count': 0}),
          )
          .timeout(const Duration(seconds: 15));

      captured.addAll(newMessages.map((m) => m.id));
    } catch (_) {
      // 静默跳过
    }
  }

  /// 生成日期+时间的会话名（如 kelivo-2026-09-04-15-30-00）。
  String _newSessionId() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return 'kelivo-${n.year}-${p(n.month)}-${p(n.day)}-${p(n.hour)}-${p(n.minute)}-${p(n.second)}';
  }

  Future<String?> _createSessionRaw() async {
    try {
      final response = await _client
          .post(
            _endpoint('/api/v1/sessions'),
            headers: _headers,
            body: jsonEncode({'session_id': _newSessionId()}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final result = body['result'];
      if (result is Map) {
        return (result['session_id'] ?? result['id']) as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 把聊天消息转成 OV session 的 {role, content} 列表（对齐 android-agent 的
  /// toOvMessages + shouldCapture：跳过自动注入块、命令、短回复与无意义文本）。
  List<Map<String, String>> _toOvMessages(List<ChatMessage> messages) {
    final out = <Map<String, String>>[];
    for (final m in messages) {
      var c = m.content;
      if (c.contains(_recallMarker)) continue;
      if (m.role != 'user' && m.role != 'assistant') continue;
      c = c.length > 4000 ? c.substring(0, 4000) : c;
      if (!_shouldCapture(c, m.role)) continue;
      out.add({'role': m.role, 'content': c});
    }
    return out;
  }

  bool _shouldCapture(String text, String role) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (role == 'user' &&
        RegExp(r'^/[a-z0-9_-]{1,64}\b', caseSensitive: false).hasMatch(t)) {
      return false;
    }
    if (RegExp(
      r'^(?:ok|okay|k|yes|yep|no|nope|thanks|thank you|thx|done|收到|好的|好|嗯|可以|继续|不用|不需要|没了|好了)[.!?。！？\s]*$',
      caseSensitive: false,
    ).hasMatch(t)) {
      return false;
    }
    if (!RegExp(r'[a-z0-9\u3400-\u9fff]', caseSensitive: false).hasMatch(t)) {
      return false;
    }
    final cjk = RegExp(r'[\u3400-\u9fff]').allMatches(t).length;
    final alnum = RegExp(
      r'[a-z0-9]',
      caseSensitive: false,
    ).allMatches(t).length;
    return cjk >= 4 || alnum >= 6 || t.length >= 12;
  }
}

class OvMemoryHit {
  final String uri;
  final double score;
  final String snippet;
  final String category;
  OvMemoryHit({
    required this.uri,
    required this.score,
    required this.snippet,
    required this.category,
  });
}

class OvSearchResult {
  final List<OvMemoryHit> hits;
  const OvSearchResult({this.hits = const []});
  static const empty = OvSearchResult();
}
