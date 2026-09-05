import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/mcp/mcp_tool_service.dart';
import '../../../core/services/openviking/openviking_service.dart';
import '../../../core/providers/openviking_provider.dart';
import '../../../core/services/search/search_tool_service.dart';
import 'ask_user_interaction_service.dart';
import '../../../core/services/device_tools_service.dart';
import 'local_tools_service.dart';
import 'tool_approval_service.dart';

/// 工具调用处理服务
///
/// 处理各类工具调用：
/// - MCP 工具
/// - Memory 工具 (create/edit/delete)
/// - Search 工具
class ToolHandlerService {
  ToolHandlerService({required this.contextProvider});

  /// Build context (used for accessing providers)
  final BuildContext contextProvider;

  // ============================================================================
  // Tool Schema Sanitization
  // ============================================================================

  /// Sanitize/translate JSON Schema to each provider's accepted subset.
  ///
  /// Different providers (Google, OpenAI, Claude) have different requirements
  /// for tool parameter schemas. This method normalizes schemas to work across
  /// all providers.
  static Map<String, dynamic> sanitizeToolParametersForProvider(
    Map<String, dynamic> schema,
    ProviderKind kind,
  ) {
    Map<String, dynamic> clone = _deepCloneMap(schema);
    clone = _sanitizeNode(clone, kind) as Map<String, dynamic>;
    return clone;
  }

  static dynamic _sanitizeNode(dynamic node, ProviderKind kind) {
    if (node is List) {
      return node.map((e) => _sanitizeNode(e, kind)).toList();
    }
    if (node is! Map) return node;

    final m = Map<String, dynamic>.from(node);
    // Remove $schema as it's not needed for tool definitions
    m.remove(r'$schema');

    // Convert 'const' to 'enum' for compatibility
    if (m.containsKey('const')) {
      final v = m['const'];
      if (v is String || v is num || v is bool) {
        m['enum'] = [v];
      }
      m.remove('const');
    }

    // Flatten anyOf/oneOf/allOf to first variant for simplicity
    for (final key in [
      'anyOf',
      'oneOf',
      'allOf',
      'any_of',
      'one_of',
      'all_of',
    ]) {
      if (m[key] is List && (m[key] as List).isNotEmpty) {
        final first = (m[key] as List).first;
        final flattened = _sanitizeNode(first, kind);
        m.remove(key);
        if (flattened is Map<String, dynamic>) {
          m
            ..remove('type')
            ..remove('properties')
            ..remove('items');
          m.addAll(flattened);
        }
      }
    }

    // Normalize type array to single type
    final t = m['type'];
    if (t is List && t.isNotEmpty) m['type'] = t.first.toString();

    // Normalize items array to single item
    final items = m['items'];
    if (items is List && items.isNotEmpty) m['items'] = items.first;
    if (m['items'] is Map) m['items'] = _sanitizeNode(m['items'], kind);

    // Recursively sanitize properties
    if (m['properties'] is Map) {
      final props = Map<String, dynamic>.from(m['properties']);
      final norm = <String, dynamic>{};
      props.forEach((k, v) {
        norm[k] = _sanitizeNode(v, kind);
      });
      m['properties'] = norm;
    }

    // Keep only allowed keys based on provider
    Set<String> allowed;
    switch (kind) {
      case ProviderKind.google:
        allowed = {
          'type',
          'description',
          'properties',
          'required',
          'items',
          'enum',
        };
        break;
      case ProviderKind.openai:
      case ProviderKind.claude:
        allowed = {
          'type',
          'description',
          'properties',
          'required',
          'items',
          'enum',
        };
        break;
    }
    m.removeWhere((k, v) => !allowed.contains(k));
    return m;
  }

  static Map<String, dynamic> _deepCloneMap(Map<String, dynamic> input) {
    return jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
  }

  static String _toolError({
    required String error,
    required String message,
    required String tool,
    String? instruction,
  }) {
    return jsonEncode({
      'type': 'tool_error',
      'error': error,
      'message': message,
      'tool': tool,
      if (instruction != null) 'instruction': instruction,
    });
  }

  // ============================================================================
  // Tool Definitions Builder
  // ============================================================================

  /// Build tool definitions for API call.
  ///
  /// Returns a list of tool definitions including:
  /// - Search tool (if enabled and model supports tools)
  /// - Memory tools (if assistant has memory enabled)
  /// - MCP tools (from selected servers for the assistant)
  List<Map<String, dynamic>> buildToolDefinitions(
    SettingsProvider settings,
    Assistant? assistant,
    String providerKey,
    String modelId,
    bool hasBuiltInSearch, {
    required bool Function(String providerKey, String modelId) isToolModel,
  }) {
    final List<Map<String, dynamic>> toolDefs = <Map<String, dynamic>>[];
    final supportsTools = isToolModel(providerKey, modelId);

    // Search tool (skip when Gemini built-in search is active)
    if (assistant?.searchEnabled == true &&
        !hasBuiltInSearch &&
        supportsTools) {
      toolDefs.add(SearchToolService.getToolDefinition());
    }

    // Memory tools
    if (assistant?.enableMemory == true && supportsTools) {
      toolDefs.addAll(_buildMemoryToolDefinitions());
    }

    // Local tools
    toolDefs.addAll(
      LocalToolsService.buildToolDefinitions(
        assistant: assistant,
        supportsTools: supportsTools,
      ),
    );

    // MCP tools
    final mcpTools = _buildMcpToolDefinitions(
      settings: settings,
      assistant: assistant,
      providerKey: providerKey,
      supportsTools: supportsTools,
    );
    toolDefs.addAll(mcpTools);
    toolDefs.addAll(DeviceToolsService.getToolDefinitions());

    // OpenViking tools (when configured)
    if (supportsTools) {
      final ovProvider = contextProvider.read<OpenVikingProvider>();
      if (ovProvider.isConfigured) {
        toolDefs.addAll(_buildOvToolDefinitions());
      }
    }

    return toolDefs;
  }

  /// Build memory tool definitions (create/edit/delete).
  List<Map<String, dynamic>> _buildMemoryToolDefinitions() {
    return [
      {
        'type': 'function',
        'function': {
          'name': 'create_memory',
          'description': 'create a memory record',
          'parameters': {
            'type': 'object',
            'properties': {
              'content': {
                'type': 'string',
                'description': 'The content of the memory record',
              },
            },
            'required': ['content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'edit_memory',
          'description': 'update a memory record',
          'parameters': {
            'type': 'object',
            'properties': {
              'id': {
                'type': 'integer',
                'description': 'The id of the memory record',
              },
              'content': {
                'type': 'string',
                'description': 'The content of the memory record',
              },
            },
            'required': ['id', 'content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'delete_memory',
          'description': 'delete a memory record',
          'parameters': {
            'type': 'object',
            'properties': {
              'id': {
                'type': 'integer',
                'description': 'The id of the memory record',
              },
            },
            'required': ['id'],
          },
        },
      },
    ];
  }

  /// Build MCP tool definitions from connected servers.
  List<Map<String, dynamic>> _buildMcpToolDefinitions({
    required SettingsProvider settings,
    required Assistant? assistant,
    required String providerKey,
    required bool supportsTools,
  }) {
    if (!supportsTools) return [];

    final mcp = contextProvider.read<McpProvider>();
    final toolSvc = contextProvider.read<McpToolService>();
    final tools = toolSvc.listAvailableToolsForAssistant(
      mcp,
      contextProvider.read<AssistantProvider>(),
      assistant?.id,
    );

    if (tools.isEmpty) return [];

    final providerCfg = settings.getProviderConfig(providerKey);
    final providerKind = ProviderConfig.classify(
      providerCfg.id,
      explicitType: providerCfg.providerType,
    );

    return tools.map((t) {
      Map<String, dynamic> baseSchema;
      if (t.schema != null && t.schema!.isNotEmpty) {
        baseSchema = Map<String, dynamic>.from(t.schema!);
      } else {
        final props = <String, dynamic>{
          for (final p in t.params) p.name: {'type': (p.type ?? 'string')},
        };
        final required = [
          for (final p in t.params.where((e) => e.required)) p.name,
        ];
        baseSchema = {
          'type': 'object',
          'properties': props,
          if (required.isNotEmpty) 'required': required,
        };
      }
      final sanitized = sanitizeToolParametersForProvider(
        baseSchema,
        providerKind,
      );
      return {
        'type': 'function',
        'function': {
          'name': t.name,
          if ((t.description ?? '').isNotEmpty) 'description': t.description,
          'parameters': sanitized,
        },
      };
    }).toList();
  }

  // ============================================================================
  // Tool Call Handler
  // ============================================================================

  /// Build tool call handler function.
  ///
  /// Returns a function that handles tool calls by name and arguments.
  /// Supports:
  /// - Search tool calls
  /// - Memory tool calls (create/edit/delete)
  /// - MCP tool calls
  ToolCallHandler? buildToolCallHandler(
    SettingsProvider settings,
    Assistant? assistant, {
    ToolApprovalService? approvalService,
    AskUserInteractionService? askUserService,
  }) {
    final mcp = contextProvider.read<McpProvider>();
    final toolSvc = contextProvider.read<McpToolService>();
    // Capture AssistantProvider reference before async gap to avoid
    // use_build_context_synchronously warning
    final assistantProvider = contextProvider.read<AssistantProvider>();

    return (name, args, {toolCallId}) async {
      try {
        // Search tool
        if (name == SearchToolService.toolName &&
            assistant?.searchEnabled == true) {
          final q = (args['query'] ?? '').toString();
          return await SearchToolService.executeSearch(q, settings);
        }

        // Memory tools
        final memoryResult = await _handleMemoryToolCall(name, args, assistant);
        if (memoryResult != null) {
          return memoryResult;
        }

        // Local tools
        final localResult = await LocalToolsService.tryHandleToolCall(
          name,
          args,
          assistant,
          onSpeakText: (text) async {
            final tts = contextProvider.read<TtsProvider>();
            if (!tts.isAvailable) {
              throw StateError('Text-to-speech is unavailable.');
            }
            unawaited(
              tts.speak(text).catchError((Object error, StackTrace stack) {
                FlutterError.reportError(
                  FlutterErrorDetails(
                    exception: error,
                    stack: stack,
                    library: 'Kelivo local tools',
                    context: ErrorDescription('while playing text-to-speech'),
                  ),
                );
              }),
            );
          },
        );
        if (localResult != null) {
          return localResult;
        }

        // OpenViking tools (must be before DeviceTools to prevent MethodChannel fallthrough)
        try {
          final ovResult = await _handleOvToolCall(name, args);
          if (ovResult != null) return ovResult;
        } catch (_) {}

        // Device tools (GPS, sensor, shell, SSH, etc.)
        try {
          final deviceResult = await DeviceToolsService.execute(name, args);
          if (deviceResult.isNotEmpty) {
            return deviceResult;
          }
        } catch (_) {}

        if (name == LocalToolNames.askUser &&
            assistant != null &&
            assistant.localToolIds.contains(LocalToolNames.askUser)) {
          if (askUserService == null) {
            return _toolError(
              error: 'ask_user_unavailable',
              message: 'Ask user interaction service is unavailable.',
              tool: name,
            );
          }
          try {
            final result = await askUserService.requestAnswer(
              toolCallId: (toolCallId?.trim().isNotEmpty == true)
                  ? toolCallId!.trim()
                  : '${name}_${DateTime.now().microsecondsSinceEpoch}',
              arguments: args,
            );
            return result.toJsonString();
          } on AskUserInvalidRequestException catch (e) {
            return _toolError(
              error: 'invalid_ask_user_request',
              message: e.message,
              tool: name,
            );
          }
        }

        // Approval gate for MCP tools
        if (approvalService != null && mcp.toolNeedsApproval(name)) {
          // Generate a unique id for this tool call approval request
          final toolCallId = '${name}_${DateTime.now().microsecondsSinceEpoch}';
          final result = await approvalService.requestApproval(
            toolCallId: toolCallId,
            toolName: name,
            arguments: args,
          );
          if (!result.approved) {
            return _toolError(
              error: 'approval_denied',
              message: result.denyReason ?? 'User denied the tool call',
              tool: name,
            );
          }
        }

        // MCP tools
        final text = await toolSvc.callToolTextForAssistant(
          mcp,
          assistantProvider,
          assistantId: assistant?.id,
          toolName: name,
          arguments: args,
        );
        return text;
      } catch (e) {
        // Catch unexpected exceptions and return error JSON to LLM
        // This prevents tool failures from terminating the chat flow
        return _toolError(
          error: 'execution_error',
          message: e.toString(),
          tool: name,
          instruction:
              'The tool execution failed unexpectedly. You may try again with different parameters or inform the user about the issue.',
        );
      }
    };
  }

  /// Handle memory tool calls (create/edit/delete).
  ///
  /// Returns null if the tool is not a memory tool or memory is not enabled.
  Future<String?> _handleMemoryToolCall(
    String name,
    Map<String, dynamic> args,
    Assistant? assistant,
  ) async {
    if (assistant?.enableMemory != true) return null;
    if (name != 'create_memory' &&
        name != 'edit_memory' &&
        name != 'delete_memory') {
      return null;
    }

    try {
      final mp = contextProvider.read<MemoryProvider>();

      if (name == 'create_memory') {
        final content = (args['content'] ?? '').toString();
        if (content.isEmpty) {
          return _toolError(
            error: 'invalid_memory_content',
            message: 'Memory content must not be empty.',
            tool: name,
          );
        }
        final m = await mp.add(assistantId: assistant!.id, content: content);
        return m.content;
      } else if (name == 'edit_memory') {
        final id = (args['id'] as num?)?.toInt() ?? -1;
        final content = (args['content'] ?? '').toString();
        if (id <= 0) {
          return _toolError(
            error: 'invalid_memory_id',
            message: 'Memory id must be a positive integer.',
            tool: name,
          );
        }
        if (content.isEmpty) {
          return _toolError(
            error: 'invalid_memory_content',
            message: 'Memory content must not be empty.',
            tool: name,
          );
        }
        final m = await mp.update(id: id, content: content);
        if (m == null) {
          return _toolError(
            error: 'memory_not_found',
            message: 'No memory record was found for id $id.',
            tool: name,
            instruction:
                'Use the available memory records shown in context, or create a new memory instead of editing a missing one.',
          );
        }
        return m.content;
      } else if (name == 'delete_memory') {
        final id = (args['id'] as num?)?.toInt() ?? -1;
        if (id <= 0) {
          return _toolError(
            error: 'invalid_memory_id',
            message: 'Memory id must be a positive integer.',
            tool: name,
          );
        }
        final ok = await mp.delete(id: id);
        if (!ok) {
          return _toolError(
            error: 'memory_not_found',
            message: 'No memory record was found for id $id.',
            tool: name,
            instruction:
                'Use the available memory records shown in context, or skip deleting a missing memory.',
          );
        }
        return 'deleted';
      }
    } catch (e) {
      return _toolError(
        error: 'memory_execution_error',
        message: e.toString(),
        tool: name,
        instruction:
            'The memory tool failed. Retry only after correcting the parameters, or inform the user about the issue.',
      );
    }

    return null;
  }

  /// Clamp an LLM-provided score threshold to [0,1], falling back to [fallback].
  static double _clampThreshold(Object? v, double fallback) {
    if (v is num) return v.toDouble().clamp(0.0, 1.0).toDouble();
    return fallback;
  }

  /// Clamp an LLM-provided result limit to [0,20], falling back to [fallback].
  static int _clampLimit(Object? v, int fallback) {
    if (v is num) return v.toInt().clamp(0, 20).toInt();
    return fallback;
  }

  /// Build OpenViking tool definitions. (Aligned with Android-agent reference)
  static List<Map<String, dynamic>> _buildOvToolDefinitions() {
    return [
      {
        'type': 'function',
        'function': {
          'name': 'openviking_search',
          'description': '在 OpenViking 外置记忆中语义搜索，查找之前保存的知识、偏好、项目信息等',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {'type': 'string', 'description': '搜索关键词，描述要查找什么内容'},
              'score_threshold': {
                'type': 'number',
                'description': '可选。相似度阈值 [0-1]，越高越严格，不传用设置页默认值(0.35)',
              },
              'limit': {
                'type': 'integer',
                'description': '可选。返回条数上限 [0-20]，不传用设置页默认值(3)',
              },
            },
            'required': ['query'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'openviking_find',
          'description':
              '在 OpenViking 外置记忆中做纯向量语义搜索（低延迟、可限定范围），查找之前保存的知识、偏好、项目信息等',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {'type': 'string', 'description': '搜索关键词，描述要查找什么内容'},
              'target_uri': {
                'type': 'string',
                'description':
                    '可选。限定检索范围，如 viking://user/{user}/memories/ 或 viking://resources/{project}/',
              },
              'score_threshold': {
                'type': 'number',
                'description': '可选。相似度阈值 [0-1]，越高越严格，不传用设置页默认值(0.4)',
              },
              'limit': {
                'type': 'integer',
                'description': '可选。返回条数上限 [0-20]，不传用设置页默认值(3)',
              },
            },
            'required': ['query'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'openviking_remember',
          'description':
              '将重要信息保存到 OpenViking 外置记忆中，以便后续对话回忆。适合保存：用户偏好、项目配置、关键决策、有用的操作经验',
          'parameters': {
            'type': 'object',
            'properties': {
              'category': {
                'type': 'string',
                'enum': ['preferences', 'entities', 'events', 'experiences'],
                'description':
                    '记忆分类：preferences=用户偏好, entities=项目/概念/人物, events=决策/里程碑, experiences=操作经验',
              },
              'name': {'type': 'string', 'description': '记忆名称/主题'},
              'content': {
                'type': 'string',
                'description': '要保存的内容（Markdown 格式）',
              },
            },
            'required': ['category', 'name', 'content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'openviking_read',
          'description':
              '通过 URI 读取 OpenViking 记忆中的单个文件内容。URI 格式: viking://user/{user}/...',
          'parameters': {
            'type': 'object',
            'properties': {
              'uri': {'type': 'string', 'description': '文件的完整 URI'},
            },
            'required': ['uri'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'openviking_list_dir',
          'description': '列出 OpenViking 指定目录下的所有文件和子目录，用于探索记忆结构或查找特定文件',
          'parameters': {
            'type': 'object',
            'properties': {
              'uri': {'type': 'string', 'description': '目录 URI'},
              'recursive': {
                'type': 'boolean',
                'description': '是否递归列出子目录（默认 false）',
              },
            },
            'required': ['uri'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'openviking_write_file',
          'description':
              '写入内容到 OpenViking 记忆文件。支持三种模式：create=创建新文件, replace=覆盖已有文件, append=追加内容',
          'parameters': {
            'type': 'object',
            'properties': {
              'uri': {'type': 'string', 'description': '文件 URI'},
              'content': {
                'type': 'string',
                'description': '要写入的内容（Markdown 格式）',
              },
              'mode': {
                'type': 'string',
                'enum': ['create', 'replace', 'append'],
                'description': '写入模式',
              },
            },
            'required': ['uri', 'content', 'mode'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'openviking_delete_file',
          'description': '通过 URI 删除 OpenViking 记忆中的文件。注意：此操作不可撤销！',
          'parameters': {
            'type': 'object',
            'properties': {
              'uri': {'type': 'string', 'description': '要删除的文件 URI'},
            },
            'required': ['uri'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'openviking_create_session',
          'description': '在 OpenViking 中创建一个新的对话 Session，用于保存一段完整的对话历史',
          'parameters': {
            'type': 'object',
            'properties': {
              'session_id': {
                'type': 'string',
                'description': '可选。自定义 session_id (UUID 格式)。不传则自动生成',
              },
            },
            'required': [],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'openviking_add_message',
          'description': '向 OpenViking Session 中添加一条消息（user 或 assistant）',
          'parameters': {
            'type': 'object',
            'properties': {
              'session_id': {'type': 'string', 'description': 'Session ID'},
              'role': {
                'type': 'string',
                'enum': ['user', 'assistant'],
                'description': '消息角色',
              },
              'content': {'type': 'string', 'description': '消息内容'},
            },
            'required': ['session_id', 'role', 'content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'openviking_commit_session',
          'description':
              '提交/归档 OpenViking Session，触发从会话内容中提取结构化长期记忆。commit 之后不要再次 add_message',
          'parameters': {
            'type': 'object',
            'properties': {
              'session_id': {'type': 'string', 'description': 'Session ID'},
              'keep_recent_count': {
                'type': 'integer',
                'description': '保留最近 N 条消息在活跃 session 中。0=归档所有消息（默认）',
              },
            },
            'required': ['session_id'],
          },
        },
      },
    ];
  }

  /// Handle OpenViking tool calls. Returns null if not an OV tool.
  Future<String?> _handleOvToolCall(
    String name,
    Map<String, dynamic> args,
  ) async {
    const ovTools = [
      'openviking_search',
      'openviking_find',
      'openviking_remember',
      'openviking_read',
      'openviking_list_dir',
      'openviking_write_file',
      'openviking_delete_file',
      'openviking_create_session',
      'openviking_add_message',
      'openviking_commit_session',
    ];
    if (!ovTools.contains(name)) return null;

    OpenVikingService? svc;
    try {
      final ovProvider = contextProvider.read<OpenVikingProvider>();
      if (!ovProvider.isConfigured)
        return jsonEncode({'error': 'OpenViking not configured'});
      svc = ovProvider.service;
      if (svc == null)
        return jsonEncode({'error': 'OpenViking service not available'});
    } catch (e) {
      return jsonEncode({'error': 'Failed to read OpenViking config: $e'});
    }

    final base = svc.baseUrl.replaceAll(RegExp(r'/\$'), '');
    final user = svc.user;
    final headers = {
      'Authorization': 'Bearer ${svc.apiKey}',
      'Content-Type': 'application/json',
      'X-OpenViking-Account': 'default',
      'X-OpenViking-Peer': 'default',
    };

    try {
      if (name == 'openviking_search') {
        final query = (args['query'] ?? '').toString().trim();
        if (query.isEmpty) return jsonEncode({'error': 'query is required'});
        final ovProvider = contextProvider.read<OpenVikingProvider>();
        final scoreThreshold =
            _clampThreshold(args['score_threshold'], ovProvider.threshold);
        final limit = _clampLimit(args['limit'], ovProvider.displayCount);
        final resp = await http
            .post(
              Uri.parse('$base/api/v1/search/search'),
              headers: headers,
              body: jsonEncode({
                'query': query,
                'score_threshold': scoreThreshold,
                'limit': limit,
              }),
            )
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode != 200)
          return jsonEncode({'error': 'HTTP ${resp.statusCode}'});
        final body = jsonDecode(resp.body);
        final result = body['result'] as Map? ?? {};
        final mems = result['memories'] as List? ?? [];
        if (mems.isEmpty)
          return jsonEncode({
            'success': true,
            'results': [],
            'message': 'No results',
          });
        final hits = mems.take(limit).map((m) {
          final obj = m as Map;
          return {
            'uri': obj['uri'] ?? '',
            'score': (obj['score'] as num?)?.toDouble() ?? 0.0,
            'snippet': (obj['abstract'] as String? ?? '').toString(),
            'category': obj['category'] ?? '',
          };
        }).toList();
        return jsonEncode({'success': true, 'results': hits});
      }

      if (name == 'openviking_find') {
        final query = (args['query'] ?? '').toString().trim();
        if (query.isEmpty) return jsonEncode({'error': 'query is required'});
        final targetUri = (args['target_uri'] ?? '').toString().trim();
        final ovProvider = contextProvider.read<OpenVikingProvider>();
        final scoreThreshold = _clampThreshold(
          args['score_threshold'],
          ovProvider.findThreshold,
        );
        final limit = _clampLimit(args['limit'], ovProvider.findLimit);
        final buildPayload = (double t) => <String, dynamic>{
          'query': query,
          'score_threshold': t,
          'limit': limit,
          if (targetUri.isNotEmpty) 'target_uri': targetUri,
        };
        final parseHits = (Map body) {
          final result = body['result'] as Map? ?? {};
          final seen = <String>{};
          final hits =
              [result['memories'], result['resources'], result['skills']]
                  .whereType<List>()
                  .expand((list) => list)
                  .map((m) {
                    final obj = m as Map;
                    final uri = (obj['uri'] ?? '').toString();
                    if (uri.isNotEmpty && !seen.add(uri)) return null;
                    return {
                      'uri': uri,
                      'score': (obj['score'] as num?)?.toDouble() ?? 0.0,
                      'snippet': (obj['abstract'] as String? ?? '').toString(),
                      'category': obj['category'] ?? '',
                    };
                  })
                  .whereType<Map<dynamic, dynamic>>()
                  .toList();
          return hits;
        };
        Future<List<Map<dynamic, dynamic>>> postFind(double t) async {
          final resp = await http
              .post(
                Uri.parse('$base/api/v1/search/find'),
                headers: headers,
                body: jsonEncode(buildPayload(t)),
              )
              .timeout(const Duration(seconds: 15));
          if (resp.statusCode != 200) return const [];
          final body = jsonDecode(resp.body);
          return parseHits(body as Map);
        }

        final hits = await postFind(scoreThreshold);
        if (hits.isEmpty)
          return jsonEncode({
            'success': true,
            'results': [],
            'message': 'No results',
          });
        return jsonEncode({
          'success': true,
          'results': hits.take(limit).toList(),
        });
      }

      if (name == 'openviking_remember') {
        final category = (args['category'] ?? 'entities').toString().trim();
        final name = (args['name'] ?? 'untitled').toString().trim();
        final content = (args['content'] ?? '').toString().trim();
        if (content.isEmpty)
          return jsonEncode({'error': 'content is required'});
        final uri =
            'viking://user/$user/peers/default/memories/$category/$name.md';

        // Try replace first; if NOT_FOUND/404, retry with create (aligned with Android-agent)
        final resp = await http
            .post(
              Uri.parse('$base/api/v1/content/write'),
              headers: headers,
              body: jsonEncode({
                'uri': uri,
                'content': content,
                'mode': 'replace',
                'wait': true,
              }),
            )
            .timeout(const Duration(seconds: 15));

        if (resp.statusCode == 200) {
          final b = jsonDecode(resp.body);
          final errCode = b['error'] is Map
              ? b['error']['code']?.toString() ?? ''
              : '';
          if (b['status'] == 'ok')
            return jsonEncode({'success': true, 'uri': uri});
          if (errCode.contains('NOT_FOUND')) {
            // File doesn't exist, create it
            final retry = await http
                .post(
                  Uri.parse('$base/api/v1/content/write'),
                  headers: headers,
                  body: jsonEncode({
                    'uri': uri,
                    'content': content,
                    'mode': 'create',
                    'wait': false,
                  }),
                )
                .timeout(const Duration(seconds: 15));
            if (retry.statusCode == 200)
              return jsonEncode({'success': true, 'uri': uri});
            return jsonEncode({
              'error': 'Create failed: HTTP ${retry.statusCode}',
            });
          }
          return jsonEncode({'error': '$errCode'});
        }
        // 404 fallback (file doesn't exist)
        if (resp.statusCode == 404) {
          final retry = await http
              .post(
                Uri.parse('$base/api/v1/content/write'),
                headers: headers,
                body: jsonEncode({
                  'uri': uri,
                  'content': content,
                  'mode': 'create',
                  'wait': false,
                }),
              )
              .timeout(const Duration(seconds: 15));
          if (retry.statusCode == 200)
            return jsonEncode({'success': true, 'uri': uri});
          return jsonEncode({
            'error': 'Create failed: HTTP ${retry.statusCode}',
          });
        }
        return jsonEncode({'error': 'HTTP ${resp.statusCode}'});
      }

      if (name == 'openviking_read') {
        final uri = (args['uri'] ?? '').toString().trim();
        if (uri.isEmpty) return jsonEncode({'error': 'uri is required'});
        final resp = await http
            .get(
              Uri.parse(
                '$base/api/v1/content/read?uri=${Uri.encodeComponent(uri)}',
              ),
              headers: headers,
            )
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode != 200)
          return jsonEncode({'error': 'HTTP ${resp.statusCode}'});
        final body = jsonDecode(resp.body);
        final content = body['content'] ?? resp.body;
        return jsonEncode({'success': true, 'uri': uri, 'content': content});
      }

      if (name == 'openviking_list_dir') {
        final uri = (args['uri'] ?? '').toString().trim();
        if (uri.isEmpty) return jsonEncode({'error': 'uri is required'});
        final recursive = args['recursive'] == true;
        final resp = await http
            .get(
              Uri.parse(
                '$base/api/v1/fs/tree?uri=${Uri.encodeComponent(uri)}${recursive ? '&recursive=true' : ''}',
              ),
              headers: headers,
            )
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode != 200)
          return jsonEncode({'error': 'HTTP ${resp.statusCode}'});
        return jsonEncode({'success': true, 'tree': jsonDecode(resp.body)});
      }

      if (name == 'openviking_write_file') {
        final uri = (args['uri'] ?? '').toString().trim();
        final content = (args['content'] ?? '').toString().trim();
        final mode = (args['mode'] ?? 'replace').toString().trim();
        if (uri.isEmpty) return jsonEncode({'error': 'uri is required'});
        if (content.isEmpty)
          return jsonEncode({'error': 'content is required'});
        final resp = await http
            .post(
              Uri.parse('$base/api/v1/content/write'),
              headers: headers,
              body: jsonEncode({
                'uri': uri,
                'content': content,
                'mode': mode,
                'wait': mode != 'create',
              }),
            )
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200)
          return jsonEncode({'success': true, 'uri': uri, 'mode': mode});
        return jsonEncode({'error': 'HTTP ${resp.statusCode}'});
      }

      if (name == 'openviking_delete_file') {
        final uri = (args['uri'] ?? '').toString().trim();
        if (uri.isEmpty) return jsonEncode({'error': 'uri is required'});
        final resp = await http
            .delete(
              Uri.parse('$base/api/v1/fs?uri=${Uri.encodeComponent(uri)}'),
              headers: headers,
            )
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200)
          return jsonEncode({'success': true, 'uri': uri});
        return jsonEncode({'error': 'HTTP ${resp.statusCode}'});
      }

      if (name == 'openviking_create_session') {
        final sessionId = (args['session_id'] ?? '').toString().trim();
        final payload = sessionId.isNotEmpty ? {'session_id': sessionId} : {};
        final resp = await http
            .post(
              Uri.parse('$base/api/v1/sessions'),
              headers: headers,
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200) {
          final body = jsonDecode(resp.body);
          return jsonEncode({
            'success': true,
            'result': body['result'] ?? body,
          });
        }
        return jsonEncode({'error': 'HTTP ${resp.statusCode}'});
      }

      if (name == 'openviking_add_message') {
        final sessionId = (args['session_id'] ?? '').toString().trim();
        final role = (args['role'] ?? '').toString().trim();
        final content = (args['content'] ?? '').toString().trim();
        if (sessionId.isEmpty)
          return jsonEncode({'error': 'session_id is required'});
        if (role.isEmpty) return jsonEncode({'error': 'role is required'});
        final resp = await http
            .post(
              Uri.parse('$base/api/v1/sessions/$sessionId/messages'),
              headers: headers,
              body: jsonEncode({'role': role, 'content': content}),
            )
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200) {
          final body = jsonDecode(resp.body);
          return jsonEncode({
            'success': true,
            'result': body['result'] ?? body,
          });
        }
        return jsonEncode({'error': 'HTTP ${resp.statusCode}'});
      }

      if (name == 'openviking_commit_session') {
        final sessionId = (args['session_id'] ?? '').toString().trim();
        final keepRecent = (args['keep_recent_count'] as num?)?.toInt() ?? 0;
        if (sessionId.isEmpty)
          return jsonEncode({'error': 'session_id is required'});
        final resp = await http
            .post(
              Uri.parse('$base/api/v1/sessions/$sessionId/commit'),
              headers: headers,
              body: jsonEncode({'keep_recent_count': keepRecent}),
            )
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200) {
          final body = jsonDecode(resp.body);
          return jsonEncode({
            'success': true,
            'result': body['result'] ?? body,
          });
        }
        return jsonEncode({'error': 'HTTP ${resp.statusCode}'});
      }
    } catch (e) {
      return jsonEncode({'error': 'OpenViking call failed: $e'});
    }

    return jsonEncode({
      'error': 'OpenViking tool internal error: unexpected flow',
    });
  }
}
