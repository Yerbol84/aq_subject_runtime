// aq_subject_runtime/lib/src/executors/llm_agent_executor.dart

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/subject.dart';
import 'package:aq_schema/sandbox.dart';
import 'package:aq_schema/tools.dart';
import '../constants/llm_agent_keys.dart';

/// Резолвинг base URL провайдера:
///   1. Env переменная {PROVIDER_UPPER}_BASE_URL
///   2. Стандартный URL из LlmAgentKeys.providerBaseUrls
String _resolveBaseUrl(String provider) {
  final envKey  = '${provider.toUpperCase()}${LlmAgentKeys.baseUrlEnvSuffix}';
  final override = Platform.environment[envKey];
  if (override != null) return override;

  final known = LlmAgentKeys.providerBaseUrls[provider];
  if (known != null) return known;

  throw ArgumentError(
    'Unknown provider "$provider". Set $envKey env variable.',
  );
}

class LlmAgentExecutor {
  const LlmAgentExecutor();

  Future<SubjectOutput> execute(
    SubjectDescriptor descriptor,
    SubjectInput input,
    RunContext context,
    IToolExecutor toolExecutor, {
    int round = 0,
    void Function(SubjectSessionEvent)? onEvent,
  }) async {
    if (round >= LlmAgentKeys.maxRounds) {
      return SubjectOutput(
        success: false,
        data: {LlmAgentKeys.error: 'Max tool rounds exceeded (${LlmAgentKeys.maxRounds})'},
      );
    }

    try {
      // ── Конфигурация LLM из descriptor ──────────────────────────────────
      final source  = descriptor.spec.source as LlmAgentSource;
      final baseUrl = _resolveBaseUrl(source.provider);
      final apiKey  = Platform.environment[source.apiKeyRef] ?? '';
      final model   = source.model;

      // ── Доступные tools (кроме llm) ──────────────────────────────────────
      final availableTools = (await toolExecutor.listAvailable())
          .where((t) => t.ref.name != LlmAgentKeys.llmToolName)
          .toList();

      // Нормализуем имена tools для LLM (Gemini не принимает '/', ':' в именах).
      // Маппинг: нормализованное → оригинальное (для обратного маппинга при вызове).
      final toolNameMap = <String, String>{
        for (final t in availableTools)
          _normalizeName(t.ref.name): t.ref.name,
      };

      final toolsSchema = availableTools.map((t) => {
        LlmToolKeys.type: LlmToolKeys.typeFunction,
        LlmToolKeys.function: {
          LlmToolKeys.name:      _normalizeName(t.ref.name),
          'description':         t.description,
          'parameters':          t.inputSchema,
        },
      }).toList();

      final messages = ((input.data[LlmAgentKeys.messages] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

      // ── Вызов LLM tool ───────────────────────────────────────────────────
      final ToolOutput llmOutput;
      try {
        llmOutput = await toolExecutor
            .execute(
              ToolRef(LlmAgentKeys.llmToolName),
              ToolInput(data: {
                LlmToolKeys.baseUrl:  baseUrl,
                LlmToolKeys.apiKey:   apiKey,
                LlmToolKeys.model:    model,
                LlmToolKeys.messages: messages,
                if (toolsSchema.isNotEmpty) LlmToolKeys.tools: toolsSchema,
              }),
            )
            .timeout(
              LlmAgentKeys.llmTimeout,
              onTimeout: () => ToolOutput(
                success: false,
                error: 'LLM timeout after ${LlmAgentKeys.llmTimeout.inSeconds}s',
              ),
            );
      } catch (e) {
        return SubjectOutput(success: false, data: {LlmAgentKeys.error: e.toString()});
      }

      if (!llmOutput.success) {
        return SubjectOutput(
          success: false,
          data: {LlmAgentKeys.error: llmOutput.error ?? 'LLM call failed'},
        );
      }

      final content      = llmOutput.data?[LlmToolKeys.content]   as String? ?? '';
      final rawToolCalls = llmOutput.data?[LlmToolKeys.toolCalls]  as List?;

      // ── Финальный ответ ──────────────────────────────────────────────────
      if (rawToolCalls == null || rawToolCalls.isEmpty) {
        return SubjectOutput(
          success: true,
          data: {LlmAgentKeys.content: content, LlmAgentKeys.role: LlmToolKeys.roleAssistant},
        );
      }

      // ── Выполнение tool_calls ────────────────────────────────────────────
      final toolResults = <Map<String, dynamic>>[];
      print('\n🔧 Executing tools (round ${round + 1})...');

      for (final tc in rawToolCalls.map((e) => Map<String, dynamic>.from(e as Map))) {
        final normalizedName = tc[LlmToolKeys.name] as String;
        final args = Map<String, dynamic>.from(tc[LlmToolKeys.arguments] as Map);
        final id   = tc[LlmToolKeys.id]        as String;

        // Денормализуем имя обратно (LLM вернул нормализованное)
        final originalName = toolNameMap[normalizedName] ?? normalizedName;

        onEvent?.call(ToolCalledEvent(DateTime.now(), originalName, args));

        final result = await toolExecutor.execute(
          ToolRef(originalName),
          ToolInput(data: args),
        );

        if (result.denyReason == ToolDenyReason.notAllowed) {
          onEvent?.call(ToolAccessRequestedEvent(
              DateTime.now(), originalName, descriptor.metadata.name));
          print('   🔐 $originalName: access denied → access request emitted');
        } else {
          print('   ${result.success ? '✅' : '❌'} $originalName: '
              '${result.success ? 'success' : result.error}');
        }

        toolResults.add({
          LlmToolKeys.role:        LlmToolKeys.roleTool,
          LlmToolKeys.toolCallId:  id,
          LlmToolKeys.content:     result.success
              ? (result.data?.toString() ?? LlmToolKeys.fallbackOk)
              : result.error ?? 'failed',
        });
      }

      // ── Рекурсия ─────────────────────────────────────────────────────────
      final assistantMsg = <String, dynamic>{
        LlmToolKeys.role:      LlmToolKeys.roleAssistant,
        LlmToolKeys.content:   content,
        LlmToolKeys.toolCalls: rawToolCalls
            .map((e) => Map<String, dynamic>.from(e as Map))
            .map((tc) {
              final args = tc[LlmToolKeys.arguments];
              // Ollama ожидает arguments как JSON строку, OpenAI принимает оба формата.
              // Сериализуем Map → строку для совместимости.
              final argsStr = args is String ? args : jsonEncode(args);
              return {
                LlmToolKeys.id:   tc[LlmToolKeys.id],
                LlmToolKeys.type: LlmToolKeys.typeFunction,
                LlmToolKeys.function: {
                  LlmToolKeys.name:      tc[LlmToolKeys.name],
                  LlmToolKeys.arguments: argsStr,
                },
              };
            })
            .toList(),
      };

      return execute(
        descriptor,
        SubjectInput(data: {
          LlmAgentKeys.messages: [...messages, assistantMsg, ...toolResults],
        }),
        context,
        toolExecutor,
        round: round + 1,
        onEvent: onEvent,
      );
    } catch (e, st) {
      print('   ❌ LlmAgentExecutor error: $e\n$st');
      return SubjectOutput(success: false, data: {LlmAgentKeys.error: e.toString()});
    }
  }
}

/// Нормализует имя tool для LLM API.
/// Gemini/OpenAI не принимают '/', ':', '-' в начале имён функций.
/// Заменяем '/' и ':' на '_'.
String _normalizeName(String name) =>
    name.replaceAll('/', '_').replaceAll(':', '_').replaceAll('-', '_');
