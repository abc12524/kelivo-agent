import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

class BaiduQianfanProvider extends ChangeNotifier {
  static const _key = 'baidu_qianfan_api_key_v1';
  String _apiKey = '';
  String get apiKey => _apiKey;
  bool get isConfigured => _apiKey.isNotEmpty;
  BaiduQianfanProvider() { _load(); }
  Future<void> _load() async {
    _apiKey = (await SharedPreferences.getInstance()).getString(_key) ?? '';
    notifyListeners();
  }
  Future<void> setApiKey(String v) async {
    _apiKey = v.trim();
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_key, _apiKey);
  }
}

class BaiduQianfanService {
  static Future<String> _getKey() async {
    return (await SharedPreferences.getInstance()).getString('baidu_qianfan_api_key_v1') ?? '';
  }

  static Future<String> search(String q) async {
    final k = await _getKey();
    if (k.isEmpty) return '{"error":"Not configured"}';
    try {
      final r = await http.post(
        Uri.parse('https://qianfan.baidubce.com/v2/ai_search/web_search'),
        headers: {'Content-Type': 'application/json', 'X-Appbuilder-Authorization': 'Bearer '},
        body: jsonEncode({'messages': [{'role': 'user', 'content': q}], 'search_source': 'baidu_search_v2', 'resource_type_filter': [{'type': 'web', 'top_k': 10}]}),
      ).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return '{"error":"HTTP .statusCode"}';
      final b = jsonDecode(r.body);
      final refs = b['references'] as List<dynamic>?;
      if (refs == null || refs.isEmpty) return '{"error":"No results"}';
      final results = refs.map((x) {
        final m = x as Map<String, dynamic>;
        return {'title': m['title'] ?? '', 'url': m['url'] ?? '', 'snippet': m['snippet'] ?? ''};
      }).toList();
      return jsonEncode({'success': true, 'results': results});
    } catch (e) { return '{"error":""}'; }
  }

  static Future<String> baike(String q) async {
    final k = await _getKey();
    if (k.isEmpty) return '{"error":"Not configured"}';
    try {
      final u = Uri.parse('https://appbuilder.baidu.com/v2/baike/lemma/get_content?search_type=lemmaTitle&search_key=' + Uri.encodeComponent(q));
      final r = await http.get(u, headers: {'Authorization': 'Bearer '}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return '{"error":"HTTP .statusCode"}';
      final b = jsonDecode(r.body);
      final result = b['result'] as Map<String, dynamic>?;
      if (result == null) return '{"error":"Not found"}';
      final summary = (result['summary'] as String?) ?? '';
      return jsonEncode({'success': true, 'title': result['lemma_title'] ?? '', 'summary': summary.length > 2000 ? summary.substring(0,2000) : summary, 'url': result['url'] ?? ''});
    } catch (e) { return '{"error":""}'; }
  }
}
