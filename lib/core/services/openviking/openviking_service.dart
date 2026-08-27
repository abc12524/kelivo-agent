import 'dart:convert';
import 'package:http/http.dart' as http;

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

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
    'X-OpenViking-Account': 'default',
    'X-OpenViking-Peer': 'default',
  };

  Future<OvSearchResult> search(String query, {double scoreThreshold = 0.35, int limit = 5}) async {
    if (baseUrl.isEmpty) return OvSearchResult.empty;
    try {
      final base = baseUrl.replaceAll(RegExp(r'/\$/'), '');
      final url = Uri.parse('$base/api/v1/search/search');
      final response = await _client.post(url, headers: _headers, body: jsonEncode({
        'query': query, 'score_threshold': scoreThreshold, 'limit': limit,
      })).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return OvSearchResult.empty;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final result = body['result'] as Map<String, dynamic>?;
      // 检索结果分布在 memories / resources / skills 三段，需合并后按相关度排序
      final segments = [
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
          hits.add(OvMemoryHit(
            uri: uri,
            score: (obj['score'] as num?)?.toDouble() ?? 0.0,
            snippet: (obj['abstract'] as String? ?? ''),
            category: obj['category'] as String? ?? '',
          ));
        }
      }
      if (hits.isEmpty) return OvSearchResult.empty;
      hits.sort((a, b) => b.score.compareTo(a.score));
      return OvSearchResult(hits: hits.take(limit).toList());
    } catch (_) { return OvSearchResult.empty; }
  }

  Future<String> loadContext(String query, {double scoreThreshold = 0.35, int displayCount = 3}) async {
    if (displayCount <= 0 || baseUrl.isEmpty) return '';
    final result = await search(query, scoreThreshold: scoreThreshold, limit: displayCount);
    if (result.hits.isEmpty) return '';
    return result.hits.map((h) {
      final scoreStr = h.score > 0 ? '(${h.score.toStringAsFixed(2)})' : '';
      return '> 📚 [${h.uri}] $scoreStr\n  ${h.snippet}';
    }).join('\n');
  }
}

class OvMemoryHit {
  final String uri; final double score; final String snippet; final String category;
  OvMemoryHit({required this.uri, required this.score, required this.snippet, required this.category});
}

class OvSearchResult {
  final List<OvMemoryHit> hits;
  const OvSearchResult({this.hits = const []});
  static const empty = OvSearchResult();
}
