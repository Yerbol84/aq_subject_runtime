// aq_subject_runtime/lib/src/restricted_tool_executor_factory.dart

import 'package:aq_schema/tools.dart';
import 'package:aq_schema/subject.dart';
import 'package:aq_schema/sandbox.dart';
import 'restricted_tool_executor.dart';

final class RestrictedToolExecutorFactory implements IToolExecutorFactory {
  const RestrictedToolExecutorFactory();

  @override
  IToolExecutor create(
    List<ToolRef> allowedTools,
    String subjectId,
    RunContext sessionContext,
  ) =>
      RestrictedToolExecutor(
        IAQToolRegistrySimple.instance,
        List.of(allowedTools),
        subjectId,
        toolRuntime: IToolRuntimeExecutor.instance,
        sessionContext: sessionContext,
      );
}
