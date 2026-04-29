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

    final result = switch (_descriptor.spec.kind) {
      SubjectKind.llmAgent => await const LlmAgentExecutor().execute(
          _descriptor, input, _context, toolExecutor!,
          onEvent: emit,
        ),
      _ => throw UnsupportedSubjectKindException(_descriptor.spec.kind),
    };

    _eventController.add(SessionCompletedEvent(DateTime.now(), result));
    return result;
  }

  @override
  Stream<SubjectOutputChunk> sendStream(SubjectInput input) =>
      throw UnimplementedError('Streaming not implemented');

  @override
  Future<SubjectSessionResult> dispose({bool saveArtifacts = true}) async {
    final start = DateTime.now();
    await _sandbox.dispose(saveArtifacts: saveArtifacts);
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
