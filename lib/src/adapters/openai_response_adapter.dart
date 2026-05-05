// aq_subject_runtime/lib/src/adapters/openai_response_adapter.dart
//
// P-13: Адаптер для OpenAI / OpenAI-compatible формата ответов.

import 'dart:convert';
import 'package:aq_schema/subject.dart';
import 'package:aq_schema/tools.dart';

final class OpenAiResponseAdapter implements ILlmResponseAdapter {
  const OpenAiResponseAdapter();

  @override
  LlmNormalizedResponse normalize(Map<String, dynamic> data) {
    final content = data[LlmToolKeys.content] as String? ?? '';
    final rawToolCalls = data[LlmToolKeys.toolCalls] as List?;

    if (rawToolCalls == null || rawToolCalls.isEmpty) {
      return LlmNormalizedResponse(content: content, toolCalls: const []);
    }

    final toolCalls = rawToolCalls
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map((tc) {
          final args = tc[LlmToolKeys.arguments];
          final argsMap = args is String
              ? Map<String, dynamic>.from(jsonDecode(args) as Map)
              : Map<String, dynamic>.from(args as Map);
          return LlmNormalizedToolCall(
            id: tc[LlmToolKeys.id] as String,
            name: tc[LlmToolKeys.name] as String,
            arguments: argsMap,
          );
        })
        .toList();

    return LlmNormalizedResponse(content: content, toolCalls: toolCalls);
  }
}
