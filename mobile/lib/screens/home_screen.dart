import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../models/service_models.dart';
import '../services/app_store.dart';
import 'catalog_sheet.dart';
import 'settings_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.store,
    required this.onThemeChanged,
  });

  final AppStore store;
  final ValueChanged<bool> onThemeChanged;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _initialized = false;
  bool _isLocked = false;
  List<CategoryMeta> _categories = const [];
  List<CatalogService> _catalog = const [];
  List<ServiceInstance> _instances = [];
  AppSettings _settings = const AppSettings();

  final Map<String, WebViewController> _controllers = {};
  final Map<String, TabRuntimeState> _runtimeMap = {};
  final TextEditingController _unlockPinController = TextEditingController();
  String? _unlockError;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _unlockPinController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final catalogData = await widget.store.loadCatalog();
    final (settings, instances) =
        await widget.store.loadState(catalogData.services);

    for (final inst in instances) {
      _runtimeMap[inst.instanceId] = TabRuntimeState(
        currentUrl: inst.url,
        title: inst.name,
        isSleeping: true,
      );
    }

    if (!mounted) return;
    setState(() {
      _categories = catalogData.categories;
      _catalog = catalogData.services;
      _settings = settings;
      _instances = instances;
      _initialized = true;
    });

    widget.onThemeChanged(settings.isDarkMode);
    _ensureSafeActiveAndLoad();
  }

  List<ServiceInstance> get _visibleInstances => _instances;

  ServiceInstance? get _activeInstance {
    final activeId = _settings.activeInstanceId;
    if (activeId == null) return null;
    for (final inst in _visibleInstances) {
      if (inst.instanceId == activeId) return inst;
    }
    return null;
  }

  int get _totalUnread {
    if (_isLocked) return 0;
    var sum = 0;
    for (final inst in _visibleInstances) {
      if (!inst.notificationsEnabled) continue;
      sum += _runtimeMap[inst.instanceId]?.unreadCount ?? 0;
    }
    return sum;
  }

  void _ensureSafeActiveAndLoad() {
    final visible = _visibleInstances;
    var activeId = _settings.activeInstanceId;
    if (activeId == null || !visible.any((i) => i.instanceId == activeId)) {
      activeId = visible.isNotEmpty ? visible.first.instanceId : null;
      _settings = _settings.copyWith(
        activeInstanceId: activeId,
        clearActive: activeId == null,
      );
      _persist();
    }
    if (activeId != null) {
      final inst = visible.firstWhere((i) => i.instanceId == activeId);
      _ensureController(inst);
    }
    if (mounted) setState(() {});
  }

  Future<void> _persist() async {
    await widget.store.saveState(_settings, _instances);
  }

  WebViewController _ensureController(ServiceInstance instance) {
    final existing = _controllers[instance.instanceId];
    if (existing != null) return existing;

    final PlatformWebViewControllerCreationParams params =
        WebViewPlatform.instance is AndroidWebViewPlatform
            ? AndroidWebViewControllerCreationParams()
            : const PlatformWebViewControllerCreationParams();

    final controller = WebViewController.fromPlatformCreationParams(
      params,
      onPermissionRequest: (request) => request.grant(),
    );

    if (controller.platform is AndroidWebViewController) {
      final androidCtrl = controller.platform as AndroidWebViewController;
      androidCtrl.setMediaPlaybackRequiresUserGesture(false);
      androidCtrl.setGeolocationPermissionsPromptCallbacks(
        onShowPrompt: (_) async => const GeolocationPermissionsResponse(
          allow: true,
          retain: true,
        ),
      );
    }

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(buildUserAgent(instance.uaMode))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            _updateRuntime(
              instance.instanceId,
              (cur) => cur.copyWith(
                progress: progress,
                isLoading: progress < 100,
                isSleeping: false,
              ),
            );
          },
          onPageStarted: (url) {
            _updateRuntime(
              instance.instanceId,
              (cur) => cur.copyWith(
                currentUrl: url,
                isLoading: true,
                isSleeping: false,
                clearError: true,
              ),
            );
          },
          onPageFinished: (url) async {
            final title = await controller.getTitle() ?? instance.name;
            final canBack = await controller.canGoBack();
            final canFwd = await controller.canGoForward();
            final unread = parseUnreadCountFromTitle(title);
            _updateRuntime(
              instance.instanceId,
              (cur) => cur.copyWith(
                currentUrl: url,
                title: title,
                progress: 100,
                unreadCount: unread,
                isLoading: false,
                isSleeping: false,
                canGoBack: canBack,
                canGoForward: canFwd,
              ),
            );
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame != true) return;
            _updateRuntime(
              instance.instanceId,
              (cur) => cur.copyWith(
                isLoading: false,
                loadError: '${error.description} (${error.errorCode})',
              ),
            );
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            if (uri.scheme == 'http' || uri.scheme == 'https') {
              return NavigationDecision.navigate;
            }
            if (uri.scheme == 'mailto' || uri.scheme == 'tel') {
              launchUrl(uri, mode: LaunchMode.externalApplication);
            }
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(Uri.parse(instance.url));

    _controllers[instance.instanceId] = controller;
    _updateRuntime(
      instance.instanceId,
      (cur) => cur.copyWith(
        isSleeping: false,
        isLoading: true,
        clearError: true,
      ),
    );
    return controller;
  }

  void _updateRuntime(
    String instanceId,
    TabRuntimeState Function(TabRuntimeState current) updater,
  ) {
    final current = _runtimeMap[instanceId];
    if (current == null) return;
    _runtimeMap[instanceId] = updater(current);
    if (mounted) setState(() {});
  }

  void _activateInstance(ServiceInstance inst) {
    setState(() {
      _settings = _settings.copyWith(activeInstanceId: inst.instanceId);
    });
    _ensureController(inst);
    _persist();
  }

  void _sleepInstance(String instanceId) {
    _controllers.remove(instanceId);
    _updateRuntime(
      instanceId,
      (cur) => cur.copyWith(
        isSleeping: true,
        isLoading: false,
        unreadCount: 0,
        clearError: true,
      ),
    );
    _showSnack('タブを休止してメモリを解放しました');
  }

  Future<void> _toggleUaForActive() async {
    final active = _activeInstance;
    if (active == null) return;
    final nextUa = active.uaMode == UserAgentMode.desktop
        ? UserAgentMode.mobile
        : UserAgentMode.desktop;

    final idx =
        _instances.indexWhere((i) => i.instanceId == active.instanceId);
    if (idx == -1) return;

    final updated = active.copyWith(uaMode: nextUa);
    setState(() {
      _instances[idx] = updated;
    });
    await _persist();

    final ctrl = _controllers[active.instanceId];
    if (ctrl != null) {
      await ctrl.setUserAgent(buildUserAgent(nextUa));
      await ctrl.reload();
    }
    _showSnack(
      nextUa == UserAgentMode.desktop
          ? 'PC版 User-Agent に切り替えました'
          : 'スマホ版 User-Agent に切り替えました',
    );
  }

  Future<void> _openCatalog() async {
    final req = await Navigator.of(context).push<NewInstanceRequest>(
      MaterialPageRoute(
        builder: (_) => CatalogScreen(
          categories: _categories,
          catalog: _catalog,
          existingInstances: _instances,
        ),
      ),
    );
    if (req == null) return;

    final randHex = Random()
        .nextInt(0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0');
    final safePrefix =
        req.serviceId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final newInstance = ServiceInstance(
      instanceId: 'svc-${safePrefix.isEmpty ? 'custom' : safePrefix}-$randHex',
      serviceId: req.serviceId,
      name: req.name,
      category: req.category,
      url: req.url,
      colorHex: req.colorHex,
      badge: req.badge,
      uaMode: req.uaMode,
      notificationsEnabled: true,
      order: _instances.length,
    );

    setState(() {
      _instances.add(newInstance);
      _runtimeMap[newInstance.instanceId] = TabRuntimeState(
        currentUrl: newInstance.url,
        title: newInstance.name,
        isSleeping: true,
      );
      _settings = _settings.copyWith(activeInstanceId: newInstance.instanceId);
    });
    _ensureController(newInstance);
    await _persist();
    _showSnack('「${newInstance.name}」を追加しました');
  }

  Future<void> _openSettings() async {
    final updated = await Navigator.of(context).push<AppSettings>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          settings: _settings,
          onClearAllCookies: () async {
            await WebViewCookieManager().clearCookies();
            for (final id in _controllers.keys.toList()) {
              await _controllers[id]?.reload();
            }
          },
        ),
      ),
    );
    if (updated == null) return;
    setState(() {
      _settings = updated;
    });
    widget.onThemeChanged(updated.isDarkMode);
    _ensureSafeActiveAndLoad();
    await _persist();
  }

  Future<void> _editInstance(ServiceInstance inst) async {
    final nameCtrl = TextEditingController(text: inst.name);
    final urlCtrl = TextEditingController(text: inst.url);
    var uaMode = inst.uaMode;
    var notify = inst.notificationsEnabled;

    final updated = await showDialog<ServiceInstance>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('「${inst.name}」を編集'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '表示名',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'ホーム / DM画面 URL',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<UserAgentMode>(
                  initialValue: uaMode,
                  decoration: const InputDecoration(
                    labelText: 'User-Agent',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: UserAgentMode.mobile,
                      child: Text('スマホ版 (Android Chrome)'),
                    ),
                    DropdownMenuItem(
                      value: UserAgentMode.desktop,
                      child: Text('PC版 (Windows Chrome)'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setDialogState(() => uaMode = v);
                  },
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: notify,
                  onChanged: (v) => setDialogState(() => notify = v ?? true),
                  title: const Text('未読バッジ監視'),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () {
                final normalized = normalizeServiceUrl(urlCtrl.text);
                if (normalized == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('有効なURLを入力してください')),
                  );
                  return;
                }
                Navigator.of(ctx).pop(
                  inst.copyWith(
                    name: nameCtrl.text.trim().isEmpty
                        ? inst.name
                        : nameCtrl.text.trim(),
                    url: normalized,
                    uaMode: uaMode,
                    notificationsEnabled: notify,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    nameCtrl.dispose();
    urlCtrl.dispose();

    if (updated == null) return;
    final idx =
        _instances.indexWhere((i) => i.instanceId == inst.instanceId);
    if (idx == -1) return;

    final uaChanged = inst.uaMode != updated.uaMode;
    setState(() {
      _instances[idx] = updated;
    });
    await _persist();

    final ctrl = _controllers[inst.instanceId];
    if (ctrl != null && uaChanged) {
      await ctrl.setUserAgent(buildUserAgent(updated.uaMode));
      await ctrl.reload();
    }
    _showSnack('設定を保存しました');
  }

  Future<void> _removeInstance(ServiceInstance inst) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('サービスを削除'),
        content: Text('「${inst.name}」を一覧から削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    _controllers.remove(inst.instanceId);
    _runtimeMap.remove(inst.instanceId);
    setState(() {
      _instances.removeWhere((i) => i.instanceId == inst.instanceId);
    });
    _ensureSafeActiveAndLoad();
    await _persist();
    _showSnack('「${inst.name}」を削除しました');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  void _attemptUnlock() {
    final expected = _settings.lockPin;
    if (expected.isNotEmpty && _unlockPinController.text != expected) {
      setState(() => _unlockError = 'PINコードが一致しません');
      return;
    }
    setState(() {
      _isLocked = false;
      _unlockError = null;
      _unlockPinController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_isLocked) {
      return _buildLockScreen();
    }

    final active = _activeInstance;
    final activeRt =
        active != null ? _runtimeMap[active.instanceId] : null;
    final visible = _visibleInstances;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ctrl = active != null ? _controllers[active.instanceId] : null;
        if (ctrl != null && await ctrl.canGoBack()) {
          await ctrl.goBack();
          return;
        }
        if (context.mounted) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        drawer: _buildDrawer(visible),
        appBar: AppBar(
          toolbarHeight: 52,
          titleSpacing: 4,
          title: active == null
              ? const Text('OmniSNS')
              : InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () async {
                    final url = activeRt?.currentUrl ?? active.url;
                    await Clipboard.setData(ClipboardData(text: url));
                    _showSnack('現在のURLをコピーしました');
                  },
                  child: Row(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: parseHexColor(active.colorHex),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          active.badge,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              active.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              activeRt?.currentUrl ?? active.url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(fontSize: 10.5),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
          actions: [
            if (active != null)
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: ActionChip(
                  visualDensity: VisualDensity.compact,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  label: Text(
                    active.uaMode == UserAgentMode.desktop ? 'PC' : 'スマホ',
                    style: const TextStyle(fontSize: 11),
                  ),
                  tooltip: 'PC版 / スマホ版 User-Agent 切替',
                  onPressed: _toggleUaForActive,
                ),
              ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'サービスを追加',
              onPressed: _openCatalog,
            ),
            IconButton(
              icon: const Icon(Icons.lock_outline),
              tooltip: 'プライバシーロック',
              onPressed: () => setState(() => _isLocked = true),
            ),
            PopupMenuButton<String>(
              onSelected: (value) async {
                final ctrl =
                    active != null ? _controllers[active.instanceId] : null;
                switch (value) {
                  case 'back':
                    if (ctrl != null && await ctrl.canGoBack()) {
                      await ctrl.goBack();
                    }
                  case 'forward':
                    if (ctrl != null && await ctrl.canGoForward()) {
                      await ctrl.goForward();
                    }
                  case 'reload':
                    if (active != null) {
                      if (ctrl != null) {
                        await ctrl.reload();
                      } else {
                        _ensureController(active);
                      }
                    }
                  case 'home':
                    if (active != null) {
                      final c = _ensureController(active);
                      await c.loadRequest(Uri.parse(active.url));
                    }
                  case 'sleep':
                    if (active != null) _sleepInstance(active.instanceId);
                  case 'external':
                    if (active != null) {
                      final uri =
                          Uri.tryParse(activeRt?.currentUrl ?? active.url);
                      if (uri != null) {
                        await launchUrl(uri,
                            mode: LaunchMode.externalApplication);
                      }
                    }
                  case 'settings':
                    await _openSettings();
                }
              },
              itemBuilder: (_) => [
                if (active != null) ...[
                  const PopupMenuItem(value: 'back', child: Text('← 戻る')),
                  const PopupMenuItem(value: 'forward', child: Text('→ 進む')),
                  const PopupMenuItem(value: 'reload', child: Text('↻ 再読み込み')),
                  const PopupMenuItem(
                    value: 'home',
                    child: Text('⌂ DM/ホーム画面へ戻る'),
                  ),
                  const PopupMenuItem(
                    value: 'sleep',
                    child: Text('☾ タブ休止（メモリ解放）'),
                  ),
                  const PopupMenuItem(
                    value: 'external',
                    child: Text('↗ 外部ブラウザで開く'),
                  ),
                  const PopupMenuDivider(),
                ],
                const PopupMenuItem(value: 'settings', child: Text('⚙ アプリ設定')),
              ],
            ),
          ],
          bottom: activeRt != null && activeRt.isLoading
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2.5),
                  child: LinearProgressIndicator(
                    minHeight: 2.5,
                    value: activeRt.progress > 0 && activeRt.progress < 100
                        ? activeRt.progress / 100
                        : null,
                  ),
                )
              : null,
        ),
        body: Column(
          children: [
            Expanded(child: _buildViewport(visible, active, activeRt)),
            _buildBottomTabStrip(visible, active),
          ],
        ),
      ),
    );
  }

  Widget _buildViewport(
    List<ServiceInstance> visible,
    ServiceInstance? active,
    TabRuntimeState? activeRt,
  ) {
    if (active == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.forum_outlined, size: 52),
              const SizedBox(height: 12),
              const Text(
                'サービスを追加して始めましょう',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '全60種のDM送信対応サービスから選んでワンタップで切り替えられます。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _openCatalog,
                icon: const Icon(Icons.add),
                label: const Text('カタログを開く'),
              ),
            ],
          ),
        ),
      );
    }

    if (activeRt?.isSleeping == true || !_controllers.containsKey(active.instanceId)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bedtime_outlined, size: 48),
              const SizedBox(height: 10),
              Text(
                '「${active.name}」は休止中です',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text('メモリ節約のため表示を一時停止しています。'),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: () {
                  _ensureController(active);
                  setState(() {});
                },
                child: const Text('再開する'),
              ),
            ],
          ),
        ),
      );
    }

    if (activeRt?.loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, size: 48),
              const SizedBox(height: 10),
              const Text(
                'ページの読み込みに失敗しました',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(activeRt!.loadError!, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => _controllers[active.instanceId]?.reload(),
                    child: const Text('再読み込み'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      final uri = Uri.tryParse(activeRt.currentUrl);
                      if (uri != null) {
                        launchUrl(uri, mode: LaunchMode.externalApplication);
                      }
                    },
                    child: const Text('外部ブラウザで開く'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final liveIds = visible
        .where((i) => _controllers.containsKey(i.instanceId))
        .map((i) => i.instanceId)
        .toList();
    final activeIndex = liveIds.indexOf(active.instanceId);
    if (activeIndex < 0) return const SizedBox.shrink();

    return IndexedStack(
      index: activeIndex,
      children: [
        for (final id in liveIds)
          WebViewWidget(
            key: ValueKey('wv-$id'),
            controller: _controllers[id]!,
          ),
      ],
    );
  }

  Widget _buildBottomTabStrip(
    List<ServiceInstance> visible,
    ServiceInstance? active,
  ) {
    final surface = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Material(
      color: surface,
      elevation: 4,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 54,
          child: Row(
            children: [
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 7,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final inst = visible[index];
                    final isActive = inst.instanceId == active?.instanceId;
                    final rt = _runtimeMap[inst.instanceId];
                    final unread = inst.notificationsEnabled
                        ? (rt?.unreadCount ?? 0)
                        : 0;
                    final color = parseHexColor(inst.colorHex);

                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _activateInstance(inst),
                        onLongPress: () => _showInstanceActionSheet(inst),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: isActive
                                ? Theme.of(context)
                                    .colorScheme
                                    .primaryContainer
                                : Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isActive
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.transparent,
                              width: 1.4,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: color.withValues(
                                    alpha: rt?.isSleeping == true ? 0.45 : 1.0,
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  inst.badge,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 96),
                                child: Text(
                                  inst.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: isActive
                                        ? FontWeight.bold
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                              if (unread > 0) ...[
                                const SizedBox(width: 5),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.redAccent,
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                  child: Text(
                                    unread > 99 ? '99+' : '$unread',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'サービス追加',
                onPressed: _openCatalog,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showInstanceActionSheet(ServiceInstance inst) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                inst.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(inst.url),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('名前・URL・UA設定を編集'),
              onTap: () {
                Navigator.of(ctx).pop();
                _editInstance(inst);
              },
            ),
            ListTile(
              leading: const Icon(Icons.bedtime_outlined),
              title: const Text('このタブを休止（メモリ解放）'),
              onTap: () {
                Navigator.of(ctx).pop();
                _sleepInstance(inst.instanceId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text(
                '一覧から削除',
                style: TextStyle(color: Colors.redAccent),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _removeInstance(inst);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawer(List<ServiceInstance> visible) {
    final activeId = _settings.activeInstanceId;
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFF3B82F6),
                          Color(0xFF8B5CF6),
                          Color(0xFFEC4899),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      'O',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'OmniSNS',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Android · v1.1.0',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  if (_totalUnread > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        _totalUnread > 99 ? '99+' : '$_totalUnread',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ReorderableListView.builder(
                itemCount: visible.length,
                onReorder: (oldIndex, newIndex) async {
                  if (newIndex > oldIndex) newIndex -= 1;
                  final moved = visible[oldIndex];
                  final target = visible[newIndex];
                  final fullFrom = _instances
                      .indexWhere((i) => i.instanceId == moved.instanceId);
                  final fullTo = _instances
                      .indexWhere((i) => i.instanceId == target.instanceId);
                  if (fullFrom == -1 || fullTo == -1) return;
                  setState(() {
                    final item = _instances.removeAt(fullFrom);
                    _instances.insert(fullTo, item);
                  });
                  await _persist();
                },
                itemBuilder: (context, index) {
                  final inst = visible[index];
                  final rt = _runtimeMap[inst.instanceId];
                  final selected = inst.instanceId == activeId;
                  return ListTile(
                    key: ValueKey('drawer-${inst.instanceId}'),
                    selected: selected,
                    leading: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: parseHexColor(inst.colorHex),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        inst.badge,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(
                      inst.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        inst.uaMode == UserAgentMode.desktop ? 'PC版UA' : 'スマホUA',
                        if (rt?.isSleeping == true) '休止中',
                      ].join(' · '),
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.more_vert, size: 18),
                      onPressed: () {
                        Navigator.of(context).pop();
                        _showInstanceActionSheet(inst);
                      },
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      _activateInstance(inst);
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        _openCatalog();
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('サービスを追加'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        _openSettings();
                      },
                      icon: const Icon(Icons.settings_outlined, size: 18),
                      label: const Text('アプリ設定'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLockScreen() {
    final hasPin = _settings.lockPin.isNotEmpty;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_outline, size: 46),
                    const SizedBox(height: 12),
                    const Text(
                      'OmniSNS はロック中です',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'すべてのサービス画面を非表示にしています。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5),
                    ),
                    if (hasPin) ...[
                      const SizedBox(height: 14),
                      TextField(
                        controller: _unlockPinController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: 'PINコード',
                          errorText: _unlockError,
                          border: const OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _attemptUnlock(),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _attemptUnlock,
                        child: const Text('ロックを解除する'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
