// aq_subject_runtime/lib/src/constants/llm_agent_keys.dart
//
// Константы LlmAgentExecutor.
// Уровень 2 (внутри пакета) — константы класса.

/// Конфигурационные константы LLM Agent executor.
class LlmAgentKeys {
  LlmAgentKeys._();

  // ── Лимиты ────────────────────────────────────────────────────────────────
  static const int    maxRounds  = 10;
  static const Duration llmTimeout = Duration(seconds: 60);

  // ── Имя LLM tool ──────────────────────────────────────────────────────────
  static const String llmToolName = 'llm';

  // ── SubjectInput keys ─────────────────────────────────────────────────────
  static const String messages = 'messages';

  // ── SubjectOutput keys ────────────────────────────────────────────────────
  static const String content = 'content';
  static const String role    = 'role';
  static const String error   = 'error';

  // ── Env variable suffixes ─────────────────────────────────────────────────
  /// Суффикс для env переменной с base URL провайдера.
  /// Итоговое имя: {PROVIDER_UPPER}_BASE_URL
  static const String baseUrlEnvSuffix = '_BASE_URL';

  // ── Известные провайдеры → стандартные base URL ───────────────────────────
  static const Map<String, String> providerBaseUrls = {
    'openai':        'https://api.openai.com/v1',
    'anthropic':     'https://api.anthropic.com/v1',
    'gemini':        'https://generativelanguage.googleapis.com/v1beta/openai',
    'ollama':        'http://localhost:11434/v1',
    'ollama-docker': 'http://host.docker.internal:11434/v1',
    'mock':          'http://localhost:0', // placeholder — перехватывается MockLlmHandler
  };
}
