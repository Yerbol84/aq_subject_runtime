// aq_subject_runtime/lib/src/subject_session_factory.dart

import 'package:aq_schema/subject.dart';
import 'package:aq_schema/sandbox.dart';
import 'subject_session.dart';

/// Реализация ISubjectSessionFactory.
/// Создаёт SubjectSession. Не знает о RestrictedToolExecutor.
/// Инициализация: ISubjectSessionFactory.initialize(SubjectSessionFactory());
final class SubjectSessionFactory implements ISubjectSessionFactory {
  const SubjectSessionFactory();

  @override
  ISubjectSession createSession({
    required String sessionId,
    required SubjectDescriptor descriptor,
    required RunContext context,
    required ISandboxHandle sandbox,
    IToolExecutor? toolExecutor,
  }) =>
      SubjectSession(
        sessionId: sessionId,
        descriptor: descriptor,
        context: context,
        sandbox: sandbox,
        toolExecutor: toolExecutor,
      );
}
