import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'assistant/brief.dart';
import 'assistant/ha_client.dart';
import 'assistant/panel_style.dart';
import 'assistant/today.dart';
import 'assistant/actual_client.dart';
import 'assistant/spotify_client.dart';
import 'assistant/chat.dart';
import 'assistant/ollama.dart';
import 'assistant/today_panel.dart';
import 'assistant/vikunja_client.dart';
import 'noxo/brain.dart';
import 'noxo/feather.dart';
import 'noxo/noxo_view.dart';
import 'update/updater.dart';
import 'win/win_desktop.dart';
import 'win/native.dart';

Future<void> main(List<String> args) async {
  // The unpacked new version replacing the old one: no window, no tray.
  final install = parseInstallArgs(args);
  if (install != null) {
    await finishInstall(install);
    exit(0);
  }

  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  await acrylic.Window.initialize();

  const options = WindowOptions(
    size: kNoxoWindowSize,
    backgroundColor: Colors.transparent,
    skipTaskbar: true,
    alwaysOnTop: true,
    titleBarStyle: TitleBarStyle.hidden,
    title: 'Noxo',
  );
  final desktop = WinDesktop(WinDesktop.findOwnWindow());
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setHasShadow(false);
    await windowManager.setResizable(false);
    await acrylic.Window.setEffect(effect: acrylic.WindowEffect.transparent);
    desktop.makeLayered();
    desktop.setClickThrough(true);
    // Inactive: Noxo must not take the focus from the app in use.
    await windowManager.show(inactive: true);
  });

  _keepNoxSettings();
  final prefs = await SharedPreferences.getInstance();
  final mode = prefs.getString('mode') == 'espiegle' ? NoxoMode.espiegle : NoxoMode.sage;

  await _moveNoxStartup();
  launchAtStartup.setup(appName: 'Noxo', appPath: Platform.resolvedExecutable);

  final pranks = {
    for (final prank in NoxoPrank.values)
      if (prefs.getBool('prank_${prank.name}') ?? true) prank,
  };

  final brain = NoxoBrain(mode: mode, pranks: pranks)
    ..scale = desktop.scale()
    ..workMode = prefs.getBool('work') ?? false
    ..nestX = prefs.getDouble('nest_x') ?? 0.5
    ..nestBottom = prefs.getBool('nest_bottom') ?? false;
  final feather = renderFeather(desktop.scale());
  desktop.setFeatherImage(feather.bgra, feather.width, feather.height);
  brain.spawn(desktop, desktop.cursor());

  runApp(NoxoApp(brain: brain, desktop: desktop, prefs: prefs));
}

class NoxoApp extends StatefulWidget {
  const NoxoApp({super.key, required this.brain, required this.desktop, required this.prefs});

  final NoxoBrain brain;
  final WinDesktop desktop;
  final SharedPreferences prefs;

  @override
  State<NoxoApp> createState() => _NoxoAppState();
}

class _NoxoAppState extends State<NoxoApp> with TrayListener {
  bool _startup = false;

  /// Folded sections of the panel and the dashboard of the "Maison" tab.
  late final _panelMemory = PanelMemory(
    read: widget.prefs.getString,
    write: (key, value) => widget.prefs.setString(key, value),
  );

  /// An update Noxo is offering, waiting for a yes or a no.
  UpdateInfo? _update;
  bool _installing = false;

  /// Why the last accepted update did not install.
  String? _updateError;
  Timer? _cleanUpdate;
  Timer? _firstCheck;
  Timer? _dailyCheck;

  // "Aujourd'hui" panel.
  bool _panelOpen = false;

  // Chat (kept until the owl quits).
  bool _panelChat = false;
  final List<ChatMessage> _chat = [];
  String? _conversationId;
  bool _thinking = false;

  /// The PC AI's answer as it is being written.
  String _partial = '';

  /// The PC's model is held in memory while the island's chat is open.
  bool _modelHeld = false;
  Timer? _outsideClick;
  TodayData? _today;
  bool _todayLoading = false;
  Timer? _todayTimer;

  // Morning brief.
  Brief? _brief;
  bool _briefing = false;
  DateTime? _lastBriefTry;
  Timer? _briefTimer;

  String get _haUrl => widget.prefs.getString('ha_url') ?? '';
  String get _haToken => widget.prefs.getString('ha_token') ?? '';
  String get _haAgent => widget.prefs.getString('ha_agent') ?? '';
  bool get _haConfigured => _haUrl.isNotEmpty && _haToken.isNotEmpty;

  Future<void> _sendChat(String text) async {
    if (_thinking) return;
    setState(() {
      _chat.add(ChatMessage(text: text, fromUser: true));
      _thinking = true;
    });
    ChatMessage? answer;
    // Chosen in the settings: the AI on this PC first, Home Assistant if it fails.
    ChatMessage? local;
    if (_offlineFirst) {
      local = await _askOfflineAi("Noxo n'a pas pu répondre");
      if (!local.error) answer = local;
    }
    var haProblem = "Noxo n'est pas relié à Home Assistant";
    if (answer == null && _haConfigured) {
      try {
        final reply = await HaClient(
          _haUrl,
          _haToken,
        ).converse(text, conversationId: _conversationId, agentId: await _chatAgent());
        _conversationId = reply.conversationId ?? _conversationId;
        answer = ChatMessage(text: reply.text, fromUser: false);
      } on HaException catch (e) {
        haProblem = e.message;
      } catch (_) {
        haProblem = 'Home Assistant est injoignable';
      }
    }
    // Home Assistant away: the AI on this PC answers instead.
    final message =
        answer ??
        (local != null
            ? ChatMessage(text: '$haProblem et l\'IA du PC ne répond pas.', fromUser: false, error: true)
            : await _askOfflineAi(haProblem));
    if (!mounted) return;
    setState(() {
      _chat.add(message);
      _thinking = false;
      _partial = '';
    });
  }

  bool get _offlineFirst => widget.prefs.getBool('ollama_first') ?? false;

  Future<void> _saveOfflineFirst(bool value) async {
    await widget.prefs.setBool('ollama_first', value);
    if (mounted) setState(() {});
  }

  String get _offlineModel => widget.prefs.getString('ollama_model') ?? kDefaultOllamaModel;

  /// Ollama and its model, installed by Noxo himself.
  final _offlineAi = OllamaSetup();
  Timer? _offlineAiTimer;

  Future<ChatMessage> _askOfflineAi(String haProblem) async {
    try {
      if (!await _offlineAi.start()) throw const OllamaException('Ollama absent');
      final home = _haConfigured ? HaClient(_haUrl, _haToken) : null;
      final held = _modelHeld;
      final text = await _offlineAi.client.chat(
        _offlineModel,
        ollamaMessages(_chat, DateTime.now(), home: home != null),
        home: home,
        keepAlive: held ? -1 : null,
        onText: (text) {
          if (mounted) setState(() => _partial = text);
        },
      );
      // The island was closed meanwhile: the answer must not keep it loaded.
      if (held && !_modelHeld) unawaited(_releaseModel(force: true));
      return ChatMessage(text: text, fromUser: false, source: 'IA du PC');
    } catch (_) {
      final why = _offlineAi.busy ? "l'IA du PC est en cours d'installation" : "l'IA du PC ne répond pas";
      return ChatMessage(text: '$haProblem et $why.', fromUser: false, error: true);
    }
  }

  /// Island clicked: the PC's model gets loaded, so the first answer is quick.
  Future<void> _holdModel() async {
    _modelHeld = true;
    try {
      if (_offlineAi.busy || !await _offlineAi.start() || !_modelHeld) return;
      await _offlineAi.client.load(_offlineModel);
      // Closed while it was loading.
      if (!_modelHeld) await _offlineAi.client.unload(_offlineModel);
    } catch (_) {
      // Loaded at the first question instead.
    }
  }

  /// Island closed: the model leaves the memory.
  Future<void> _releaseModel({bool force = false}) async {
    if (!_modelHeld && !force) return;
    _modelHeld = false;
    try {
      if (await _offlineAi.client.running()) await _offlineAi.client.unload(_offlineModel);
    } catch (_) {
      // Ollama frees it by itself after a few minutes.
    }
  }

  Future<void> _saveOfflineModel(String model) async {
    final chosen = model.isEmpty ? kDefaultOllamaModel : model;
    await widget.prefs.setString('ollama_model', chosen);
    if (mounted) setState(() {});
    unawaited(_offlineAi.ensure(chosen));
  }

  /// At startup, then every hour until it is done.
  void _installOfflineAi() {
    if (!_offlineAi.ready) unawaited(_offlineAi.ensure(_offlineModel));
  }

  /// Agent of Home Assistant's preferred voice assistant, looked up again
  /// every 10 minutes ('' for the built-in Assist).
  String? _pipelineAgent;
  DateTime? _pipelineAgentAt;

  /// The agent chosen in the settings, else Home Assistant's default one.
  Future<String> _chatAgent() async {
    if (_haAgent.isNotEmpty) return _haAgent;
    final at = _pipelineAgentAt;
    final cached = _pipelineAgent;
    final fresh = at != null && DateTime.now().difference(at) < const Duration(minutes: 10);
    if (cached != null && fresh) return cached;
    try {
      _pipelineAgent = await HaClient(_haUrl, _haToken).defaultAgent() ?? '';
      _pipelineAgentAt = DateTime.now();
    } catch (_) {
      // Unknown: Home Assistant picks.
    }
    final agent = _pipelineAgent ?? '';
    if (agent != cached) _conversationId = null;
    return agent;
  }

  Future<void> _saveAgent(String agent) async {
    if (agent == _haAgent) return;
    await widget.prefs.setString('ha_agent', agent);
    _conversationId = null;
  }

  void _loadCachedToday() {
    final cached = widget.prefs.getString('today_cache');
    if (cached == null) return;
    try {
      _today = TodayData.fromJson(jsonDecode(cached));
    } on FormatException {
      _today = null;
    }
  }

  /// Reads today's data from Home Assistant; keeps the last one if it fails.
  Future<void> _refreshToday() async {
    if (!_haConfigured || _todayLoading) return;
    setState(() => _todayLoading = true);
    try {
      final data = await HaClient(_haUrl, _haToken).fetchToday(DateTime.now());
      _today = data;
      await widget.prefs.setString('today_cache', jsonEncode(data.toJson()));
    } catch (_) {
      // Offline: the cached day stays; the tabs show their own errors.
    }
    if (!mounted) return;
    setState(() => _todayLoading = false);
  }

  void _loadBrief() {
    final saved = widget.prefs.getString('brief');
    if (saved == null) return;
    try {
      _brief = Brief.fromJson(jsonDecode(saved));
    } on FormatException {
      _brief = null;
    }
  }

  /// Today's brief, if there is one.
  Brief? get _todayBrief {
    final brief = _brief;
    return brief != null && brief.day == dayKey(DateTime.now()) ? brief : null;
  }

  /// Noxo holds an envelope while he has news: an update or an unread brief.
  void _updateCarrying() {
    final brief = _todayBrief;
    widget.brain.carrying = _update != null || (brief != null && !brief.read);
  }

  /// At the first sign of life of the day, Noxo fetches the day and brings
  /// the brief. Checked every minute.
  Future<void> _checkBrief() async {
    // Yesterday's unread brief is no longer news.
    _updateCarrying();
    final now = DateTime.now();
    if (!_haConfigured || _briefing) return;
    if (!briefDue(now, _brief?.day)) return;
    // Someone must be there to receive it.
    if (widget.brain.sleeping || widget.desktop.idleMillis() > 60000) return;
    final last = _lastBriefTry;
    if (last != null && now.difference(last) < const Duration(minutes: 15)) return;
    _lastBriefTry = now;
    _briefing = true;
    try {
      await _refreshToday();
      final data = _today;
      // Without today's data (Home Assistant unreachable), try again later.
      if (data == null || !isFromToday(data, now)) return;
      final ai = await HaClient(_haUrl, _haToken).aiBrief(data, now);
      final brief = Brief(day: dayKey(now), text: ai ?? offlineBrief(data, now), byAi: ai != null);
      _brief = brief;
      await widget.prefs.setString('brief', jsonEncode(brief.toJson()));
      if (!mounted) return;
      _updateCarrying();
      await _refreshMenu();
    } finally {
      _briefing = false;
    }
  }

  Future<void> _markBriefRead() async {
    final brief = _todayBrief;
    if (brief == null || brief.read) return;
    _brief = brief.markRead();
    await widget.prefs.setString('brief', jsonEncode(_brief!.toJson()));
    _updateCarrying();
    await _refreshMenu();
  }

  Future<String?> _saveHaSettings(String url, String token) async {
    final base = normalizeHaUrl(url);
    if (base == null) return 'Adresse invalide.';
    final secret = token.trim().isEmpty ? _haToken : token.trim();
    if (secret.isEmpty) return 'Il manque le jeton.';
    try {
      await HaClient(base, secret).ping();
    } on HaException catch (e) {
      return e.message;
    } catch (_) {
      return 'Home Assistant injoignable à cette adresse.';
    }
    await widget.prefs.setString('ha_url', base);
    await widget.prefs.setString('ha_token', secret);
    unawaited(_refreshToday());
    return null;
  }

  String get _vikunjaUrl => widget.prefs.getString('vikunja_url') ?? '';
  String get _vikunjaToken => widget.prefs.getString('vikunja_token') ?? '';

  Future<String?> _saveVikunjaSettings(String url, String token) async {
    final base = normalizeVikunjaUrl(url);
    if (base == null) return 'Adresse invalide.';
    final secret = token.trim().isEmpty ? _vikunjaToken : token.trim();
    if (secret.isEmpty) return 'Il manque le jeton.';
    try {
      await VikunjaClient(base, secret).ping();
    } on VikunjaException catch (e) {
      return e.message;
    } catch (_) {
      return 'Vikunja injoignable à cette adresse.';
    }
    await widget.prefs.setString('vikunja_url', base);
    await widget.prefs.setString('vikunja_token', secret);
    if (mounted) setState(() {});
    return null;
  }

  String get _actualUrl => widget.prefs.getString('actual_url') ?? '';
  String get _actualKey => widget.prefs.getString('actual_key') ?? '';
  String get _actualSyncId => widget.prefs.getString('actual_sync_id') ?? '';
  String get _actualPassword => widget.prefs.getString('actual_password') ?? '';

  ActualClient? get _actual =>
      _actualUrl.isNotEmpty && _actualKey.isNotEmpty && _actualSyncId.isNotEmpty
      ? ActualClient(_actualUrl, _actualKey, _actualSyncId, password: _actualPassword)
      : null;

  Future<String?> _saveActualSettings(
    String url,
    String key,
    String syncId,
    String password,
  ) async {
    final base = normalizeActualUrl(url);
    if (base == null) return 'Adresse invalide.';
    final secret = key.trim().isEmpty ? _actualKey : key.trim();
    if (secret.isEmpty) return 'Il manque la clé d\'API.';
    final budget = syncId.trim();
    if (budget.isEmpty) return 'Il manque l\'ID de synchronisation du budget.';
    final pass = password.isEmpty ? _actualPassword : password;
    try {
      await ActualClient(base, secret, budget, password: pass).ping();
    } on ActualException catch (e) {
      return e.message;
    } catch (_) {
      return 'actual-http-api injoignable à cette adresse.';
    }
    await widget.prefs.setString('actual_url', base);
    await widget.prefs.setString('actual_key', secret);
    await widget.prefs.setString('actual_sync_id', budget);
    await widget.prefs.setString('actual_password', pass);
    if (mounted) setState(() {});
    return null;
  }

  /// Kept while Noxo runs, so its access token is reused.
  late SpotifyClient? _spotify = _makeSpotify();

  SpotifyClient? _makeSpotify() {
    final id = widget.prefs.getString('spotify_client_id') ?? '';
    final refresh = widget.prefs.getString('spotify_refresh') ?? '';
    if (id.isEmpty || refresh.isEmpty) return null;
    return SpotifyClient(
      id,
      refresh,
      onNewRefreshToken: (token) => widget.prefs.setString('spotify_refresh', token),
    );
  }

  Future<String?> _spotifyLogin(String clientId) async {
    if (clientId.isEmpty) return 'Il manque le Client ID.';
    try {
      final refresh = await SpotifyClient.login(clientId);
      await widget.prefs.setString('spotify_client_id', clientId);
      await widget.prefs.setString('spotify_refresh', refresh);
    } on SpotifyException catch (e) {
      return e.message;
    } catch (_) {
      return 'Spotify injoignable.';
    }
    if (mounted) setState(() => _spotify = _makeSpotify());
    // The browser took the focus: the panel comes back to the front.
    if (_panelOpen) widget.desktop.bringToFront();
    return null;
  }

  Future<void> _spotifyLogout() async {
    await widget.prefs.remove('spotify_refresh');
    if (mounted) setState(() => _spotify = null);
  }

  /// [chat]: the owl was called from his island, the panel opens on the chat.
  void _openPanel({bool chat = false}) {
    if (_panelOpen) return;
    widget.desktop.enterPanel(widget.brain.pos, kPanelSize);
    setState(() {
      _panelOpen = true;
      _panelChat = chat;
    });
    if (chat) unawaited(_holdModel());
    _watchOutsideClick();
    unawaited(_markBriefRead());
    unawaited(_refreshToday());
  }

  /// A click anywhere outside the panel closes it.
  void _watchOutsideClick() {
    _outsideClick?.cancel();
    // A button still held from the click that opened the panel is ignored.
    var wasDown = true;
    _outsideClick = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final down = widget.desktop.leftButtonDown();
      if (down && !wasDown && !widget.desktop.ownRect().contains(widget.desktop.cursor())) {
        _closePanel();
      }
      wasDown = down;
    });
  }

  void _closePanel() {
    _outsideClick?.cancel();
    _outsideClick = null;
    if (!_panelOpen) return;
    widget.desktop.leavePanel(kNoxoWindowSize);
    setState(() => _panelOpen = false);
    unawaited(_releaseModel());
  }

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    _initTray();
    _firstCheck = Timer(const Duration(seconds: 20), _checkForUpdate);
    _dailyCheck = Timer.periodic(const Duration(hours: 24), (_) => _checkForUpdate());
    _loadCachedToday();
    // Keeps the offline cache fresh even when the panel stays closed.
    _todayTimer = Timer.periodic(const Duration(minutes: 30), (_) => _refreshToday());
    _firstToday = Timer(const Duration(seconds: 5), _refreshToday);
    _loadBrief();
    _updateCarrying();
    // Lets the installer that started this Noxo finish before cleaning up.
    _cleanUpdate = Timer(const Duration(seconds: 30), cleanUpdate);
    _briefTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkBrief());
    _firstOfflineAi = Timer(const Duration(seconds: 15), _installOfflineAi);
    _offlineAiTimer = Timer.periodic(const Duration(hours: 1), (_) => _installOfflineAi());
  }

  Timer? _firstToday;

  /// Looks for a newer build; if there is one, Noxo brings it as news.
  /// [manual] also re-offers a build that was declined before.
  Future<void> _checkForUpdate({bool manual = false}) async {
    if (_installing) return;
    final update = await checkForUpdate();
    if (!mounted) return;
    final declined = widget.prefs.getInt('update_declined') ?? 0;
    if (update == null || (!manual && update.build <= declined)) return;
    _update = update;
    _updateCarrying();
    await _refreshMenu();
  }

  Future<void> _answerUpdate(bool accept) async {
    final update = _update;
    if (update == null || _installing) return;
    if (!accept) {
      _update = null;
      _updateCarrying();
      await widget.prefs.setInt('update_declined', update.build);
      await _refreshMenu();
      return;
    }
    _installing = true;
    _updateError = null;
    await _refreshMenu();
    final error = await downloadAndInstall(update);
    if (error == null) {
      await _quit();
      return;
    }
    // Keep the offer so it can be tried again.
    _updateError = error;
    _installing = false;
    await _refreshMenu();
  }

  Future<void> _quit() async {
    await trayManager.destroy();
    await windowManager.destroy();
    exit(0);
  }

  Future<void> _initTray() async {
    try {
      _startup = await launchAtStartup.isEnabled();
    } catch (_) {
      _startup = false;
    }
    await trayManager.setIcon('assets/noxo.ico');
    await trayManager.setToolTip('Noxo veille');
    await _refreshMenu();
  }

  /// Sends Noxo to his nest (the island at the top of the screen) or out.
  Future<void> _toggleNest() async {
    final on = !widget.brain.workMode;
    widget.brain.setWorkMode(on, widget.desktop);
    await widget.prefs.setBool('work', on);
    await _refreshMenu();
  }

  Future<void> _refreshMenu() async {
    final mode = widget.brain.mode;
    final update = _update;
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            key: 'title',
            label: kNoxoBuild > 0 ? 'Noxo — version $kNoxoBuild' : 'Noxo — version locale',
            disabled: true,
          ),
          MenuItem.separator(),
          if (update != null) ...[
            MenuItem(
              key: 'update_title',
              label: _installing
                  ? 'Mise à jour en cours…'
                  : 'Noxo apporte une mise à jour (version ${update.build})',
              disabled: true,
            ),
            if (_updateError != null && !_installing)
              MenuItem(key: 'update_error', label: _updateError, disabled: true),
            if (!_installing) MenuItem(key: 'update_accept', label: 'Accepter'),
            if (!_installing) MenuItem(key: 'update_decline', label: 'Refuser'),
            MenuItem.separator(),
          ],
          MenuItem.checkbox(key: 'sage', label: 'Mode sage', checked: mode == NoxoMode.sage),
          MenuItem.checkbox(
            key: 'espiegle',
            label: 'Mode espiègle',
            checked: mode == NoxoMode.espiegle,
          ),
          MenuItem.separator(),
          MenuItem(key: 'pranks', label: 'Bêtises (mode espiègle)', disabled: true),
          for (final prank in NoxoPrank.values)
            MenuItem.checkbox(
              key: 'prank_${prank.name}',
              label: _prankLabels[prank]!,
              checked: widget.brain.pranks.contains(prank),
            ),
          MenuItem.separator(),
          MenuItem.checkbox(
            key: 'work',
            label: 'Nichoir (mode travail)',
            checked: widget.brain.workMode,
          ),
          MenuItem(
            key: 'today',
            label: _todayBrief?.read == false ? "Aujourd'hui (brief à lire)" : "Aujourd'hui",
          ),
          MenuItem(key: 'recall', label: 'Rappeler Noxo'),
          MenuItem.checkbox(
            key: 'startup',
            label: 'Lancer au démarrage de Windows',
            checked: _startup,
          ),
          if (update == null) MenuItem(key: 'update_check', label: 'Rechercher une mise à jour'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quitter'),
        ],
      ),
    );
  }

  static const _prankLabels = {
    NoxoPrank.chase: 'Chasser le curseur',
    NoxoPrank.feather: 'Laisser une plume',
    NoxoPrank.peck: 'Picorer une icône',
    NoxoPrank.push: 'Pousser la fenêtre',
  };

  Future<void> _togglePrank(NoxoPrank prank) async {
    final pranks = widget.brain.pranks;
    final on = !pranks.contains(prank);
    on ? pranks.add(prank) : pranks.remove(prank);
    await widget.prefs.setBool('prank_${prank.name}', on);
    await _refreshMenu();
  }

  Future<void> _setMode(NoxoMode mode) async {
    widget.brain.mode = mode;
    await widget.prefs.setString('mode', mode.name);
    await _refreshMenu();
  }

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    for (final prank in NoxoPrank.values) {
      if (menuItem.key == 'prank_${prank.name}') {
        await _togglePrank(prank);
        return;
      }
    }
    switch (menuItem.key) {
      case 'sage':
        await _setMode(NoxoMode.sage);
      case 'espiegle':
        await _setMode(NoxoMode.espiegle);
      case 'today':
        _panelOpen ? _closePanel() : _openPanel();
      case 'work':
        await _toggleNest();
      case 'recall':
        _closePanel();
        if (widget.brain.workMode) {
          widget.brain.setWorkMode(false, widget.desktop);
          await widget.prefs.setBool('work', false);
          await _refreshMenu();
        }
        widget.brain.recall(widget.desktop, widget.desktop.cursor());
      case 'startup':
        _startup ? await launchAtStartup.disable() : await launchAtStartup.enable();
        _startup = await launchAtStartup.isEnabled();
        await _refreshMenu();
      case 'update_accept':
        await _answerUpdate(true);
      case 'update_decline':
        await _answerUpdate(false);
      case 'update_check':
        await _checkForUpdate(manual: true);
      case 'quit':
        await _quit();
    }
  }

  Timer? _firstOfflineAi;

  @override
  void dispose() {
    _firstOfflineAi?.cancel();
    _offlineAiTimer?.cancel();
    _offlineAi.dispose();
    _firstCheck?.cancel();
    _dailyCheck?.cancel();
    _todayTimer?.cancel();
    _firstToday?.cancel();
    _briefTimer?.cancel();
    _cleanUpdate?.cancel();
    _outsideClick?.cancel();
    trayManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFF2B53A),
        useMaterial3: true,
      ),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: _panelOpen
            ? TodayPanel(
                now: DateTime.now(),
                data: _today,
                brief: _todayBrief,
                configured: _haConfigured,
                haUrl: _haUrl,
                client: _haConfigured ? HaClient(_haUrl, _haToken) : null,
                vikunjaUrl: _vikunjaUrl,
                vikunja: _vikunjaUrl.isNotEmpty && _vikunjaToken.isNotEmpty
                    ? VikunjaClient(_vikunjaUrl, _vikunjaToken)
                    : null,
                onSaveVikunja: _saveVikunjaSettings,
                spotify: _spotify,
                spotifyClientId: widget.prefs.getString('spotify_client_id') ?? '',
                onSpotifyLogin: _spotifyLogin,
                onSpotifyLogout: _spotifyLogout,
                actualUrl: _actualUrl,
                actualSyncId: _actualSyncId,
                actual: _actual,
                onSaveActual: _saveActualSettings,
                onRefresh: _refreshToday,
                onClose: _closePanel,
                onSaveSettings: _saveHaSettings,
                memory: _panelMemory,
                startInChat: _panelChat,
                messages: List.unmodifiable(_chat),
                thinking: _thinking,
                partial: _partial,
                onSend: _sendChat,
                haAgent: _haAgent,
                onSaveAgent: _saveAgent,
                offlineAi: _offlineAi,
                offlineModel: _offlineModel,
                onSaveOfflineModel: _saveOfflineModel,
                offlineFirst: _offlineFirst,
                onOfflineFirst: _saveOfflineFirst,
              )
            : NoxoView(
                brain: widget.brain,
                desktop: widget.desktop,
                onMouseOver: (over) => widget.desktop.setClickThrough(!over),
                onDoubleClick: _openPanel,
                onCall: () => _openPanel(chat: true),
                onToggleNest: _toggleNest,
                onNestMoved: () {
                  widget.prefs.setDouble('nest_x', widget.brain.nestX);
                  widget.prefs.setBool('nest_bottom', widget.brain.nestBottom);
                },
              ),
      ),
    );
  }
}

/// Settings saved under the old name "Nox" (tokens, servers…) are copied to
/// Noxo's folder the first time Noxo starts.
void _keepNoxSettings() {
  final appData = Platform.environment['APPDATA'];
  if (!Platform.isWindows || appData == null) return;
  const file = 'shared_preferences.json';
  final now = File('$appData\\fr.noxo\\noxo\\$file');
  final before = File('$appData\\fr.nox\\nox\\$file');
  try {
    if (now.existsSync() || !before.existsSync()) return;
    now.parent.createSync(recursive: true);
    before.copySync(now.path);
  } on FileSystemException {
    // Noxo starts with fresh settings.
  }
}

/// Replaces the old "Nox" launch at Windows startup by Noxo's.
Future<void> _moveNoxStartup() async {
  try {
    if (!Platform.isWindows || !hasStartupEntry('Nox')) return;
    launchAtStartup.setup(appName: 'Nox', appPath: Platform.resolvedExecutable);
    await launchAtStartup.disable();
    launchAtStartup.setup(appName: 'Noxo', appPath: Platform.resolvedExecutable);
    await launchAtStartup.enable();
  } catch (_) {
    // Left as it is: can be set again from the menu.
  }
}
