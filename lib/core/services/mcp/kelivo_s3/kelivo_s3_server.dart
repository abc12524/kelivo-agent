import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_client/mcp_client.dart' as mcp;
import 'package:xml/xml.dart';

import '../../../models/backup.dart';

/// @kelivo/s3 — In-memory MCP server engine for S3-compatible object storage
///
/// Provides tools for interacting with S3-compatible object storage:
/// - s3_list_buckets    → List all buckets
/// - s3_list_objects    → List objects in a bucket
/// - s3_get_object      → Download object content (returns base64 for binary)
/// - s3_put_object      → Upload an object
/// - s3_delete_object   → Delete a single object
/// - s3_delete_objects  → Batch delete multiple objects
/// - s3_copy_object     → Copy an object
/// - s3_head_object     → Get object metadata
/// - s3_create_bucket   → Create a bucket
/// - s3_delete_bucket   → Delete a bucket
/// - s3_presign_url     → Generate a presigned URL

class S3ToolRequestPayload {
  final S3Config config;
  final String? bucket;
  final String? key;
  final String? body;
  final String? contentType;
  final String? copySource;
  final String? prefix;
  final int? maxKeys;
  final List<String>? keys;
  final int? expiresIn;
  final String? delimiter;

  S3ToolRequestPayload({
    required this.config,
    this.bucket,
    this.key,
    this.body,
    this.contentType,
    this.copySource,
    this.prefix,
    this.maxKeys,
    this.keys,
    this.expiresIn,
    this.delimiter,
  });

  static S3ToolRequestPayload parse(Object? args, S3Config config) {
    if (args is! Map) {
      throw ArgumentError('Invalid arguments: expected object');
    }
    final map = args.cast<String, dynamic>();

    return S3ToolRequestPayload(
      config: config,
      bucket: map['bucket']?.toString(),
      key: map['key']?.toString(),
      body: map['body']?.toString(),
      contentType: map['contentType']?.toString(),
      copySource: map['copySource']?.toString(),
      prefix: map['prefix']?.toString(),
      maxKeys: map['maxKeys'] is int ? map['maxKeys'] as int : null,
      keys: map['keys'] is List
          ? (map['keys'] as List).map((e) => e.toString()).toList()
          : null,
      expiresIn: map['expiresIn'] is int ? map['expiresIn'] as int : null,
      delimiter: map['delimiter']?.toString(),
    );
  }
}

/// Minimal S3 operations helper using the existing S3BackupClient
class KelivoS3Helper {
  static Future<http.Response> _sendRequest(
    S3Config cfg, {
    required String method,
    required Uri uri,
    Map<String, String>? headers,
    List<int>? bodyBytes,
  }) async {
    final client = http.Client();
    try {
      final now = DateTime.now().toUtc();
      final amzDate = _amzDate(now);
      final dateStamp = _dateStamp(now);
      final payload = bodyBytes ?? const <int>[];
      final payloadHash = _hashHex(payload);

      final host = _hostHeader(uri);
      final reqHeaders = <String, String>{
        'host': host,
        'x-amz-date': amzDate,
        'x-amz-content-sha256': payloadHash,
        ...?headers,
      };
      if (cfg.sessionToken.trim().isNotEmpty) {
        reqHeaders['x-amz-security-token'] = cfg.sessionToken.trim();
      }
      if (cfg.userAgent.trim().isNotEmpty) {
        reqHeaders['User-Agent'] = cfg.userAgent.trim();
      }

      final canonHeaders = _canonicalHeaders(reqHeaders);
      final signedHeaders = _signedHeaders(reqHeaders);
      final canonicalRequest = [
        method,
        uri.path.isEmpty ? '/' : uri.path,
        _canonicalQuery(uri.queryParameters),
        canonHeaders,
        signedHeaders,
        payloadHash,
      ].join('\n');
      final canonicalRequestHash = _hashHex(utf8.encode(canonicalRequest));
      final scope = '$dateStamp/${cfg.region.trim()}/s3/aws4_request';
      final sts = _stringToSign(
        amzDate: amzDate,
        credentialScope: scope,
        canonicalRequestHash: canonicalRequestHash,
      );
      final sig = _signature(
        secretAccessKey: cfg.secretAccessKey,
        dateStamp: dateStamp,
        region: cfg.region.trim(),
        service: 's3',
        stringToSign: sts,
      );
      final auth =
          'AWS4-HMAC-SHA256 Credential=${cfg.accessKeyId.trim()}/$scope, SignedHeaders=$signedHeaders, Signature=$sig';

      final req = http.Request(method, uri);
      req.headers.addAll({...reqHeaders, 'Authorization': auth});
      if (payload.isNotEmpty) {
        req.bodyBytes = Uint8List.fromList(payload);
      }

      final streamed = await client.send(req);
      return await http.Response.fromStream(streamed);
    } finally {
      client.close();
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _amzDate(DateTime utc) {
    final t = utc.toUtc();
    return '${t.year}${_two(t.month)}${_two(t.day)}T${_two(t.hour)}${_two(t.minute)}${_two(t.second)}Z';
  }

  static String _dateStamp(DateTime utc) {
    final t = utc.toUtc();
    return '${t.year}${_two(t.month)}${_two(t.day)}';
  }

  static String _hashHex(List<int> bytes) => sha256.convert(bytes).toString();

  static List<int> _hmacSha256(List<int> key, String msg) {
    return Hmac(sha256, key).convert(utf8.encode(msg)).bytes;
  }

  static String _hex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static String _awsEncode(String s) {
    return Uri.encodeComponent(s).replaceAll('%7E', '~');
  }

  static String _canonicalQuery(Map<String, String> query) {
    final pairs = <(String, String)>[
      for (final e in query.entries) (e.key, e.value),
    ];
    pairs.sort((a, b) {
      final k = _awsEncode(a.$1).compareTo(_awsEncode(b.$1));
      if (k != 0) return k;
      return _awsEncode(a.$2).compareTo(_awsEncode(b.$2));
    });
    return pairs
        .map((p) => '${_awsEncode(p.$1)}=${_awsEncode(p.$2)}')
        .join('&');
  }

  static String _canonicalHeaders(Map<String, String> headers) {
    final entries = headers.entries
        .map(
          (e) => MapEntry(
            e.key.toLowerCase().trim(),
            e.value.trim().replaceAll(RegExp(r'\s+'), ' '),
          ),
        )
        .toList();
    entries.sort((a, b) => a.key.compareTo(b.key));
    final sb = StringBuffer();
    for (final e in entries) {
      sb.write('${e.key}:${e.value}\n');
    }
    return sb.toString();
  }

  static String _signedHeaders(Map<String, String> headers) {
    final names =
        headers.keys.map((k) => k.toLowerCase().trim()).toSet().toList()
          ..sort();
    return names.join(';');
  }

  static String _hostHeader(Uri uri) {
    if (!uri.hasPort) return uri.host;
    final port = uri.port;
    if (uri.scheme == 'https' && port == 443) return uri.host;
    if (uri.scheme == 'http' && port == 80) return uri.host;
    return '${uri.host}:$port';
  }

  static String _stringToSign({
    required String amzDate,
    required String credentialScope,
    required String canonicalRequestHash,
  }) {
    return 'AWS4-HMAC-SHA256\n$amzDate\n$credentialScope\n$canonicalRequestHash';
  }

  static String _signature({
    required String secretAccessKey,
    required String dateStamp,
    required String region,
    required String service,
    required String stringToSign,
  }) {
    final kSecret = utf8.encode('AWS4$secretAccessKey');
    final kDate = _hmacSha256(kSecret, dateStamp);
    final kRegion = _hmacSha256(kDate, region);
    final kService = _hmacSha256(kRegion, service);
    final kSigning = _hmacSha256(kService, 'aws4_request');
    final sig = Hmac(sha256, kSigning).convert(utf8.encode(stringToSign)).bytes;
    return _hex(sig);
  }

  static Uri _buildObjectUri(S3Config cfg, String key) {
    final base = Uri.parse(_normalizeEndpoint(cfg.endpoint));
    final baseSegs = _normalizedBasePathSegments(base, cfg);
    final keySegs = key.split('/').where((s) => s.isNotEmpty).toList();

    final host = cfg.pathStyle ? base.host : '${cfg.bucket}.${base.host}';
    final segs = cfg.pathStyle
        ? [...baseSegs, cfg.bucket, ...keySegs]
        : [...baseSegs, ...keySegs];
    return Uri(
      scheme: base.scheme.isEmpty ? 'https' : base.scheme,
      host: host,
      port: base.hasPort ? base.port : null,
      pathSegments: segs,
    );
  }

  static List<String> _normalizedBasePathSegments(Uri base, S3Config cfg) {
    final segs = base.pathSegments.where((s) => s.trim().isNotEmpty).toList();
    final bucket = cfg.bucket.trim();
    if (!cfg.pathStyle || bucket.isEmpty || segs.isEmpty) return segs;
    if (segs.last == bucket) {
      return segs.sublist(0, segs.length - 1);
    }
    return segs;
  }

  static String _normalizeEndpoint(String endpoint) {
    var s = endpoint.trim();
    if (s.isEmpty) throw Exception('S3 endpoint is empty');
    if (!s.contains('://')) s = 'https://$s';
    return s;
  }

  // List all buckets
  static Future<Map<String, dynamic>> listBuckets(S3Config cfg) async {
    final base = Uri.parse(_normalizeEndpoint(cfg.endpoint));
    final uri = Uri(
      scheme: base.scheme.isEmpty ? 'https' : base.scheme,
      host: cfg.pathStyle ? base.host : 's3.${cfg.region}.amazonaws.com',
      port: base.hasPort ? base.port : null,
      path: '/',
    );

    final res = await _sendRequest(cfg, method: 'GET', uri: uri);
    if (res.statusCode != 200) {
      throw Exception('Failed to list buckets: ${res.statusCode}');
    }

    // Parse XML response
    final buckets = <Map<String, dynamic>>[];
    final doc = XmlDocument.parse(res.body);
    for (final bucket in doc.findAllElements('Bucket', namespace: '*')) {
      final name = bucket.getElement('Name', namespace: '*')?.innerText ?? '';
      final creationDate =
          bucket.getElement('CreationDate', namespace: '*')?.innerText ?? '';
      buckets.add({'name': name, 'creationDate': creationDate});
    }

    return {'buckets': buckets};
  }

  // List objects in bucket
  static Future<Map<String, dynamic>> listObjects(
    S3Config cfg, {
    String? prefix,
    int? maxKeys,
    String? delimiter,
    String? continuationToken,
  }) async {
    final query = <String, String>{
      'list-type': '2',
      if (prefix != null && prefix.isNotEmpty) 'prefix': prefix,
      if (maxKeys != null) 'max-keys': maxKeys.toString(),
      if (delimiter != null && delimiter.isNotEmpty) 'delimiter': delimiter,
      if (continuationToken != null) 'continuation-token': continuationToken,
    };

    final base = Uri.parse(_normalizeEndpoint(cfg.endpoint));
    final host = cfg.pathStyle ? base.host : '${cfg.bucket}.${base.host}';
    final uri = Uri(
      scheme: base.scheme.isEmpty ? 'https' : base.scheme,
      host: host,
      port: base.hasPort ? base.port : null,
      path: '/',
      queryParameters: query,
    );

    final res = await _sendRequest(
      cfg,
      method: 'GET',
      uri: uri,
      headers: {'accept': 'application/xml'},
    );

    if (res.statusCode != 200) {
      throw Exception('Failed to list objects: ${res.statusCode}');
    }

    final objects = <Map<String, dynamic>>[];
    final doc = XmlDocument.parse(res.body);
    for (final c in doc.findAllElements('Contents', namespace: '*')) {
      final key = c.getElement('Key', namespace: '*')?.innerText ?? '';
      final sizeStr = c.getElement('Size', namespace: '*')?.innerText ?? '0';
      final lastModified =
          c.getElement('LastModified', namespace: '*')?.innerText ?? '';
      final storageClass =
          c.getElement('StorageClass', namespace: '*')?.innerText ?? '';
      final etag = c.getElement('ETag', namespace: '*')?.innerText ?? '';

      objects.add({
        'key': key,
        'size': int.tryParse(sizeStr) ?? 0,
        'lastModified': lastModified,
        'storageClass': storageClass,
        'etag': etag,
      });
    }

    final isTruncated =
        doc
            .findAllElements('IsTruncated', namespace: '*')
            .map((e) => e.innerText.trim().toLowerCase())
            .firstWhere((s) => s.isNotEmpty, orElse: () => 'false') ==
        'true';
    final nextToken = doc
        .findAllElements('NextContinuationToken', namespace: '*')
        .map((e) => e.innerText.trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');

    return {
      'objects': objects,
      'isTruncated': isTruncated,
      'nextContinuationToken': nextToken,
      'name':
          doc
              .findAllElements('Name', namespace: '*')
              .map((e) => e.innerText)
              .firstOrNull ??
          '',
      'prefix':
          doc
              .findAllElements('Prefix', namespace: '*')
              .map((e) => e.innerText)
              .firstOrNull ??
          '',
    };
  }

  // Get object content
  static Future<Map<String, dynamic>> getObject(
    S3Config cfg, {
    required String key,
    bool returnBase64 = false,
  }) async {
    final uri = _buildObjectUri(cfg, key);
    final res = await _sendRequest(cfg, method: 'GET', uri: uri);

    if (res.statusCode != 200) {
      throw Exception('Failed to get object: ${res.statusCode}');
    }

    final contentType = res.headers['content-type'] ?? '';
    final contentLength = res.headers['content-length'] ?? '0';
    final lastModified = res.headers['last-modified'] ?? '';
    final etag = res.headers['etag'] ?? '';

    if (returnBase64) {
      return {
        'content': base64Encode(res.bodyBytes),
        'contentType': contentType,
        'contentLength': int.tryParse(contentLength) ?? 0,
        'lastModified': lastModified,
        'etag': etag,
        'encoding': 'base64',
      };
    }

    return {
      'content': res.body,
      'contentType': contentType,
      'contentLength': int.tryParse(contentLength) ?? 0,
      'lastModified': lastModified,
      'etag': etag,
    };
  }

  // Put object
  static Future<Map<String, dynamic>> putObject(
    S3Config cfg, {
    required String key,
    required List<int> body,
    String? contentType,
  }) async {
    final uri = _buildObjectUri(cfg, key);
    final headers = <String, String>{
      if (contentType != null && contentType.isNotEmpty)
        'content-type': contentType,
    };

    final res = await _sendRequest(
      cfg,
      method: 'PUT',
      uri: uri,
      headers: headers,
      bodyBytes: body,
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Failed to put object: ${res.statusCode}');
    }

    return {
      'success': true,
      'etag': res.headers['etag'] ?? '',
      'key': key,
      'size': body.length,
    };
  }

  // Delete object
  static Future<Map<String, dynamic>> deleteObject(
    S3Config cfg, {
    required String key,
  }) async {
    final uri = _buildObjectUri(cfg, key);
    final res = await _sendRequest(cfg, method: 'DELETE', uri: uri);

    if (res.statusCode != 204 && res.statusCode != 200) {
      throw Exception('Failed to delete object: ${res.statusCode}');
    }

    return {'success': true, 'key': key};
  }

  // Batch delete objects
  static Future<Map<String, dynamic>> deleteObjects(
    S3Config cfg, {
    required List<String> keys,
  }) async {
    if (keys.isEmpty) return {'success': true, 'deleted': []};

    final deleteXml = StringBuffer('<Delete>');
    for (final key in keys) {
      deleteXml.write('<Object><Key>${_xmlEscape(key)}</Key></Object>');
    }
    deleteXml.write('</Delete>');

    final bodyBytes = utf8.encode(deleteXml.toString());
    final base = Uri.parse(_normalizeEndpoint(cfg.endpoint));
    final host = cfg.pathStyle ? base.host : '${cfg.bucket}.${base.host}';
    final uri = Uri(
      scheme: base.scheme.isEmpty ? 'https' : base.scheme,
      host: host,
      port: base.hasPort ? base.port : null,
      path: '/',
      queryParameters: {'delete': ''},
    );

    final res = await _sendRequest(
      cfg,
      method: 'POST',
      uri: uri,
      headers: {'content-type': 'application/xml'},
      bodyBytes: bodyBytes,
    );

    if (res.statusCode != 200) {
      throw Exception('Failed to delete objects: ${res.statusCode}');
    }

    return {'success': true, 'deleted': keys};
  }

  // Copy object
  static Future<Map<String, dynamic>> copyObject(
    S3Config cfg, {
    required String source,
    required String destination,
  }) async {
    final uri = _buildObjectUri(cfg, destination);
    final sourceBucket = cfg.bucket;
    final copySource = '/$sourceBucket/$source';

    final res = await _sendRequest(
      cfg,
      method: 'PUT',
      uri: uri,
      headers: {'x-amz-copy-source': copySource},
    );

    if (res.statusCode != 200) {
      throw Exception('Failed to copy object: ${res.statusCode}');
    }

    return {
      'success': true,
      'source': source,
      'destination': destination,
      'etag': res.headers['etag'] ?? '',
    };
  }

  // Head object (get metadata)
  static Future<Map<String, dynamic>> headObject(
    S3Config cfg, {
    required String key,
  }) async {
    final uri = _buildObjectUri(cfg, key);
    final res = await _sendRequest(cfg, method: 'HEAD', uri: uri);

    if (res.statusCode != 200) {
      throw Exception('Failed to head object: ${res.statusCode}');
    }

    return {
      'key': key,
      'contentLength': int.tryParse(res.headers['content-length'] ?? '0') ?? 0,
      'contentType': res.headers['content-type'] ?? '',
      'etag': res.headers['etag'] ?? '',
      'lastModified': res.headers['last-modified'] ?? '',
      'storageClass': res.headers['x-amz-storage-class'] ?? '',
      'metadata': Map.fromEntries(
        res.headers.entries
            .where((e) => e.key.startsWith('x-amz-meta-'))
            .map(
              (e) => MapEntry(e.key.substring('x-amz-meta-'.length), e.value),
            ),
      ),
    };
  }

  // Create bucket
  static Future<Map<String, dynamic>> createBucket(
    S3Config cfg, {
    required String bucketName,
  }) async {
    final base = Uri.parse(_normalizeEndpoint(cfg.endpoint));
    final uri = Uri(
      scheme: base.scheme.isEmpty ? 'https' : base.scheme,
      host: cfg.pathStyle ? base.host : 's3.${cfg.region}.amazonaws.com',
      port: base.hasPort ? base.port : null,
      path: cfg.pathStyle ? '/$bucketName' : '/',
    );

    final res = await _sendRequest(
      cfg,
      method: 'PUT',
      uri: uri,
      headers: {'content-type': 'application/xml'},
    );

    if (res.statusCode != 200) {
      throw Exception('Failed to create bucket: ${res.statusCode}');
    }

    return {'success': true, 'bucket': bucketName};
  }

  // Delete bucket
  static Future<Map<String, dynamic>> deleteBucket(
    S3Config cfg, {
    required String bucketName,
  }) async {
    final base = Uri.parse(_normalizeEndpoint(cfg.endpoint));
    final uri = Uri(
      scheme: base.scheme.isEmpty ? 'https' : base.scheme,
      host: cfg.pathStyle ? base.host : 's3.${cfg.region}.amazonaws.com',
      port: base.hasPort ? base.port : null,
      path: cfg.pathStyle ? '/$bucketName' : '/',
    );

    final res = await _sendRequest(cfg, method: 'DELETE', uri: uri);

    if (res.statusCode != 204 && res.statusCode != 200) {
      throw Exception('Failed to delete bucket: ${res.statusCode}');
    }

    return {'success': true, 'bucket': bucketName};
  }

  // Generate presigned URL
  static Future<Map<String, dynamic>> presignUrl(
    S3Config cfg, {
    required String key,
    int expiresIn = 3600,
  }) async {
    final uri = _buildObjectUri(cfg, key);
    final now = DateTime.now().toUtc();
    final amzDate = _amzDate(now);
    final dateStamp = _dateStamp(now);

    final queryParameters = {
      'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
      'X-Amz-Credential':
          '${cfg.accessKeyId.trim()}/$dateStamp/${cfg.region.trim()}/s3/aws4_request',
      'X-Amz-Date': amzDate,
      'X-Amz-Expires': expiresIn.toString(),
      'X-Amz-SignedHeaders': 'host',
    };

    final canonicalQueryString = _canonicalQuery(queryParameters);
    final hostHeader = _hostHeader(uri);
    final canonicalRequest = [
      'GET',
      uri.path.isEmpty ? '/' : uri.path,
      canonicalQueryString,
      'host:$hostHeader\n',
      'host',
      'UNSIGNED-PAYLOAD',
    ].join('\n');
    final canonicalRequestHash = _hashHex(utf8.encode(canonicalRequest));
    final scope = '$dateStamp/${cfg.region.trim()}/s3/aws4_request';
    final sts = _stringToSign(
      amzDate: amzDate,
      credentialScope: scope,
      canonicalRequestHash: canonicalRequestHash,
    );
    final sig = _signature(
      secretAccessKey: cfg.secretAccessKey,
      dateStamp: dateStamp,
      region: cfg.region.trim(),
      service: 's3',
      stringToSign: sts,
    );

    final presignedUri = uri.replace(
      queryParameters: {...queryParameters, 'X-Amz-Signature': sig},
    );

    return {'url': presignedUri.toString(), 'expiresIn': expiresIn, 'key': key};
  }

  static String _xmlEscape(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}

/// Minimal JSON-RPC server for MCP that serves @kelivo/s3 tools.
class KelivoS3McpServerEngine {
  bool _closed = false;
  final S3Config Function() _configProvider;

  KelivoS3McpServerEngine(this._configProvider);

  S3Config get _config => _configProvider();

  Future<dynamic> handleMessage(dynamic message) async {
    if (_closed) return null;

    if (message is List) {
      final out = <dynamic>[];
      for (final m in message) {
        out.add(await _handleSingle(m));
      }
      return out;
    }
    return await _handleSingle(message);
  }

  Future<Map<String, dynamic>> _handleSingle(dynamic raw) async {
    try {
      if (raw is! Map) {
        return _error(null, code: -32600, message: 'Invalid Request');
      }
      final req = raw.cast<String, dynamic>();
      final id = req['id'];
      final method = (req['method'] ?? '').toString();
      final params = (req['params'] is Map)
          ? (req['params'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};

      switch (method) {
        case mcp.McpProtocol.methodInitialize:
          return _ok(
            id,
            result: {
              'serverInfo': {'name': '@kelivo/s3', 'version': '0.1.0'},
              'protocolVersion': mcp.McpProtocol.defaultVersion,
              'capabilities': {
                'tools': {'listChanged': false},
              },
            },
          );

        case mcp.McpProtocol.methodListTools:
          return _ok(id, result: {'tools': _toolDefinitions()});

        case mcp.McpProtocol.methodCallTool:
          final name = (params['name'] ?? '').toString();
          final arguments = (params['arguments'] is Map)
              ? (params['arguments'] as Map).cast<String, dynamic>()
              : <String, dynamic>{};

          try {
            final result = await _executeTool(name, arguments);
            return _ok(id, result: _success(result));
          } catch (e) {
            return _ok(id, result: _errorResult(e.toString()));
          }

        default:
          if (id == null) return _noop();
          return _error(id, code: -32601, message: 'Method not found: $method');
      }
    } catch (e) {
      return _error(null, code: -32603, message: 'Internal error: $e');
    }
  }

  Future<Map<String, dynamic>> _executeTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final cfg = _config;

    switch (name) {
      case 's3_list_buckets':
        return KelivoS3Helper.listBuckets(cfg);

      case 's3_list_objects':
        return KelivoS3Helper.listObjects(
          cfg,
          prefix: arguments['prefix']?.toString(),
          maxKeys: arguments['maxKeys'] is int
              ? arguments['maxKeys'] as int
              : null,
          delimiter: arguments['delimiter']?.toString(),
          continuationToken: arguments['continuationToken']?.toString(),
        );

      case 's3_get_object':
        final key = arguments['key']?.toString();
        if (key == null || key.isEmpty) throw ArgumentError('key is required');
        return KelivoS3Helper.getObject(
          cfg,
          key: key,
          returnBase64: arguments['returnBase64'] == true,
        );

      case 's3_put_object':
        final key = arguments['key']?.toString();
        if (key == null || key.isEmpty) throw ArgumentError('key is required');
        final body = arguments['body']?.toString();
        if (body == null) throw ArgumentError('body is required');
        return KelivoS3Helper.putObject(
          cfg,
          key: key,
          body: utf8.encode(body),
          contentType: arguments['contentType']?.toString(),
        );

      case 's3_delete_object':
        final key = arguments['key']?.toString();
        if (key == null || key.isEmpty) throw ArgumentError('key is required');
        return KelivoS3Helper.deleteObject(cfg, key: key);

      case 's3_delete_objects':
        final keys = arguments['keys'];
        if (keys is! List) throw ArgumentError('keys is required');
        final keyList = keys.map((e) => e.toString()).toList();
        return KelivoS3Helper.deleteObjects(cfg, keys: keyList);

      case 's3_copy_object':
        final source = arguments['source']?.toString();
        final destination = arguments['destination']?.toString();
        if (source == null || source.isEmpty) {
          throw ArgumentError('source is required');
        }
        if (destination == null || destination.isEmpty) {
          throw ArgumentError('destination is required');
        }
        return KelivoS3Helper.copyObject(
          cfg,
          source: source,
          destination: destination,
        );

      case 's3_head_object':
        final key = arguments['key']?.toString();
        if (key == null || key.isEmpty) throw ArgumentError('key is required');
        return KelivoS3Helper.headObject(cfg, key: key);

      case 's3_create_bucket':
        final bucketName = arguments['bucketName']?.toString();
        if (bucketName == null || bucketName.isEmpty) {
          throw ArgumentError('bucketName is required');
        }
        return KelivoS3Helper.createBucket(cfg, bucketName: bucketName);

      case 's3_delete_bucket':
        final bucketName = arguments['bucketName']?.toString();
        if (bucketName == null || bucketName.isEmpty) {
          throw ArgumentError('bucketName is required');
        }
        return KelivoS3Helper.deleteBucket(cfg, bucketName: bucketName);

      case 's3_presign_url':
        final key = arguments['key']?.toString();
        if (key == null || key.isEmpty) throw ArgumentError('key is required');
        final expiresIn = arguments['expiresIn'] is int
            ? arguments['expiresIn'] as int
            : 3600;
        return KelivoS3Helper.presignUrl(cfg, key: key, expiresIn: expiresIn);

      default:
        throw Exception('Tool not found: $name');
    }
  }

  void close() {
    _closed = true;
  }

  Map<String, dynamic> _ok(dynamic id, {required Map<String, dynamic> result}) {
    return {'jsonrpc': '2.0', if (id != null) 'id': id, 'result': result};
  }

  Map<String, dynamic> _error(
    dynamic id, {
    required int code,
    required String message,
  }) {
    return {
      'jsonrpc': '2.0',
      if (id != null) 'id': id,
      'error': {'code': code, 'message': message},
    };
  }

  Map<String, dynamic> _noop() => {'jsonrpc': '2.0'};

  Map<String, dynamic> _success(Map<String, dynamic> data) {
    return {
      'content': [
        {'type': 'text', 'text': jsonEncode(data)},
      ],
      'isStreaming': false,
      'isError': false,
    };
  }

  Map<String, dynamic> _errorResult(String message) {
    return {
      'content': [
        {'type': 'text', 'text': message},
      ],
      'isStreaming': false,
      'isError': true,
    };
  }

  List<Map<String, dynamic>> _toolDefinitions() {
    return [
      {
        'name': 's3_list_buckets',
        'description': 'List all buckets in the S3-compatible storage',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
      {
        'name': 's3_list_objects',
        'description': 'List objects in a bucket',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'prefix': {'type': 'string', 'description': 'Filter by prefix'},
            'maxKeys': {
              'type': 'integer',
              'description': 'Maximum number of objects to return',
            },
            'delimiter': {
              'type': 'string',
              'description': 'Delimiter for grouping',
            },
            'continuationToken': {
              'type': 'string',
              'description': 'Token for pagination',
            },
          },
        },
      },
      {
        'name': 's3_get_object',
        'description':
            'Download an object from S3. Returns content as text or base64.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'key': {'type': 'string', 'description': 'Object key'},
            'returnBase64': {
              'type': 'boolean',
              'description': 'Return content as base64 (for binary files)',
            },
          },
          'required': ['key'],
        },
      },
      {
        'name': 's3_put_object',
        'description': 'Upload an object to S3',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'key': {'type': 'string', 'description': 'Object key'},
            'body': {'type': 'string', 'description': 'Object content'},
            'contentType': {
              'type': 'string',
              'description': 'Content type (optional)',
            },
          },
          'required': ['key', 'body'],
        },
      },
      {
        'name': 's3_delete_object',
        'description': 'Delete an object from S3',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'key': {'type': 'string', 'description': 'Object key'},
          },
          'required': ['key'],
        },
      },
      {
        'name': 's3_delete_objects',
        'description': 'Batch delete multiple objects from S3',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'keys': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'List of object keys to delete',
            },
          },
          'required': ['keys'],
        },
      },
      {
        'name': 's3_copy_object',
        'description': 'Copy an object within S3',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'source': {'type': 'string', 'description': 'Source object key'},
            'destination': {
              'type': 'string',
              'description': 'Destination object key',
            },
          },
          'required': ['source', 'destination'],
        },
      },
      {
        'name': 's3_head_object',
        'description': 'Get object metadata without downloading content',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'key': {'type': 'string', 'description': 'Object key'},
          },
          'required': ['key'],
        },
      },
      {
        'name': 's3_create_bucket',
        'description': 'Create a new bucket',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'bucketName': {
              'type': 'string',
              'description': 'Name of the bucket to create',
            },
          },
          'required': ['bucketName'],
        },
      },
      {
        'name': 's3_delete_bucket',
        'description': 'Delete a bucket (must be empty)',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'bucketName': {
              'type': 'string',
              'description': 'Name of the bucket to delete',
            },
          },
          'required': ['bucketName'],
        },
      },
      {
        'name': 's3_presign_url',
        'description':
            'Generate a presigned URL for temporary access to an object',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'key': {'type': 'string', 'description': 'Object key'},
            'expiresIn': {
              'type': 'integer',
              'description': 'URL expiration time in seconds (default: 3600)',
            },
          },
          'required': ['key'],
        },
      },
    ];
  }
}

/// In-memory ClientTransport for the S3 MCP server
class KelivoS3InMemoryClientTransport implements mcp.ClientTransport {
  final KelivoS3McpServerEngine _server;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  bool _closed = false;

  KelivoS3InMemoryClientTransport(this._server);

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    if (_closed) return;
    Future.microtask(() async {
      final resp = await _server.handleMessage(message);
      if (_closed) return;
      if (resp != null) {
        _messageController.add(resp);
      }
    });
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _server.close();
    } catch (_) {}
    if (!_messageController.isClosed) _messageController.close();
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
  }
}
