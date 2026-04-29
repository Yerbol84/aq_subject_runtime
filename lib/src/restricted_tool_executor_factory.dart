// aq_subject_runtime/lib/src/restricted_tool_executor_factory.dart

import 'package:aq_schema/tools.dart';
import 'package:aq_schema/subject.dart';
import 'restricted_tool_executor.dart';

/// Реализация IToolExecutorFactory.
/// Создаёт RestrictedToolExecutor через синглтоны.
/// Инициализация: IToolExecutorFactory.initialize(RestrictedToolExecutorFactory());
final class RestrictedToolExecutorFactory implements IToolExecutorFactory {
  const RestrictedToolExecutorFactory();

  @override
  IToolExecutor create(List<ToolRef> allowedTools, String subjectId) =>
      RestrictedToolExecutor(
        IAQToolRegistrySimple.instance,
        List.of(allowedTools),
        subjectId,
        toolRuntime: IToolRuntimeExecutor.instance,
      );
}
