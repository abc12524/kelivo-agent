import 'dart:async';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/model_override_payload_parser.dart';
import '../../../core/utils/multimodal_input_utils.dart';
import '../../../core/utils/openai_model_compat.dart';
import '../../../utils/assistant_regex.dart';
import '../../../core/models/assistant_regex.dart';
import '../controllers/stream_controller.dart' as stream_ctrl;
import '../controllers/generation_controller.dart';
import 'ask_user_interaction_service.dart';
import 'message_builder_service.dart';
import 'tool_approval_service.dart';
import '../../../core/providers/openviking_provider.dart';
import '../../../core/services/openviking/recall.dart';
import '../../../core/services/openviking/recall_engine.dart';
import '../../../core/services/tools/skill_tool.dart';

/// Callback types for UI updates from MessageGenerationService
typedef OnMessagesChanged = void Function();
typedef OnConversationLoadingChanged =
    void Function(String conversationId, bool loading);
typedef OnScrollToBottom = void Function();
typedef OnShowError = void Function(String message);
typedef OnShowWarning = void Function(String message);
typedef OnHapticFeedback = void Function();

const String conversationIdHeaderName = 'X-Conversation-Id';
const String _conversationIdHeaderNameLower = 'x-conversation-id';

Map<String, String>? buildConversationRequestHeaders({
  required String conversationId,
  Map<String, String>? customHeaders,
}) {
  final headers = <String, String>{
    if (customHeaders != null)
      for (final entry in customHeaders.entries)
        if (entry.key.toLowerCase() != _conversationIdHeaderNameLower)
          entry.key: entry.value,
  };
  final normalizedConversationId = conversationId.trim();
  if (normalizedConversationId.isNotEmpty) {
    headers[conversationIdHeaderName] = normalizedConversationId;
  }
  return headers.isEmpty ? null : headers;
}

/// Result of preparing a message generation
class PreparedGeneration {
  final List<Map<String, dynamic>> apiMessages;
  final List<Map<String, dynamic>> toolDefs;
  final ToolCallHandler? onToolCall;
  final bool hasBuiltInSearch;
  final List<String> lastUserImagePaths;

  PreparedGeneration({
    required this.apiMessages,
    required this.toolDefs,
    this.onToolCall,
    required this.hasBuiltInSearch,
    required this.lastUserImagePaths,
  });
}

/// Service for handling message generation orchestration.
///
/// This service coordinates:
/// - Message creation (user + assistant placeholder)
/// - API message preparation with all injections
/// - Stream execution and management
/// - Reasoning state initialization
///
/// UI updates are communicated through callbacks to maintain separation.
class MessageGenerationService {
  MessageGenerationService({
    required this.chatService,
    required this.messageBuilderService,
    required this.generationController,
    required this.streamController,
    required this.contextProvider,
  });

  final ChatService chatService;
  final MessageBuilderService messageBuilderService;
  final GenerationController generationController;
  final stream_ctrl.StreamController streamController;
  final BuildContext contextProvider;

  // Callbacks for UI updates (set by home_page)
  OnMessagesChanged? onMessagesChanged;
  OnConversationLoadingChanged? onConversationLoadingChanged;
  OnScrollToBottom? onScrollToBottom;
  OnShowError? onShowError;
  OnShowWarning? onShowWarning;
  OnHapticFeedback? onHapticFeedback;

  /// Called when file processing starts.
  VoidCallback? onFileProcessingStarted;

  /// Called when file processing finishes.
  VoidCallback? onFileProcessingFinished;

  /// 会话 → 召回引擎（同一会话内强制去重；换会话由 seed 重建）。
  final Map<String, RecallEngine> _recallEngines = <String, RecallEngine>{};

  /// Check if reasoning is enabled for given budget
  bool isReasoningEnabled(int? budget) {
    if (budget == null) return true;
    if (budget == -1) return true;
    return budget >= 1024;
  }

  /// Prepare API messages with all injections applied.
  Future<PreparedGeneration> prepareApiMessagesWithInjections({
    required List<ChatMessage> messages,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    required SettingsProvider settings,
    required Assistant? assistant,
    required String? assistantId,
    required String providerKey,
    required String modelId,
    ToolApprovalService? approvalService,
    AskUserInteractionService? askUserService,
  }) async {
    final cfg = settings.getProviderConfig(providerKey);
    final kind = ProviderConfig.classify(
      providerKey,
      explicitType: cfg.providerType,
    );
    final includeToolMessages = switch (kind) {
      ProviderKind.openai || ProviderKind.claude || ProviderKind.google => true,
    };

    onFileProcessingStarted?.call();

    // Build API messages
    final apiMessages = messageBuilderService.buildApiMessages(
      messages: messages,
      versionSelections: versionSelections,
      currentConversation: currentConversation,
      includeToolMessages: includeToolMessages,
    );

    // Apply assistant replace-only regexes at send-time (visual stays unchanged).
    if (assistant != null && assistant.regexRules.isNotEmpty) {
      for (int i = 0; i < apiMessages.length; i++) {
        final role = (apiMessages[i]['role'] ?? '').toString();
        if (role != 'assistant') continue;
        final raw = (apiMessages[i]['content'] ?? '').toString();
        if (raw.isEmpty) continue;
        apiMessages[i]['content'] = applyAssistantRegexes(
          raw,
          assistant: assistant,
          scope: AssistantRegexScope.assistant,
          target: AssistantRegexTransformTarget.send,
        );
      }
    }

    // Process user messages (documents, OCR, templates)
    final lastUserImagePaths = await messageBuilderService
        .processUserMessagesForApi(apiMessages, settings, assistant);

    // Signal processing finished
    onFileProcessingFinished?.call();

    // 刷新已注册 skill 缓存（Android）：供动态注入系统提示与工具描述使用。
    await SkillTool.instance.ensureScanned();

    // Inject prompts
    messageBuilderService.injectSystemPrompt(apiMessages, assistant, modelId);
    await messageBuilderService.injectMemoryAndRecentChats(
      apiMessages,
      assistant,
      currentConversationId: currentConversation?.id,
    );

    final hasBuiltInSearch = messageBuilderService.hasBuiltInSearch(
      settings,
      providerKey,
      modelId,
    );

    messageBuilderService.injectSearchPrompt(
      apiMessages,
      settings,
      assistant,
      hasBuiltInSearch,
    );
    await messageBuilderService.injectInstructionPrompts(
      apiMessages,
      assistantId,
    );
    await messageBuilderService.injectWorldBookPrompts(
      apiMessages,
      assistantId,
    );

    // Apply context limit and inline images
    messageBuilderService.applyContextLimit(apiMessages, assistant);
    await messageBuilderService.inlineLocalImages(apiMessages);

    // Prepare tools
    final toolDefs = generationController.buildToolDefinitions(
      settings,
      assistant,
      providerKey,
      modelId,
      hasBuiltInSearch,
    );
    final onToolCall = toolDefs.isNotEmpty
        ? generationController.buildToolCallHandler(
            settings,
            assistant,
            approvalService: approvalService,
            askUserService: askUserService,
          )
        : null;

    return PreparedGeneration(
      apiMessages: apiMessages,
      toolDefs: toolDefs,
      onToolCall: onToolCall,
      hasBuiltInSearch: hasBuiltInSearch,
      lastUserImagePaths: lastUserImagePaths,
    );
  }

  /// Create user message from input data.
  Future<ChatMessage> createUserMessage({
    required String conversationId,
    required ChatInputData input,
    required Assistant? assistant,
  }) async {
    return chatService.addMessage(
      conversationId: conversationId,
      role: 'user',
      content: MessageGenerationService.buildPersistedUserMessageContent(
        input,
        assistant: assistant,
      ),
    );
  }

  /// 本轮开始：ovCommit 开启时建立 OV session 并抓取用户问题。
  Future<void> captureUserTurn({
    required String conversationId,
    required ChatMessage userMessage,
    required bool enabled,
  }) async {
    if (!enabled) return;
    try {
      final ov = contextProvider.read<OpenVikingProvider>();
      if (!ov.isConfigured || !ov.commit) return;
      final service = ov.service;
      if (service == null) return;
      await service.captureMessages(conversationId, [userMessage]);
    } catch (_) {}
  }

  /// 每轮开始：从当前会话历史重建会话内去重记录（回滚后不沿用旧记忆）。
  void prepareRecallTurn(String conversationId) {
    try {
      final ov = contextProvider.read<OpenVikingProvider>();
      final engine = _engineFor(conversationId, ov);
      engine?.seed(chatService.getMessages(conversationId));
    } catch (_) {}
  }

  /// 每轮注入：skill 名单 + 问题召回 + user_tips 合并为一条 inject_user 消息。
  /// 没有工具轮数限制，因此不注入轮次与耗尽警告。
  Future<ChatMessage?> prepareTurnInjection({
    required String conversationId,
    required String query,
    required bool recallEnabled,
  }) async {
    try {
      final ov = contextProvider.read<OpenVikingProvider>();
      final injected = chatService
          .getMessages(conversationId)
          .where((m) => m.role == ChatMessage.roleInjectUser)
          .map((m) => m.content)
          .toList(growable: false);

      final blocks = <String>[];
      final skillBlock = await _takeSkillBlock(injected);
      if (skillBlock != null) blocks.add(skillBlock);

      if (recallEnabled && ov.isConfigured && ov.recallQuestion) {
        final engine = _engineFor(conversationId, ov);
        final block = engine == null ? null : await engine.recall(query);
        if (block != null) blocks.add(Recall.openvikingBlock(block));
      }

      final tipsBlock = _takeUserTipsBlock(injected, ov);
      if (tipsBlock != null) blocks.add(tipsBlock);

      if (blocks.isEmpty) return null;
      return _persistInject(
        conversationId,
        Recall.buildTurnContext(blocks),
      );
    } catch (_) {
      return null;
    }
  }

  /// skill 名单块：首轮全量，之后只补新增项。
  Future<String?> _takeSkillBlock(List<String> injected) async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.windows &&
        defaultTargetPlatform != TargetPlatform.linux) {
      return null;
    }
    await SkillTool.instance.ensureScanned();
    final enabled = SkillTool.instance.skills
        .where((s) => s.enabled)
        .toList(growable: false);
    if (enabled.isEmpty) return null;

    final known = <String>{};
    for (final content in injected) {
      if (!content.contains(Recall.skillMark)) continue;
      known.addAll(Recall.parseSkillNames(content));
    }
    final fresh = enabled
        .where((s) => !known.contains(s.name))
        .map((s) => (s.name, s.description))
        .toList(growable: false);
    if (fresh.isEmpty) return null;
    return Recall.buildSkillBlock(fresh, delta: known.isNotEmpty);
  }

  /// user_tips 每会话只注入一次。
  String? _takeUserTipsBlock(
    List<String> injected,
    OpenVikingProvider ov,
  ) {
    final tips = ov.userTips.trim();
    if (tips.isEmpty) return null;
    if (injected.any((c) => c.contains(Recall.userTipsOpen))) return null;
    return Recall.buildUserTipsBlock(tips);
  }

  /// 每步召回：只以 LLM 的 reasoning / content 为 query。
  /// 命中后落库并返回包裹好的注入文本，供 provider 追加到下一轮请求。
  Future<String?> stepRecallInjection({
    required String conversationId,
    required String reasoning,
    required String content,
    required bool enabled,
  }) async {
    if (!enabled) return null;
    try {
      final ov = contextProvider.read<OpenVikingProvider>();
      if (!ov.isConfigured || !ov.recallStep) return null;
      final engine = _engineFor(conversationId, ov);
      if (engine == null) return null;
      final query = Recall.buildStepQuery(
        reasoning: reasoning,
        content: content,
      );
      final block = await engine.recall(query);
      if (block == null) return null;
      final wrapped = Recall.wrapRecallBlock(block);
      await _persistInject(conversationId, wrapped);
      return wrapped;
    } catch (_) {
      return null;
    }
  }

  RecallEngine? _engineFor(String conversationId, OpenVikingProvider ov) {
    final service = ov.service;
    if (service == null) return null;
    final existing = _recallEngines[conversationId];
    if (existing != null &&
        identical(existing.service, service) &&
        existing.findThreshold == ov.findThreshold &&
        existing.findLimit == ov.findLimit) {
      return existing;
    }
    final engine = RecallEngine(
      service: service,
      findThreshold: ov.findThreshold,
      findLimit: ov.findLimit,
    );
    _recallEngines[conversationId] = engine;
    return engine;
  }

  Future<ChatMessage> _persistInject(
    String conversationId,
    String content,
  ) {
    return chatService.addMessage(
      conversationId: conversationId,
      role: ChatMessage.roleInjectUser,
      content: content,
    );
  }

  /// Build the persisted content string for a user message.
  static String buildPersistedUserMessageContent(
    ChatInputData input, {
    required Assistant? assistant,
  }) {
    final content = input.text.trim();
    final imageMarkers = input.imagePaths.map((p) => '\n[image:$p]').join();
    final docMarkers = input.documents
        .map((d) => '\n[file:${d.path}|${d.fileName}|${d.mime}]')
        .join();

    final processedUserText = applyAssistantRegexes(
      content,
      assistant: assistant,
      scope: AssistantRegexScope.user,
      target: AssistantRegexTransformTarget.persist,
    );

    return processedUserText + imageMarkers + docMarkers;
  }

  /// Create assistant message placeholder.
  Future<ChatMessage> createAssistantPlaceholder({
    required String conversationId,
    required String modelId,
    required String providerKey,
    String? groupId,
    int version = 0,
  }) async {
    return chatService.addMessage(
      conversationId: conversationId,
      role: 'assistant',
      content: '',
      modelId: modelId,
      providerId: providerKey,
      isStreaming: true,
      groupId: groupId,
      version: version,
    );
  }

  /// Initialize reasoning state for a message if reasoning is enabled.
  Future<void> initializeReasoningState({
    required String messageId,
    required bool enableReasoning,
  }) async {
    if (enableReasoning) {
      final rd = stream_ctrl.ReasoningData();
      streamController.reasoning[messageId] = rd;
      await chatService.updateMessage(
        messageId,
        reasoningStartAt: DateTime.now(),
      );
    }
  }

  /// Build GenerationContext for streaming.
  stream_ctrl.GenerationContext buildGenerationContext({
    required ChatMessage assistantMessage,
    required PreparedGeneration prepared,
    required List<String> userImagePaths,
    required bool allowImagesApiRouting,
    required String providerKey,
    required String modelId,
    required Assistant? assistant,
    required SettingsProvider settings,
    required bool supportsReasoning,
    required bool enableReasoning,
    required bool generateTitleOnFinish,
    StepRecallCallback? onStepRecall,
  }) {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    return stream_ctrl.GenerationContext(
      assistantMessage: assistantMessage,
      apiMessages: prepared.apiMessages,
      userImagePaths: userImagePaths,
      allowImagesApiRouting: allowImagesApiRouting,
      providerKey: providerKey,
      modelId: modelId,
      assistant: assistant,
      settings: settings,
      config: settings.getProviderConfig(providerKey),
      toolDefs: prepared.toolDefs,
      onToolCall: prepared.onToolCall,
      onStepRecall: onStepRecall,
      extraHeaders: buildConversationRequestHeaders(
        conversationId: assistantMessage.conversationId,
        customHeaders: generationController.buildCustomHeaders(assistant),
      ),
      extraBody: generationController.buildCustomBody(assistant),
      supportsReasoning: supportsReasoning,
      enableReasoning: enableReasoning,
      streamOutput: assistant?.streamOutput ?? true,
      ocrActive: ocrActive,
      generateTitleOnFinish: generateTitleOnFinish,
    );
  }

  /// Get current model and provider from assistant or global settings.
  ({String? providerKey, String? modelId}) getModelConfig(
    SettingsProvider settings,
    Assistant? assistant,
  ) {
    return (
      providerKey:
          assistant?.chatModelProvider ?? settings.currentModelProvider,
      modelId: assistant?.chatModelId ?? settings.currentModelId,
    );
  }

  /// Calculate version info for regeneration.
  ({String? targetGroupId, int nextVersion, int lastKeep})
  calculateRegenerationVersioning({
    required ChatMessage message,
    required List<ChatMessage> messages,
    required bool assistantAsNewReply,
  }) {
    final idx = messages.indexWhere((m) => m.id == message.id);
    if (idx < 0) {
      return (targetGroupId: null, nextVersion: 0, lastKeep: -1);
    }

    String? targetGroupId;
    int nextVersion = 0;
    int lastKeep;

    if (message.role == 'assistant') {
      lastKeep = idx;
      if (assistantAsNewReply) {
        targetGroupId = null;
        nextVersion = 0;
      } else {
        targetGroupId = message.groupId ?? message.id;
        int maxVer = -1;
        for (final m in messages) {
          final gid = (m.groupId ?? m.id);
          if (gid == targetGroupId) {
            if (m.version > maxVer) maxVer = m.version;
          }
        }
        nextVersion = maxVer + 1;
      }
    } else {
      // User message
      final userGroupId = message.groupId ?? message.id;
      int userFirst = -1;
      for (int i = 0; i < messages.length; i++) {
        final gid0 = (messages[i].groupId ?? messages[i].id);
        if (gid0 == userGroupId) {
          userFirst = i;
          break;
        }
      }
      if (userFirst < 0) userFirst = idx;

      int aid = -1;
      for (int i = userFirst + 1; i < messages.length; i++) {
        if (messages[i].role == 'assistant') {
          aid = i;
          break;
        }
      }

      if (aid >= 0) {
        lastKeep = aid;
        targetGroupId = messages[aid].groupId ?? messages[aid].id;
        int maxVer = -1;
        for (final m in messages) {
          final gid = (m.groupId ?? m.id);
          if (gid == targetGroupId) {
            if (m.version > maxVer) maxVer = m.version;
          }
        }
        nextVersion = maxVer + 1;
      } else {
        lastKeep = userFirst;
        targetGroupId = null;
        nextVersion = 0;
      }
    }

    return (
      targetGroupId: targetGroupId,
      nextVersion: nextVersion,
      lastKeep: lastKeep,
    );
  }

  /// Remove trailing messages after regeneration cut point.
  @visibleForTesting
  static List<String> collectTrailingMessageIdsForRemoval({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
  }) {
    if (lastKeep >= messages.length - 1) {
      return const [];
    }

    final keepGroups = <String>{};
    for (int i = 0; i <= lastKeep && i < messages.length; i++) {
      keepGroups.add(messages[i].groupId ?? messages[i].id);
    }
    if (targetGroupId != null) keepGroups.add(targetGroupId);

    final removeIds = <String>[];
    for (final message in messages.sublist(lastKeep + 1)) {
      final groupId = message.groupId ?? message.id;
      if (!keepGroups.contains(groupId)) {
        removeIds.add(message.id);
      }
    }
    return removeIds;
  }

  /// Remove trailing messages after regeneration cut point.
  Future<List<String>> removeTrailingMessages({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
  }) async {
    final removeIds = collectTrailingMessageIdsForRemoval(
      messages: messages,
      lastKeep: lastKeep,
      targetGroupId: targetGroupId,
    );

    for (final id in removeIds) {
      try {
        await chatService.deleteMessage(id);
      } catch (_) {}
      streamController.reasoning.remove(id);
      streamController.toolParts.remove(id);
      streamController.reasoningSegments.remove(id);
    }

    return removeIds;
  }

  bool _shouldIncludeAudioForProvider(
    SettingsProvider settings, {
    required String providerKey,
    required String modelId,
  }) {
    final cfg = settings.getProviderConfig(providerKey);
    if (ProviderConfig.classify(providerKey, explicitType: cfg.providerType) !=
        ProviderKind.openai) {
      return false;
    }
    final override = ModelOverridePayloadParser.modelOverride(
      cfg.modelOverrides,
      modelId,
    );
    final upstreamModelId = resolveApiModelIdOverride(override, modelId);
    return isLongCatOmniModelId(upstreamModelId);
  }

  bool supportsAudioAttachmentsForProvider(
    SettingsProvider settings, {
    required String providerKey,
    required String modelId,
  }) {
    return _shouldIncludeAudioForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    );
  }

  String _effectiveAttachmentMime(DocumentAttachment attachment) {
    return resolveDocumentAttachmentMime(attachment);
  }

  bool inputContainsAudioAttachments(ChatInputData input) {
    for (final attachment in input.documents) {
      if (isAudioMime(_effectiveAttachmentMime(attachment))) {
        return true;
      }
    }
    return false;
  }

  bool apiMessagesContainAudioAttachments(List<Map<String, dynamic>> messages) {
    for (final message in messages) {
      if ((message['role'] ?? '').toString() != 'user') continue;
      final parsed = messageBuilderService.parseInputFromRaw(
        (message['content'] ?? '').toString(),
      );
      if (parsed.documents.any(
        (attachment) => isAudioMime(_effectiveAttachmentMime(attachment)),
      )) {
        return true;
      }
    }
    return false;
  }

  List<String> _filterMediaPathsForProvider(
    List<String> paths, {
    required bool includeAudio,
  }) {
    return paths
        .where((path) {
          final mime = inferMediaMimeFromSource(
            path,
            fallbackMime: 'image/png',
          );
          if (isAudioMime(mime)) return includeAudio;
          return isImageMime(mime) || isVideoMime(mime);
        })
        .toList(growable: false);
  }

  /// Build user image paths considering OCR mode.
  List<String> buildUserImagePaths({
    required ChatInputData? input,
    required List<String> lastUserImagePaths,
    required SettingsProvider settings,
    required String providerKey,
    required String modelId,
  }) {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    final includeAudio = _shouldIncludeAudioForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    );

    if (input != null) {
      final currentMediaPaths = <String>[];
      for (final d in input.documents) {
        final effectiveMime = _effectiveAttachmentMime(d);
        if (isVideoMime(effectiveMime) ||
            (includeAudio && isAudioMime(effectiveMime))) {
          currentMediaPaths.add(d.path);
        }
      }
      return _filterMediaPathsForProvider(<String>[
        if (!ocrActive) ...input.imagePaths,
        ...currentMediaPaths,
      ], includeAudio: includeAudio);
    }

    return _filterMediaPathsForProvider(
      lastUserImagePaths
          .where((path) {
            if (!ocrActive) return true;
            return !isImageMime(
              inferMediaMimeFromSource(path, fallbackMime: 'image/png'),
            );
          })
          .toList(growable: false),
      includeAudio: includeAudio,
    );
  }
}
