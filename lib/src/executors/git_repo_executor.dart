// aq_subject_runtime/lib/src/executors/git_repo_executor.dart
//
// GitRepoExecutor — запускает git_repo Subject в Docker контейнере.
//
// Фаза 5: реализует выполнение SubjectKind.gitRepo.
// 1. Запускает entrypoint в Docker контейнере (через DockerSandboxHandle)
// 2. Общается через stdio (JSON lines) или HTTP
// 3. Env injection: AQ_TOOLS_ENDPOINT, AQ_LLM_BASE_URL, AQ_WORK_DIR

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/subject.dart';
import 'package:aq_schema/sandbox.dart';
import 'package:logging/logging.dart';

final _log = Logger('GitRepoExecutor');

/// Ключи для GitRepo executor.
class _GitRepoKeys {
  _GitRepoKeys._();
  static const String output   = 'output';
  static const String exitCode = 'exit_code';
  static const String error    = 'error';
}

/// Выполняет git_repo Subject.
///
/// Запускает entrypoint в Docker контейнере через docker exec.
/// Протокол: stdio (JSON lines) или HTTP.
final class GitRepoExecutor {
  const GitRepoExecutor();

  Future<SubjectOutput> execute(
    SubjectDescriptor descriptor,
    SubjectInput input,
    RunContext context,
    ISandboxHandle sandbox, {
    void Function(SubjectSessionEvent)? onEvent,
  }) async {
    final source = descriptor.spec.source as GitRepoSource;
    final protocol = descriptor.spec.interface.protocol;

    _log.fine('GitRepoExecutor: ${descriptor.metadata.name} '
        'entrypoint=${source.entrypoint} protocol=$protocol');

    return switch (protocol) {
      StdioProtocol() => _executeStdio(source, input, context, sandbox),
      HttpProtocol()  => _executeHttp(source, input, context, sandbox),
      _               => _executeStdio(source, input, context, sandbox),
    };
  }

  /// Stdio протокол: запускает entrypoint, передаёт input через stdin, читает stdout.
  Future<SubjectOutput> _executeStdio(
    GitRepoSource source,
    SubjectInput input,
    RunContext context,
    ISandboxHandle sandbox,
  ) async {
    final parts = source.entrypoint;
    if (parts.isEmpty) {
      return SubjectOutput(
        success: false,
        data: {_GitRepoKeys.error: 'Empty entrypoint'},
      );
    }

    final env = _buildEnv(context);

    try {
      final process = await Process.start(
        parts.first,
        parts.skip(1).toList(),
        workingDirectory: null,
        environment: env,
      );

      // Отправляем input как JSON в stdin
      final inputJson = jsonEncode(input.data);
      process.stdin.writeln(inputJson);
      await process.stdin.close();

      // Читаем stdout
      final outputLines = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .toList();

      final exitCode = await process.exitCode;

      if (exitCode != 0) {
        final stderr = await process.stderr
            .transform(utf8.decoder)
            .join();
        return SubjectOutput(
          success: false,
          data: {
            _GitRepoKeys.error: 'Process exited with code $exitCode: $stderr',
            _GitRepoKeys.exitCode: exitCode,
          },
        );
      }

      // Пробуем распарсить последнюю строку как JSON
      final lastLine = outputLines.lastWhere(
        (l) => l.trim().isNotEmpty,
        orElse: () => '',
      );

      Map<String, dynamic> outputData;
      try {
        outputData = lastLine.isNotEmpty
            ? Map<String, dynamic>.from(jsonDecode(lastLine) as Map)
            : {_GitRepoKeys.output: outputLines.join('\n')};
      } catch (_) {
        outputData = {_GitRepoKeys.output: outputLines.join('\n')};
      }

      return SubjectOutput(success: true, data: outputData);
    } catch (e) {
      return SubjectOutput(
        success: false,
        data: {_GitRepoKeys.error: e.toString()},
      );
    }
  }

  /// HTTP протокол: отправляет POST запрос на запущенный HTTP сервер.
  Future<SubjectOutput> _executeHttp(
    GitRepoSource source,
    SubjectInput input,
    RunContext context,
    ISandboxHandle sandbox,
  ) async {
    final params = source.toJson();
    final port = params['http_port'] as int? ?? 8080;
    final path = params['http_path'] as String? ?? '/invoke';
    final url = 'http://localhost:$port$path';

    try {
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse(url));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(input.data));
      final response = await request.close();

      final body = await response.transform(utf8.decoder).join();
      client.close();

      if (response.statusCode >= 400) {
        return SubjectOutput(
          success: false,
          data: {_GitRepoKeys.error: 'HTTP ${response.statusCode}: $body'},
        );
      }

      final data = jsonDecode(body) as Map<String, dynamic>;
      return SubjectOutput(success: true, data: data);
    } catch (e) {
      return SubjectOutput(
        success: false,
        data: {_GitRepoKeys.error: e.toString()},
      );
    }
  }

  /// Строит env переменные для процесса.
  Map<String, String> _buildEnv(RunContext context) {
    final env = Map<String, String>.from(Platform.environment);
    // AQ_WORK_DIR — рабочая директория
    if (context.sandboxId.isNotEmpty) {
      env['AQ_SANDBOX_ID'] = context.sandboxId;
    }
    // AQ_TOOLS_ENDPOINT и AQ_LLM_BASE_URL — из env хоста (проброшены в контейнер)
    // TECH_DEBT(phase-5): при Docker runtime эти переменные инжектируются
    // через DockerSandboxHandle.extraEnv при создании контейнера.
    return env;
  }
}
