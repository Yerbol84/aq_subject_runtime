// aq_subject_runtime/lib/src/llm/llm_client.dart

import 'package:aq_schema/tools.dart';

/// LLM Client (заглушка).
abstract class LLMClient {
  Future<LLMResponse> chat({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
  });
}

class LLMResponse {
  final String content;
  final List<ToolCall>? toolCalls;

  LLMResponse(this.content, {this.toolCalls});

  Map<String, dynamic> toMessage() => {
    LlmToolKeys.role:      LlmToolKeys.roleAssistant,
    LlmToolKeys.content:   content,
    if (toolCalls != null)
      LlmToolKeys.toolCalls: toolCalls!.map((t) => t.toJson()).toList(),
  };
}

class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  ToolCall(this.id, this.name, this.arguments);

  Map<String, dynamic> toJson() => {
    LlmToolKeys.id:        id,
    LlmToolKeys.name:      name,
    LlmToolKeys.arguments: arguments,
  };
}

/// Заглушка для тестов.
class MockLLMClient implements LLMClient {
  @override
  Future<LLMResponse> chat({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
  }) async {
    return LLMResponse('Mock response from LLM');
  }
}
