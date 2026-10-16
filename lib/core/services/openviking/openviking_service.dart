import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../../models/chat_message.dart';

class OpenVikingService {
  final String baseUrl;
  final String apiKey;
  final String user;

  /// 显式 peer（非空时优先，对齐 android-agent 的 ovPeerId）。
  final String explicitPeerId;

  /// 是否按包名派生 ws-* peer（对齐 android-agent 的 ovWorkspacePeer）。
  final bool workspacePeer;

  /// 应用包名（用于 ws-* 派生）。
  final String packageName;

  final http.Client _client;
  OpenVikingService({
    required this.baseUrl,
    required this.apiKey,
    required this.user,
    this.explicitPeerId = '',
    this.workspacePeer = false,
    this.packageName = '',
    http.Client? client,
  }) : _client = client ?? http.Client();

  // 会话级捕获状态（跨实例保留，对齐 android-agent 的 ovSessions / 去重）
  static final Map<String, String> _ovSessions =
      {}; // conversationId -> ov session_id
  static final Map<String, Set<String>> _capturedIds =
      {}; // conversationId -> 已捕获消息 id

  // 跨轮召回按 URI 去重（对齐 android-agent 的 _RECALL_SEEN）
  static final Map<String, Set<String>> _recallSeen = {};

  static const String _recallMarker = '[自动检索的候选记忆';

  String? _peerCache;

  /// 解析当前 actor peer：显式 ovPeerId > 按包名派生 ws-* > 回退 default
  /// （对齐 android-agent / 官方 DSH 插件）。
  String peerId() {
    final cached = _peerCache;
    if (cached != null) return cached;
    final explicit = explicitPeerId.trim();
    final String peer;
    if (explicit.isNotEmpty) {
      peer = explicit;
    } else if (workspacePeer && packageName.trim().isNotEmpty) {
      final digest = crypto.md5.convert(utf8.encode(packageName.trim()));
      peer = 'ws-${digest.toString().substring(0, 12)}';
    } else {
      peer = 'default';
    }
    _peerCache = peer;
    return peer;
  }

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
    'X-OpenViking-Account': 'default',
    'X-OpenViking-Peer': peerId(),
  };

  Uri _endpoint(String path) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/\$/'), '')}$path');

  /// POST JSON 并解析写入类响应（对齐 android-agent 对 content/write 的判定）。
  Future<_OvWriteResult> _postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final resp = await _client
          .post(_endpoint(path), headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        return _OvWriteResult(
          ok: false,
          statusCode: resp.statusCode,
          errorCode: '',
          error: 'HTTP ${resp.statusCode}',
        );
      }
      var errCode = '';
      var ok = true;
      var error = '';
      try {
        final b = jsonDecode(resp.body) as Map<String, dynamic>;
        final err = b['error'];
        if (err is Map) {
          errCode = (err['code'] ?? '').toString();
        } else if (err is String) {
          errCode = err;
        }
        final status = b['status'];
        ok = errCode.isEmpty && (status == null || status == 'ok');
        if (errCode.isNotEmpty) {
          error = errCode;
        } else if (!ok) {
          error = '$status';
        }
      } catch (_) {
        ok = true;
      }
      return _OvWriteResult(
        ok: ok,
        statusCode: resp.statusCode,
        errorCode: errCode,
        error: error,
      );
    } catch (e) {
      return _OvWriteResult(
        ok: false,
        statusCode: 0,
        errorCode: '',
        error: '$e',
      );
    }
  }

  /// 合并 memories / resources / skills 三段检索结果，按 uri 去重并按分数降序。
  /// 兼容多种后端结构（result 直接列表 / 顶层 memories / hits 等），对齐 android-agent。
  List<OvMemoryHit> _parseHits(Map<String, dynamic> body, int limit) {
    final raw = <dynamic>[];
    final result = body['result'];
    if (result is Map) {
      for (final key in const ['memories', 'resources', 'skills']) {
        final seg = result[key];
        if (seg is List) raw.addAll(seg);
      }
      if (raw.isEmpty) {
        for (final key in const ['hits', 'items', 'results', 'memories']) {
          final seg = result[key];
          if (seg is List) {
            raw.addAll(seg);
            break;
          }
        }
      }
    } else if (result is List) {
      raw.addAll(result);
    } else {
      for (final key in const ['memories', 'hits', 'items', 'results']) {
        final seg = body[key];
        if (seg is List) {
          raw.addAll(seg);
          break;
        }
      }
    }

    final seen = <String>{};
    final hits = <OvMemoryHit>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final obj = item.cast<String, dynamic>();
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
    if (hits.isEmpty) return const [];
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }

  /// 严格按给定阈值检索：不越权放宽阈值，低分命中对注入没有意义。
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
      final hits = await _postSearch(path, payload, limit);
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

  /// 加载相关记忆作为上下文（带跨轮按 URI 去重）；自动注入走 find 接口（纯向量低延迟）。
  /// [sessionId] 非空且 [dedup] 为 true 时，同一会话已注入过的 URI 不再重复注入。
  Future<String> loadContext(
    String query, {
    double scoreThreshold = 0.4,
    int displayCount = 3,
    String sessionId = '',
    bool dedup = true,
  }) async {
    if (displayCount <= 0 || baseUrl.isEmpty) return '';
    final result = await find(
      query,
      scoreThreshold: scoreThreshold,
      limit: displayCount,
    );
    if (result.hits.isEmpty) return '';

    var hits = result.hits;
    if (sessionId.isNotEmpty && dedup) {
      final seen = _recallSeen.putIfAbsent(sessionId, () => <String>{});
      hits = hits.where((h) => h.uri.isEmpty || seen.add(h.uri)).toList();
      if (seen.length > 500) {
        _recallSeen[sessionId] = seen.toList().sublist(seen.length - 500).toSet();
      }
    }
    if (hits.isEmpty) return '';
    return hits
        .map((h) {
          final scoreStr = h.score > 0 ? '(${h.score.toStringAsFixed(2)})' : '';
          return '> 📚 [${h.uri}] $scoreStr\n  ${h.snippet}';
        })
        .join('\n');
  }

  // ========== 保存记忆（对齐 android-agent：replace 失败 404/NOT_FOUND 时重试 create） ==========

  /// 保存记忆到 `viking://user/<user>/peers/<peer>/memories/<category>/<name>.md`。
  Future<String> remember(
    String category,
    String name,
    String content,
  ) async {
    if (baseUrl.isEmpty) return '{"error": "OpenViking 未配置"}';
    final cat = category.trim().isEmpty ? 'entities' : category.trim();
    final nm = name.trim().isEmpty ? 'untitled' : name.trim();
    final uri = 'viking://user/$user/peers/${peerId()}/memories/$cat/$nm.md';

    final replace = await _postJson('/api/v1/content/write', {
      'uri': uri,
      'content': content,
      'mode': 'replace',
      'wait': true,
    });
    if (replace.ok) {
      final err = replace.errorCode;
      if (err.contains('NOT_FOUND', caseSensitive: false)) {
        return _createMemory(uri, content);
      }
      if (err.isNotEmpty) return '{"error": "$err"}';
      return '{"success": true, "uri": "$uri"}';
    }
    if (replace.statusCode == 404 ||
        replace.error.contains('NOT_FOUND', caseSensitive: false)) {
      return _createMemory(uri, content);
    }
    return '{"error": "${replace.error}"}';
  }

  Future<String> _createMemory(String uri, String content) async {
    final retry = await _postJson('/api/v1/content/write', {
      'uri': uri,
      'content': content,
      'mode': 'create',
      'wait': false,
    });
    if (retry.ok || retry.statusCode == 200) {
      return '{"success": true, "uri": "$uri"}';
    }
    return '{"error": "${retry.error}"}';
  }

  // ========== 读取文件 ==========

  /// 读取单个 URI 的内容，返回原始文本或错误信封。
  Future<String> readFile(String uri) async {
    final target = uri.trim();
    if (baseUrl.isEmpty || target.isEmpty) {
      return '{"error": "uri 不能为空"}';
    }
    try {
      final resp = await _client
          .get(
            _endpoint('/api/v1/content/read?uri=${Uri.encodeComponent(target)}'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        return '{"error": "HTTP ${resp.statusCode}"}';
      }
      try {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        return (body['content'] as String?) ?? resp.body;
      } catch (_) {
        return resp.body;
      }
    } catch (e) {
      return '{"error": "$e"}';
    }
  }

  /// 批量读取多个 URI，返回 `{"success":true,"count":N,"results":[...]}`。
  Future<String> readFiles(List<String> uris) async {
    if (uris.isEmpty) return '{"error": "uris 列表为空"}';
    final results = <Map<String, dynamic>>[];
    for (final uri in uris) {
      final out = await readFile(uri);
      final isErr = out.startsWith('{"error"');
      results.add({
        'uri': uri,
        'success': !isErr,
        if (isErr) 'error': out else 'content': out,
      });
    }
    return jsonEncode({
      'success': true,
      'count': results.length,
      'results': results,
    });
  }

  // ========== 列出目录 ==========

  Future<String> listDir(String uri, {bool recursive = false}) async {
    final target = uri.trim();
    if (baseUrl.isEmpty || target.isEmpty) {
      return '{"error": "uri 不能为空"}';
    }
    try {
      final suffix = recursive ? '&recursive=true' : '';
      final resp = await _client
          .get(
            _endpoint('/api/v1/fs/tree?uri=${Uri.encodeComponent(target)}$suffix'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        return '{"error": "HTTP ${resp.statusCode}"}';
      }
      return resp.body;
    } catch (e) {
      return '{"error": "$e"}';
    }
  }

  // ========== 写入文件 ==========

  Future<String> writeFile(
    String uri,
    String content, {
    String mode = 'replace',
  }) async {
    final target = uri.trim();
    if (baseUrl.isEmpty || target.isEmpty) {
      return '{"error": "uri 不能为空"}';
    }
    final m = mode.trim().isEmpty ? 'replace' : mode.trim();
    final resp = await _postJson('/api/v1/content/write', {
      'uri': target,
      'content': content,
      'mode': m,
      'wait': m != 'create',
    });
    if (resp.ok) {
      return '{"success": true, "uri": "$target", "mode": "$m"}';
    }
    return '{"error": "${resp.error}"}';
  }

  // ========== 删除（遗忘）记忆文件/目录 ==========

  /// 删除指定 URI 的文件或目录（对齐 MCP forget）。
  /// [recursive] 为 true 时递归删除目录及其所有子项。
  /// 返回 true 表示删除成功。
  Future<bool> forget(String uri, {bool recursive = false}) async {
    final target = uri.trim();
    if (baseUrl.isEmpty || target.isEmpty) return false;
    try {
      final suffix = recursive ? '&recursive=true' : '';
      final response = await _client
          .delete(
            _endpoint(
              '/api/v1/fs?uri=${Uri.encodeComponent(target)}$suffix',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ========== 对话自动上传（捕获到 OV Session 并提取长期记忆） ==========

  /// 把一段对话捕获到 OpenViking Session 并提取长期记忆（对齐 android-agent 的
  /// captureSession）。按 conversationId 复用同一个 OV session，只追加尚未捕获的新消息
  /// （带噪音过滤，跳过自动注入的检索/记忆块与短回复）。失败静默，不影响主对话。
  Future<void> captureSession(
    String conversationId,
    List<ChatMessage> messages, {
    Map<String, List<Map<String, dynamic>>>? toolEventsById,
  }) async {
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

      final ovMessages = _toOvMessages(newMessages, toolEventsById);
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

  /// 把聊天消息转成 OV session 消息列表（对齐 opencode 插件 buildCapturePayload：
  /// 纯文本发 {role, content}，含工具调用发 {role, parts}，assistant 消息带 peer_id。
  /// 跳过自动注入块、命令、短回复与无意义文本。工具调用取自已持久化的 tool_events。
  List<Map<String, dynamic>> _toOvMessages(
    List<ChatMessage> messages,
    Map<String, List<Map<String, dynamic>>>? toolEventsById,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      var c = m.content;
      if (c.contains(_recallMarker)) continue;
      if (m.role != 'user' && m.role != 'assistant') continue;
      c = c.length > 4000 ? c.substring(0, 4000) : c;
      final textCaptured = _shouldCapture(c, m.role);

      if (m.role == 'user') {
        if (!textCaptured) continue;
        out.add({'role': 'user', 'content': c});
        continue;
      }

      // assistant
      final tools = _toolParts(toolEventsById?[m.id] ?? const []);
      if (tools.isNotEmpty) {
        final parts = <Map<String, dynamic>>[];
        if (textCaptured) parts.add({'type': 'text', 'text': c});
        parts.addAll(tools);
        out.add({'role': 'assistant', 'parts': parts, 'peer_id': peerId()});
      } else {
        if (!textCaptured) continue;
        out.add({'role': 'assistant', 'content': c, 'peer_id': peerId()});
      }
    }
    return out;
  }

  /// 把已持久化的工具事件转成 OV 的 tool part（对齐 hermes.json 的 tool 结构）。
  List<Map<String, dynamic>> _toolParts(List<Map<String, dynamic>> events) {
    final out = <Map<String, dynamic>>[];
    for (final e in events) {
      final name = (e['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final id = (e['id'] ?? '').toString().trim();
      final content = (e['content'] ?? '').toString();
      final part = <String, dynamic>{
        'type': 'tool',
        'tool_id': id,
        'tool_name': name,
        'tool_status': 'completed',
      };
      final args = e['arguments'];
      if (args is Map) part['tool_input'] = args;
      part['tool_output'] = content.length > 4000
          ? content.substring(0, 4000)
          : content;
      out.add(part);
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

class _OvWriteResult {
  final bool ok;
  final int statusCode;
  final String errorCode;
  final String error;
  const _OvWriteResult({
    required this.ok,
    required this.statusCode,
    required this.errorCode,
    required this.error,
  });
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
