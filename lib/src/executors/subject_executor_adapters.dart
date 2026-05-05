// aq_subject_runtime/lib/src/executors/subject_executor_adapters.dart
//
// P-10: Адаптеры ISubjectExecutor для существующих executors.
// Делегируют к LlmAgentExecutor и GitRepoExecutor.

import 'package:aq_schema/subject.dart';
import 'package:aq_schema/sandbox.dart';
import 'llm_agent_executor.dart';
import 'git_repo_executor.dart';

/// ISubjectExecutor для SubjectKinds.llmAgent.
final class LlmAgentSubjectExecutor implements ISubjectExecutor {
  const LlmAgentSubjectExecutor();

  @override
  Future<SubjectOutput> execute(
    SubjectDescriptor descriptor,
    SubjectInput input,
    RunContext context,
    ISandboxHandle sandbox,
    IToolExecutor? toolExecutor, {
    void Function(SubjectSessionEvent)? onEvent,
  }) =>
      const LlmAgentExecutor().execute(
        descriptor, input, context, toolExecutor!,
        onEvent: onEvent,
      );
}

/// ISubjectExecutor для SubjectKind.gitRepo.
final class GitRepoSubjectExecutor implements ISubjectExecutor {
  const GitRepoSubjectExecutor();

  @override
  Future<SubjectOutput> execute(
    SubjectDescriptor descriptor,
    SubjectInput input,
    RunContext context,
    ISandboxHandle sandbox,
    IToolExecutor? toolExecutor, {
    void Function(SubjectSessionEvent)? onEvent,
  }) =>
      const GitRepoExecutor().execute(
        descriptor, input, context, sandbox,
        onEvent: onEvent,
      );
}
