// aq_subject_runtime/lib/src/subject_session.dart

import 'dart:async';
import 'package:aq_schema/subject.dart';
import 'package:aq_schema/sandbox.dart';
import 'executors/llm_agent_executor.dart';

class SubjectSession implements ISubjectSession {
  @override
  final String sessionId;
  @override
  final String subjectId;
  @override
  final String sandboxId;
  @override
  final IToolExecutor? toolExecutor;

  final SubjectDescriptor _descriptor;
  final RunContext _context;
  final ISandboxHandle _sandbox;
  final _eventController = StreamController<SubjectSessionEvent>.broadcast();

  SubjectSession({
    required this.sessionId,
    required SubjectDescriptor descriptor,
    required RunContext context,
    required ISandboxHandle sandbox,
    this.toolExecutor,
  })  : subjectId = descriptor.metadata.name,
        sandboxId = sandbox.sandboxId,
        _descriptor = descriptor,
        _context = context,
        _sandbox = sandbox;

  @override
  Stream<SubjectSessionEvent> get events => _eventController.stream;

  void emit(SubjectSessionEvent event) => _eventController.add(event);

  @override
  Future<SubjectOutput> send(SubjectInput input) async {
    _eventController.add(SessionStartedEvent(DateTime.now()));

    final maxTime = _context.policy?.budget.maxExecutionTime;

    Future<SubjectOutput> doExecute() {
      final kind = _descriptor.spec.kind;
      final executor = ISubjectExecutorRegistry.instance.find(kind);
      if (executor == null) {
        throw UnsupportedSubjectKindException(kind);
      }
      return executor.execute(
        _descriptor, input, _context, _sandbox, toolExecutor,
        onEvent: emit,
      );
    }

    // S-06: enforce maxExecutionTime через Future.timeout.
    // TECH_DEBT(phase-5): maxMemoryMb и maxCpuPercent enforced только в DockerRuntime.
    final result = maxTime != null
        ? await doExecute().timeout(
            maxTime,
            onTimeout: () => SubjectOutput(
              success: false,
              data: {
                'error':
                    'Execution exceeded maxExecutionTime (${maxTime.inSeconds}s)',
              },
            ),
          )
        : await doExecute();

    _eventController.add(SessionCompletedEvent(DateTime.now(), result));
    return result;
  }

  @override
  Stream<SubjectOutputChunk> sendStream(SubjectInput input) {
    if (_descriptor.spec.kind != SubjectKinds.llmAgent) {
      throw StreamingNotSupportedException(subjectId);
    }
    _eventController.add(SessionStartedEvent(DateTime.now()));
    return const LlmAgentExecutor().executeStream(
      _descriptor, input, _context, toolExecutor!,
    );
  }

  @override
  Future<SubjectSessionResult> dispose({bool saveArtifacts = true}) async {
    final start = DateTime.now();
    await _context.sandboxResources.dispose();
    await _sandbox.dispose(saveArtifacts: saveArtifacts);
    await ISandboxProvider.instance.release(_sandbox.sandboxId);
    await ISubjectSessionRepository.instance.delete(sessionId);
    if (IQuotaService.isInitialized) {
      await IQuotaService.instance.release(
        _descriptor.metadata.namespace,
        QuotaResource.concurrentSession,
      );
    }
    // TD-10: освобождаем пулы всех subjects вызванных как tools из этой сессии.
    if (ISubjectToolPoolManager.isInitialized) {
      await ISubjectToolPoolManager.instance.releaseForSession(sessionId);
    }
    await _eventController.close();
    return SubjectSessionResult(
      sessionId: sessionId,
      elapsed: DateTime.now().difference(start),
      success: true,
    );
  }
}

class UnsupportedSubjectKindException implements Exception {
  final SubjectKind kind;
  UnsupportedSubjectKindException(this.kind);
  @override
  String toString() => 'Unsupported SubjectKind: $kind';
}
