import 'dart:async';
import 'dart:convert';

import 'package:mcp_client/mcp_client.dart' as mcp;

import '../../providers/openviking_provider.dart';

/// @kelivo/openviking — In-memory MCP server engine for OpenViking memory.
///
/// Provides tools (aligned with android-agent semantics):
/// - openviking_search      → 语义搜索（带会话上下文）
/// - openviking_find        → 纯向量语义搜索（可限定 target_uri）
/// - openviking_remember    → 保存记忆
/// - openviking_forget      → 删除记忆文件/目录
/// - openviking_read        → 读取记忆文件（单个/数组）
/// - openviking_list_dir    → 列出目录
/// - openviking_write_file  → 写入记忆文件
///
/// 连接参数（url / key / user / peer / 阈值 / 条数）从 OpenVikingProvider
/// 实时读取，无需作为工具参数传入。用户启用了本 MCP 服务即启用 OpenViking 能力与召回。
class KelivoOpenVikingMcpServerEngine {
  bool _closed = false;
  final OpenVikingProvider Function() _provider;

  KelivoOpenVikingMcpServerEngine(this._provider);

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
              'serverInfo': {'name': '@kelivo/openviking', 'version': '0.1.0'},
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
    final provider = _provider();
    if (!provider.isConfigured) {
      throw Exception('OpenViking 未配置（请在设置中填写服务器地址与 API Key）');
    }
    final svc = provider.service;
    if (svc == null) throw Exception('OpenViking 服务不可用');

    switch (name) {
      case 'openviking_search':
        final query = _req(arguments, 'query');
        final result = await svc.search(
          query,
          scoreThreshold: _threshold(arguments['score_threshold'], provider.threshold),
          limit: _limit(arguments['limit'], provider.displayCount),
        );
        return _hits(result);

      case 'openviking_find':
        final query = _req(arguments, 'query');
        final result = await svc.find(
          query,
          scoreThreshold: _threshold(arguments['score_threshold'], provider.findThreshold),
          limit: _limit(arguments['limit'], provider.findLimit),
          targetUri: _str(arguments, 'target_uri'),
        );
        return _hits(result);

      case 'openviking_remember':
        final category = _str(arguments, 'category');
        final nameV = _str(arguments, 'name');
        final content = (arguments['content'] ?? '').toString();
        if (content.trim().isEmpty) throw ArgumentError('content is required');
        return _envelope(
          await svc.remember(
            category.isEmpty ? 'entities' : category,
            nameV.isEmpty ? 'untitled' : nameV,
            content,
          ),
        );

      case 'openviking_forget':
        final uri = _req(arguments, 'uri');
        final recursive = arguments['recursive'] == true;
        final deleted = await svc.forget(uri, recursive: recursive);
        if (!deleted) throw Exception('删除失败');
        return {'success': true, 'uri': uri, 'recursive': recursive};

      case 'openviking_read':
        final raw = arguments['uri'];
        final uris = <String>[];
        if (raw is String && raw.trim().isNotEmpty) {
          uris.add(raw.trim());
        } else if (raw is List) {
          uris.addAll(raw.map((e) => e.toString()).where((e) => e.isNotEmpty));
        }
        if (uris.isEmpty) throw ArgumentError('uri is required');
        if (uris.length == 1) {
          final content = await svc.readFile(uris.first);
          if (content.trimLeft().startsWith('{"error"')) {
            throw Exception(_decodeError(content));
          }
          return {'success': true, 'uri': uris.first, 'content': content};
        }
        return _envelope(await svc.readFiles(uris));

      case 'openviking_list_dir':
        final uri = _req(arguments, 'uri');
        final tree = await svc.listDir(uri, recursive: arguments['recursive'] == true);
        if (tree.trimLeft().startsWith('{"error"')) {
          throw Exception(_decodeError(tree));
        }
        try {
          final decoded = jsonDecode(tree);
          return {'success': true, 'tree': decoded};
        } catch (_) {
          return {'success': true, 'tree': tree};
        }

      case 'openviking_write_file':
        final uri = _req(arguments, 'uri');
        final content = (arguments['content'] ?? '').toString();
        final mode = _str(arguments, 'mode').isEmpty ? 'replace' : _str(arguments, 'mode');
        return _envelope(await svc.writeFile(uri, content, mode: mode));

      default:
        throw Exception('Tool not found: $name');
    }
  }

  Map<String, dynamic> _hits(dynamic result) {
    final hits = (result.hits as List).cast<dynamic>();
    if (hits.isEmpty) {
      return {'success': true, 'results': [], 'message': '未找到相关记忆'};
    }
    final results = hits
        .map(
          (h) => {
            'uri': h.uri,
            'score': h.score,
            'snippet': h.snippet,
            'category': h.category,
          },
        )
        .toList();
    return {'success': true, 'results': results, 'total': results.length};
  }

  /// 把 OpenVikingService 返回的 JSON 信封解成 Map；含 error 时抛出。
  Map<String, dynamic> _envelope(String jsonish) {
    dynamic decoded;
    try {
      decoded = jsonDecode(jsonish);
    } catch (_) {
      return {'success': true, 'content': jsonish};
    }
    if (decoded is Map) {
      final map = decoded.cast<String, dynamic>();
      final err = map['error'];
      if (err != null) throw Exception(err.toString());
      return map;
    }
    return {'success': true, 'content': jsonish};
  }

  String _decodeError(String jsonish) {
    try {
      final m = jsonDecode(jsonish);
      if (m is Map && m['error'] != null) return m['error'].toString();
    } catch (_) {}
    return jsonish;
  }

  static String _str(Map<String, dynamic> args, String key) =>
      (args[key] as String?)?.trim() ?? '';

  static String _req(Map<String, dynamic> args, String key) {
    final v = _str(args, key);
    if (v.isEmpty) throw ArgumentError('$key is required');
    return v;
  }

  static double _threshold(Object? v, double fallback) {
    if (v is num) return v.toDouble().clamp(0.0, 1.0).toDouble();
    return fallback;
  }

  static int _limit(Object? v, int fallback) {
    if (v is num) return v.toInt().clamp(0, 20).toInt();
    return fallback;
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
        'name': 'openviking_search',
        'description': '在 OpenViking 外置记忆中语义搜索（带会话上下文），查找之前保存的知识、偏好、项目信息等',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '搜索关键词，描述要查找什么内容'},
            'score_threshold': {
              'type': 'number',
              'description': '相似度阈值 [0-1]，越高越严格，不传用设置页默认值',
            },
            'limit': {
              'type': 'integer',
              'description': '返回条数上限 [0-20]，不传用设置页默认值',
            },
          },
          'required': ['query'],
        },
      },
      {
        'name': 'openviking_find',
        'description': '在 OpenViking 外置记忆中做纯向量语义搜索（低延迟、可限定范围），查找之前保存的知识、偏好、项目信息等',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '搜索关键词，描述要查找什么内容'},
            'target_uri': {
              'type': 'string',
              'description': '可选。限定检索范围，如 viking://user/{user}/memories/',
            },
            'score_threshold': {
              'type': 'number',
              'description': '相似度阈值 [0-1]，越高越严格，不传用设置页默认值',
            },
            'limit': {
              'type': 'integer',
              'description': '返回条数上限 [0-20]，不传用设置页默认值',
            },
          },
          'required': ['query'],
        },
      },
      {
        'name': 'openviking_remember',
        'description': '将重要信息保存到 OpenViking 外置记忆中，以便后续对话回忆。适合保存：用户偏好、项目配置、关键决策、有用的操作经验',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'category': {
              'type': 'string',
              'enum': ['preferences', 'entities', 'events', 'experiences'],
              'description': '记忆分类：preferences=用户偏好, entities=项目/概念/人物, events=决策/里程碑, experiences=操作经验',
            },
            'name': {'type': 'string', 'description': '记忆名称/主题'},
            'content': {'type': 'string', 'description': '要保存的内容（Markdown 格式）'},
          },
          'required': ['category', 'name', 'content'],
        },
      },
      {
        'name': 'openviking_forget',
        'description': '从 OpenViking 中删除记忆文件或目录。注意：此操作不可撤销！删除非空目录时必须将 recursive 设为 true',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'uri': {'type': 'string', 'description': '要删除的文件/目录 URI'},
            'recursive': {'type': 'boolean', 'description': '是否递归删除目录及其所有子项（默认 false）'},
          },
          'required': ['uri'],
        },
      },
      {
        'name': 'openviking_read',
        'description': '通过 URI 读取 OpenViking 记忆中的文件内容（字符串或数组）',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'uri': {
              'description': '文件 URI（字符串）或 URI 数组',
            },
          },
          'required': ['uri'],
        },
      },
      {
        'name': 'openviking_list_dir',
        'description': '列出 OpenViking 指定目录下的所有文件和子目录',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'uri': {'type': 'string', 'description': '目录 URI'},
            'recursive': {'type': 'boolean', 'description': '是否递归列出子目录（默认 false）'},
          },
          'required': ['uri'],
        },
      },
      {
        'name': 'openviking_write_file',
        'description': '写入内容到 OpenViking 记忆文件。mode：create=创建, replace=覆盖, append=追加',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'uri': {'type': 'string', 'description': '文件 URI'},
            'content': {'type': 'string', 'description': '要写入的内容（Markdown 格式）'},
            'mode': {
              'type': 'string',
              'enum': ['create', 'replace', 'append'],
              'description': '写入模式',
            },
          },
          'required': ['uri', 'content'],
        },
      },
    ];
  }
}

/// In-memory ClientTransport for the OpenViking MCP server.
class KelivoOpenVikingInMemoryClientTransport implements mcp.ClientTransport {
  final KelivoOpenVikingMcpServerEngine _server;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  bool _closed = false;

  KelivoOpenVikingInMemoryClientTransport(this._server);

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
