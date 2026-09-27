import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// DeepSeek Files API 服务（文件暂存空间）。
///
/// 仅支持图片：JPEG / PNG / GIF / WebP，单文件 ≤64 MiB。
/// 上传一次取得 `file_id`，之后可在对话补全请求中以 `{type: file, file_id}` 引用。
/// 默认有效期 7 天（604800 秒），传 [expiresSeconds] 为 0 表示永久有效。
class DeepSeekFileService {
  DeepSeekFileService({
    required this.baseUrl,
    required this.apiKey,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String apiKey;
  final http.Client _client;

  static const int defaultExpiresSeconds = 604800; // 7 天
  static const int minExpiresSeconds = 3600; // 1 小时
  static const int maxExpiresSeconds = 2592000; // 30 天

  Map<String, String> get _authHeaders => {'Authorization': 'Bearer $apiKey'};

  Uri _endpoint(String path) {
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  /// 上传本地图片文件。返回文件对象（含 id，形如 file-api-...）。
  /// [expiresSeconds] 为 null 时使用默认 7 天；为 0 表示永久有效。
  Future<Map<String, dynamic>> upload(
    File file, {
    int? expiresSeconds = defaultExpiresSeconds,
  }) async {
    if (apiKey.isEmpty) throw StateError('DeepSeek API Key is not configured');
    if (!file.existsSync()) throw StateError('Local file not found: ${file.path}');

    final request = http.MultipartRequest('POST', _endpoint('/files'))
      ..headers.addAll(_authHeaders)
      ..fields['purpose'] = 'user_data';
    if (expiresSeconds != null && expiresSeconds != 0) {
      final secs = expiresSeconds.clamp(minExpiresSeconds, maxExpiresSeconds);
      request.fields['expires_after[anchor]'] = 'created_at';
      request.fields['expires_after[seconds]'] = secs.toString();
    }
    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        file.path,
        contentType: null,
      ),
    );

    final streamed = await request.send().timeout(const Duration(minutes: 10));
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode != 200) {
      throw StateError('Upload failed (HTTP ${resp.statusCode}): ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// 列出已上传文件（游标分页）。
  Future<Map<String, dynamic>> list({
    String? after,
    int limit = 100,
    String order = 'asc',
    String purpose = 'user_data',
  }) async {
    if (apiKey.isEmpty) throw StateError('DeepSeek API Key is not configured');
    final params = <String, String>{
      'limit': limit.clamp(1, 1000).toString(),
      'order': order,
      if (purpose.isNotEmpty) 'purpose': purpose,
      if (after != null && after.isNotEmpty) 'after': after,
    };
    final uri = _endpoint('/files').replace(queryParameters: params);
    final resp = await _client
        .get(uri, headers: _authHeaders)
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw StateError('List failed (HTTP ${resp.statusCode}): ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// 查询单个文件信息。
  Future<Map<String, dynamic>> retrieve(String fileId) async {
    if (apiKey.isEmpty) throw StateError('DeepSeek API Key is not configured');
    final resp = await _client
        .get(_endpoint('/files/$fileId'), headers: _authHeaders)
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw StateError(
        'Retrieve failed (HTTP ${resp.statusCode}): ${resp.body}',
      );
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// 删除文件。
  Future<bool> delete(String fileId) async {
    if (apiKey.isEmpty) throw StateError('DeepSeek API Key is not configured');
    final resp = await _client
        .delete(_endpoint('/files/$fileId'), headers: _authHeaders)
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw StateError(
        'Delete failed (HTTP ${resp.statusCode}): ${resp.body}',
      );
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return body['deleted'] == true;
  }

  /// 识别本地图片：先上传取得 file_id，再以 file_id 引用调用 vision 模型。
  ///
  /// [model] 为识别所用模型，默认 `deepseek-flash`。
  /// 返回识别文本。
  Future<String> recognize(
    File file, {
    String prompt = '请详细描述这张图片的内容',
    String model = 'deepseek-flash',
    int? expiresSeconds = defaultExpiresSeconds,
  }) async {
    if (apiKey.isEmpty) throw StateError('DeepSeek API Key is not configured');
    final uploaded = await upload(file, expiresSeconds: expiresSeconds);
    final fileId = (uploaded['id'] ?? '').toString();
    if (fileId.isEmpty) throw StateError('Upload succeeded but no file id returned');

    final payload = {
      'model': model,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            {'type': 'file', 'file_id': fileId},
          ],
        },
      ],
    };
    final resp = await _client
        .post(
          _endpoint('/chat/completions'),
          headers: {
            ..._authHeaders,
            'Content-Type': 'application/json',
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 120));
    if (resp.statusCode != 200) {
      throw StateError(
        'Recognize failed (HTTP ${resp.statusCode}): ${resp.body}',
      );
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final choices = body['choices'] as List?;
    final message = choices?.isNotEmpty == true
        ? (choices!.first as Map)['message'] as Map?
        : null;
    return (message?['content'] ?? '').toString();
  }
}
