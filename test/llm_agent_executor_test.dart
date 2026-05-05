// aq_subject_runtime/test/llm_agent_executor_test.dart
//
// Тест S-04: fail-fast при отсутствии API key.

import 'package:aq_schema/subject.dart';
import 'package:aq_schema/sandbox.dart';
import 'package:aq_schema/tools.dart';
import 'package:test/test.dart';
import 'package:aq_subject_runtime/aq_subject_runtime.dart';

void main() {
  group('LlmAgentExecutor S-04: API key fail-fast', () {
    final descriptor = SubjectDescriptor(
      metadata: SubjectMetadata(
        name: 'test-agent',
        namespace: 'test',
        version: '1.0.0',
        description: 'Test agent',
      ),
      spec: SubjectSpec(
        kind: SubjectKinds.llmAgent,
        source: LlmAgentSource(
          provider: 'openai',
          model: 'gpt-4o',
          apiKeyRef: 'NONEXISTENT_API_KEY_XYZ_12345',
        ),
        tools: {},
        interface: SubjectInterface(
          protocol: OpenAiCompatibleProtocol(),
          inputSchema: {},
          outputSchema: {},
        ),
      ),
    );

    final context = RunContext.minimal(
      runId: 'test-run',
      sandboxId: 'test-sandbox',
      sessionId: 'test-session',
    );

    test('returns failure when API key env var is not set', () async {
      // Убеждаемся что переменная не установлена
      // (NONEXISTENT_API_KEY_XYZ_12345 заведомо не существует)
      final executor = LlmAgentExecutor();
      final mockToolExecutor = _NoOpToolExecutor();

      final result = await executor.execute(
        descriptor,
        SubjectInput(data: {LlmAgentKeys.messages: []}),
        context,
        mockToolExecutor,
      );

      expect(result.success, isFalse);
      expect(
        result.data[LlmAgentKeys.error] as String?,
        contains('NONEXISTENT_API_KEY_XYZ_12345'),
      );
    });
  });
}

/// Заглушка IToolExecutor для тестов.
class _NoOpToolExecutor implements IToolExecutor {
  @override
  Future<ToolOutput> execute(ToolRef ref, ToolInput input) async =>
      ToolOutput(success: false, error: 'no-op');

  @override
  Future<List<ToolContract>> listAvailable() async => [];

  @override
  void grantTool(ToolRef ref) {}
}
