import 'package:flutter/foundation.dart';
import 'package:llm_api/llm_api.dart' as llm;
import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/ids.dart';
import '../core/prompt_utils.dart';
import '../data/config_repository.dart';
import '../data/index_repository.dart';
import '../data/models_dev_repository.dart';
import '../data/project_repository.dart';
import '../data/session_repository.dart';
import '../data/template_repository.dart';
import '../llm/session_compressor.dart';
import '../llm/session_namer.dart';
import '../models/agent_mode.dart';
import '../models/app_config.dart';
import '../models/models_dev.dart';
import '../models/project.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_message.dart';
import '../models/session_params.dart';
import '../models/session_template.dart';
import '../session/session_controller.dart';
import 'approval_center.dart';

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

  /// Ids of sessions that exist in memory but are not on disk yet (their
  /// write is still in flight). They stay in the session list so the UI can
  /// open them immediately.
  final Set<String> _pendingSessions = <String>{};

  /// Live session controllers, keyed by session id. A controller (and the
  /// agent turn it drives) outlives the chat panel: switching to another
  /// session no longer disposes — and therefore stops — the previous one, so
  /// multiple sessions can work at the same time.
  final Map<String, SessionController> _controllers = <String, SessionController>{};

  /// Ids of sessions with a currently running agent turn (sidebar spinner).
  final Set<String> _runningSessionIds = <String>{};

  /// Ids of sessions whose agent turn is running right now.
  Set<String> get runningSessionIds => Set<String>.unmodifiable(_runningSessionIds);

  /// Global tool-approval queue: collects pending approvals from every session
  /// so the approval window works no matter which session is visible.
  late final ApprovalCenter approvalCenter = ApprovalCenter();

  @override
  void dispose() {
    approvalCenter.dispose();
    super.dispose();
  }

  /// Returns the live controller for [sessionId], creating (and opening) it
  /// on first use. The controller is owned by this store, not by the panel.
  SessionController controllerFor(String sessionId) {
    final existing = _controllers[sessionId];
    if (existing != null) return existing;
    final session = sessionById(sessionId);
    if (session == null) throw StateError('会话不存在：$sessionId');
    final controller = SessionController(
      repository: sessionRepository,
      config: config,
      providerResolver: providerById,
    );
    controller.open(session);
    controller.addListener(_onControllerChanged);
    _controllers[sessionId] = controller;
    return controller;
  }

  /// Re-broadcasts controller notifications only when the *running* set
  /// actually changes, so stream deltas don't rebuild the whole app.
  void _onControllerChanged() {
    var changed = false;
    for (final entry in _controllers.entries) {
      final shouldMark = entry.value.isRunning;
      final marked = _runningSessionIds.contains(entry.key);
      if (shouldMark && !marked) {
        _runningSessionIds.add(entry.key);
        changed = true;
      } else if (!shouldMark && marked) {
        _runningSessionIds.remove(entry.key);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Repairs the global provider / model selection.
  ///
  /// A provider may be removed, or its model list refreshed by a catalogue
  /// sync, while the config still points at the old model. The model dropdowns
  /// would then hold a value that matches no item and the UI throws, so the
  /// selection is normalized here — every page sees a valid pair.
  ///
  /// Returns true when something was repaired (the caller persists it).
  bool _sanitizeConfig() {
    if (config.providers.isEmpty) return false;
    var changed = false;
    if (!config.providers.any((p) => p.id == config.currentProviderId)) {
      config.currentProviderId = config.providers.first.id;
      changed = true;
    }
    final provider = providerById(config.currentProviderId);
    // A provider without a model list is fine: the model is then typed by hand.
    if (provider.models.isEmpty) return changed;
    if (config.currentModel.isEmpty ||
        !provider.models.contains(config.currentModel)) {
      config.currentModel = provider.models.first;
      changed = true;
    }
    return changed;
  }

  Future<void> load() async {
    config = await configRepository.load();
    // Self-heal a stale provider/model selection and persist the repair.
    if (_sanitizeConfig()) await configRepository.save(config);
    // Local catalog snapshot only (no network on startup): it drives the
    // per-model reasoning options offered in the session toolbar.
    modelsDev = await modelsDevRepository.loadCached();
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
    // A session whose write is still in flight is not on disk yet — keep it
    // visible so the panel opened for it does not lose it.
    for (final id in _pendingSessions) {
      final pending = _sessionCache[id];
      if (pending != null && !sessions.any((s) => s.id == id)) {
        sessions = [pending, ...sessions];
      }
    }
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
    final keep = <String>{
      ...activeIds,
      ...archivedSessions.map((s) => s.id),
      ..._pendingSessions,
    };
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

  /// Provider/model used for app-level LLM features (session auto-naming,
  /// prompt generation/polish): the service & model selected on the 模型服务 page.
  (ProviderConfig, String) get appFeatureTarget {
    final provider = providerById(config.currentProviderId);
    final model =
        config.currentModel.isNotEmpty ? config.currentModel : _defaultModel(provider);
    return (provider, model);
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
    AgentMode? mode,
    bool? webSearchEnabled,
  }) async {
    final session = createSessionDraft(
      title: title,
      providerId: providerId,
      model: model,
      systemPrompt: systemPrompt,
      params: params,
      tools: tools,
      toolCallsLimit: toolCallsLimit,
      thinkingReplyMode: thinkingReplyMode,
      tags: tags,
      projectId: projectId,
      sandbox: sandbox,
      extraMessages: extraMessages,
      mode: mode,
      webSearchEnabled: webSearchEnabled,
    );
    await persistSession(session);
    return session;
  }

  /// Creates a session and registers it in the in-memory catalog *without*
  /// touching the disk.
  ///
  /// The home page opens the chat panel from the returned session right away
  /// and persists it with [persistSession] in the background, so the first
  /// paint is not delayed by the disk write.
  Session createSessionDraft({
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
    AgentMode? mode,
    bool? webSearchEnabled,
  }) {
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
      mode: mode ?? AgentMode.auto,
      webSearchEnabled: webSearchEnabled ?? true,
      tools: tools ?? List<String>.of(config.defaultTools),
      params: params ?? config.defaultParams.copyWith(),
      messages: <SessionMessage>[
        // The workspace-root line (`工作空间根目录: <绝对路径>`) is written to the
        // top of the system prompt automatically; users never type it (nor the
        // old `工作空间根目录: {sandbox}` placeholder) themselves.
        SessionMessage(
          role: MessageRole.system,
          content: injectWorkspaceRoot(systemPrompt ?? '', resolvedSandbox),
        ),
        ...?extraMessages,
      ],
    );
    // The session is not on disk yet — keep it in the catalog anyway, so the
    // UI can open it before the write completes.
    _pendingSessions.add(session.id);
    _sessionCache[session.id] = session;
    sessions = [session, ...sessions];
    notifyListeners();
    return session;
  }

  /// Writes a session to disk and refreshes the catalog index.
  ///
  /// On failure the session stays "pending": it is still usable in memory
  /// (the agent writes it on its first turn), so it must not vanish from
  /// the session list.
  Future<void> persistSession(Session session) async {
    await sessionRepository.write(session);
    _pendingSessions.remove(session.id);
    await refreshSessions();
  }

  String _defaultModel(ProviderConfig provider) =>
      provider.models.isNotEmpty ? provider.models.first : '';

  /// Creates a session from a template without touching the disk — see
  /// [createSessionDraft].
  Session createFromTemplateDraft(
    SessionTemplate template, {
    String? projectId,
    String? sandbox,
    AgentMode? mode,
  }) {
    return createSessionDraft(
      // 模板名不作为会话标题；标题为空时由 LLM 自动命名。
      title: '',
      providerId: template.provider.isNotEmpty ? template.provider : null,
      model: template.model.isNotEmpty ? template.model : null,
      systemPrompt: template.systemPrompt,
      params: template.params.copyWith(),
      tools: List<String>.of(template.tools),
      toolCallsLimit: template.toolCallsLimit,
      thinkingReplyMode: template.thinkingReplyMode,
      tags: List<String>.of(template.tags),
      projectId: projectId,
      sandbox: sandbox,
      mode: mode,
    );
  }

  Future<void> deleteSession(String id) async {
    await sessionRepository.delete(id);
    _sessionCache.remove(id);
    _pendingSessions.remove(id);
    _controllers.remove(id)?.dispose();
    _runningSessionIds.remove(id);
    // A pending approval of the deleted session can never be answered.
    approvalCenter.dropForSession(id);
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

  /// Generates and persists an LLM-derived title from the session's first turn.
  ///
  /// [byAppModel] selects the caller: the automatic naming at the first turn
  /// runs on the session's own model; the manual「AI 自动命名」menu runs on the
  /// app default model (the「应用功能调用模型」picked on the 模型服务 page).
  /// Each side falls back to the other when its model is unconfigured.
  Future<String> _titleFromFirstTurn(String id, {required bool byAppModel}) async {
    final session = await loadFullSession(id);
    final (appProvider, appModel) = appFeatureTarget;
    final sessionProvider = providerById(
      session.provider.isNotEmpty ? session.provider : config.currentProviderId,
    );
    final sessionModel =
        session.model.isNotEmpty ? session.model : _defaultModel(sessionProvider);
    final useApp = byAppModel ? appModel.isNotEmpty : sessionModel.isEmpty;
    final providerConfig = useApp ? appProvider : sessionProvider;
    final model = useApp ? appModel : sessionModel;
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

  ///「AI 自动命名」菜单：首轮对话 user/assistant + 应用默认模型。
  Future<String> autoNameSession(String id) =>
      _titleFromFirstTurn(id, byAppModel: true);

  /// 首轮对话结束后的自动命名：首轮对话 user/assistant + 会话自身模型。
  Future<String> autoNameFirstTurn(String id) =>
      _titleFromFirstTurn(id, byAppModel: false);

  /// Compresses a session via the LLM and creates a new session containing
  /// the same system prompt plus one user/assistant pair:
  /// user = hand-off of the compressed context, assistant = the summary itself.
  ///
  /// The clone inherits the source's working dir, tools and runtime switches,
  /// and is persisted before it is returned, so the caller can rely on it being
  /// a real, re-openable session.
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
    final sourceTitle = source.title.trim();
    final title = '${sourceTitle.isEmpty ? '会话' : sourceTitle}（压缩）';
    final extraMessages = <SessionMessage>[
      SessionMessage(
        role: MessageRole.user,
        id: newShortId(),
        content: buildCompressHandoff(sourceTitle, compressed),
      ),
      SessionMessage(
        role: MessageRole.assistant,
        id: newShortId(),
        content: compressed,
      ),
    ];
    final created = await createSession(
      title: title,
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
      mode: source.mode,
      webSearchEnabled: source.webSearchEnabled,
    );
    created.updatedAt = DateTime.now();
    // Persist explicitly: the compressed session is only useful if it survives
    // a restart, and a failed write must surface as an error, not silently.
    await sessionRepository.write(created);
    if (!await sessionRepository.exists(created.id)) {
      throw StateError('压缩会话写入失败：${paths.sessionFile(created.id)}');
    }
    return created;
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

  /// 默认会话模板（设置里指定）；未配置或模板已被删除时返回 null。
  SessionTemplate? get defaultTemplate {
    final id = config.defaultTemplateId;
    if (id.isEmpty) return null;
    for (final template in templates) {
      if (template.id == id) return template;
    }
    return null;
  }

  Future<void> saveTemplate(SessionTemplate template) async {
    await templateRepository.write(template);
    await refreshTemplates();
  }

  Future<void> deleteTemplate(String id) async {
    await templateRepository.delete(id);
    // 被删除的模板不能再作为默认模板。
    if (config.defaultTemplateId == id) {
      config.defaultTemplateId = '';
      await configRepository.save(config);
    }
    await refreshTemplates();
  }

  /// Enables/disables the template as a quick session on the home page.
  Future<void> setTemplateQuickEnabled(String id, bool enabled) async {
    final template = templates.firstWhere(
      (t) => t.id == id,
      orElse: () => throw StateError('模板不存在：$id'),
    );
    template.quickEnabled = enabled;
    await saveTemplate(template);
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

  /// Returns the project bound to [path], creating it on first use.
  ///
  /// The project name is the last path segment (the folder name); the project
  /// working dir is the folder itself, so its sessions work in that folder.
  Future<Project> ensureProjectForPath(String path) async {
    final resolved = paths.resolveSandbox(path);
    for (final project in [...projects, ...archivedProjects]) {
      if (p.equals(project.sandbox, resolved)) return project;
    }
    final name = p.basename(resolved);
    return createProject(
      name: name.isEmpty ? '新项目' : name,
      description: '工作目录：$resolved',
      sandbox: resolved,
    );
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
    _sanitizeConfig();
    await saveConfig();
  }

  Future<void> removeProvider(String id) async {
    config.providers.removeWhere((p) => p.id == id);
    if (config.currentProviderId == id) {
      config.currentProviderId = config.providers.isEmpty ? '' : config.providers.first.id;
    }
    _sanitizeConfig();
    await saveConfig();
  }
}
