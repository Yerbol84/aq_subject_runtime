// aq_subject_runtime/lib/src/restricted_tool_executor.dart

import 'package:aq_schema/subject.dart';
import 'package:aq_schema/tools.dart';

/// Реализация IToolExecutor с ограничениями и runtime grant.
final class RestrictedToolExecutor implements IToolExecutor {
  final IAQToolRegistrySimple _toolRegistry;
  final List<ToolRef> _allowedTools;
  final String _subjectId;
  final IToolRuntimeExecutor? _toolRuntime;

  /// Вызывается когда агент запрашивает tool которого у него нет.
  void Function(ToolRef ref)? onAccessRequested;

  RestrictedToolExecutor(
    this._toolRegistry,
    this._allowedTools,
    this._subjectId, {
    required IToolRuntimeExecutor? toolRuntime,
    this.onAccessRequested,
  }) : _toolRuntime = toolRuntime;

  @override
  void grantTool(ToolRef ref) {
    if (!_allowedTools.any((t) => t.name == ref.name)) {
      _allowedTools.add(ref);
    }
  }

  @override
  Future<ToolOutput> execute(ToolRef ref, ToolInput input) async {
    if (!_allowedTools.any((t) => t.name == ref.name)) {
      onAccessRequested?.call(ref);
      return ToolOutput(
        success: false,
        denyReason: ToolDenyReason.notAllowed,
        error: 'Tool ${ref.name} not allowed for agent $_subjectId.',
      );
    }

    final ToolContract contract;
    try {
      contract = await _toolRegistry.resolve(ref);
    } catch (_) {
      return ToolOutput(
        success: false,
        denyReason: ToolDenyReason.notFound,
        error: 'Tool ${ref.name} not found in registry',
      );
    }

    if (_toolRuntime == null) {
      return ToolOutput(
        success: false,
        error: 'No ToolRuntime configured for agent $_subjectId',
      );
    }

    return await _toolRuntime.execute(contract, input);
  }

  @override
  Future<List<ToolContract>> listAvailable() async {
    final contracts = <ToolContract>[];
    for (final ref in List.of(_allowedTools)) {
      try {
        contracts.add(await _toolRegistry.resolve(ref));
      } catch (_) {
        continue;
      }
    }
    return contracts;
  }
}
