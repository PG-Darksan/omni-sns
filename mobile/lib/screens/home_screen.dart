import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/service_models.dart';
import '../services/app_store.dart';
import '../services/omni_webview.dart';
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

class _ServiceGroup {
  const _ServiceGroup({
    required this.key,
    required this.serviceId,
    required this.displayName,
    required this.colorHex,
    required this.badge,
    required this.accounts,
  });

  final String key;
  final String serviceId;
  final String displayName;
  final String colorHex;
  final String badge;
  final List<ServiceInstance> accounts;
}

class _HomeScreenState extends State<HomeScreen> {
  bool _initialized = false;
  bool _multiProfileSupported = false;
  List<CategoryMeta> _categories = const [];
  List<CatalogService> _catalog = const [];
  List<ServiceInstance> _instances = [];
  AppSettings _settings = const AppSettings();

  final Map<String, OmniWebViewController> _controllers = {};
  final Map<String, TabRuntimeState> _runtimeMap = {};
  final Map<String, String> _lastActiveByGroup = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    for (final ctrl in _controllers.values) {
      ctrl.dispose();
    }
    _controllers.clear();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final catalogData = await widget.store.loadCatalog();
    final (settings, instances) =
        await widget.store.loadState(catalogData.services);
    final multiProfile = await OmniWebViewManager.isMultiProfileSupported();

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
      _multiProfileSupported = multiProfile;
      _initialized = true;
    });

    widget.onThemeChanged(settings.isDarkMode);
    _ensureSafeActiveAndLoad();
  }

  List<ServiceInstance> get _visibleInstances => _instances;

  CatalogService? _catalogServiceFor(String serviceId) {
    if (serviceId == 'custom') return null;
    for (final svc in _catalog) {
      if (svc.id == serviceId) return svc;
    }
    return null;
  }

  List<_ServiceGroup> get _serviceGroups {
    final groups = <_ServiceGroup>[];
    final indexMap = <String, int>{};
    for (final inst in _instances) {
      final key = serviceGroupKey(inst);
      final existingIdx = indexMap[key];
      if (existingIdx != null) {
        groups[existingIdx].accounts.add(inst);
      } else {
        final cat = _catalogServiceFor(inst.serviceId);
        final displayName = cat?.name ??
            inst.name.replaceFirst(RegExp(r'\s*\(\d+\)\s*$'), '').trim();
        indexMap[key] = groups.length;
        groups.add(
          _ServiceGroup(
            key: key,
            serviceId: inst.serviceId,
            displayName: displayName.isEmpty ? inst.name : displayName,
            colorHex: inst.colorHex,
            badge: inst.badge,
            accounts: [inst],
          ),
        );
      }
    }
    return groups;
  }

  ServiceInstance? get _activeInstance {
    final activeId = _settings.activeInstanceId;
    if (activeId == null) return null;
    for (final inst in _visibleInstances) {
      if (inst.instanceId == activeId) return inst;
    }
    return null;
  }

  _ServiceGroup? get _activeGroup {
    final active = _activeInstance;
    if (active == null) return null;
    final key = serviceGroupKey(active);
    for (final grp in _serviceGroups) {
      if (grp.key == key) return grp;
    }
    return null;
  }

  ServiceInstance _pickTargetAccountForGroup(_ServiceGroup group) {
    final savedId = _lastActiveByGroup[group.key];
    if (savedId != null) {
      for (final acc in group.accounts) {
        if (acc.instanceId == savedId) return acc;
      }
    }
    return group.accounts.first;
  }

  int get _totalUnread {
    var sum = 0;
    for (final inst in _visibleInstances) {
      if (!inst.notificationsEnabled) continue;
      sum += _runtimeMap[inst.instanceId]?.unreadCount ?? 0;
    }
    return sum;
  }

  int get _otherGroupsUnread {
    final activeKey = _activeGroup?.key;
    var sum = 0;
    for (final inst in _visibleInstances) {
      if (!inst.notificationsEnabled) continue;
      if (activeKey != null && serviceGroupKey(inst) == activeKey) continue;
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
      _lastActiveByGroup[serviceGroupKey(inst)] = inst.instanceId;
      _ensureController(inst);
    }
    if (mounted) setState(() {});
  }

  Future<void> _persist() async {
    await widget.store.saveState(_settings, _instances);
  }

  OmniWebViewController _ensureController(ServiceInstance instance) {
    final existing = _controllers[instance.instanceId];
    if (existing != null && !existing.isDisposed) return existing;

    final controller = OmniWebViewController(
      initialUrl: instance.url,
      profileName: _multiProfileSupported
          ? instance.effectiveProfileName
          : defaultWebViewProfileName,
      userAgent: buildMobileUserAgent(),
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
            currentUrl: isHttpOrHttpsUrl(url) ? url : cur.currentUrl,
            isLoading: true,
            isSleeping: false,
            clearError: true,
          ),
        );
      },
      onPageFinished: (url, title, canBack, canFwd, hadError) {
        final safeTitle = title.trim().isEmpty ? instance.name : title;
        final unread = parseUnreadCountFromTitle(safeTitle);
        final validUrl = isHttpOrHttpsUrl(url);
        _updateRuntime(
          instance.instanceId,
          (cur) => cur.copyWith(
            currentUrl: validUrl ? url : cur.currentUrl,
            title: safeTitle,
            progress: 100,
            unreadCount: unread,
            isLoading: false,
            isSleeping: false,
            canGoBack: canBack,
            canGoForward: canFwd,
            clearError: !hadError && validUrl,
          ),
        );
      },
      onTitleChanged: (title) {
        final safeTitle = title.trim().isEmpty ? instance.name : title;
        final unread = parseUnreadCountFromTitle(safeTitle);
        _updateRuntime(
          instance.instanceId,
          (cur) => cur.copyWith(
            title: safeTitle,
            unreadCount: unread,
          ),
        );
      },
      onHistoryChanged: (url, canBack, canFwd) {
        _updateRuntime(
          instance.instanceId,
          (cur) => cur.copyWith(
            currentUrl: isHttpOrHttpsUrl(url) ? url : cur.currentUrl,
            canGoBack: canBack,
            canGoForward: canFwd,
          ),
        );
      },
      onWebResourceError: (description, errorCode) {
        _updateRuntime(
          instance.instanceId,
          (cur) => cur.copyWith(
            isLoading: false,
            loadError: '$description ($errorCode)',
          ),
        );
      },
      onExternalScheme: (url) {
        _openExternalUrlSafely(url);
      },
      onFollowDetected: (_) {
        _adjustFollowCount(instance.instanceId, 1);
      },
    );

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
    _lastActiveByGroup[serviceGroupKey(inst)] = inst.instanceId;
    setState(() {
      _settings = _settings.copyWith(activeInstanceId: inst.instanceId);
    });
    _ensureController(inst);
    _persist();
  }

  void _activateGroup(_ServiceGroup group) {
    _activateInstance(_pickTargetAccountForGroup(group));
  }

  Future<void> _reloadInstance(ServiceInstance instance) async {
    final rt = _runtimeMap[instance.instanceId];
    final fallbackUrl =
        isHttpOrHttpsUrl(rt?.currentUrl) ? rt!.currentUrl : instance.url;

    final ctrl = _controllers[instance.instanceId];
    if (ctrl == null || ctrl.isDisposed) {
      _ensureController(instance);
      return;
    }

    _updateRuntime(
      instance.instanceId,
      (cur) => cur.copyWith(
        isSleeping: false,
        isLoading: true,
        progress: 5,
        clearError: true,
      ),
    );
    await ctrl.reload(fallbackUrl: fallbackUrl);
  }

  Future<void> _reloadActiveTab() async {
    final active = _activeInstance;
    if (active == null) return;
    await _reloadInstance(active);
  }

  Future<void> _openExternalUrlSafely(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) return;
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        _showSnack('外部アプリで開けませんでした');
      }
    } catch (_) {
      _showSnack('外部アプリで開けませんでした');
    }
  }

  Future<void> _adjustFollowCount(String instanceId, int delta) async {
    final idx = _instances.indexWhere((i) => i.instanceId == instanceId);
    if (idx == -1) return;
    setState(() {
      _instances[idx] = _instances[idx].withFollowDelta(delta);
    });
    await _persist();
  }

  Future<void> _resetFollowCount(
    String instanceId, {
    required bool resetTotal,
  }) async {
    final idx = _instances.indexWhere((i) => i.instanceId == instanceId);
    if (idx == -1) return;
    setState(() {
      _instances[idx] = _instances[idx].withFollowReset(resetTotal: resetTotal);
    });
    await _persist();
  }

  Future<void> _showFollowCounterSheet(ServiceInstance target) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final current = _instances.cast<ServiceInstance?>().firstWhere(
                (i) => i?.instanceId == target.instanceId,
                orElse: () => null,
              );
          if (current == null) return const SizedBox.shrink();

          final grp = _serviceGroups.cast<_ServiceGroup?>().firstWhere(
                (g) => g?.key == serviceGroupKey(current),
                orElse: () => null,
              );
          final siblingIdx = grp == null
              ? 0
              : max(
                  0,
                  grp.accounts
                      .indexWhere((a) => a.instanceId == current.instanceId),
                );
          final accLabel = accountDisplayLabel(
            current,
            siblingIdx,
            baseServiceName: grp?.displayName,
          );
          final title = _multiProfileSupported
              ? '${grp?.displayName ?? current.name} · $accLabel'
              : (grp?.displayName ?? current.name);

          final now = DateTime.now();
          final todayCount = current.effectiveFollowCountToday(now);
          final totalCount = current.followCountTotal;
          var allTodaySum = 0;
          for (final inst in _instances) {
            allTodaySum += inst.effectiveFollowCountToday(now);
          }
          final colorScheme = Theme.of(ctx).colorScheme;

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.person_add_alt_1_rounded,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'フォロー回数カウンター',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(ctx).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer
                                .withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: colorScheme.primary.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Column(
                            children: [
                              const Text(
                                '今日のフォロー数',
                                style: TextStyle(fontSize: 11.5),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$todayCount',
                                key: const ValueKey('follow-sheet-today'),
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  color: colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: colorScheme.outlineVariant,
                            ),
                          ),
                          child: Column(
                            children: [
                              const Text(
                                '累計フォロー数',
                                style: TextStyle(fontSize: 11.5),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$totalCount',
                                key: const ValueKey('follow-sheet-total'),
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('follow-sheet-dec'),
                          onPressed: todayCount > 0 || totalCount > 0
                              ? () async {
                                  await _adjustFollowCount(
                                    current.instanceId,
                                    -1,
                                  );
                                  setSheetState(() {});
                                }
                              : null,
                          icon: const Icon(Icons.remove, size: 18),
                          label: const Text('−1'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          key: const ValueKey('follow-sheet-inc'),
                          onPressed: () async {
                            await _adjustFollowCount(current.instanceId, 1);
                            setSheetState(() {});
                          },
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('＋1'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: todayCount > 0
                              ? () async {
                                  await _resetFollowCount(
                                    current.instanceId,
                                    resetTotal: false,
                                  );
                                  setSheetState(() {});
                                }
                              : null,
                          child: const Text('今日をリセット'),
                        ),
                      ),
                      Expanded(
                        child: TextButton(
                          onPressed: totalCount > 0 || todayCount > 0
                              ? () async {
                                  await _resetFollowCount(
                                    current.instanceId,
                                    resetTotal: true,
                                  );
                                  setSheetState(() {});
                                }
                              : null,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                          ),
                          child: const Text('累計もリセット'),
                        ),
                      ),
                    ],
                  ),
                  if (_instances.length >= 2) ...[
                    const Divider(height: 16),
                    Text(
                      '全アカウント合計（今日）: $allTodaySum 回',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    'Threads・Instagram・Bluesky 等でフォローを押すと自動でカウントされます（日付が変わると「今日」は自動で0に戻ります）。',
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                        ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _toggleBottomTabsCollapsed() async {
    setState(() {
      _settings = _settings.copyWith(
        isBottomTabsCollapsed: !_settings.isBottomTabsCollapsed,
      );
    });
    await _persist();
  }

  Future<void> _toggleHeaderCollapsed() async {
    setState(() {
      _settings = _settings.copyWith(
        isHeaderCollapsed: !_settings.isHeaderCollapsed,
      );
    });
    await _persist();
  }

  Future<void> _addAccountForActiveService() async {
    if (!_multiProfileSupported) return;
    final active = _activeInstance;
    final group = _activeGroup;
    if (active == null || group == null) return;

    final existingLabels = List.generate(
      group.accounts.length,
      (idx) => accountDisplayLabel(
        group.accounts[idx],
        idx,
        baseServiceName: group.displayName,
      ),
    );
    final nextLabel = nextDefaultAccountLabel(existingLabels);
    final catSvc = _catalogServiceFor(active.serviceId);

    final randHex = Random()
        .nextInt(0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0');
    final safePrefix =
        active.serviceId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final newInstanceId =
        'svc-${safePrefix.isEmpty ? 'custom' : safePrefix}-$randHex';
    final newInstance = ServiceInstance(
      instanceId: newInstanceId,
      serviceId: active.serviceId,
      name: group.displayName,
      accountLabel: nextLabel,
      profileName: makeProfileNameForInstance(newInstanceId),
      category: active.category,
      url: catSvc?.url ?? active.url,
      colorHex: active.colorHex,
      badge: active.badge,
      notificationsEnabled: true,
      order: _instances.length,
    );

    _lastActiveByGroup[serviceGroupKey(newInstance)] = newInstance.instanceId;
    final newGroupKey = serviceGroupKey(newInstance);
    final lastSiblingIdx = _instances.lastIndexWhere(
      (i) => serviceGroupKey(i) == newGroupKey,
    );
    final insertAt =
        lastSiblingIdx >= 0 ? lastSiblingIdx + 1 : _instances.length;
    setState(() {
      _instances.insert(insertAt, newInstance);
      _runtimeMap[newInstance.instanceId] = TabRuntimeState(
        currentUrl: newInstance.url,
        title: newInstance.name,
        isSleeping: true,
      );
      _settings = _settings.copyWith(activeInstanceId: newInstance.instanceId);
    });
    _ensureController(newInstance);
    await _persist();
    _showSnack('「${group.displayName} / $nextLabel」を追加しました（独立セッション）');
  }

  void _sleepInstance(String instanceId) {
    final removed = _controllers.remove(instanceId);
    removed?.dispose();
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

  Future<void> _clearSessionForInstance(ServiceInstance inst) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ログイン情報を消去'),
        content: Text(
          _multiProfileSupported
              ? 'このアカウントのCookieとログイン情報を消去してログアウトしますか？'
              : 'Cookieとログイン情報を消去してログアウトしますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('消去する'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final profileName = _multiProfileSupported
        ? inst.effectiveProfileName
        : defaultWebViewProfileName;
    await OmniWebViewManager.clearProfileData(profileName);
    final ctrl = _controllers[inst.instanceId];
    if (ctrl != null) {
      await ctrl.loadUrl(inst.url);
    }
    _showSnack('ログイン情報を消去しました');
  }

  Future<void> _openCatalog() async {
    final req = await Navigator.of(context).push<NewInstanceRequest>(
      MaterialPageRoute(
        builder: (_) => CatalogScreen(
          categories: _categories,
          catalog: _catalog,
          existingInstances: _instances,
          multiProfileSupported: _multiProfileSupported,
        ),
      ),
    );
    if (req == null) return;

    if (req.openExistingInstanceId != null) {
      final existing = _instances.cast<ServiceInstance?>().firstWhere(
            (i) => i?.instanceId == req.openExistingInstanceId,
            orElse: () => null,
          );
      if (existing != null) {
        _activateInstance(existing);
        return;
      }
    }

    final randHex = Random()
        .nextInt(0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0');
    final safePrefix =
        req.serviceId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final newInstanceId =
        'svc-${safePrefix.isEmpty ? 'custom' : safePrefix}-$randHex';
    final newInstance = ServiceInstance(
      instanceId: newInstanceId,
      serviceId: req.serviceId,
      name: req.name,
      accountLabel: req.accountLabel,
      profileName: makeProfileNameForInstance(newInstanceId),
      category: req.category,
      url: req.url,
      colorHex: req.colorHex,
      badge: req.badge,
      notificationsEnabled: true,
      order: _instances.length,
    );

    _lastActiveByGroup[serviceGroupKey(newInstance)] = newInstance.instanceId;
    final newGroupKey = serviceGroupKey(newInstance);
    final lastSiblingIdx = _instances.lastIndexWhere(
      (i) => serviceGroupKey(i) == newGroupKey,
    );
    final insertAt =
        lastSiblingIdx >= 0 ? lastSiblingIdx + 1 : _instances.length;
    setState(() {
      _instances.insert(insertAt, newInstance);
      _runtimeMap[newInstance.instanceId] = TabRuntimeState(
        currentUrl: newInstance.url,
        title: newInstance.name,
        isSleeping: true,
      );
      _settings = _settings.copyWith(activeInstanceId: newInstance.instanceId);
    });
    _ensureController(newInstance);
    await _persist();
    final suffix = _multiProfileSupported &&
            (newInstance.accountLabel?.isNotEmpty ?? false)
        ? ' / ${newInstance.accountLabel}'
        : '';
    _showSnack('「${newInstance.name}$suffix」を追加しました');
  }

  Future<void> _openSettings() async {
    final updated = await Navigator.of(context).push<AppSettings>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          settings: _settings,
          onClearAllCookies: () async {
            await OmniWebViewManager.clearAllCookies();
            for (final id in _controllers.keys.toList()) {
              final inst = _instances.cast<ServiceInstance?>().firstWhere(
                    (i) => i?.instanceId == id,
                    orElse: () => null,
                  );
              if (inst != null) {
                await _reloadInstance(inst);
              } else {
                await _controllers[id]?.reload();
              }
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
    final grp = _serviceGroups.cast<_ServiceGroup?>().firstWhere(
          (g) => g?.key == serviceGroupKey(inst),
          orElse: () => null,
        );
    final siblingIdx = grp == null
        ? 0
        : max(0, grp.accounts.indexWhere((a) => a.instanceId == inst.instanceId));
    final curAccLabel = accountDisplayLabel(
      inst,
      siblingIdx,
      baseServiceName: grp?.displayName,
    );
    final accCtrl = TextEditingController(text: curAccLabel);
    final nameCtrl = TextEditingController(text: inst.name);
    final urlCtrl = TextEditingController(text: inst.url);
    var notify = inst.notificationsEnabled;

    final dialogTitle = _multiProfileSupported
        ? '「${grp?.displayName ?? inst.name} · $curAccLabel」を編集'
        : '「${grp?.displayName ?? inst.name}」を編集';

    final updated = await showDialog<ServiceInstance>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(dialogTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_multiProfileSupported) ...[
                  TextField(
                    controller: accCtrl,
                    decoration: const InputDecoration(
                      labelText: 'アカウント名（ヘッダー表示名）',
                      hintText: '例: メイン / サブ / 仕事用',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'サービス表示名',
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
                final trimmedAcc = accCtrl.text.trim();
                Navigator.of(ctx).pop(
                  inst.copyWith(
                    name: nameCtrl.text.trim().isEmpty
                        ? inst.name
                        : nameCtrl.text.trim(),
                    accountLabel: _multiProfileSupported
                        ? (trimmedAcc.isEmpty ? null : trimmedAcc)
                        : inst.accountLabel,
                    clearAccountLabel:
                        _multiProfileSupported && trimmedAcc.isEmpty,
                    url: normalized,
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

    accCtrl.dispose();
    nameCtrl.dispose();
    urlCtrl.dispose();

    if (updated == null) return;
    final idx =
        _instances.indexWhere((i) => i.instanceId == inst.instanceId);
    if (idx == -1) return;

    setState(() {
      _instances[idx] = updated;
    });
    await _persist();
    _showSnack('設定を保存しました');
  }

  Future<void> _removeInstance(ServiceInstance inst) async {
    final groupKey = serviceGroupKey(inst);
    final grp = _serviceGroups.cast<_ServiceGroup?>().firstWhere(
          (g) => g?.key == groupKey,
          orElse: () => null,
        );
    final siblingIdx = grp == null
        ? 0
        : max(0, grp.accounts.indexWhere((a) => a.instanceId == inst.instanceId));
    final label = accountDisplayLabel(
      inst,
      siblingIdx,
      baseServiceName: grp?.displayName,
    );
    final displayTitle = _multiProfileSupported &&
            grp != null &&
            grp.accounts.length >= 2
        ? '${grp.displayName} / $label'
        : (grp?.displayName ?? inst.name);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_multiProfileSupported ? 'アカウントを削除' : 'サービスを削除'),
        content: Text('「$displayTitle」を削除しますか？'),
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

    final wasActive = _settings.activeInstanceId == inst.instanceId;
    final removedCtrl = _controllers.remove(inst.instanceId);
    removedCtrl?.dispose();
    _runtimeMap.remove(inst.instanceId);
    setState(() {
      _instances.removeWhere((i) => i.instanceId == inst.instanceId);
      if (wasActive) {
        final sameGroupNext = _instances
            .cast<ServiceInstance?>()
            .firstWhere((i) => i != null && serviceGroupKey(i) == groupKey,
                orElse: () => null);
        if (sameGroupNext != null) {
          _settings =
              _settings.copyWith(activeInstanceId: sameGroupNext.instanceId);
        }
      }
    });
    _ensureSafeActiveAndLoad();
    await _persist();
    if (_multiProfileSupported &&
        inst.effectiveProfileName != defaultWebViewProfileName) {
      await OmniWebViewManager.deleteProfile(inst.effectiveProfileName);
    }
    _showSnack('「$displayTitle」を削除しました');
  }

  Future<void> _removeGroup(_ServiceGroup group) async {
    if (group.accounts.length == 1) {
      await _removeInstance(group.accounts.first);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('サービスを削除'),
        content: Text(
          '「${group.displayName}」（全${group.accounts.length}アカウント）を削除しますか？',
        ),
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

    final profilesToDelete = <String>[];
    final ids = group.accounts.map((a) => a.instanceId).toSet();
    for (final acc in group.accounts) {
      final ctrl = _controllers.remove(acc.instanceId);
      ctrl?.dispose();
      _runtimeMap.remove(acc.instanceId);
      if (_multiProfileSupported &&
          acc.effectiveProfileName != defaultWebViewProfileName) {
        profilesToDelete.add(acc.effectiveProfileName);
      }
    }
    setState(() {
      _instances.removeWhere((i) => ids.contains(i.instanceId));
    });
    _ensureSafeActiveAndLoad();
    await _persist();
    for (final profile in profilesToDelete) {
      await OmniWebViewManager.deleteProfile(profile);
    }
    _showSnack('「${group.displayName}」を削除しました');
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

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final active = _activeInstance;
    final activeGroup = _activeGroup;
    final activeRt =
        active != null ? _runtimeMap[active.instanceId] : null;
    final visible = _visibleInstances;
    final groups = _serviceGroups;
    final tabsCollapsed = _settings.isBottomTabsCollapsed;
    final headerCollapsed = _settings.isHeaderCollapsed;
    final otherUnread = _otherGroupsUnread;

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
        drawer: _buildDrawer(groups, activeGroup),
        appBar: headerCollapsed
            ? null
            : AppBar(
                toolbarHeight: 50,
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
                                    activeGroup?.displayName ?? active.name,
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
                  if (tabsCollapsed)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: ActionChip(
                        visualDensity: VisualDensity.compact,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                        avatar: const Icon(
                          Icons.keyboard_arrow_up_rounded,
                          size: 16,
                        ),
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('タブ', style: TextStyle(fontSize: 11)),
                            if (otherUnread > 0) ...[
                              const SizedBox(width: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 0.5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent,
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: Text(
                                  otherUnread > 99 ? '99+' : '$otherUnread',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        tooltip: '下部タブを展開',
                        onPressed: _toggleBottomTabsCollapsed,
                      ),
                    ),
                  if (active != null)
                    IconButton(
                      key: const ValueKey('header-reload-button'),
                      icon: const Icon(Icons.refresh_rounded),
                      visualDensity: VisualDensity.compact,
                      tooltip: '再読み込み',
                      onPressed: _reloadActiveTab,
                    ),
                  IconButton(
                    key: const ValueKey('header-collapse-button'),
                    icon: const Icon(Icons.keyboard_arrow_up_rounded),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'ヘッダーを折り畳む',
                    onPressed: _toggleHeaderCollapsed,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'サービスを追加',
                    onPressed: _openCatalog,
                  ),
                  PopupMenuButton<String>(
                    onSelected: (value) async {
                      final ctrl = active != null
                          ? _controllers[active.instanceId]
                          : null;
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
                          await _reloadActiveTab();
                        case 'home':
                          if (active != null) {
                            final c = _ensureController(active);
                            _updateRuntime(
                              active.instanceId,
                              (cur) => cur.copyWith(
                                isSleeping: false,
                                isLoading: true,
                                progress: 5,
                                clearError: true,
                              ),
                            );
                            await c.loadUrl(active.url);
                          }
                        case 'toggle-header':
                          await _toggleHeaderCollapsed();
                        case 'toggle-bottom-tabs':
                          await _toggleBottomTabsCollapsed();
                        case 'follow-counter':
                          if (active != null) {
                            await _showFollowCounterSheet(active);
                          }
                        case 'sleep':
                          if (active != null) _sleepInstance(active.instanceId);
                        case 'external':
                          if (active != null) {
                            final url = isHttpOrHttpsUrl(activeRt?.currentUrl)
                                ? activeRt!.currentUrl
                                : active.url;
                            await _openExternalUrlSafely(url);
                          }
                        case 'settings':
                          await _openSettings();
                      }
                    },
                    itemBuilder: (_) => [
                      if (active != null) ...[
                        const PopupMenuItem(value: 'back', child: Text('← 戻る')),
                        const PopupMenuItem(
                          value: 'forward',
                          child: Text('→ 進む'),
                        ),
                        const PopupMenuItem(
                          value: 'reload',
                          child: Text('↻ 再読み込み'),
                        ),
                        const PopupMenuItem(
                          value: 'home',
                          child: Text('⌂ DM/ホーム画面へ戻る'),
                        ),
                        const PopupMenuItem(
                          value: 'toggle-header',
                          child: Text('▲ ヘッダーを折り畳む'),
                        ),
                        PopupMenuItem(
                          value: 'toggle-bottom-tabs',
                          child: Text(
                            tabsCollapsed ? '▲ 下部タブを展開' : '▼ 下部タブを折り畳む',
                          ),
                        ),
                        PopupMenuItem(
                          value: 'follow-counter',
                          child: Text(
                            '👤 フォロー回数 (今日 ${active.effectiveFollowCountToday()}回)',
                          ),
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
                      const PopupMenuItem(
                        value: 'settings',
                        child: Text('⚙ アプリ設定'),
                      ),
                    ],
                  ),
                ],
                bottom: activeRt != null && activeRt.isLoading
                    ? PreferredSize(
                        preferredSize: const Size.fromHeight(2.5),
                        child: LinearProgressIndicator(
                          minHeight: 2.5,
                          value: activeRt.progress > 0 &&
                                  activeRt.progress < 100
                              ? activeRt.progress / 100
                              : null,
                        ),
                      )
                    : null,
              ),
        body: Column(
          children: [
            if (headerCollapsed)
              _buildCollapsedHeaderBar(
                active,
                activeGroup,
                activeRt,
                tabsCollapsed,
                otherUnread,
              ),
            if (!headerCollapsed && active != null && activeGroup != null)
              _buildAccountSwitcherBar(activeGroup, active),
            Expanded(
              child: SafeArea(
                top: false,
                bottom: tabsCollapsed,
                child: _buildViewport(visible, active, activeRt),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: tabsCollapsed
                  ? const SizedBox(width: double.infinity, height: 0)
                  : _buildBottomTabStrip(groups, activeGroup),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollapsedHeaderBar(
    ServiceInstance? active,
    _ServiceGroup? activeGroup,
    TabRuntimeState? activeRt,
    bool tabsCollapsed,
    int otherUnread,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final todayFollows = active?.effectiveFollowCountToday() ?? 0;
    return Material(
      key: const ValueKey('collapsed-header-bar'),
      color: colorScheme.surfaceContainerLow,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Builder(
                    builder: (scaffoldCtx) => IconButton(
                      icon: const Icon(Icons.menu, size: 19),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 34, minHeight: 34),
                      tooltip: 'メニュー',
                      onPressed: () => Scaffold.of(scaffoldCtx).openDrawer(),
                    ),
                  ),
                  if (active != null) ...[
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: parseHexColor(active.colorHex),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        active.badge,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        activeGroup?.displayName ?? active.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    InkWell(
                      key: const ValueKey('follow-counter-chip'),
                      borderRadius: BorderRadius.circular(99),
                      onTap: () => _showFollowCounterSheet(active),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: todayFollows > 0
                              ? colorScheme.tertiaryContainer
                              : colorScheme.surface,
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                            color: todayFollows > 0
                                ? colorScheme.tertiary
                                : colorScheme.outlineVariant,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.person_add_alt_1_rounded,
                              size: 12,
                              color: todayFollows > 0
                                  ? colorScheme.onTertiaryContainer
                                  : colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '$todayFollows',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: todayFollows > 0
                                    ? colorScheme.onTertiaryContainer
                                    : colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ] else
                    const Expanded(
                      child: Text(
                        'OmniSNS',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  if (tabsCollapsed) ...[
                    const SizedBox(width: 4),
                    InkWell(
                      borderRadius: BorderRadius.circular(99),
                      onTap: _toggleBottomTabsCollapsed,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.surface,
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(color: colorScheme.outlineVariant),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('タブ', style: TextStyle(fontSize: 10.5)),
                            if (otherUnread > 0) ...[
                              const SizedBox(width: 3),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 0.5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent,
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: Text(
                                  otherUnread > 99 ? '99+' : '$otherUnread',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 8.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (active != null)
                    IconButton(
                      key: const ValueKey('header-reload-button'),
                      icon: const Icon(Icons.refresh_rounded, size: 19),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 34, minHeight: 34),
                      tooltip: '再読み込み',
                      onPressed: _reloadActiveTab,
                    ),
                  IconButton(
                    key: const ValueKey('header-expand-button'),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 22),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 34, minHeight: 34),
                    tooltip: 'ヘッダーを展開',
                    onPressed: _toggleHeaderCollapsed,
                  ),
                ],
              ),
            ),
            if (activeRt != null && activeRt.isLoading)
              LinearProgressIndicator(
                minHeight: 2,
                value: activeRt.progress > 0 && activeRt.progress < 100
                    ? activeRt.progress / 100
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountSwitcherBar(
    _ServiceGroup group,
    ServiceInstance active,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final todayFollows = active.effectiveFollowCountToday();
    return Material(
      color: colorScheme.surfaceContainerLow,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: _multiProfileSupported
                  ? ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
                      children: [
                        for (var i = 0; i < group.accounts.length; i++)
                          Builder(
                            builder: (context) {
                              final inst = group.accounts[i];
                              final isCurrent =
                                  inst.instanceId == active.instanceId;
                              final rt = _runtimeMap[inst.instanceId];
                              final unread = inst.notificationsEnabled
                                  ? (rt?.unreadCount ?? 0)
                                  : 0;
                              final label = accountDisplayLabel(
                                inst,
                                i,
                                baseServiceName: group.displayName,
                              );
                              return Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(99),
                                  onTap: () {
                                    if (!isCurrent) _activateInstance(inst);
                                  },
                                  onLongPress: () =>
                                      _showInstanceActionSheet(inst),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isCurrent
                                          ? colorScheme.primaryContainer
                                          : colorScheme.surface,
                                      borderRadius: BorderRadius.circular(99),
                                      border: Border.all(
                                        color: isCurrent
                                            ? colorScheme.primary
                                            : colorScheme.outlineVariant,
                                        width: isCurrent ? 1.3 : 1,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 7,
                                          height: 7,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: rt?.isLoading == true
                                                ? colorScheme.primary
                                                : rt?.isSleeping == true
                                                    ? Colors.grey
                                                    : Colors.green,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          label,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: isCurrent
                                                ? FontWeight.bold
                                                : FontWeight.w500,
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
                                              borderRadius:
                                                  BorderRadius.circular(99),
                                            ),
                                            child: Text(
                                              unread > 99 ? '99+' : '$unread',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 9.5,
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
                        InkWell(
                          borderRadius: BorderRadius.circular(99),
                          onTap: _addAccountForActiveService,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(99),
                              border: Border.all(
                                color: colorScheme.outlineVariant,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.add,
                                  size: 14,
                                  color: colorScheme.primary,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  'アカウント追加',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          group.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 5, 8, 5),
              child: InkWell(
                key: const ValueKey('follow-counter-chip'),
                borderRadius: BorderRadius.circular(99),
                onTap: () => _showFollowCounterSheet(active),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: todayFollows > 0
                        ? colorScheme.tertiaryContainer
                        : colorScheme.surface,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(
                      color: todayFollows > 0
                          ? colorScheme.tertiary
                          : colorScheme.outlineVariant,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.person_add_alt_1_rounded,
                        size: 13.5,
                        color: todayFollows > 0
                            ? colorScheme.onTertiaryContainer
                            : colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'フォロー $todayFollows',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: todayFollows > 0
                              ? colorScheme.onTertiaryContainer
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
                '無料プランでDM送信できる全44種のサービスから選んでワンタップで切り替えられます。',
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

    final liveIds = visible
        .where((i) => _controllers.containsKey(i.instanceId))
        .map((i) => i.instanceId)
        .toList();
    final activeIndex = liveIds.indexOf(active.instanceId);
    final isSleeping =
        activeRt?.isSleeping == true || !_controllers.containsKey(active.instanceId);
    final hasError = activeRt?.loadError != null;
    final showWebView = !isSleeping && !hasError && activeIndex >= 0;

    return Stack(
      children: [
        if (liveIds.isNotEmpty)
          Positioned.fill(
            child: Offstage(
              offstage: !showWebView,
              child: IndexedStack(
                index: activeIndex >= 0 ? activeIndex : 0,
                children: [
                  for (final id in liveIds)
                    OmniWebViewWidget(
                      key: ValueKey('wv-$id'),
                      controller: _controllers[id]!,
                    ),
                ],
              ),
            ),
          ),
        if (isSleeping)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.bedtime_outlined, size: 48),
                      const SizedBox(height: 10),
                      Text(
                        '「${active.name}」は休止中です',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
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
              ),
            ),
          )
        else if (hasError)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.wifi_off, size: 48),
                      const SizedBox(height: 10),
                      const Text(
                        'ページの読み込みに失敗しました',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(activeRt!.loadError!, textAlign: TextAlign.center),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton(
                            onPressed: _reloadActiveTab,
                            child: const Text('再読み込み'),
                          ),
                          OutlinedButton(
                            onPressed: () {
                              final url = isHttpOrHttpsUrl(activeRt.currentUrl)
                                  ? activeRt.currentUrl
                                  : active.url;
                              _openExternalUrlSafely(url);
                            },
                            child: const Text('外部ブラウザで開く'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBottomTabStrip(
    List<_ServiceGroup> groups,
    _ServiceGroup? activeGroup,
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
                  itemCount: groups.length,
                  itemBuilder: (context, index) {
                    final group = groups[index];
                    final isActive = group.key == activeGroup?.key;
                    final primary = isActive && _activeInstance != null
                        ? _activeInstance!
                        : _pickTargetAccountForGroup(group);
                    final allSleeping = group.accounts.every(
                      (a) => _runtimeMap[a.instanceId]?.isSleeping != false,
                    );
                    var unread = 0;
                    for (final acc in group.accounts) {
                      if (!acc.notificationsEnabled) continue;
                      unread += _runtimeMap[acc.instanceId]?.unreadCount ?? 0;
                    }
                    final color = parseHexColor(primary.colorHex);

                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _activateGroup(group),
                        onLongPress: () => _showInstanceActionSheet(primary),
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
                                    alpha: allSleeping ? 0.45 : 1.0,
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  primary.badge,
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
                                  group.displayName,
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
                              if (_multiProfileSupported &&
                                  group.accounts.length >= 2) ...[
                                const SizedBox(width: 4),
                                Text(
                                  '${group.accounts.length}垢',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ],
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
                icon: const Icon(Icons.add, size: 22),
                visualDensity: VisualDensity.compact,
                tooltip: 'サービス追加',
                onPressed: _openCatalog,
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 24),
                visualDensity: VisualDensity.compact,
                tooltip: '下部タブを折り畳む',
                onPressed: _toggleBottomTabsCollapsed,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showInstanceActionSheet(ServiceInstance inst) async {
    final grp = _serviceGroups.cast<_ServiceGroup?>().firstWhere(
          (g) => g?.key == serviceGroupKey(inst),
          orElse: () => null,
        );
    final idx = grp == null
        ? 0
        : max(0, grp.accounts.indexWhere((a) => a.instanceId == inst.instanceId));
    final accLabel = accountDisplayLabel(
      inst,
      idx,
      baseServiceName: grp?.displayName,
    );
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                _multiProfileSupported
                    ? '${grp?.displayName ?? inst.name} · $accLabel'
                    : (grp?.displayName ?? inst.name),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(inst.url),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(
                _multiProfileSupported ? 'アカウント名・URLを編集' : '表示名・URLを編集',
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _editInstance(inst);
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout_outlined),
              title: Text(
                _multiProfileSupported
                    ? 'このアカウントのログイン情報を消去'
                    : 'ログイン情報を消去',
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _clearSessionForInstance(inst);
              },
            ),
            ListTile(
              leading: const Icon(Icons.bedtime_outlined),
              title: Text(
                _multiProfileSupported
                    ? 'このアカウントを休止（メモリ解放）'
                    : 'このタブを休止（メモリ解放）',
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _sleepInstance(inst.instanceId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: Text(
                _multiProfileSupported ? 'このアカウントを削除' : 'このサービスを削除',
                style: const TextStyle(color: Colors.redAccent),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _removeInstance(inst);
              },
            ),
            if (_multiProfileSupported && grp != null && grp.accounts.length >= 2)
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined,
                    color: Colors.redAccent),
                title: Text(
                  '「${grp.displayName}」の全${grp.accounts.length}アカウントを削除',
                  style: const TextStyle(color: Colors.redAccent),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _removeGroup(grp);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawer(
    List<_ServiceGroup> groups,
    _ServiceGroup? activeGroup,
  ) {
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
                          'Android · v1.4.0',
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
                itemCount: groups.length,
                onReorder: (oldIndex, newIndex) async {
                  if (newIndex > oldIndex) newIndex -= 1;
                  final reorderedGroups = List<_ServiceGroup>.from(groups);
                  final moved = reorderedGroups.removeAt(oldIndex);
                  reorderedGroups.insert(newIndex, moved);
                  setState(() {
                    _instances = reorderedGroups
                        .expand((g) => g.accounts)
                        .toList();
                  });
                  await _persist();
                },
                itemBuilder: (context, index) {
                  final group = groups[index];
                  final selected = group.key == activeGroup?.key;
                  final primary = selected && _activeInstance != null
                      ? _activeInstance!
                      : _pickTargetAccountForGroup(group);
                  final allSleeping = group.accounts.every(
                    (a) => _runtimeMap[a.instanceId]?.isSleeping != false,
                  );
                  final host = Uri.tryParse(primary.url)?.host ?? '';
                  final subtitleParts = <String>[
                    if (_multiProfileSupported && group.accounts.length >= 2)
                      '${group.accounts.length}アカウント',
                    if (allSleeping) '休止中',
                    if (host.isNotEmpty) host,
                  ];
                  return ListTile(
                    key: ValueKey('drawer-${group.key}'),
                    selected: selected,
                    leading: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: parseHexColor(primary.colorHex),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        primary.badge,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(
                      group.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: subtitleParts.isEmpty
                        ? null
                        : Text(
                            subtitleParts.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                    trailing: IconButton(
                      icon: const Icon(Icons.more_vert, size: 18),
                      onPressed: () {
                        Navigator.of(context).pop();
                        _showInstanceActionSheet(primary);
                      },
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      _activateGroup(group);
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
                      icon: const Icon(Icons.settings_outlined),
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
}
