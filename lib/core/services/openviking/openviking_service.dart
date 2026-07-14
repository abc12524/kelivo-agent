import 'dart:convert';
import 'package:http/http.dart' as http;

class OpenVikingService {
  final String baseUrl;
  final String apiKey;
  final String user;
  OpenVikingService({required this.baseUrl, required this.apiKey, required this.user});

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
      final response = await http.post(url, headers: _headers, body: jsonEncode({
        'query': query, 'score_threshold': scoreThreshold, 'limit': limit,
      })).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return OvSearchResult.empty;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final result = body['result'] as Map<String, dynamic>?;
      final memories = result?['memories'] as List<dynamic>?;
      if (memories == null || memories.isEmpty) return OvSearchResult.empty;
      final hits = memories.take(limit).map((m) {
        final obj = m as Map<String, dynamic>;
        return OvMemoryHit(
          uri: obj['uri'] as String? ?? '',
          score: (obj['score'] as num?)?.toDouble() ?? 0.0,
          snippet: (obj['abstract'] as String? ?? ''),
          category: obj['category'] as String? ?? '',
        );
      }).toList();
      return OvSearchResult(hits: hits);
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
