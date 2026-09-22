import 'package:flutter/foundation.dart';
import 'package:llm_api/llm_api.dart' as llm;

import '../core/app_paths.dart';
import '../core/ids.dart';
import '../data/config_repository.dart';
import '../data/index_repository.dart';
import '../data/models_dev_repository.dart';
import '../data/project_repository.dart';
import '../data/session_repository.dart';
import '../data/template_repository.dart';
import '../llm/session_compressor.dart';
import '../llm/session_namer.dart';
import '../models/app_config.dart';
import '../models/models_dev.dart';
import '../models/project.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_message.dart';
import '../models/session_params.dart';
import '../models/session_template.dart';

/// Top-level application state: config, session list, templates, projects.
///
/// Lists are backed by the on-disk catalog index and carry metadata only
/// (no messages). A session's conversation is loaded lazily into
/// [_sessionCache] when it is opened, so re-listing never discards an open
/// session's messages.
class AppState extends ChangeNotifier {
  AppState({
    required this.paths,
    required this.configRepository,
    required this.sessionRepository,
    required this.templateRepository,
    required this.projectRepository,
    IndexRepository? indexRepository,
  }) : indexRepository = indexRepository ?? IndexRepository(paths);

  final AppPaths paths;
  final ConfigRepository configRepository;
  final SessionRepository sessionRepository;
  final TemplateRepository templateRepository;
  final ProjectRepository projectRepository;
  final IndexRepository indexRepository;

  AppConfig config = AppConfig();
  List<Session> sessions = <Session>[];
  List<Session> archivedSessions = <Session>[];
  List<SessionTemplate> templates = <SessionTemplate>[];
  List<Project> projects = <Project>[];
  List<Project> archivedProjects = <Project>[];

  /// Sessions whose full conversation (messages) has been loaded in memory.
  final Map<String, Session> _sessionCache = <String, Session>{};

  Future<void> load() async {
    config = await configRepository.load();
    await refreshSessions();
    await refreshArchived();
    await refreshTemplates();
    await refreshProjects();
    await refreshArchivedProjects();
  }

  Future<void> saveConfig() async {
    await configRepository.save(config);
    notifyListeners();
  }

  Future<void> refreshSessions() async {
    final metas = await sessionRepository.list();
    sessions = [
      for (final meta in metas) _sessionCache[meta.id] ?? meta,
    ];
    _pruneCache(metas.map((m) => m.id));
    notifyListeners();
  }

  Future<void> refreshArchived() async {
    final metas = await sessionRepository.listArchived();
    archivedSessions = [
      for (final meta in metas) _sessionCache[meta.id] ?? meta,
    ];
    _pruneCache(metas.map((m) => m.id));
    notifyListeners();
  }

  void _pruneCache(Iterable<String> activeIds) {
    final keep = <String>{...activeIds, ...archivedSessions.map((s) => s.id)};
    _sessionCache.removeWhere((id, _) => !keep.contains(id));
  }

  Future<void> refreshTemplates() async {
    templates = await templateRepository.list();
    notifyListeners();
  }

  Future<void> refreshProjects() async {
    projects = await projectRepository.list();
    notifyListeners();
  }

  Future<void> refreshArchivedProjects() async {
    archivedProjects = await projectRepository.listArchived();
    notifyListeners();
  }

  Project? projectById(String id) {
    for (final project in projects) {
      if (project.id == id) return project;
    }
    for (final project in archivedProjects) {
      if (project.id == id) return project;
    }
    return null;
  }

  ProviderConfig providerById(String id) {
    return config.providerById(id) ?? config.providers.first;
  }

  Session? sessionById(String id) {
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    for (final session in archivedSessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  /// Returns the session with its full conversation loaded (from cache or disk).
  Future<Session> loadFullSession(String id) async {
    final cached = _sessionCache[id];
    if (cached != null) return cached;
    final full = await sessionRepository.read(id);
    _sessionCache[id] = full;
    return full;
  }

  /// Reloads one session from disk, replacing the in-memory copy so any
  /// external edits (or a stale list entry) are reflected.
  Future<void> reloadSession(String id) async {
    try {
      final fresh = await sessionRepository.read(id);
      _sessionCache[id] = fresh;
      final index = sessions.indexWhere((s) => s.id == id);
      if (index >= 0) {
        sessions[index] = fresh;
      } else {
        sessions.add(fresh);
      }
      notifyListeners();
    } catch (_) {
      // File missing/unreadable → keep the in-memory copy.
    }
  }

  // --------------------------------------------------------------- sessions

  Future<Session> createSession({
    String title = '',
    String? providerId,
    String? model,
    String? systemPrompt,
    SessionParams? params,
    List<String>? tools,
    int? toolCallsLimit,
    ThinkingReplyMode? thinkingReplyMode,
    List<String>? tags,
    String? projectId,
    String? sandbox,
    List<SessionMessage>? extraMessages,
  }) async {
    final resolvedProvider = providerId ?? config.currentProviderId;
    final provider = providerById(resolvedProvider);
    final resolvedProject = projectId ?? '';
    final id = newId();
    final project = resolvedProject.isEmpty ? null : projectById(resolvedProject);
    final resolvedSandbox = (sandbox != null && sandbox.trim().isNotEmpty)
        ? paths.resolveSandbox(sandbox)
        : (project != null ? project.sandbox : paths.sessionSandboxDir(id));
    final session = Session(
      id: id,
      sandbox: resolvedSandbox,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      toolCallsLimit: toolCallsLimit ?? config.defaultToolCallsLimit,
      title: title,
      projectId: resolvedProject,
      tags: tags ?? <String>[],
      provider: resolvedProvider,
      model: model ?? (config.currentModel.isNotEmpty ? config.currentModel : _defaultModel(provider)),
      thinkingReplyMode: thinkingReplyMode ?? ThinkingReplyMode.auto,
      tools: tools ?? List<String>.of(config.defaultTools),
      params: params ?? config.defaultParams.copyWith(),
      messages: <SessionMessage>[
        SessionMessage(role: MessageRole.system, content: systemPrompt ?? ''),
        ...?extraMessages,
      ],
    );
    await sessionRepository.write(session);
    _sessionCache[session.id] = session;
    await refreshSessions();
    return session;
  }

  String _defaultModel(ProviderConfig provider) =>
      provider.models.isNotEmpty ? provider.models.first : '';

  Future<Session> createFromTemplate(SessionTemplate template) async {
    return createSession(
      title: template.name,
      providerId: template.provider.isNotEmpty ? template.provider : null,
      model: template.model.isNotEmpty ? template.model : null,
      systemPrompt: template.systemPrompt,
      params: template.params.copyWith(),
      tools: List<String>.of(template.tools),
      toolCallsLimit: template.toolCallsLimit,
      thinkingReplyMode: template.thinkingReplyMode,
      tags: List<String>.of(template.tags),
    );
  }

  Future<void> deleteSession(String id) async {
    await sessionRepository.delete(id);
    _sessionCache.remove(id);
    await refreshSessions();
  }

  /// Duplicates a session, keeping only the data that precedes the first turn
  /// (system prompt + settings). The clone gets its own sandbox unless it
  /// belongs to a project.
  Future<Session> cloneSession(Session source) =>
      _cloneSession(source, (full) => full.cloneEmpty(), freshSandbox: true);

  /// Duplicates a session including the first exchange (first user turn and the
  /// assistant reply/tool messages up to the next user turn). The clone keeps
  /// the source sandbox so any referenced files stay available.
  Future<Session> cloneSessionWithFirstTurn(Session source) =>
      _cloneSession(source, (full) => full.cloneWithFirstTurn(),
          freshSandbox: false);

  /// Duplicates a session with its entire conversation. The clone keeps the
  /// source sandbox so the copied history stays usable.
  Future<Session> cloneSessionFull(Session source) =>
      _cloneSession(source, (full) => full.cloneFull(), freshSandbox: false);

  Future<Session> _cloneSession(
    Session source,
    Session Function(Session full) build, {
    required bool freshSandbox,
  }) async {
    final full = await loadFullSession(source.id);
    final clone = build(full);
    clone.sandbox = (freshSandbox && full.projectId.isEmpty)
        ? paths.sessionSandboxDir(clone.id)
        : full.sandbox;
    await sessionRepository.write(clone);
    _sessionCache[clone.id] = clone;
    await refreshSessions();
    return clone;
  }

  /// Renames a session (loads its full content first so messages are preserved).
  Future<void> renameSession(String id, String title) async {
    final session = await loadFullSession(id);
    session.title = title;
    await sessionRepository.write(session);
    await refreshSessions();
  }

  /// Replaces a session's tags.
  Future<void> setSessionTags(String id, List<String> tags) async {
    final session = await loadFullSession(id);
    session.tags = List<String>.of(tags);
    await sessionRepository.write(session);
    await refreshSessions();
  }

  /// Archives or restores a session.
  Future<void> setSessionArchived(String id, bool archived) async {
    final session = await loadFullSession(id);
    session.archivedAt = archived ? DateTime.now() : null;
    await sessionRepository.write(session);
    _sessionCache[id] = session;
    // Refresh the archived list first so the cache entry survives pruning.
    await refreshArchived();
    await refreshSessions();
  }

  /// Generates and persists an LLM-derived title for a session.
  Future<String> autoNameSession(String id) async {
    final session = await loadFullSession(id);
    final providerConfig = providerById(
      session.provider.isNotEmpty ? session.provider : config.currentProviderId,
    );
    final model = session.model.isNotEmpty ? session.model : _defaultModel(providerConfig);
    final title = await generateSessionTitle(
      provider: providerConfig,
      model: model,
      session: session,
    );
    session.title = title;
    await sessionRepository.write(session);
    _sessionCache[id] = session;
    await refreshSessions();
    return title;
  }

  /// Compresses a session via the LLM and creates a new session containing
  /// the same system prompt plus one user/assistant pair:
  /// user = compress prompt, assistant = compressed context.
  Future<Session> compressSession(
    String id,
    String compressPrompt, {
    void Function(String partialText)? onProgress,
    llm.CancelToken? cancel,
  }) async {
    final source = await loadFullSession(id);
    final providerConfig = providerById(
      source.provider.isNotEmpty ? source.provider : config.currentProviderId,
    );
    final model = source.model.isNotEmpty ? source.model : _defaultModel(providerConfig);
    final compressed = await compressSessionContent(
      provider: providerConfig,
      model: model,
      session: source,
      compressPrompt: compressPrompt,
      systemPrompt: source.systemPrompt,
      onProgress: onProgress,
      cancel: cancel,
    );
    final extraMessages = <SessionMessage>[
      SessionMessage(role: MessageRole.user, content: compressPrompt),
      SessionMessage(role: MessageRole.assistant, content: compressed),
    ];
    return createSession(
      title: '${source.title.isEmpty ? '会话' : source.title}（压缩）',
      providerId: source.provider.isNotEmpty ? source.provider : null,
      model: source.model.isNotEmpty ? source.model : null,
      systemPrompt: source.systemPrompt,
      params: source.params.copyWith(),
      tools: List<String>.of(source.tools),
      toolCallsLimit: source.toolCallsLimit,
      thinkingReplyMode: source.thinkingReplyMode,
      tags: List<String>.of(source.tags),
      projectId: source.projectId.isNotEmpty ? source.projectId : null,
      sandbox: source.sandbox,
      extraMessages: extraMessages,
    );
  }

  /// All distinct tags across active sessions (for the list filter).
  List<String> get allTags {
    final tags = <String>{};
    for (final session in sessions) {
      tags.addAll(session.tags.where((t) => t.trim().isNotEmpty));
    }
    final sorted = tags.toList()..sort();
    return sorted;
  }

  // -------------------------------------------------------------- templates

  Future<void> saveTemplate(SessionTemplate template) async {
    await templateRepository.write(template);
    await refreshTemplates();
  }

  Future<void> deleteTemplate(String id) async {
    await templateRepository.delete(id);
    await refreshTemplates();
  }

  // --------------------------------------------------------------- projects

  Future<Project> createProject({
    String name = '',
    String description = '',
    String? sandbox,
    String? providerId,
    String? model,
  }) async {
    final id = newId();
    final now = DateTime.now();
    final project = Project(
      id: id,
      name: name.isEmpty ? '新项目' : name,
      description: description,
      sandbox: (sandbox != null && sandbox.trim().isNotEmpty)
          ? paths.resolveSandbox(sandbox)
          : paths.projectSandboxDir(id),
      createdAt: now,
      updatedAt: now,
      provider: providerId ?? '',
      model: model ?? '',
    );
    await projectRepository.write(project);
    await refreshProjects();
    return project;
  }

  Future<void> saveProject(Project project) async {
    project.sandbox = paths.resolveSandbox(project.sandbox);
    if (project.sandbox.isEmpty) {
      project.sandbox = paths.projectSandboxDir(project.id);
    }
    project.updatedAt = DateTime.now();
    await projectRepository.write(project);
    await refreshProjects();
  }

  /// Archives or restores a project.
  Future<void> setProjectArchived(String id, bool archived) async {
    final project = projectById(id);
    if (project == null) return;
    project.archivedAt = archived ? DateTime.now() : null;
    project.updatedAt = DateTime.now();
    await projectRepository.write(project);
    await refreshProjects();
    await refreshArchivedProjects();
  }

  Future<void> deleteProject(String id) async {
    // Detach sessions so they survive as standalone sessions.
    for (final meta in <Session>[...sessions, ...archivedSessions]) {
      if (meta.projectId == id) {
        final session = await loadFullSession(meta.id);
        session.projectId = '';
        session.sandbox = paths.sessionSandboxDir(session.id);
        await sessionRepository.write(session);
        _sessionCache[session.id] = session;
      }
    }
    await projectRepository.delete(id);
    await refreshProjects();
    await refreshArchivedProjects();
    await refreshSessions();
  }

  // --------------------------------------------------------------- providers

  /// models.dev catalog access (cached snapshot + one-click refresh).
  late final ModelsDevRepository modelsDevRepository = ModelsDevRepository(paths);
  ModelsDevCatalog? modelsDev;

  /// One-click update of all configured providers from models.dev: fresh model
  /// lists, per-model parameters (context window, output cap, reasoning) and —
  /// for untouched endpoints — provider names and base URLs. API keys, headers
  /// and user-customized endpoints are never touched.
  Future<ModelsDevSyncResult> syncModelsDev() async {
    final (catalog, source) = await modelsDevRepository.loadOrRefresh();
    modelsDev = catalog;
    var updated = 0;
    var totalModels = 0;
    final unmatched = <String>[];
    for (final provider in config.providers) {
      final source = catalog.matchFor(provider);
      if (source == null) {
        unmatched.add(provider.name);
        continue;
      }
      final result = applyModelsDev(provider, source);
      updated++;
      totalModels += result.models;
    }
    await saveConfig();
    return ModelsDevSyncResult(
      updatedProviders: updated,
      totalModels: totalModels,
      unmatched: unmatched,
      source: source,
    );
  }

  /// Catalog snapshot for pickers/wizards: network refresh with cache fallback.
  Future<ModelsDevCatalog> loadModelsDev() async {
    final catalog = modelsDev ?? (await modelsDevRepository.loadOrRefresh()).$1;
    modelsDev = catalog;
    return catalog;
  }

  /// Builds a models.dev-filled copy of [draft] for the provider editor
  /// (`full` fill: name, endpoint and reasoning parameters are overwritten and
  /// reviewed before saving). `null` when no catalog entry matches.
  Future<ProviderConfig?> fillFromModelsDev(ProviderConfig draft) async {
    final catalog = await loadModelsDev();
    final source = catalog.matchFor(draft);
    if (source == null) return null;
    final filled = draft.copyWith();
    applyModelsDev(filled, source, full: true);
    return filled;
  }

  Future<void> upsertProvider(ProviderConfig provider) async {
    final index = config.providers.indexWhere((p) => p.id == provider.id);
    if (index >= 0) {
      config.providers[index] = provider;
    } else {
      config.providers.add(provider);
    }
    await saveConfig();
  }

  Future<void> removeProvider(String id) async {
    config.providers.removeWhere((p) => p.id == id);
    if (config.currentProviderId == id) {
      config.currentProviderId = config.providers.isEmpty ? '' : config.providers.first.id;
    }
    await saveConfig();
  }
}
