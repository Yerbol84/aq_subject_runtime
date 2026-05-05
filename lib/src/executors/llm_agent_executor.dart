// aq_subject_runtime/lib/src/executors/llm_agent_executor.dart

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/subject.dart';
import 'package:aq_schema/sandbox.dart';
import 'package:aq_schema/tools.dart';
import 'package:logging/logging.dart';
import '../constants/llm_agent_keys.dart';
import '../adapters/openai_response_adapter.dart';

final _log = Logger('LlmAgentExecutor');

/// Резолвинг base URL провайдера.
String _resolveBaseUrl(String provider) {
  final envKey = '${provider.toUpperCase()}${LlmAgentKeys.baseUrlEnvSuffix}';
  final override = Platform.environment[envKey];
  if (override != null) return override;
  final known = LlmAgentKeys.providerBaseUrls[provider];
  if (known != null) return known;
  throw ArgumentError('Unknown provider "$provider". Set $envKey env variable.');
}

class LlmAgentExecutor {
  const LlmAgentExecutor();

  /// Streaming версия execute().
  ///
  /// Эмитит [SubjectOutputChunk] по мере выполнения:
  /// - текстовые токены → чанки с text по мере получения от LLM
  /// - tool_called → чанк с данными события (после завершения tool call round)
  /// - финальный ответ → чанк с isDone: true
  Stream<SubjectOutputChunk> executeStream(
    SubjectDescriptor descriptor,
    SubjectInput input,
    RunContext context,
    IToolExecutor toolExecutor,
  ) async* {
    try {
      final source = descriptor.spec.source as LlmAgentSource;
      final baseUrl = _resolveBaseUrl(source.provider);
      final apiKey = Platform.environment[source.apiKeyRef] ?? '';

      if (source.provider != 'mock' && apiKey.isEmpty) {
        yield SubjectOutputChunk(
          data: {'error': 'API key not found: env variable "${source.apiKeyRef}" is not set.'},
          isDone: true,
        );
        return;
      }

      if (context.net == null) {
        yield SubjectOutputChunk(data: {'error': 'NET capability not available'}, isDone: true);
        return;
      }

      final availableTools = (await toolExecutor.listAvailable())
          .where((t) => t.ref.name != LlmAgentKeys.llmToolName)
          .toList();

      final toolNameMap = <String, String>{
        for (final t in availableTools) _normalizeName(t.ref.name): t.ref.name,
      };

      final toolsSchema = availableTools.map((t) => {
            LlmToolKeys.type: LlmToolKeys.typeFunction,
            LlmToolKeys.function: {
              LlmToolKeys.name: _normalizeName(t.ref.name),
              'description': t.description,
              'parameters': t.inputSchema,
            },
          }).toList();

      final messages = List<Map<String, dynamic>>.from(
        ((input.data[LlmAgentKeys.messages] as List?) ?? const []).cast<Map<String, dynamic>>(),
      );

      final hasSystemMsg = messages.any((m) => m[LlmToolKeys.role] == LlmAgentKeys.roleSystem);
      if (!hasSystemMsg) {
        final systemPrompt = input.data[LlmAgentKeys.systemPrompt] as String? ??
            descriptor.metadata.description;
        if (systemPrompt != null && systemPrompt.isNotEmpty) {
          messages.insert(0, {LlmToolKeys.role: LlmAgentKeys.roleSystem, LlmToolKeys.content: systemPrompt});
        }
      }

      final url = '${baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl}/chat/completions';
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      };

      for (var round = 0; round < LlmAgentKeys.maxRounds; round++) {
        final body = jsonEncode(<String, dynamic>{
          LlmToolKeys.messages: messages,
          LlmToolKeys.stream: true,
          LlmToolKeys.model: source.model,
          if (toolsSchema.isNotEmpty) LlmToolKeys.tools: toolsSchema,
        });

        // Буфер tool calls для текущего round
        final toolCallBuffers = <int, _ToolCallBuffer>{};
        final assistantTextBuffer = StringBuffer();

        await for (final line in context.net!.postStream(url, body: body, headers: headers)) {
          if (!line.startsWith('data: ')) continue;
          final data = line.substring(6).trim();
          if (data == '[DONE]') break;

          final Map<String, dynamic> json;
          try {
            json = jsonDecode(data) as Map<String, dynamic>;
          } catch (_) {
            continue;
          }

          final choices = json[LlmToolKeys.choices] as List?;
          if (choices == null || choices.isEmpty) continue;

          final choiceMap = choices.first as Map<String, dynamic>;
          final delta = choiceMap[LlmToolKeys.delta] as Map<String, dynamic>?;

          if (delta != null) {
            final token = delta[LlmToolKeys.content] as String?;
            if (token != null && token.isNotEmpty) {
              assistantTextBuffer.write(token);
              yield SubjectOutputChunk(text: token);
            }

            final rawToolCalls = delta[LlmToolKeys.toolCalls] as List?;
            if (rawToolCalls != null) {
              for (final tc in rawToolCalls) {
                final tcMap = tc as Map<String, dynamic>;
                final index = tcMap['index'] as int? ?? 0;
                final buffer = toolCallBuffers.putIfAbsent(index, () => _ToolCallBuffer());
                buffer.id ??= tcMap[LlmToolKeys.id] as String?;
                final fn = tcMap[LlmToolKeys.function] as Map<String, dynamic>?;
                if (fn != null) {
                  buffer.name ??= fn[LlmToolKeys.name] as String?;
                  buffer.arguments.write(fn[LlmToolKeys.arguments] as String? ?? '');
                }
              }
            }
          }
        }

        // Финальный ответ без tool calls
        if (toolCallBuffers.isEmpty) {
          yield SubjectOutputChunk(text: null, isDone: true);
          return;
        }

        // Выполняем tool calls
        final toolCalls = toolCallBuffers.entries.map((entry) {
          final buffer = entry.value;
          final argsStr = buffer.arguments.toString();
          final args = argsStr.isNotEmpty
              ? (jsonDecode(argsStr) as Map<String, dynamic>)
              : <String, dynamic>{};
          return (id: buffer.id ?? '', name: buffer.name ?? '', arguments: args);
        }).toList();

        final toolResults = <Map<String, dynamic>>[];
        for (final tc in toolCalls) {
          final originalName = toolNameMap[tc.name] ?? tc.name;
          yield SubjectOutputChunk(
            data: {'event': 'tool_called', 'tool': originalName, 'args': tc.arguments},
          );

          final result = await toolExecutor.execute(ToolRef(originalName), ToolInput(data: tc.arguments));
          toolResults.add({
            LlmToolKeys.role: LlmToolKeys.roleTool,
            LlmToolKeys.toolCallId: tc.id,
            LlmToolKeys.content: result.success
                ? (result.textContent ?? result.data?.toString() ?? LlmToolKeys.fallbackOk)
                : result.error ?? 'failed',
          });
        }

        // Добавляем assistant + tool results в messages для следующего round
        messages
          ..add({
            LlmToolKeys.role: LlmToolKeys.roleAssistant,
            LlmToolKeys.content: assistantTextBuffer.toString(),
            LlmToolKeys.toolCalls: toolCalls.map((tc) => {
                  LlmToolKeys.id: tc.id,
                  LlmToolKeys.type: LlmToolKeys.typeFunction,
                  LlmToolKeys.function: {
                    LlmToolKeys.name: tc.name,
                    LlmToolKeys.arguments: jsonEncode(tc.arguments),
                  },
                }).toList(),
          })
          ..addAll(toolResults);
      }

      yield SubjectOutputChunk(
        data: {'error': 'Max tool rounds exceeded (${LlmAgentKeys.maxRounds})'},
        isDone: true,
      );
    } catch (e, st) {
      _log.severe('LlmAgentExecutor.executeStream error: $e', e, st);
      yield SubjectOutputChunk(data: {'error': e.toString()}, isDone: true);
    }
  }

  Future<SubjectOutput> execute(
    SubjectDescriptor descriptor,
    SubjectInput input,
    RunContext context,
    IToolExecutor toolExecutor, {
    void Function(SubjectSessionEvent)? onEvent,
  }) async {
    try {
      final source = descriptor.spec.source as LlmAgentSource;
      final baseUrl = _resolveBaseUrl(source.provider);

      // S-04 fix: fail-fast при отсутствии API key.
      // Исключение: provider='mock' — для тестов и примеров без реального LLM.
      final apiKey = Platform.environment[source.apiKeyRef] ?? '';
      if (source.provider != 'mock' && apiKey.isEmpty) {
        return SubjectOutput(
          success: false,
          data: {
            LlmAgentKeys.error:
                'API key not found: env variable "${source.apiKeyRef}" is not set. '
                'Set the environment variable before running the agent.',
          },
        );
      }

      final availableTools = (await toolExecutor.listAvailable())
          .where((t) => t.ref.name != LlmAgentKeys.llmToolName)
          .toList();

      final toolNameMap = <String, String>{
        for (final t in availableTools) _normalizeName(t.ref.name): t.ref.name,
      };

      final toolsSchema = availableTools.map((t) => {
            LlmToolKeys.type: LlmToolKeys.typeFunction,
            LlmToolKeys.function: {
              LlmToolKeys.name: _normalizeName(t.ref.name),
              'description': t.description,
              'parameters': t.inputSchema,
            },
          }).toList();

      // C-05 fix: итерация вместо рекурсии — O(n) память вместо O(n²).
      final messages = List<Map<String, dynamic>>.from(
        ((input.data[LlmAgentKeys.messages] as List?) ?? const [])
            .cast<Map<String, dynamic>>(),
      );

      // System prompt: из input.data['system_prompt'] или descriptor.metadata.description.
      // Добавляется первым если в messages ещё нет role=system.
      // Инструкция использовать относительные пути — исправляет llama3.1 path escape.
      final hasSystemMsg = messages.any(
        (m) => m[LlmToolKeys.role] == LlmAgentKeys.roleSystem,
      );
      if (!hasSystemMsg) {
        final systemPrompt = input.data[LlmAgentKeys.systemPrompt] as String? ??
            descriptor.metadata.description;
        if (systemPrompt != null && systemPrompt.isNotEmpty) {
          messages.insert(0, {
            LlmToolKeys.role: LlmAgentKeys.roleSystem,
            LlmToolKeys.content: systemPrompt,
          });
        }
      }

      for (var round = 0; round < LlmAgentKeys.maxRounds; round++) {
        // ── Вызов LLM ──────────────────────────────────────────────────────
        final ToolOutput llmOutput;
        try {
          llmOutput = await toolExecutor
              .execute(
                ToolRef(LlmAgentKeys.llmToolName),
                ToolInput(data: {
                  LlmToolKeys.baseUrl: baseUrl,
                  LlmToolKeys.apiKey: apiKey,
                  LlmToolKeys.model: source.model,
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

        // P-13: нормализуем ответ через адаптер вместо прямого парсинга
        const ILlmResponseAdapter adapter = OpenAiResponseAdapter();
        final normalized = adapter.normalize(llmOutput.data ?? {});

        // ── Финальный ответ (нет tool calls) ───────────────────────────────
        if (!normalized.hasToolCalls) {
          return SubjectOutput(
            success: true,
            data: {LlmAgentKeys.content: normalized.content, LlmAgentKeys.role: LlmToolKeys.roleAssistant},
          );
        }

        // ── Выполнение tool_calls ───────────────────────────────────────────
        _log.fine('Executing tools (round ${round + 1})...');
        final toolResults = <Map<String, dynamic>>[];

        for (final tc in normalized.toolCalls) {
          final originalName = toolNameMap[tc.name] ?? tc.name;

          onEvent?.call(ToolCalledEvent(DateTime.now(), originalName, tc.arguments));

          final result = await toolExecutor.execute(
            ToolRef(originalName),
            ToolInput(data: tc.arguments),
          );

          if (result.denyReason == ToolDenyReason.notAllowed) {
            onEvent?.call(ToolAccessRequestedEvent(
                DateTime.now(), originalName, descriptor.metadata.name));
            _log.warning('$originalName: access denied → access request emitted');
          } else {
            _log.fine('$originalName: ${result.success ? 'success' : result.error}');
          }

          toolResults.add({
            LlmToolKeys.role: LlmToolKeys.roleTool,
            LlmToolKeys.toolCallId: tc.id,
            LlmToolKeys.content: result.success
                ? (result.textContent ?? result.data?.toString() ?? LlmToolKeys.fallbackOk)
                : result.error ?? 'failed',
          });
        }

        // Добавляем assistant + tool results в messages для следующего раунда.
        final assistantMsg = <String, dynamic>{
          LlmToolKeys.role: LlmToolKeys.roleAssistant,
          LlmToolKeys.content: normalized.content,
          LlmToolKeys.toolCalls: normalized.toolCalls.map((tc) => {
                LlmToolKeys.id: tc.id,
                LlmToolKeys.type: LlmToolKeys.typeFunction,
                LlmToolKeys.function: {
                  LlmToolKeys.name: tc.name,
                  LlmToolKeys.arguments: jsonEncode(tc.arguments),
                },
              }).toList(),
        };

        messages
          ..add(assistantMsg)
          ..addAll(toolResults);
      }

      return SubjectOutput(
        success: false,
        data: {LlmAgentKeys.error: 'Max tool rounds exceeded (${LlmAgentKeys.maxRounds})'},
      );
    } catch (e, st) {
      _log.severe('LlmAgentExecutor error: $e', e, st);
      return SubjectOutput(success: false, data: {LlmAgentKeys.error: e.toString()});
    }
  }
}

String _normalizeName(String name) =>
    name.replaceAll('/', '_').replaceAll(':', '_').replaceAll('-', '_');

class _ToolCallBuffer {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}