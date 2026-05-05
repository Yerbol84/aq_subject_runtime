// aq_subject_runtime/lib/src/subject_executor_registry.dart
//
// P-10: Реализация ISubjectExecutorRegistry.

import 'package:aq_schema/subject.dart';

final class SubjectExecutorRegistry implements ISubjectExecutorRegistry {
  final Map<SubjectKind, ISubjectExecutor> _executors = {};

  @override
  void register(SubjectKind kind, ISubjectExecutor executor) =>
      _executors[kind] = executor;

  @override
  ISubjectExecutor? find(SubjectKind kind) => _executors[kind];
}
