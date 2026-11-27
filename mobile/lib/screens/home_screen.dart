import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/gesture_models.dart';
import '../models/service_models.dart';
import '../services/app_store.dart';
import '../services/follow_sync_service.dart';
import '../services/jev_service.dart';
import '../services/omni_webview.dart';
import '../widgets/gesture_overlay.dart';
import 'catalog_sheet.dart';
import 'gesture_settings_screen.dart';
import 'settings_sheet.dart';

/// サブタブを閉じた後に選択すべき次のアクティブタブID（null = メインタブ）を返す。
/// - 右側にタブがある場合は右隣のタブへ移動する
/// - 残りタブがメインタブのみ（2タブ状態で閉じた場合）や右端を閉じた場合は残りの隣接タブへ移動する
String? pickNextActiveSubTabAfterClose(
  List<String> remainingExtraTabIds,
  int closedIdx,
) {
  if (remainingExtraTabIds.isEmpty) {
    return null;
  }
  if (closedIdx >= 0 && closedIdx < remainingExtraTabIds.length) {
    return remainingExtraTabIds[closedIdx];
  }
  return remainingExtraTabIds.last;
}

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

class _ExtraSubTab {
  _ExtraSubTab({
    required this.tabId,
    required this.instanceId,
    required this.controller,
    required this.runtime,
  });

  final String tabId;
  final String instanceId;
  final OmniWebViewController controller;
  TabRuntimeState runtime;
}

class _JevTabLiveState {
  const _JevTabLiveState({
    this.active = false,
    this.matched = 0,
    this.hidden = 0,
    this.autoFetching = false,
  });

  final bool active;
  final int matched;
  final int hidden;
  final bool autoFetching;
}

class _AccountFilterTabLiveState {
  const _AccountFilterTabLiveState({
    this.active = false,
    this.matched = 0,
    this.hidden = 0,
    this.pending = 0,
    this.autoFetching = false,
  });

  final bool active;
  final int matched;
  final int hidden;
  final int pending;
  final bool autoFetching;
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const String _gmailUrl = 'https://mail.google.com/';
  static const String _gmailProfileName = 'omnisns_gmail';
  static const int _maxExtraSubTabsPerAccount = 12;

  bool _initialized = false;
  bool _multiProfileSupported = false;
  bool _isGmailOpen = false;
  OmniWebViewController? _gmailController;
  TabRuntimeState _gmailRuntime = const TabRuntimeState(
    currentUrl: _gmailUrl,
    title: 'Gmail',
    isSleeping: true,
  );
  List<CategoryMeta> _categories = const [];
  List<CatalogService> _catalog = const [];
  List<ServiceInstance> _instances = [];
  List<ArchivedInstance> _archivedInstances = [];
  AppSettings _settings = const AppSettings();
  FollowSyncSettings _followSyncSettings = const FollowSyncSettings();
  FollowSyncLedger _followLedger = FollowSyncLedger();
  Timer? _cloudSyncDebounce;
  Timer? _cloudSyncPeriodic;
  Timer? _followWindowRefreshTimer;
  Timer? _snackDismissTimer;
  Future<String>? _syncInFlight;
  bool _needsResync = false;
  int _manualSyncWaiters = 0;
  int _followSyncConfigGen = 0;

  final JevService _jev = JevService();
  final Map<String, OmniWebViewController> _controllers = {};
  final Map<String, TabRuntimeState> _runtimeMap = {};
  final Map<String, List<_ExtraSubTab>> _extraTabs = {};
  final Map<String, String?> _activeSubTabId = {};
  final Map<String, _JevTabLiveState> _jevLiveByKey = {};
  final Map<String, _AccountFilterTabLiveState> _accountFilterLiveByKey = {};
  int _jevCheckingCount = 0;
  int _subTabSeq = 0;
  final Map<String, String> _lastActiveByGroup = {};
  final Map<String, ({String service, String handle})> _crossSiteIdentities = {};
  final Map<String, List<int>> _bridgeEventTimestamps = {};
  final GlobalKey<MobileGestureOverlayState> _gestureOverlayKey = GlobalKey();
  final GlobalKey _rootStackKey = GlobalKey();
  final GlobalKey _viewportKey = GlobalKey();
  Offset? _movingOrbGlobalPos;
  bool _isOrbOverHeaderDock = false;
  bool _isDraggingFromHeaderDock = false;
  int? _headerDockPointer;
  Offset? _headerDockDownGlobal;
  Timer? _headerDockLongPressTimer;
  bool _headerDockLongPressFired = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _jev.addListener(_onJevChanged);
    unawaited(_jev.ensureLoaded());
    _bootstrap();
  }

  void _onJevChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // バックグラウンド中に Android LMK で終了したアクティブタブを復帰時に自動再構築する
      _syncActiveWebViews(forceNotifyActive: true);
    }
  }

  void _syncActiveWebViews({bool forceNotifyActive = false}) {
    final activeId = _isGmailOpen ? null : _settings.activeInstanceId;
    for (final entry in _controllers.entries) {
      final shouldBeActive =
          entry.key == activeId && _activeSubTabId[entry.key] == null;
      unawaited(
        entry.value.setActive(
          shouldBeActive,
          force: forceNotifyActive && shouldBeActive,
        ),
      );
    }
    for (final entry in _extraTabs.entries) {
      final activeSubId = entry.key == activeId ? _activeSubTabId[entry.key] : null;
      for (final tab in entry.value) {
        final shouldBeActive = activeSubId != null && tab.tabId == activeSubId;
        unawaited(
          tab.controller.setActive(
            shouldBeActive,
            force: forceNotifyActive && shouldBeActive,
          ),
        );
      }
    }
    final gCtrl = _gmailController;
    if (gCtrl != null && !gCtrl.isDisposed) {
      unawaited(
        gCtrl.setActive(
          _isGmailOpen,
          force: forceNotifyActive && _isGmailOpen,
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _jev.removeListener(_onJevChanged);
    _jev.dispose();
    _cloudSyncDebounce?.cancel();
    _cloudSyncPeriodic?.cancel();
    _followWindowRefreshTimer?.cancel();
    _snackDismissTimer?.cancel();
    _headerDockLongPressTimer?.cancel();
    _gmailController?.dispose();
    _gmailController = null;
    for (final ctrl in _controllers.values) {
      ctrl.dispose();
    }
    _controllers.clear();
    for (final list in _extraTabs.values) {
      for (final tab in list) {
        tab.controller.dispose();
      }
    }
    _extraTabs.clear();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final catalogData = await widget.store.loadCatalog();
      final (settings, loadedInstances) =
          await widget.store.loadState(catalogData.services);
      final archivedInstances =
          await widget.store.loadArchivedInstances(loadedInstances);
      final (followSyncSettings, followLedger) =
          await widget.store.loadFollowSyncState();
      final today = formatLocalYmd(DateTime.now());
      final (instances, _) = projectLedgerToInstances(
        loadedInstances,
        followLedger,
        today,
        windowHours: settings.followWindowHours,
      );
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
        _archivedInstances = archivedInstances;
        _followSyncSettings = followSyncSettings;
        _followLedger = followLedger;
        _multiProfileSupported = multiProfile;
        _initialized = true;
      });

      widget.onThemeChanged(settings.isDarkMode);
      _ensureSafeActiveAndLoad();
      _startFollowSyncEngine();
      _followWindowRefreshTimer?.cancel();
      _followWindowRefreshTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _refreshFollowWindowCounts(),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _initialized = true;
      });
      _showSnack('初期データの読み込みに失敗しました');
    }
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
    _syncActiveWebViews();
    if (mounted) setState(() {});
  }

  Future<void> _persist() async {
    await widget.store.saveState(_settings, _instances);
  }

  bool _allowBridgeEvent(String instanceId) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final list = _bridgeEventTimestamps.putIfAbsent(instanceId, () => <int>[]);
    list.removeWhere((t) => nowMs - t > 1000);
    if (list.length >= 25) return false;
    list.add(nowMs);
    return true;
  }

  String? _verifiedBridgeService(
    ServiceInstance src,
    String nativeService, {
    String? overrideUrl,
  }) {
    final currentUrl = overrideUrl ?? _runtimeMap[src.instanceId]?.currentUrl;
    final fromUrl = detectPlatformServiceFromUrl(currentUrl);
    if (fromUrl != null) return fromUrl;
    // Mastodon / Misskey のカスタムインスタンスや初回ロード直後のイベントは、
    // ネイティブ側で HTTPS オリジン検証済みのサービスIDとタブ設定 URL のホスト一致で検証する
    final normNative = nativeService.trim().toLowerCase();
    if (normNative.isEmpty) return null;
    if (normNative == 'mastodon' || normNative == 'misskey') {
      final curUri =
          currentUrl != null ? Uri.tryParse(currentUrl.trim()) : null;
      final srcUri = Uri.tryParse(src.url.trim());
      if (curUri != null &&
          srcUri != null &&
          curUri.scheme == 'https' &&
          curUri.host.isNotEmpty &&
          curUri.host.toLowerCase() == srcUri.host.toLowerCase() &&
          src.serviceId == normNative) {
        return normNative;
      }
    }
    const knownNativeServices = <String>{
      'instagram',
      'threads',
      'bluesky',
      'mixi2',
      'x',
      'tiktok',
      'facebook',
      'note',
      'youtube',
      'twitch',
      'reddit',
      'pinterest',
      'linkedin',
      'tumblr',
      'pixiv',
      'mastodon',
      'misskey',
    };
    if (knownNativeServices.contains(normNative) &&
        (currentUrl == null || currentUrl.trim().isEmpty)) {
      return normNative;
    }
    return null;
  }

  int? _sanitizeBridgeStat(int? raw) {
    if (raw == null || raw < 0) return null;
    return raw > 0xFFFFFFFF ? 0xFFFFFFFF : raw;
  }

  void _clearCrossSiteHintIfReturned(String instanceId, String url) {
    final src = _instances.cast<ServiceInstance?>().firstWhere(
          (i) => i?.instanceId == instanceId,
          orElse: () => null,
        );
    if (src == null) return;
    final detected = detectPlatformServiceFromUrl(url);
    if (detected == src.serviceId) {
      _crossSiteIdentities.remove(instanceId);
    }
  }

  Future<void> _persistArchived() async {
    await widget.store.saveArchivedInstances(_archivedInstances);
  }

  String _formatArchivedDisplayTitle(ServiceInstance inst) {
    return formatArchivedAccountTitle(inst);
  }

  Future<ServiceInstance?> _renameArchivedInstance(
    String instanceId,
    String newLabel,
  ) async {
    final idx = _archivedInstances
        .indexWhere((a) => a.instance.instanceId == instanceId);
    if (idx == -1) return null;
    final entry = _archivedInstances[idx];
    final trimmed = newLabel.trim();
    final updatedInst = entry.instance.copyWith(
      accountLabel: trimmed.isEmpty ? null : trimmed,
      clearAccountLabel: trimmed.isEmpty,
    );
    setState(() {
      _archivedInstances[idx] = ArchivedInstance(
        instance: updatedInst,
        archivedAt: entry.archivedAt,
      );
    });
    await _persistArchived();
    return updatedInst;
  }

  Future<void> _updateCatalogOrder(List<String> newOrder) async {
    final sanitized = sanitizeCatalogOrder(newOrder);
    if (mounted) {
      setState(() {
        _settings = _settings.copyWith(catalogOrder: sanitized);
      });
    } else {
      _settings = _settings.copyWith(catalogOrder: sanitized);
    }
    await _persist();
  }

  void _refreshFollowWindowCounts() {
    if (!mounted || !_initialized) return;
    final today = formatLocalYmd(DateTime.now());
    final (projected, changed) = projectLedgerToInstances(
      _instances,
      _followLedger,
      today,
      windowHours: _settings.followWindowHours,
    );
    if (changed && mounted) {
      setState(() {
        _instances = projected;
      });
      unawaited(_persist());
    }
  }

  Future<void> _updateFollowWindowHours(int hours) async {
    final clamped = hours.clamp(minFollowWindowHours, maxFollowWindowHours);
    final today = formatLocalYmd(DateTime.now());
    final (projected, _) = projectLedgerToInstances(
      _instances,
      _followLedger,
      today,
      windowHours: clamped,
    );
    if (mounted) {
      setState(() {
        _settings = _settings.copyWith(followWindowHours: clamped);
        _instances = projected;
      });
    } else {
      _settings = _settings.copyWith(followWindowHours: clamped);
      _instances = projected;
    }
    await _persist();
  }

  Future<void> _archiveInstances(List<ServiceInstance> removed) async {
    if (removed.isEmpty) return;
    final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    setState(() {
      for (final inst in removed.reversed) {
        _archivedInstances.removeWhere(
          (a) => a.instance.instanceId == inst.instanceId,
        );
        _archivedInstances.insert(
          0,
          ArchivedInstance(instance: inst, archivedAt: nowSecs),
        );
      }
      if (_archivedInstances.length > 100) {
        _archivedInstances = _archivedInstances.sublist(0, 100);
      }
    });
    await _persistArchived();
  }

  Future<void> _restoreArchivedInstance(String instanceId) async {
    final idx = _archivedInstances
        .indexWhere((a) => a.instance.instanceId == instanceId);
    if (idx == -1) return;
    final entry = _archivedInstances[idx];
    final inst = entry.instance;

    final existingIdx =
        _instances.indexWhere((i) => i.instanceId == inst.instanceId);
    if (existingIdx != -1) {
      setState(() {
        _archivedInstances.removeAt(idx);
      });
      await _persistArchived();
      _activateInstance(_instances[existingIdx]);
      return;
    }

    final groupKey = serviceGroupKey(inst);
    final lastSiblingIdx = _instances.lastIndexWhere(
      (i) => serviceGroupKey(i) == groupKey,
    );
    final insertAt =
        lastSiblingIdx >= 0 ? lastSiblingIdx + 1 : _instances.length;

    _lastActiveByGroup[groupKey] = inst.instanceId;
    setState(() {
      _archivedInstances.removeAt(idx);
      _instances.insert(insertAt, inst);
      _runtimeMap[inst.instanceId] = TabRuntimeState(
        currentUrl: inst.url,
        title: inst.name,
        isSleeping: true,
      );
      _isGmailOpen = false;
      _settings = _settings.copyWith(activeInstanceId: inst.instanceId);
    });
    _ensureController(inst);
    _syncActiveWebViews();
    await _persist();
    await _persistArchived();
    _showSnack('「${_formatArchivedDisplayTitle(inst)}」をログイン記憶から呼び出しました');
  }

  Future<void> _purgeArchivedInstance(String instanceId) async {
    final idx = _archivedInstances
        .indexWhere((a) => a.instance.instanceId == instanceId);
    if (idx == -1) return;
    final removed = _archivedInstances[idx].instance;
    setState(() {
      _archivedInstances.removeAt(idx);
    });
    await _persistArchived();
    final stillActive = _instances.any((i) => i.instanceId == instanceId);
    if (!stillActive &&
        _multiProfileSupported &&
        removed.effectiveProfileName != defaultWebViewProfileName) {
      await OmniWebViewManager.deleteProfile(removed.effectiveProfileName);
    }
    _showSnack('「${_formatArchivedDisplayTitle(removed)}」のログイン記憶を完全削除しました');
  }

  Future<void> _purgeAllArchivedInstances() async {
    if (_archivedInstances.isEmpty) return;
    final removed = List<ArchivedInstance>.from(_archivedInstances);
    setState(() {
      _archivedInstances.clear();
    });
    await _persistArchived();
    if (_multiProfileSupported) {
      for (final entry in removed) {
        final inst = entry.instance;
        final stillActive =
            _instances.any((i) => i.instanceId == inst.instanceId);
        if (!stillActive &&
            inst.effectiveProfileName != defaultWebViewProfileName) {
          await OmniWebViewManager.deleteProfile(inst.effectiveProfileName);
        }
      }
    }
    _showSnack('ログイン記憶 ${removed.length} 件を完全削除しました');
  }

  OmniWebViewController _ensureController(ServiceInstance instance) {
    final existing = _controllers[instance.instanceId];
    if (existing != null && !existing.isDisposed) return existing;

    final isCurrentlyActive = !_isGmailOpen &&
        _settings.activeInstanceId == instance.instanceId &&
        _activeSubTabId[instance.instanceId] == null;
    late final OmniWebViewController controller;
    controller = OmniWebViewController(
      initialUrl: instance.url,
      profileName: _multiProfileSupported
          ? instance.effectiveProfileName
          : defaultWebViewProfileName,
      userAgent: buildUserAgentForMode(instance.uaMode),
      serviceId: instance.serviceId,
      initiallyActive: isCurrentlyActive,
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
        if (isHttpOrHttpsUrl(url)) {
          _clearCrossSiteHintIfReturned(instance.instanceId, url);
        }
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
        if (validUrl) {
          _clearCrossSiteHintIfReturned(instance.instanceId, url);
        }
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
        if (isHttpOrHttpsUrl(url)) {
          _clearCrossSiteHintIfReturned(instance.instanceId, url);
        }
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
      onFollowDetected: (_, service) {
        if (!_allowBridgeEvent(instance.instanceId)) return;
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => null,
            );
        if (src == null) return;
        final verifiedService = _verifiedBridgeService(src, service);
        if (verifiedService == null) return;
        final resolved = _resolveCounterTarget(
          src,
          explicitService: verifiedService,
        );
        if (resolved.target != null) {
          _adjustFollowCount(resolved.target!.instanceId, 1);
        }
      },
      onUnfollowDetected: (_, service) {
        if (!_allowBridgeEvent(instance.instanceId)) return;
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => null,
            );
        if (src == null) return;
        final verifiedService = _verifiedBridgeService(src, service);
        if (verifiedService == null) return;
        final resolved = _resolveCounterTarget(
          src,
          explicitService: verifiedService,
        );
        if (resolved.target != null) {
          _adjustUnfollowCount(resolved.target!.instanceId, 1);
        }
      },
      onAccountIdentity: (service, handle, following, followers) {
        if (!_allowBridgeEvent(instance.instanceId)) return;
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => null,
            );
        if (src == null) return;
        final verifiedService = _verifiedBridgeService(src, service);
        if (verifiedService == null) return;
        final normHandle = normalizeAccountHandle(handle);
        if (normHandle == null) return;
        if (verifiedService != src.serviceId) {
          _crossSiteIdentities[src.instanceId] =
              (service: verifiedService, handle: normHandle);
        }
        final resolved = _resolveCounterTarget(
          src,
          explicitService: verifiedService,
          handleHint: normHandle,
        );
        if (resolved.target != null) {
          _handleAccountIdentity(
            resolved.target!.instanceId,
            normHandle,
            following: _sanitizeBridgeStat(following),
            followers: _sanitizeBridgeStat(followers),
          );
        }
      },
      onOpenNewTab: (url, activate) {
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => instance,
            );
        if (src != null) {
          // F/FW バッジのタップ（activate=true）は新規タブを開いてそのまま切り替える
          _openUrlInNewSubTab(src, url, activate: activate);
        }
      },
      onJevGetConfig: () {
        _pushJevConfigToController(controller);
      },
      onJevCheckAccounts: (reqId, payloadJson) {
        unawaited(_handleJevCheckFromWebView(controller, reqId, payloadJson));
      },
      onJevState: (active, matched, hidden, autoFetching) {
        _updateJevLiveState(
          'main:${instance.instanceId}',
          active: active,
          matched: matched,
          hidden: hidden,
          autoFetching: autoFetching,
        );
      },
      onAccountFilterGetConfig: () {
        _pushAccountFilterConfigToController(controller);
      },
      onAccountFilterState: (active, matched, hidden, pending, autoFetching) {
        _updateAccountFilterLiveState(
          'main:${instance.instanceId}',
          active: active,
          matched: matched,
          hidden: hidden,
          pending: pending,
          autoFetching: autoFetching,
        );
      },
    );

    _controllers[instance.instanceId] = controller;
    // 新しいコントローラの WebView を必ずビルドさせるため、見た目が同じでも再ビルドする
    _updateRuntime(
      instance.instanceId,
      (cur) => cur.copyWith(
        isSleeping: false,
        isLoading: true,
        clearError: true,
      ),
      forceRebuild: true,
    );
    return controller;
  }

  _ExtraSubTab? _activeExtraTabFor(String instanceId) {
    final activeTid = _activeSubTabId[instanceId];
    if (activeTid == null) return null;
    final list = _extraTabs[instanceId];
    if (list == null) return null;
    for (final tab in list) {
      if (tab.tabId == activeTid) return tab;
    }
    return null;
  }

  String _activeJevKeyFor(ServiceInstance? active) {
    if (active == null) return '';
    final extra = _activeExtraTabFor(active.instanceId);
    return extra != null ? 'sub:${extra.tabId}' : 'main:${active.instanceId}';
  }

  _JevTabLiveState _currentJevLiveState(ServiceInstance? active) {
    if (_isGmailOpen || active == null) return const _JevTabLiveState();
    return _jevLiveByKey[_activeJevKeyFor(active)] ?? const _JevTabLiveState();
  }

  void _updateJevLiveState(
    String key, {
    required bool active,
    required int matched,
    required int hidden,
    required bool autoFetching,
  }) {
    final prev = _jevLiveByKey[key];
    if (prev != null &&
        prev.active == active &&
        prev.matched == matched &&
        prev.hidden == hidden &&
        prev.autoFetching == autoFetching) {
      return;
    }
    if (active) {
      _jevLiveByKey[key] = _JevTabLiveState(
        active: active,
        matched: matched,
        hidden: hidden,
        autoFetching: autoFetching,
      );
    } else {
      _jevLiveByKey.remove(key);
    }
    if (mounted) setState(() {});
  }

  void _pushJevConfigToController(
    OmniWebViewController ctrl, {
    bool resetJudged = false,
  }) {
    if (ctrl.isDisposed) return;
    final payload = jsonEncode(_jev.jsConfigPayload(resetJudged: resetJudged));
    unawaited(
      ctrl.evaluateJavascript(
        'window.__omniJevApplyConfig && window.__omniJevApplyConfig($payload);',
      ),
    );
  }

  void _syncJevConfigToAllControllers({bool resetJudged = false}) {
    for (final ctrl in _controllers.values) {
      _pushJevConfigToController(ctrl, resetJudged: resetJudged);
    }
    for (final list in _extraTabs.values) {
      for (final tab in list) {
        _pushJevConfigToController(tab.controller, resetJudged: resetJudged);
      }
    }
  }

  _AccountFilterTabLiveState _currentAccountFilterLiveState(
    ServiceInstance? active,
  ) {
    if (_isGmailOpen || active == null) {
      return const _AccountFilterTabLiveState();
    }
    return _accountFilterLiveByKey[_activeJevKeyFor(active)] ??
        const _AccountFilterTabLiveState();
  }

  void _updateAccountFilterLiveState(
    String key, {
    required bool active,
    required int matched,
    required int hidden,
    required int pending,
    required bool autoFetching,
  }) {
    final prev = _accountFilterLiveByKey[key];
    if (prev != null &&
        prev.active == active &&
        prev.matched == matched &&
        prev.hidden == hidden &&
        prev.pending == pending &&
        prev.autoFetching == autoFetching) {
      return;
    }
    if (active) {
      _accountFilterLiveByKey[key] = _AccountFilterTabLiveState(
        active: active,
        matched: matched,
        hidden: hidden,
        pending: pending,
        autoFetching: autoFetching,
      );
    } else {
      _accountFilterLiveByKey.remove(key);
    }
    if (mounted) setState(() {});
  }

  void _pushAccountFilterConfigToController(OmniWebViewController ctrl) {
    if (ctrl.isDisposed) return;
    final payload = jsonEncode(_settings.accountFilter.toJsConfig());
    unawaited(
      ctrl.evaluateJavascript(
        'window.__omniAccountFilterApplyConfig && window.__omniAccountFilterApplyConfig($payload);',
      ),
    );
  }

  void _syncAccountFilterConfigToAllControllers() {
    if (!_settings.accountFilter.isActive) {
      _accountFilterLiveByKey.clear();
    }
    for (final ctrl in _controllers.values) {
      _pushAccountFilterConfigToController(ctrl);
    }
    for (final list in _extraTabs.values) {
      for (final tab in list) {
        _pushAccountFilterConfigToController(tab.controller);
      }
    }
  }

  Future<void> _updateAccountFilterSettings(
    AccountFilterSettings next, {
    String? toastMessage,
  }) async {
    final sanitized = next.sanitized();
    setState(() {
      _settings = _settings.copyWith(accountFilter: sanitized);
    });
    _syncAccountFilterConfigToAllControllers();
    await _persist();
    if (toastMessage != null && mounted) {
      _showSnack(toastMessage);
    }
  }

  Future<void> _quickToggleAccountFilter() async {
    final af = _settings.accountFilter;
    if (!af.hasAnyCondition) {
      await _showAccountFilterSheet();
      return;
    }
    final next = af.copyWith(enabled: !af.enabled).sanitized();
    await _updateAccountFilterSettings(
      next,
      toastMessage: next.isActive
          ? 'アカウント条件フィルタ ON（${next.summaryLabel}）'
          : 'アカウント条件フィルタ OFF',
    );
  }

  Future<void> _handleJevCheckFromWebView(
    OmniWebViewController ctrl,
    String reqId,
    String payloadJson,
  ) async {
    await _jev.ensureLoaded();
    if (!_jev.isActive || ctrl.isDisposed) {
      if (!ctrl.isDisposed) {
        unawaited(
          ctrl.evaluateJavascript(
            'window.__omniJevResolve && window.__omniJevResolve(${jsonEncode(reqId)}, {});',
          ),
        );
      }
      return;
    }
    List<dynamic> rawList;
    try {
      final decoded = jsonDecode(payloadJson);
      rawList = decoded is List ? decoded : const [];
    } catch (_) {
      rawList = const [];
    }
    final candidates = <JevAccountCandidate>[
      for (final item in rawList)
        if (item is Map && item['u'] is String)
          JevAccountCandidate(
            username: item['u'] as String,
            displayName: (item['n'] as String?) ?? '',
            bio: (item['bio'] as String?) ?? '',
            avatarUrl: (item['img'] as String?) ?? '',
            avatarBase64: item['b64'] as String?,
            avatarFormat: item['fmt'] as String?,
            platform: (item['p'] as String?) ?? 'instagram',
          ),
    ];
    if (candidates.isEmpty) {
      if (!ctrl.isDisposed) {
        unawaited(
          ctrl.evaluateJavascript(
            'window.__omniJevResolve && window.__omniJevResolve(${jsonEncode(reqId)}, {});',
          ),
        );
      }
      return;
    }
    if (mounted) {
      setState(() => _jevCheckingCount++);
    } else {
      _jevCheckingCount++;
    }
    try {
      final res = await _jev.judgeAccounts(candidates);
      if (!ctrl.isDisposed) {
        unawaited(
          ctrl.evaluateJavascript(
            'window.__omniJevResolve && window.__omniJevResolve(${jsonEncode(reqId)}, ${jsonEncode(res)});',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _jevCheckingCount = max(0, _jevCheckingCount - 1));
      } else {
        _jevCheckingCount = max(0, _jevCheckingCount - 1);
      }
    }
  }

  void _openUrlInNewSubTab(
    ServiceInstance instance,
    String rawUrl, {
    bool activate = false,
  }) {
    final targetUrl = normalizeServiceUrl(rawUrl) ?? instance.url;
    final list = _extraTabs.putIfAbsent(instance.instanceId, () => []);
    if (list.length >= _maxExtraSubTabsPerAccount) {
      _showSnack('1アカウントで開ける追加タブは最大 $_maxExtraSubTabsPerAccount 件です');
      return;
    }

    final tabId = 'sub-${++_subTabSeq}';
    final initialTitle = Uri.tryParse(targetUrl)?.host ?? instance.name;
    final isSubInitiallyActive = activate &&
        !_isGmailOpen &&
        _settings.activeInstanceId == instance.instanceId;
    late final _ExtraSubTab subTab;
    late final OmniWebViewController ctrl;
    ctrl = OmniWebViewController(
      initialUrl: targetUrl,
      profileName: _multiProfileSupported
          ? instance.effectiveProfileName
          : defaultWebViewProfileName,
      userAgent: buildUserAgentForMode(instance.uaMode),
      serviceId: instance.serviceId,
      initiallyActive: isSubInitiallyActive,
      onProgress: (progress) {
        _updateSubTabRuntime(
          subTab,
          (cur) => cur.copyWith(
            progress: progress,
            isLoading: progress < 100,
            isSleeping: false,
          ),
        );
      },
      onPageStarted: (url) {
        _updateSubTabRuntime(
          subTab,
          (cur) => cur.copyWith(
            currentUrl: isHttpOrHttpsUrl(url) ? url : cur.currentUrl,
            isLoading: true,
            isSleeping: false,
            clearError: true,
          ),
        );
      },
      onPageFinished: (url, title, canBack, canFwd, hadError) {
        final safeTitle = title.trim().isEmpty ? initialTitle : title;
        final validUrl = isHttpOrHttpsUrl(url);
        _updateSubTabRuntime(
          subTab,
          (cur) => cur.copyWith(
            currentUrl: validUrl ? url : cur.currentUrl,
            title: safeTitle,
            progress: 100,
            isLoading: false,
            isSleeping: false,
            canGoBack: canBack,
            canGoForward: canFwd,
            clearError: !hadError && validUrl,
          ),
        );
      },
      onTitleChanged: (title) {
        final safeTitle = title.trim().isEmpty ? initialTitle : title;
        _updateSubTabRuntime(
          subTab,
          (cur) => cur.copyWith(title: safeTitle),
        );
      },
      onHistoryChanged: (url, canBack, canFwd) {
        _updateSubTabRuntime(
          subTab,
          (cur) => cur.copyWith(
            currentUrl: isHttpOrHttpsUrl(url) ? url : cur.currentUrl,
            canGoBack: canBack,
            canGoForward: canFwd,
          ),
        );
      },
      onWebResourceError: (description, errorCode) {
        _updateSubTabRuntime(
          subTab,
          (cur) => cur.copyWith(
            isLoading: false,
            loadError: '$description ($errorCode)',
          ),
        );
      },
      onExternalScheme: (url) => _openExternalUrlSafely(url),
      onFollowDetected: (_, service) {
        if (!_allowBridgeEvent(instance.instanceId)) return;
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => null,
            );
        if (src == null) return;
        final verifiedService = _verifiedBridgeService(
          src,
          service,
          overrideUrl: subTab.runtime.currentUrl,
        );
        if (verifiedService == null) return;
        final resolved =
            _resolveCounterTarget(src, explicitService: verifiedService);
        if (resolved.target != null) {
          _adjustFollowCount(resolved.target!.instanceId, 1);
        }
      },
      onUnfollowDetected: (_, service) {
        if (!_allowBridgeEvent(instance.instanceId)) return;
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => null,
            );
        if (src == null) return;
        final verifiedService = _verifiedBridgeService(
          src,
          service,
          overrideUrl: subTab.runtime.currentUrl,
        );
        if (verifiedService == null) return;
        final resolved =
            _resolveCounterTarget(src, explicitService: verifiedService);
        if (resolved.target != null) {
          _adjustUnfollowCount(resolved.target!.instanceId, 1);
        }
      },
      onAccountIdentity: (service, handle, following, followers) {
        if (!_allowBridgeEvent(instance.instanceId)) return;
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => null,
            );
        if (src == null) return;
        final verifiedService = _verifiedBridgeService(
          src,
          service,
          overrideUrl: subTab.runtime.currentUrl,
        );
        if (verifiedService == null) return;
        final normHandle = normalizeAccountHandle(handle);
        if (normHandle == null) return;
        final resolved = _resolveCounterTarget(
          src,
          explicitService: verifiedService,
          handleHint: normHandle,
        );
        if (resolved.target != null) {
          _handleAccountIdentity(
            resolved.target!.instanceId,
            normHandle,
            following: _sanitizeBridgeStat(following),
            followers: _sanitizeBridgeStat(followers),
          );
        }
      },
      onOpenNewTab: (url, activate) {
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => instance,
            );
        if (src != null) {
          // F/FW バッジのタップ（activate=true）は新規タブを開いてそのまま切り替える
          _openUrlInNewSubTab(src, url, activate: activate);
        }
      },
      onJevGetConfig: () => _pushJevConfigToController(ctrl),
      onJevCheckAccounts: (reqId, payloadJson) {
        unawaited(_handleJevCheckFromWebView(ctrl, reqId, payloadJson));
      },
      onJevState: (active, matched, hidden, autoFetching) {
        _updateJevLiveState(
          'sub:$tabId',
          active: active,
          matched: matched,
          hidden: hidden,
          autoFetching: autoFetching,
        );
      },
      onAccountFilterGetConfig: () => _pushAccountFilterConfigToController(ctrl),
      onAccountFilterState: (active, matched, hidden, pending, autoFetching) {
        _updateAccountFilterLiveState(
          'sub:$tabId',
          active: active,
          matched: matched,
          hidden: hidden,
          pending: pending,
          autoFetching: autoFetching,
        );
      },
    );

    subTab = _ExtraSubTab(
      tabId: tabId,
      instanceId: instance.instanceId,
      controller: ctrl,
      runtime: TabRuntimeState(
        currentUrl: targetUrl,
        title: initialTitle,
        isSleeping: false,
        isLoading: true,
        progress: 10,
      ),
    );

    list.add(subTab);
    final totalTabs = list.length + 1;
    if (activate) {
      _activeSubTabId[instance.instanceId] = tabId;
      _syncActiveWebViews();
    }
    if (mounted) {
      setState(() {});
      HapticFeedback.mediumImpact();
      if (!activate) {
        _showTimedSnackBar(
          SnackBar(
            content: Text('裏タブで開きました（全$totalTabsタブ）'),
            duration: const Duration(milliseconds: 2500),
            action: SnackBarAction(
              label: '開く',
              onPressed: () {
                _snackDismissTimer?.cancel();
                if (!mounted) return;
                final stillExists = (_extraTabs[instance.instanceId] ?? [])
                    .any((t) => t.tabId == tabId);
                if (stillExists) {
                  setState(() {
                    _isGmailOpen = false;
                    _activeSubTabId[instance.instanceId] = tabId;
                  });
                  _syncActiveWebViews();
                }
              },
            ),
          ),
          duration: const Duration(milliseconds: 2500),
        );
      }
    }
  }

  void _closeExtraSubTab(String instanceId, String tabId) {
    final list = _extraTabs[instanceId];
    if (list == null) return;
    final idx = list.indexWhere((t) => t.tabId == tabId);
    if (idx < 0) return;
    final removed = list.removeAt(idx);
    removed.controller.dispose();
    _jevLiveByKey.remove('sub:$tabId');
    _accountFilterLiveByKey.remove('sub:$tabId');
    if (_activeSubTabId[instanceId] == tabId) {
      final nextId = pickNextActiveSubTabAfterClose(
        list.map((t) => t.tabId).toList(),
        idx,
      );
      if (nextId == null) {
        _activeSubTabId.remove(instanceId);
      } else {
        _activeSubTabId[instanceId] = nextId;
      }
    }
    if (list.isEmpty) {
      _extraTabs.remove(instanceId);
    }
    _syncActiveWebViews();
    if (mounted) setState(() {});
  }

  void _disposeExtraSubTabsFor(String instanceId) {
    final list = _extraTabs.remove(instanceId);
    if (list != null) {
      for (final t in list) {
        t.controller.dispose();
        _jevLiveByKey.remove('sub:${t.tabId}');
        _accountFilterLiveByKey.remove('sub:${t.tabId}');
      }
    }
    _activeSubTabId.remove(instanceId);
    _jevLiveByKey.remove('main:$instanceId');
    _accountFilterLiveByKey.remove('main:$instanceId');
  }

  bool _stepActiveSubTab(int delta) {
    if (_isGmailOpen) {
      _showGestureNotice('他のタブがありません');
      return false;
    }
    final active = _activeInstance;
    if (active == null) return false;
    final extras = _extraTabs[active.instanceId] ?? const <_ExtraSubTab>[];
    if (extras.isEmpty) {
      _showGestureNotice('他のタブがありません');
      return false;
    }
    final total = extras.length + 1;
    final activeTid = _activeSubTabId[active.instanceId];
    final curIdx = activeTid == null
        ? 0
        : (extras.indexWhere((t) => t.tabId == activeTid) + 1);
    final nextIdx = stepTabIndex(total, curIdx, delta, _settings.gesture.wrapTabs);
    if (nextIdx == null) {
      _showGestureNotice(delta < 0 ? '先頭のタブです' : '末尾のタブです');
      return false;
    }
    setState(() {
      _activeSubTabId[active.instanceId] =
          nextIdx == 0 ? null : extras[nextIdx - 1].tabId;
    });
    _syncActiveWebViews();
    _showGestureNotice('タブ ${nextIdx + 1}/$total');
    return true;
  }

  Future<void> _toggleDesktopMode(
    ServiceInstance inst, {
    bool? forceDesktop,
  }) async {
    final nextDesktop = forceDesktop ?? !inst.isDesktopUa;
    final nextMode = nextDesktop ? 'desktop' : 'mobile';
    final nextUa = buildUserAgentForMode(nextMode);
    setState(() {
      _instances = _instances
          .map(
            (i) => i.instanceId == inst.instanceId
                ? i.copyWith(uaMode: nextMode)
                : i,
          )
          .toList();
    });
    await _persist();
    final mainCtrl = _controllers[inst.instanceId];
    if (mainCtrl != null && !mainCtrl.isDisposed) {
      await mainCtrl.setUserAgent(nextUa, reload: true);
    }
    for (final sub in _extraTabs[inst.instanceId] ?? const <_ExtraSubTab>[]) {
      if (!sub.controller.isDisposed) {
        await sub.controller.setUserAgent(nextUa, reload: true);
      }
    }
    _showSnack(nextDesktop ? 'PC版サイト表示に切り替えました' : 'スマホ版サイト表示に戻しました');
  }

  void _updateRuntime(
    String instanceId,
    TabRuntimeState Function(TabRuntimeState current) updater, {
    bool forceRebuild = false,
  }) {
    final current = _runtimeMap[instanceId];
    if (current == null) return;
    final next = updater(current);
    _runtimeMap[instanceId] = next;
    if (!mounted) return;
    // 非表示タブの進捗だけの変化や、見た目が変わらない更新では再ビルドしない
    final visible = !_isGmailOpen &&
        _settings.activeInstanceId == instanceId &&
        _activeSubTabId[instanceId] == null;
    if (!forceRebuild && current.sameVisualState(next, includeProgress: visible)) {
      return;
    }
    setState(() {});
  }

  /// 追加サブタブの runtime を更新し、必要な場合のみ再ビルドする
  void _updateSubTabRuntime(
    _ExtraSubTab subTab,
    TabRuntimeState Function(TabRuntimeState current) updater,
  ) {
    final current = subTab.runtime;
    final next = updater(current);
    subTab.runtime = next;
    if (!mounted) return;
    final visible = !_isGmailOpen &&
        _settings.activeInstanceId == subTab.instanceId &&
        _activeSubTabId[subTab.instanceId] == subTab.tabId;
    if (current.sameVisualState(next, includeProgress: visible)) return;
    setState(() {});
  }

  void _activateInstance(ServiceInstance inst) {
    _lastActiveByGroup[serviceGroupKey(inst)] = inst.instanceId;
    setState(() {
      _isGmailOpen = false;
      _settings = _settings.copyWith(activeInstanceId: inst.instanceId);
    });
    _ensureController(inst);
    _syncActiveWebViews();
    _persist();
  }

  OmniWebViewController _ensureGmailController() {
    final existing = _gmailController;
    if (existing != null && !existing.isDisposed) return existing;

    final controller = OmniWebViewController(
      initialUrl: _gmailUrl,
      profileName: _multiProfileSupported
          ? _gmailProfileName
          : defaultWebViewProfileName,
      userAgent: buildMobileUserAgent(),
      serviceId: 'gmail',
      initiallyActive: _isGmailOpen,
      onProgress: (progress) {
        if (!mounted) return;
        setState(() {
          _gmailRuntime = _gmailRuntime.copyWith(
            progress: progress,
            isLoading: progress < 100,
            isSleeping: false,
          );
        });
      },
      onPageStarted: (url) {
        if (!mounted) return;
        setState(() {
          _gmailRuntime = _gmailRuntime.copyWith(
            currentUrl: isHttpOrHttpsUrl(url) ? url : _gmailRuntime.currentUrl,
            isLoading: true,
            isSleeping: false,
            clearError: true,
          );
        });
      },
      onPageFinished: (url, title, canBack, canFwd, hadError) {
        if (!mounted) return;
        final safeTitle = title.trim().isEmpty ? 'Gmail' : title;
        final validUrl = isHttpOrHttpsUrl(url);
        setState(() {
          _gmailRuntime = _gmailRuntime.copyWith(
            currentUrl: validUrl ? url : _gmailRuntime.currentUrl,
            title: safeTitle,
            progress: 100,
            isLoading: false,
            isSleeping: false,
            canGoBack: canBack,
            canGoForward: canFwd,
            clearError: !hadError && validUrl,
          );
        });
      },
      onTitleChanged: (title) {
        if (!mounted) return;
        setState(() {
          _gmailRuntime = _gmailRuntime.copyWith(
            title: title.trim().isEmpty ? 'Gmail' : title,
          );
        });
      },
      onHistoryChanged: (url, canBack, canFwd) {
        if (!mounted) return;
        setState(() {
          _gmailRuntime = _gmailRuntime.copyWith(
            currentUrl: isHttpOrHttpsUrl(url) ? url : _gmailRuntime.currentUrl,
            canGoBack: canBack,
            canGoForward: canFwd,
          );
        });
      },
      onWebResourceError: (description, errorCode) {
        if (!mounted) return;
        setState(() {
          _gmailRuntime = _gmailRuntime.copyWith(
            isLoading: false,
            loadError: '$description ($errorCode)',
          );
        });
      },
      onExternalScheme: (url) {
        _openExternalUrlSafely(url);
      },
    );

    _gmailController = controller;
    _gmailRuntime = _gmailRuntime.copyWith(
      isSleeping: false,
      isLoading: true,
      progress: 5,
      clearError: true,
    );
    return controller;
  }

  void _toggleInAppGmail() {
    if (_isGmailOpen) {
      setState(() {
        _isGmailOpen = false;
      });
      _syncActiveWebViews();
      return;
    }
    _ensureGmailController();
    setState(() {
      _isGmailOpen = true;
    });
    _syncActiveWebViews();
  }

  Future<void> _reloadGmail() async {
    final ctrl = _ensureGmailController();
    final fallbackUrl = isHttpOrHttpsUrl(_gmailRuntime.currentUrl)
        ? _gmailRuntime.currentUrl
        : _gmailUrl;
    setState(() {
      _gmailRuntime = _gmailRuntime.copyWith(
        isSleeping: false,
        isLoading: true,
        progress: 5,
        clearError: true,
      );
    });
    await ctrl.reload(fallbackUrl: fallbackUrl);
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
    if (_isGmailOpen) {
      await _reloadGmail();
      return;
    }
    final active = _activeInstance;
    if (active == null) return;
    final extra = _activeExtraTabFor(active.instanceId);
    if (extra != null && !extra.controller.isDisposed) {
      extra.runtime = extra.runtime.copyWith(
        isLoading: true,
        progress: 5,
        clearError: true,
      );
      if (mounted) setState(() {});
      await extra.controller.reload(fallbackUrl: extra.runtime.currentUrl);
      return;
    }
    await _reloadInstance(active);
  }

  Future<void> _openExternalUrlSafely(String rawUrl) async {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(trimmed)) {
      return;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return;
    final scheme = uri.scheme.toLowerCase();
    final allowed = switch (scheme) {
      'https' || 'http' => uri.host.isNotEmpty && !RegExp(r'[\s"\\]').hasMatch(trimmed),
      'mailto' => uri.path.trim().isNotEmpty,
      'tel' => uri.path.trim().isNotEmpty &&
          RegExp(r'^[+0-9()\-\s.]{1,32}$').hasMatch(uri.path.trim()),
      _ => false,
    };
    if (!allowed) {
      _showSnack('安全のためこのリンク形式は外部起動できません');
      return;
    }
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

  void _startFollowSyncEngine() {
    _cloudSyncPeriodic?.cancel();
    _cloudSyncPeriodic = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted) return;
      if (_followSyncSettings.githubToken.trim().isNotEmpty) {
        unawaited(_syncFollowCloudOnce(silent: true));
      }
    });

    if (_followSyncSettings.githubToken.trim().isNotEmpty) {
      unawaited(_syncFollowCloudOnce(silent: true));
    }
  }

  Future<void> _persistAllWithFollowSync() async {
    await widget.store.saveState(_settings, _instances);
    await widget.store.saveFollowSyncState(_followSyncSettings, _followLedger);
  }

  void _notifyFollowLedgerChanged() {
    if (_followSyncSettings.githubToken.trim().isNotEmpty) {
      _cloudSyncDebounce?.cancel();
      _cloudSyncDebounce = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          unawaited(_syncFollowCloudOnce(silent: true));
        }
      });
    }
  }

  Future<String> _syncFollowCloudOnce({bool silent = false}) async {
    if (silent) {
      final existing = _syncInFlight;
      if (existing != null) {
        _needsResync = true;
        try {
          return await existing;
        } catch (e) {
          return '同期エラー: ${formatSafeSyncError(e)}';
        }
      }
    } else {
      // 手動同期は進行中ジョブ（連鎖実行含む）が全て完了するまで厳密に直列待機する
      _manualSyncWaiters += 1;
      try {
        while (_syncInFlight != null) {
          try {
            await _syncInFlight!;
          } catch (_) {}
          if (!mounted) return '';
        }
      } finally {
        _manualSyncWaiters -= 1;
      }
    }

    final future = _runSingleFlightCloudSync(silent: silent);
    _syncInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_syncInFlight, future)) {
        _syncInFlight = null;
      }
      // 待機中の手動同期がある場合はそちらに譲り、並列実行（重複 Gist 作成等）を防止する
      if (_needsResync &&
          _manualSyncWaiters == 0 &&
          mounted &&
          _followSyncSettings.githubToken.trim().isNotEmpty) {
        _needsResync = false;
        unawaited(_syncFollowCloudOnce(silent: true));
      }
    }
  }

  Future<String> _runSingleFlightCloudSync({required bool silent}) async {
    final configGen = _followSyncConfigGen;
    final token = _followSyncSettings.githubToken.trim();
    final gistId = _followSyncSettings.gistId.trim();
    if (token.isEmpty) {
      const msg = 'GitHub Personal Access Token（gist 権限）を入力してください';
      if (!silent) throw const SyncUserException(msg);
      return msg;
    }

    final today = formatLocalYmd(DateTime.now());
    final snapshot = _followLedger.clone();
    try {
      final res = await FollowSyncService.syncWithGitHubGist(
        token: token,
        gistId: gistId,
        localLedger: snapshot,
        today: today,
      );
      // 同期実行中に認証情報（Token / Gist ID）が切り替わっていた場合、
      // 旧 Gist の結果を _followLedger へマージせず即破棄して異 Gist 間の汚染を防ぐ
      if (_followSyncConfigGen != configGen) {
        return '同期設定が変更されたため前回の同期結果を破棄しました';
      }
      _followLedger.mergeFrom(res.mergedLedger, today);
      final (projected, _) = projectLedgerToInstances(
        _instances,
        _followLedger,
        today,
        windowHours: _settings.followWindowHours,
      );
      if (mounted) {
        setState(() {
          _instances = projected;
          _followSyncSettings = _followSyncSettings.copyWith(
            gistId: res.gistId,
            lastSyncAt: nowUnixSecs(),
            lastSyncStatus: 'クラウド同期完了',
          );
        });
      }
      await _persistAllWithFollowSync();
      return 'クラウド同期完了';
    } catch (e) {
      final errText = formatSafeSyncError(e);
      if (mounted && _followSyncConfigGen == configGen) {
        setState(() {
          _followSyncSettings = _followSyncSettings.copyWith(
            lastSyncStatus: '同期エラー: $errText',
          );
        });
        await widget.store
            .saveFollowSyncState(_followSyncSettings, _followLedger);
      }
      if (!silent) throw SyncUserException(errText);
      return '同期エラー: $errText';
    }
  }

  ({
    ServiceInstance? target,
    bool isCrossSite,
    String? effectiveService,
  }) _resolveCounterTarget(
    ServiceInstance source, {
    String? explicitService,
    String? handleHint,
  }) {
    final rt = _runtimeMap[source.instanceId];
    final normExplicit = explicitService?.trim().toLowerCase();
    final effectiveService = (normExplicit != null && normExplicit.isNotEmpty)
        ? normExplicit
        : (detectPlatformServiceFromUrl(rt?.currentUrl) ?? source.serviceId);
    final isCrossSite = effectiveService != source.serviceId;
    final crossHint = _crossSiteIdentities[source.instanceId];
    final effectiveHandleHint = handleHint ??
        (crossHint != null && crossHint.service == effectiveService
            ? crossHint.handle
            : null);
    final target = resolveCounterTargetInstance(
      source: source,
      instances: _instances,
      currentUrl: rt?.currentUrl,
      explicitService: effectiveService,
      handleHint: effectiveHandleHint,
      lastActiveByGroup: _lastActiveByGroup,
    );
    return (
      target: target,
      isCrossSite: isCrossSite,
      effectiveService: effectiveService,
    );
  }

  String _serviceDisplayName(String serviceId) {
    final cat = _catalog.cast<CatalogService?>().firstWhere(
          (s) => s?.id == serviceId,
          orElse: () => null,
        );
    return cat?.name ?? serviceId;
  }

  Future<void> _handleAccountIdentity(
    String instanceId,
    String rawHandle, {
    int? following,
    int? followers,
  }) async {
    final norm = normalizeAccountHandle(rawHandle);
    if (norm == null) return;
    final idx = _instances.indexWhere((i) => i.instanceId == instanceId);
    if (idx == -1) return;

    final today = formatLocalYmd(DateTime.now());
    final now = nowUnixSecs();
    final winH = _settings.followWindowHours;
    final cutoff = now > winH * 3600 ? now - winH * 3600 : 0;
    final retentionCutoff =
        now > maxEventRetentionSecs ? now - maxEventRetentionSecs : 0;
    final inst = _instances[idx];
    final prevHandle = inst.detectedHandle;
    final switchedAccount = prevHandle != null && prevHandle != norm;
    final prevFollowEvents = List<int>.from(inst.followEvents);
    final prevUnfollowEvents = List<int>.from(inst.unfollowEvents);

    var uiChanged = false;
    var ledgerChanged = false;

    var nextInst = inst;
    if (prevHandle != norm) {
      nextInst = nextInst.copyWith(
        detectedHandle: norm,
        clearSnsStats: switchedAccount,
        followCountToday: switchedAccount ? 0 : null,
        followCountTotal: switchedAccount ? 0 : null,
        unfollowCountToday: switchedAccount ? 0 : null,
        unfollowCountTotal: switchedAccount ? 0 : null,
        followEvents: switchedAccount ? const [] : null,
        unfollowEvents: switchedAccount ? const [] : null,
      );
      uiChanged = true;
    }
    if (isGenericAccountLabel(nextInst.accountLabel, prevHandle: prevHandle)) {
      final autoLabel = '@$norm';
      if (nextInst.accountLabel != autoLabel) {
        nextInst = nextInst.copyWith(accountLabel: autoLabel);
        uiChanged = true;
      }
    }
    if (following != null && nextInst.snsFollowingCount != following) {
      nextInst = nextInst.copyWith(snsFollowingCount: following);
      uiChanged = true;
    }
    if (followers != null && nextInst.snsFollowersCount != followers) {
      nextInst = nextInst.copyWith(snsFollowersCount: followers);
      uiChanged = true;
    }

    final key = makeAccountSyncKey(inst.serviceId, norm);
    if (key != null) {
      final existed = _followLedger.accounts.containsKey(key);
      final acc = _followLedger.accounts.putIfAbsent(
        key,
        () => AccountFollowLedger(date: today),
      );
      acc.rollDate(today);
      if (!existed) ledgerChanged = true;

      final devId = _followSyncSettings.deviceId;
      if (prevHandle == null &&
          (prevFollowEvents.isNotEmpty || prevUnfollowEvents.isNotEmpty) &&
          devId.isNotEmpty) {
        final entry = acc.devices.putIfAbsent(
          devId,
          () => DeviceFollowEntry(
            todayEpoch: acc.resetEpoch,
            totalEpoch: acc.totalResetEpoch,
            unfollowTodayEpoch: acc.unfollowResetEpoch,
            unfollowTotalEpoch: acc.unfollowTotalResetEpoch,
            updatedAt: now,
          ),
        );
        for (final ts in prevFollowEvents) {
          if (ts > acc.followResetAt && ts >= retentionCutoff) {
            entry.followEvents.add(ts);
          }
        }
        for (final ts in prevUnfollowEvents) {
          if (ts > acc.unfollowResetAt && ts >= retentionCutoff) {
            entry.unfollowEvents.add(ts);
          }
        }
        entry.followEvents = pruneEventTimestamps(
          entry.followEvents,
          acc.followResetAt,
          retentionCutoff,
        );
        entry.unfollowEvents = pruneEventTimestamps(
          entry.unfollowEvents,
          acc.unfollowResetAt,
          retentionCutoff,
        );
        final fNet = (countEventsInWindow(
                    entry.followEvents, acc.followResetAt, cutoff) -
                countEventsInWindow(
                    entry.followDeductions, acc.followResetAt, cutoff))
            .clamp(-999999, 999999);
        final uNet = (countEventsInWindow(
                    entry.unfollowEvents, acc.unfollowResetAt, cutoff) -
                countEventsInWindow(
                    entry.unfollowDeductions, acc.unfollowResetAt, cutoff))
            .clamp(-999999, 999999);
        entry.today = fNet;
        entry.total = fNet;
        entry.todayEpoch = acc.resetEpoch;
        entry.totalEpoch = acc.totalResetEpoch;
        entry.unfollowToday = uNet;
        entry.unfollowTotal = uNet;
        entry.unfollowTodayEpoch = acc.unfollowResetEpoch;
        entry.unfollowTotalEpoch = acc.unfollowTotalResetEpoch;
        entry.updatedAt = max(now, entry.updatedAt + 1);
        nextInst = nextInst.copyWith(
          followEvents: const [],
          unfollowEvents: const [],
        );
        ledgerChanged = true;
      }

      final snsDiff = (following != null && acc.snsFollowing != following) ||
          (followers != null && acc.snsFollowers != followers);
      if (snsDiff) {
        if (following != null) acc.snsFollowing = following;
        if (followers != null) acc.snsFollowers = followers;
        acc.snsUpdatedAt = max(now, acc.snsUpdatedAt + 1);
        ledgerChanged = true;
      }
    }

    final updatedList = List<ServiceInstance>.from(_instances);
    updatedList[idx] = nextInst;
    final (projected, projChanged) = projectLedgerToInstances(
      updatedList,
      _followLedger,
      today,
      windowHours: winH,
      nowSecs: now,
    );

    if (uiChanged || projChanged || ledgerChanged) {
      if (mounted) {
        setState(() {
          _instances = projected;
        });
      }
      await _persistAllWithFollowSync();
      if (ledgerChanged) {
        _notifyFollowLedgerChanged();
      }
    }
  }

  Future<String?> _setInstanceHandleManual(
    String instanceId,
    String rawHandle,
  ) async {
    final trimmed = rawHandle.trim();
    final idx = _instances.indexWhere((i) => i.instanceId == instanceId);
    if (idx == -1) return '対象アカウントが見つかりません';
    if (trimmed.isEmpty) {
      // 旧アカウントの投影済みカウント・SNS実数が次のアカウントに混入しないようリセット
      final cur = _instances[idx];
      final clearAutoLabel = cur.detectedHandle != null &&
          cur.accountLabel?.trim().replaceFirst(RegExp(r'^@+'), '').toLowerCase() ==
              cur.detectedHandle!.toLowerCase();
      setState(() {
        _instances[idx] = cur.copyWith(
          clearDetectedHandle: true,
          clearAccountLabel: clearAutoLabel,
          clearSnsStats: true,
          followCountToday: 0,
          followCountTotal: 0,
          unfollowCountToday: 0,
          unfollowCountTotal: 0,
          followEvents: const [],
          unfollowEvents: const [],
        );
      });
      await _persist();
      return null;
    }
    final norm = normalizeAccountHandle(trimmed);
    if (norm == null) {
      return 'アカウントIDは半角英数字・.・_・- で入力してください';
    }
    await _handleAccountIdentity(instanceId, norm);
    return null;
  }

  Future<void> _adjustFollowCount(String instanceId, int delta) async {
    final idx = _instances.indexWhere((i) => i.instanceId == instanceId);
    if (idx == -1) return;
    final nowDt = DateTime.now();
    final today = formatLocalYmd(nowDt);
    final now = nowDt.millisecondsSinceEpoch ~/ 1000;
    final winH = _settings.followWindowHours;
    final cutoff = now > winH * 3600 ? now - winH * 3600 : 0;
    final retentionCutoff =
        now > maxEventRetentionSecs ? now - maxEventRetentionSecs : 0;
    final inst = _instances[idx];
    final syncKey = makeAccountSyncKey(inst.serviceId, inst.detectedHandle);

    if (syncKey != null && _followSyncSettings.deviceId.isNotEmpty) {
      final devId = _followSyncSettings.deviceId;
      final acc = _followLedger.accounts.putIfAbsent(
        syncKey,
        () => AccountFollowLedger(date: today),
      );
      acc.rollDate(today);

      if (!acc.devices.containsKey(devId)) {
        final seedF = acc.devices.isEmpty
            ? pruneEventTimestamps(
                inst.followEvents, acc.followResetAt, retentionCutoff)
            : <int>[];
        final seedU = acc.devices.isEmpty
            ? pruneEventTimestamps(
                inst.unfollowEvents, acc.unfollowResetAt, retentionCutoff)
            : <int>[];
        final fCnt = countEventsInWindow(seedF, acc.followResetAt, cutoff);
        final uCnt = countEventsInWindow(seedU, acc.unfollowResetAt, cutoff);
        acc.devices[devId] = DeviceFollowEntry(
          today: fCnt,
          total: fCnt,
          todayEpoch: acc.resetEpoch,
          totalEpoch: acc.totalResetEpoch,
          unfollowToday: uCnt,
          unfollowTotal: uCnt,
          unfollowTodayEpoch: acc.unfollowResetEpoch,
          unfollowTotalEpoch: acc.unfollowTotalResetEpoch,
          followEvents: seedF,
          unfollowEvents: seedU,
          updatedAt: now,
        );
      }

      final curEffective = acc.effectiveWindowFollowCount(now, winH);
      final entry = acc.devices[devId]!;
      if (entry.followEvents.isEmpty &&
          entry.followDeductions.isEmpty &&
          entry.today > 0 &&
          entry.todayEpoch >= acc.resetEpoch &&
          entry.updatedAt > acc.followResetAt &&
          entry.updatedAt >= cutoff) {
        final seedTs = entry.updatedAt > acc.followResetAt
            ? entry.updatedAt
            : acc.followResetAt + 1;
        entry.followEvents =
            List<int>.filled(entry.today > 1000 ? 1000 : entry.today, seedTs);
      }
      applyWindowDelta(
        events: entry.followEvents,
        deductions: entry.followDeductions,
        resetAt: acc.followResetAt,
        now: now,
        cutoff: cutoff,
        curEffective: curEffective,
        delta: delta,
      );
      final devNet = (countEventsInWindow(
                  entry.followEvents, acc.followResetAt, cutoff) -
              countEventsInWindow(
                  entry.followDeductions, acc.followResetAt, cutoff))
          .clamp(-999999, 999999);
      entry.today = devNet;
      entry.total = devNet;
      entry.todayEpoch = acc.resetEpoch;
      entry.totalEpoch = acc.totalResetEpoch;
      entry.updatedAt = max(now, entry.updatedAt + 1);

      final updatedList = List<ServiceInstance>.from(_instances);
      updatedList[idx] = updatedList[idx].copyWith(
        followEvents: const [],
        unfollowEvents: const [],
      );
      final (projected, _) = projectLedgerToInstances(
        updatedList,
        _followLedger,
        today,
        windowHours: winH,
        nowSecs: now,
      );
      if (mounted) {
        setState(() {
          _instances = projected;
        });
      }
      await _persistAllWithFollowSync();
      _notifyFollowLedgerChanged();
      return;
    }

    if (mounted) {
      setState(() {
        _instances[idx] = _instances[idx].withFollowWindowDelta(
          delta,
          windowHours: winH,
          now: nowDt,
        );
      });
    }
    await _persist();
  }

  Future<void> _resetFollowCount(
    String instanceId, {
    required bool resetTotal,
  }) async {
    final idx = _instances.indexWhere((i) => i.instanceId == instanceId);
    if (idx == -1) return;
    final nowDt = DateTime.now();
    final today = formatLocalYmd(nowDt);
    final now = nowDt.millisecondsSinceEpoch ~/ 1000;
    final winH = _settings.followWindowHours;
    final cutoff = now > winH * 3600 ? now - winH * 3600 : 0;
    final retentionCutoff =
        now > maxEventRetentionSecs ? now - maxEventRetentionSecs : 0;
    final inst = _instances[idx];
    final syncKey = makeAccountSyncKey(inst.serviceId, inst.detectedHandle);

    if (syncKey != null) {
      final devId = _followSyncSettings.deviceId;
      final acc = _followLedger.accounts.putIfAbsent(
        syncKey,
        () => AccountFollowLedger(date: today),
      );
      acc.rollDate(today);
      if (devId.isNotEmpty &&
          acc.devices.isEmpty &&
          inst.unfollowEvents.isNotEmpty) {
        final seedU = pruneEventTimestamps(
          inst.unfollowEvents,
          acc.unfollowResetAt,
          retentionCutoff,
        );
        final uCnt = countEventsInWindow(seedU, acc.unfollowResetAt, cutoff);
        acc.devices[devId] = DeviceFollowEntry(
          todayEpoch: acc.resetEpoch,
          totalEpoch: acc.totalResetEpoch,
          unfollowToday: uCnt,
          unfollowTotal: uCnt,
          unfollowTodayEpoch: acc.unfollowResetEpoch,
          unfollowTotalEpoch: acc.unfollowTotalResetEpoch,
          unfollowEvents: seedU,
          updatedAt: now,
        );
      }
      final resetAt = max(now, acc.maxFollowEventTs());
      acc.followResetAt = resetAt;
      acc.resetEpoch += 1;
      acc.totalResetEpoch += 1;
      if (devId.isNotEmpty) {
        final local = acc.devices[devId];
        if (local != null) {
          local.followEvents.removeWhere((t) => t <= resetAt);
          local.followDeductions.removeWhere((t) => t <= resetAt);
          local.today = 0;
          local.total = 0;
          local.todayEpoch = acc.resetEpoch;
          local.totalEpoch = acc.totalResetEpoch;
          local.updatedAt = max(now, local.updatedAt + 1);
        }
      }
      final updatedList = List<ServiceInstance>.from(_instances);
      updatedList[idx] = updatedList[idx].copyWith(followEvents: const []);
      final (projected, _) = projectLedgerToInstances(
        updatedList,
        _followLedger,
        today,
        windowHours: winH,
        nowSecs: now,
      );
      if (mounted) {
        setState(() {
          _instances = projected;
        });
      }
      await _persistAllWithFollowSync();
      _notifyFollowLedgerChanged();
      return;
    }

    if (mounted) {
      setState(() {
        _instances[idx] = _instances[idx].withFollowWindowReset(
          windowHours: winH,
          now: nowDt,
        );
      });
    }
    await _persist();
  }

  Future<void> _adjustUnfollowCount(String instanceId, int delta) async {
    final idx = _instances.indexWhere((i) => i.instanceId == instanceId);
    if (idx == -1) return;
    final nowDt = DateTime.now();
    final today = formatLocalYmd(nowDt);
    final now = nowDt.millisecondsSinceEpoch ~/ 1000;
    final winH = _settings.followWindowHours;
    final cutoff = now > winH * 3600 ? now - winH * 3600 : 0;
    final retentionCutoff =
        now > maxEventRetentionSecs ? now - maxEventRetentionSecs : 0;
    final inst = _instances[idx];
    final syncKey = makeAccountSyncKey(inst.serviceId, inst.detectedHandle);

    if (syncKey != null && _followSyncSettings.deviceId.isNotEmpty) {
      final devId = _followSyncSettings.deviceId;
      final acc = _followLedger.accounts.putIfAbsent(
        syncKey,
        () => AccountFollowLedger(date: today),
      );
      acc.rollDate(today);

      if (!acc.devices.containsKey(devId)) {
        final seedF = acc.devices.isEmpty
            ? pruneEventTimestamps(
                inst.followEvents, acc.followResetAt, retentionCutoff)
            : <int>[];
        final seedU = acc.devices.isEmpty
            ? pruneEventTimestamps(
                inst.unfollowEvents, acc.unfollowResetAt, retentionCutoff)
            : <int>[];
        final fCnt = countEventsInWindow(seedF, acc.followResetAt, cutoff);
        final uCnt = countEventsInWindow(seedU, acc.unfollowResetAt, cutoff);
        acc.devices[devId] = DeviceFollowEntry(
          today: fCnt,
          total: fCnt,
          todayEpoch: acc.resetEpoch,
          totalEpoch: acc.totalResetEpoch,
          unfollowToday: uCnt,
          unfollowTotal: uCnt,
          unfollowTodayEpoch: acc.unfollowResetEpoch,
          unfollowTotalEpoch: acc.unfollowTotalResetEpoch,
          followEvents: seedF,
          unfollowEvents: seedU,
          updatedAt: now,
        );
      }

      final curEffective = acc.effectiveWindowUnfollowCount(now, winH);
      final entry = acc.devices[devId]!;
      if (entry.unfollowEvents.isEmpty &&
          entry.unfollowDeductions.isEmpty &&
          entry.unfollowToday > 0 &&
          entry.unfollowTodayEpoch >= acc.unfollowResetEpoch &&
          entry.updatedAt > acc.unfollowResetAt &&
          entry.updatedAt >= cutoff) {
        final seedTs = entry.updatedAt > acc.unfollowResetAt
            ? entry.updatedAt
            : acc.unfollowResetAt + 1;
        entry.unfollowEvents = List<int>.filled(
          entry.unfollowToday > 1000 ? 1000 : entry.unfollowToday,
          seedTs,
        );
      }
      applyWindowDelta(
        events: entry.unfollowEvents,
        deductions: entry.unfollowDeductions,
        resetAt: acc.unfollowResetAt,
        now: now,
        cutoff: cutoff,
        curEffective: curEffective,
        delta: delta,
      );
      final devNet = (countEventsInWindow(
                  entry.unfollowEvents, acc.unfollowResetAt, cutoff) -
              countEventsInWindow(
                  entry.unfollowDeductions, acc.unfollowResetAt, cutoff))
          .clamp(-999999, 999999);
      entry.unfollowToday = devNet;
      entry.unfollowTotal = devNet;
      entry.unfollowTodayEpoch = acc.unfollowResetEpoch;
      entry.unfollowTotalEpoch = acc.unfollowTotalResetEpoch;
      entry.updatedAt = max(now, entry.updatedAt + 1);

      final updatedList = List<ServiceInstance>.from(_instances);
      updatedList[idx] = updatedList[idx].copyWith(
        followEvents: const [],
        unfollowEvents: const [],
      );
      final (projected, _) = projectLedgerToInstances(
        updatedList,
        _followLedger,
        today,
        windowHours: winH,
        nowSecs: now,
      );
      if (mounted) {
        setState(() {
          _instances = projected;
        });
      }
      await _persistAllWithFollowSync();
      _notifyFollowLedgerChanged();
      return;
    }

    if (mounted) {
      setState(() {
        _instances[idx] = _instances[idx].withUnfollowWindowDelta(
          delta,
          windowHours: winH,
          now: nowDt,
        );
      });
    }
    await _persist();
  }

  Future<void> _resetUnfollowCount(
    String instanceId, {
    required bool resetTotal,
  }) async {
    final idx = _instances.indexWhere((i) => i.instanceId == instanceId);
    if (idx == -1) return;
    final nowDt = DateTime.now();
    final today = formatLocalYmd(nowDt);
    final now = nowDt.millisecondsSinceEpoch ~/ 1000;
    final winH = _settings.followWindowHours;
    final cutoff = now > winH * 3600 ? now - winH * 3600 : 0;
    final retentionCutoff =
        now > maxEventRetentionSecs ? now - maxEventRetentionSecs : 0;
    final inst = _instances[idx];
    final syncKey = makeAccountSyncKey(inst.serviceId, inst.detectedHandle);

    if (syncKey != null) {
      final devId = _followSyncSettings.deviceId;
      final acc = _followLedger.accounts.putIfAbsent(
        syncKey,
        () => AccountFollowLedger(date: today),
      );
      acc.rollDate(today);
      if (devId.isNotEmpty &&
          acc.devices.isEmpty &&
          inst.followEvents.isNotEmpty) {
        final seedF = pruneEventTimestamps(
          inst.followEvents,
          acc.followResetAt,
          retentionCutoff,
        );
        final fCnt = countEventsInWindow(seedF, acc.followResetAt, cutoff);
        acc.devices[devId] = DeviceFollowEntry(
          today: fCnt,
          total: fCnt,
          todayEpoch: acc.resetEpoch,
          totalEpoch: acc.totalResetEpoch,
          unfollowTodayEpoch: acc.unfollowResetEpoch,
          unfollowTotalEpoch: acc.unfollowTotalResetEpoch,
          followEvents: seedF,
          updatedAt: now,
        );
      }
      final resetAt = max(now, acc.maxUnfollowEventTs());
      acc.unfollowResetAt = resetAt;
      acc.unfollowResetEpoch += 1;
      acc.unfollowTotalResetEpoch += 1;
      if (devId.isNotEmpty) {
        final local = acc.devices[devId];
        if (local != null) {
          local.unfollowEvents.removeWhere((t) => t <= resetAt);
          local.unfollowDeductions.removeWhere((t) => t <= resetAt);
          local.unfollowToday = 0;
          local.unfollowTotal = 0;
          local.unfollowTodayEpoch = acc.unfollowResetEpoch;
          local.unfollowTotalEpoch = acc.unfollowTotalResetEpoch;
          local.updatedAt = max(now, local.updatedAt + 1);
        }
      }
      final updatedList = List<ServiceInstance>.from(_instances);
      updatedList[idx] = updatedList[idx].copyWith(unfollowEvents: const []);
      final (projected, _) = projectLedgerToInstances(
        updatedList,
        _followLedger,
        today,
        windowHours: winH,
        nowSecs: now,
      );
      if (mounted) {
        setState(() {
          _instances = projected;
        });
      }
      await _persistAllWithFollowSync();
      _notifyFollowLedgerChanged();
      return;
    }

    if (mounted) {
      setState(() {
        _instances[idx] = _instances[idx].withUnfollowWindowReset(
          windowHours: winH,
          now: nowDt,
        );
      });
    }
    await _persist();
  }

  String _formatSyncClock(int? unixSecs) {
    if (unixSecs == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  String _generateUniqueInstanceId(String serviceId) {
    Random r;
    try {
      r = Random.secure();
    } catch (_) {
      r = Random();
    }
    final safePrefix =
        serviceId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final prefix = safePrefix.isEmpty ? 'custom' : safePrefix;
    for (var attempt = 0; attempt < 32; attempt++) {
      final randHex =
          r.nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
      final candidate = 'svc-$prefix-$randHex';
      if (!_instances.any((i) => i.instanceId == candidate)) {
        return candidate;
      }
    }
    return 'svc-$prefix-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
  }

  Future<void> _updateFollowSyncCredentials({
    required String githubToken,
    required String gistId,
  }) async {
    _followSyncConfigGen += 1;
    if (mounted) {
      setState(() {
        _followSyncSettings = _followSyncSettings.copyWith(
          githubToken: githubToken,
          gistId: gistId,
        );
      });
    } else {
      _followSyncSettings = _followSyncSettings.copyWith(
        githubToken: githubToken,
        gistId: gistId,
      );
    }
    await widget.store.saveFollowSyncState(_followSyncSettings, _followLedger);
  }

  Future<void> _showFollowCounterSheet(
    ServiceInstance target, {
    String? crossSiteSourceName,
  }) async {
    _refreshFollowWindowCounts();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _FollowCounterSheet(
        targetInstanceId: target.instanceId,
        crossSiteSourceName: crossSiteSourceName,
        multiProfileSupported: _multiProfileSupported,
        getInstances: () => _instances,
        getServiceGroups: () => _serviceGroups,
        getFollowSyncSettings: () => _followSyncSettings,
        getFollowWindowHours: () => _settings.followWindowHours,
        onChangeFollowWindowHours: _updateFollowWindowHours,
        formatSyncClock: _formatSyncClock,
        onAdjustFollow: _adjustFollowCount,
        onResetFollow: (id, resetTotal) =>
            _resetFollowCount(id, resetTotal: resetTotal),
        onAdjustUnfollow: _adjustUnfollowCount,
        onResetUnfollow: (id, resetTotal) =>
            _resetUnfollowCount(id, resetTotal: resetTotal),
        onSetHandle: _setInstanceHandleManual,
        onSaveSyncCredentials: _updateFollowSyncCredentials,
        onSyncNow: () => _syncFollowCloudOnce(silent: false),
        onOpenExternalUrl: _openExternalUrlSafely,
        onShowSnack: _showSnack,
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

    final archivedForGroup = _archivedInstances
        .where((a) => serviceGroupKey(a.instance) == group.key)
        .toList();
    if (archivedForGroup.isNotEmpty) {
      final selected = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '「${group.displayName}」にアカウントを追加',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '保存済みのログイン記憶が ${archivedForGroup.length} 件あります。ログイン済みのまま呼び出すか、新規作成できます。',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: archivedForGroup.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, idx) {
                      final entry = archivedForGroup[idx];
                      return ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                            color: Theme.of(ctx)
                                .dividerColor
                                .withValues(alpha: 0.4),
                          ),
                        ),
                        title: Text(
                          _formatArchivedDisplayTitle(entry.instance),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        trailing: FilledButton(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () =>
                              Navigator.of(ctx).pop(entry.instance.instanceId),
                          child: const Text('呼び出す'),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(ctx).pop('__NEW__'),
                  icon: const Icon(Icons.add),
                  label: const Text('新規アカウントを作成'),
                ),
              ],
            ),
          ),
        ),
      );
      if (selected == null) return;
      if (selected != '__NEW__') {
        await _restoreArchivedInstance(selected);
        return;
      }
    }

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

    final newInstanceId = _generateUniqueInstanceId(active.serviceId);
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
      _isGmailOpen = false;
      _instances.insert(insertAt, newInstance);
      _runtimeMap[newInstance.instanceId] = TabRuntimeState(
        currentUrl: newInstance.url,
        title: newInstance.name,
        isSleeping: true,
      );
      _settings = _settings.copyWith(activeInstanceId: newInstance.instanceId);
    });
    _ensureController(newInstance);
    _syncActiveWebViews();
    await _persist();
    _showSnack('「${group.displayName} / $nextLabel」を追加しました（独立セッション）');
  }

  void _sleepInstance(String instanceId) {
    final removed = _controllers.remove(instanceId);
    removed?.dispose();
    _disposeExtraSubTabsFor(instanceId);
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
    final profileName = _multiProfileSupported
        ? inst.effectiveProfileName
        : defaultWebViewProfileName;
    final affected = _instances
        .where(
          (i) =>
              (_multiProfileSupported
                  ? i.effectiveProfileName
                  : defaultWebViewProfileName) ==
              profileName,
        )
        .toList();
    final affectsMultiple = affected.length > 1;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ログイン情報を消去'),
        content: Text(
          affectsMultiple
              ? 'このプロファイル（$profileName）を共有する全${affected.length}個のアカウントからログアウトされます。Cookieとログイン情報を消去しますか？'
              : (_multiProfileSupported
                  ? 'このアカウントのCookieとログイン情報を消去してログアウトしますか？'
                  : 'Cookieとログイン情報を消去してログアウトしますか？'),
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
    if (!mounted || ok != true) return;

    await OmniWebViewManager.clearProfileData(profileName);
    if (!mounted) return;

    final affectedIds = affected.map((a) => a.instanceId).toSet();
    for (final id in affectedIds) {
      _crossSiteIdentities.remove(id);
    }
    setState(() {
      _instances = _instances.map((i) {
        if (!affectedIds.contains(i.instanceId)) return i;
        return i.copyWith(
          clearDetectedHandle: true,
          clearSnsStats: true,
          followCountToday: 0,
          followCountTotal: 0,
          unfollowCountToday: 0,
          unfollowCountTotal: 0,
          followEvents: const [],
          unfollowEvents: const [],
        );
      }).toList();
    });
    await _persist();

    for (final a in affected) {
      final ctrl = _controllers[a.instanceId];
      if (ctrl != null && !ctrl.isDisposed) {
        await ctrl.loadUrl(a.url);
      }
    }
    _showSnack('ログイン情報を消去しました');
  }

  Future<void> _openCatalog({String initialCategory = 'all'}) async {
    final req = await Navigator.of(context).push<NewInstanceRequest>(
      MaterialPageRoute(
        builder: (_) => CatalogScreen(
          categories: _categories,
          catalog: _catalog,
          existingInstances: _instances,
          multiProfileSupported: _multiProfileSupported,
          archivedInstances: _archivedInstances,
          initialCategory: initialCategory,
          catalogOrder: _settings.catalogOrder,
          onCatalogOrderChanged: _updateCatalogOrder,
          onRenameArchived: _renameArchivedInstance,
          onPurgeArchived: _purgeArchivedInstance,
          onPurgeAllArchived: _purgeAllArchivedInstances,
        ),
      ),
    );
    if (!mounted || req == null) return;

    if (req.restoreArchivedInstanceId != null) {
      await _restoreArchivedInstance(req.restoreArchivedInstanceId!);
      return;
    }

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

    final newInstanceId = _generateUniqueInstanceId(req.serviceId);
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
      _isGmailOpen = false;
      _instances.insert(insertAt, newInstance);
      _runtimeMap[newInstance.instanceId] = TabRuntimeState(
        currentUrl: newInstance.url,
        title: newInstance.name,
        isSleeping: true,
      );
      _settings = _settings.copyWith(activeInstanceId: newInstance.instanceId);
    });
    _ensureController(newInstance);
    _syncActiveWebViews();
    await _persist();
    final suffix = _multiProfileSupported &&
            (newInstance.accountLabel?.isNotEmpty ?? false)
        ? ' / ${newInstance.accountLabel}'
        : '';
    _showSnack('「${newInstance.name}$suffix」を追加しました');
  }

  Future<void> _openSettings() async {
    final active = _activeInstance;
    final activeGroup = _activeGroup;
    final updated = await Navigator.of(context).push<AppSettings>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          settings: _settings,
          onGestureChanged: (nextGesture) {
            _updateGestureSettings(nextGesture);
          },
          activeServiceName:
              (!_isGmailOpen && active != null) ? (activeGroup?.displayName ?? active.name) : null,
          activeDesktopMode: (!_isGmailOpen && active != null) ? active.isDesktopUa : null,
          onToggleDesktopMode: (!_isGmailOpen && active != null)
              ? (desktop) => _toggleDesktopMode(active, forceDesktop: desktop)
              : null,
          accountFilterSummary: _settings.accountFilter.isActive
              ? 'ON · ${_settings.accountFilter.summaryLabel}'
              : (_settings.accountFilter.hasAnyCondition
                  ? 'OFF · ${_settings.accountFilter.summaryLabel}'
                  : 'OFF · フォロー数・フォロワー数・フォロー多めで絞り込み（無料）'),
          onOpenAccountFilterSettings: () => _showAccountFilterSheet(),
          jevSummary: _jev.isActive
              ? 'ON · 分類「${_jev.category}」· 累計 ${JevService.formatCostCompact(_jev.totalCostUsd)}'
              : 'OFF · 分類「${_jev.category}」· 累計 ${JevService.formatCostCompact(_jev.totalCostUsd)}',
          onOpenJevSettings: () => _showJevSettingsSheet(),
          onClearAllCookies: () async {
            await OmniWebViewManager.clearAllCookies();
            if (!mounted) return;
            _crossSiteIdentities.clear();
            setState(() {
              _instances = _instances
                  .map(
                    (i) => i.copyWith(
                      clearDetectedHandle: true,
                      clearSnsStats: true,
                      followCountToday: 0,
                      followCountTotal: 0,
                      unfollowCountToday: 0,
                      unfollowCountTotal: 0,
                      followEvents: const [],
                      unfollowEvents: const [],
                    ),
                  )
                  .toList();
            });
            await _persist();
            if (!mounted) return;
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
            if (_gmailController != null && !_gmailController!.isDisposed) {
              await _reloadGmail();
            }
          },
        ),
      ),
    );
    if (!mounted || updated == null) return;
    setState(() {
      _settings = updated;
    });
    widget.onThemeChanged(updated.isDarkMode);
    _ensureSafeActiveAndLoad();
    await _persist();
  }

  Future<void> _updateGestureSettings(MobileGestureSettings next) async {
    if (!mounted) return;
    setState(() {
      _settings = _settings.copyWith(gesture: next);
    });
    await _persist();
  }

  Future<void> _openGestureSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GestureSettingsScreen(
          initialSettings: _settings.gesture,
          onChanged: (next) {
            _updateGestureSettings(next);
          },
        ),
      ),
    );
  }

  OmniWebViewController? _currentForegroundController() {
    if (_isGmailOpen) {
      final g = _gmailController;
      return (g != null && !g.isDisposed) ? g : null;
    }
    final active = _activeInstance;
    if (active == null) return null;
    final extra = _activeExtraTabFor(active.instanceId);
    if (extra != null && !extra.controller.isDisposed) {
      return extra.controller;
    }
    final c = _controllers[active.instanceId];
    return (c != null && !c.isDisposed) ? c : null;
  }

  void _showGestureNotice(String text, {bool isError = false}) {
    final overlay = _gestureOverlayKey.currentState;
    if (overlay != null) {
      overlay.showNotice(text, isError: isError);
    } else if (_settings.gesture.showFeedback) {
      _showSnack(text);
    }
  }

  void _handleGestureLiveScroll(double dx, double dy) {
    final ctrl = _currentForegroundController();
    if (ctrl == null) return;
    ctrl.scrollBy(dx, dy);
  }

  bool _stepActiveService(int delta) {
    final groups = _serviceGroups;
    if (groups.length <= 1) {
      _showGestureNotice('切り替えられるSNSが1つしかありません');
      return false;
    }
    final activeGroup = _activeGroup;
    final curIdx = activeGroup == null
        ? 0
        : max(0, groups.indexWhere((g) => g.key == activeGroup.key));
    final nextIdx =
        stepTabIndex(groups.length, curIdx, delta, _settings.gesture.wrapTabs);
    if (nextIdx == null) {
      _showGestureNotice(delta < 0 ? '先頭のSNSです' : '末尾のSNSです');
      return false;
    }
    final nextGroup = groups[nextIdx];
    _activateGroup(nextGroup);
    _showGestureNotice('SNS切替: ${nextGroup.displayName}');
    return true;
  }

  _ServiceGroup? _groupForInstance(ServiceInstance inst) {
    final key = serviceGroupKey(inst);
    for (final grp in _serviceGroups) {
      if (grp.key == key) return grp;
    }
    return null;
  }

  String _headerLabelForInstance(
    ServiceInstance inst, {
    required bool allScope,
    _ServiceGroup? knownGroup,
  }) {
    final grp = knownGroup ?? _groupForInstance(inst);
    final accounts = grp?.accounts ?? [inst];
    final sibIdx = max(
      0,
      accounts.indexWhere((a) => a.instanceId == inst.instanceId),
    );
    if (allScope) {
      return crossServiceAccountDisplayLabel(
        inst,
        sibIdx,
        accounts.length,
        baseServiceName: grp?.displayName ?? inst.name,
      );
    }
    return accountDisplayLabel(
      inst,
      sibIdx,
      baseServiceName: grp?.displayName ?? inst.name,
    );
  }

  Future<void> _toggleHeaderAccountScope() async {
    final nextScope = _settings.isHeaderAllAccounts ? 'service' : 'all';
    setState(() {
      _settings = _settings.copyWith(headerAccountScope: nextScope);
    });
    await _persist();
    _showSnack(
      nextScope == 'all'
          ? 'ヘッダーに全SNSのアカウントを並べて表示します'
          : 'ヘッダーを現在のSNSのアカウントのみに切り替えました',
    );
  }

  Future<void> _showCrossServiceAddAccountSheet() async {
    final active = _activeInstance;
    final activeGroup = _activeGroup;
    final archived = List<ArchivedInstance>.from(_archivedInstances);
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'ヘッダーにアカウントを追加',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                '別SNSやログイン済みアカウントを追加して、同じヘッダーからワンタップで切り替えられます。',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (_multiProfileSupported &&
                  active != null &&
                  activeGroup != null) ...[
                FilledButton.tonalIcon(
                  key: const ValueKey('cross-add-same-service-btn'),
                  onPressed: () => Navigator.of(ctx).pop('__SAME_SERVICE__'),
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                  label: Text('「${activeGroup.displayName}」に別アカウントを追加'),
                ),
                const SizedBox(height: 8),
              ],
              FilledButton.icon(
                key: const ValueKey('cross-add-catalog-btn'),
                onPressed: () => Navigator.of(ctx).pop('__CATALOG__'),
                icon: const Icon(Icons.apps_rounded, size: 18),
                label: const Text('別SNSを追加（Instagram / Bluesky など）'),
              ),
              if (_instances.length >= 2) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('cross-reorder-accounts-btn'),
                  onPressed: () => Navigator.of(ctx).pop('__REORDER__'),
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                  label: const Text('ヘッダーの並び順を変更'),
                ),
              ],
              if (archived.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  'ログイン記憶から呼び出す（${archived.length}件）',
                  style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 210),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: archived.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, idx) {
                      final entry = archived[idx];
                      final inst = entry.instance;
                      return ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                            color: Theme.of(ctx)
                                .dividerColor
                                .withValues(alpha: 0.4),
                          ),
                        ),
                        leading: Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: parseHexColor(inst.colorHex),
                            borderRadius: BorderRadius.circular(7),
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
                        title: Text(
                          _formatArchivedDisplayTitle(inst),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        trailing: FilledButton(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () =>
                              Navigator.of(ctx).pop('RESTORE:${inst.instanceId}'),
                          child: const Text('呼び出す'),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    if (selected == '__SAME_SERVICE__') {
      await _addAccountForActiveService();
    } else if (selected == '__CATALOG__') {
      await _openCatalog();
    } else if (selected == '__REORDER__') {
      await _showAccountReorderSheet();
    } else if (selected.startsWith('RESTORE:')) {
      await _restoreArchivedInstance(selected.substring('RESTORE:'.length));
    }
  }

  Future<void> _showAccountReorderSheet() async {
    if (_instances.length < 2) return;
    final working = List<ServiceInstance>.from(_instances);
    final saved = await showModalBottomSheet<List<ServiceInstance>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: SizedBox(
            height: min(MediaQuery.of(ctx).size.height * 0.72, 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 12, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'ヘッダーのアカウント並び替え',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'ドラッグしてSNSをまたいで好きな順に並べ替えられます',
                              style: TextStyle(fontSize: 11.5),
                            ),
                          ],
                        ),
                      ),
                      FilledButton(
                        key: const ValueKey('account-reorder-save-btn'),
                        onPressed: () => Navigator.of(ctx).pop(working),
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: working.length,
                    onReorder: (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex -= 1;
                      setSheetState(() {
                        final moved = working.removeAt(oldIndex);
                        working.insert(newIndex, moved);
                      });
                    },
                    itemBuilder: (_, idx) {
                      final inst = working[idx];
                      final grp = _groupForInstance(inst);
                      final label = _headerLabelForInstance(
                        inst,
                        allScope: true,
                        knownGroup: grp,
                      );
                      return ListTile(
                        key: ValueKey('reorder-acc-${inst.instanceId}'),
                        dense: true,
                        leading: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: parseHexColor(inst.colorHex),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            inst.badge,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          grp?.displayName ?? inst.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: const Icon(Icons.drag_handle_rounded),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || saved == null) return;
    setState(() {
      _instances = List.generate(
        saved.length,
        (i) => saved[i].copyWith(order: i),
      );
    });
    await _persist();
    _showSnack('ヘッダーのアカウント並び順を保存しました');
  }

  void _handleOverlayMoveDragChanged(
    Offset? globalPos,
    bool isOverHeaderDock,
  ) {
    if (!mounted) return;
    setState(() {
      _movingOrbGlobalPos = globalPos;
      _isOrbOverHeaderDock = isOverHeaderDock;
      if (globalPos == null) {
        _isDraggingFromHeaderDock = false;
      }
    });
  }

  Future<void> _dockGestureToHeader() async {
    setState(() {
      _movingOrbGlobalPos = null;
      _isOrbOverHeaderDock = false;
      _isDraggingFromHeaderDock = false;
    });
    await _updateGestureSettings(
      _settings.gesture.copyWith(dockedInHeader: true),
    );
    _showSnack('ジェスチャーボタンをヘッダーに収納しました（タップまたは下にドラッグで戻せます）');
  }

  Future<void> _undockGestureFromHeader({
    double? xFrac,
    double? yFrac,
  }) async {
    setState(() {
      _movingOrbGlobalPos = null;
      _isOrbOverHeaderDock = false;
      _isDraggingFromHeaderDock = false;
    });
    await _updateGestureSettings(
      _settings.gesture.copyWith(
        dockedInHeader: false,
        handleXFraction: xFrac,
        handleYFraction: yFrac,
      ),
    );
    HapticFeedback.lightImpact();
    _showGestureNotice(
      xFrac != null || yFrac != null
          ? 'ジェスチャーボタンを配置しました'
          : 'ジェスチャーボタンを表示しました',
    );
  }

  void _handleHeaderDockPointerDown(PointerDownEvent e) {
    if (_headerDockPointer != null) return;
    _headerDockPointer = e.pointer;
    _headerDockDownGlobal = e.position;
    _headerDockLongPressFired = false;
    _isDraggingFromHeaderDock = false;
    _headerDockLongPressTimer?.cancel();
    _headerDockLongPressTimer = Timer(const Duration(milliseconds: 460), () {
      if (_headerDockPointer != e.pointer ||
          _isDraggingFromHeaderDock ||
          !mounted) {
        return;
      }
      _headerDockLongPressFired = true;
      _headerDockPointer = null;
      _headerDockDownGlobal = null;
      HapticFeedback.mediumImpact();
      unawaited(_openGestureSettings());
    });
  }

  void _handleHeaderDockPointerMove(PointerMoveEvent e) {
    if (_headerDockPointer != e.pointer || _headerDockDownGlobal == null) {
      return;
    }
    if (!_isDraggingFromHeaderDock) {
      final moved = (e.position - _headerDockDownGlobal!).distance;
      if (moved < 10.0) return;
      _headerDockLongPressTimer?.cancel();
      _headerDockLongPressTimer = null;
      HapticFeedback.selectionClick();
      _isDraggingFromHeaderDock = true;
    }
    final vpBox =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    bool overHeader = true;
    if (vpBox != null && vpBox.hasSize) {
      final local = vpBox.globalToLocal(e.position);
      overHeader = local.dy <= 20.0;
    }
    if (mounted) {
      setState(() {
        _movingOrbGlobalPos = e.position;
        _isOrbOverHeaderDock = overHeader;
      });
    }
  }

  void _handleHeaderDockPointerUpOrCancel(
    int pointer,
    Offset globalPos, {
    required bool cancelled,
  }) {
    if (_headerDockPointer != pointer) return;
    _headerDockLongPressTimer?.cancel();
    _headerDockLongPressTimer = null;

    final wasDragging = _isDraggingFromHeaderDock;
    final firedLongPress = _headerDockLongPressFired;
    _headerDockPointer = null;
    _headerDockDownGlobal = null;
    _isDraggingFromHeaderDock = false;
    _headerDockLongPressFired = false;

    if (mounted) {
      setState(() {
        _movingOrbGlobalPos = null;
        _isOrbOverHeaderDock = false;
      });
    }
    if (cancelled || firedLongPress) return;

    if (wasDragging) {
      final vpBox =
          _viewportKey.currentContext?.findRenderObject() as RenderBox?;
      if (vpBox != null &&
          vpBox.hasSize &&
          vpBox.size.width > 0 &&
          vpBox.size.height > 0) {
        final local = vpBox.globalToLocal(globalPos);
        if (local.dy > 20.0) {
          final nextX = _settings.gesture.triggerSide == 'both'
              ? null
              : (local.dx / vpBox.size.width).clamp(0.06, 0.94);
          final nextY = (local.dy / vpBox.size.height).clamp(0.14, 0.88);
          unawaited(_undockGestureFromHeader(xFrac: nextX, yFrac: nextY));
        }
      }
      return;
    }

    // 短タップで前回位置に再表示
    unawaited(_undockGestureFromHeader());
  }

  Widget _buildHeaderGestureDockSlot({required bool compact}) {
    if (!_settings.gesture.enabled) return const SizedBox.shrink();
    final isDocked = _settings.gesture.dockedInHeader;
    final isIncomingDrag =
        !isDocked && _movingOrbGlobalPos != null && !_isDraggingFromHeaderDock;
    if (!isDocked && !isIncomingDrag) return const SizedBox.shrink();

    final sizeW = compact ? 28.0 : 30.0;
    final sizeH = compact ? 24.0 : 28.0;

    if (isIncomingDrag) {
      final highlighted = _isOrbOverHeaderDock;
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 4),
        child: AnimatedContainer(
          key: const ValueKey('header-gesture-dock-target'),
          duration: const Duration(milliseconds: 120),
          width: compact ? sizeW : null,
          height: sizeH,
          padding: compact ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: highlighted
                ? kGestureTeal.withValues(alpha: 0.92)
                : kGestureTeal.withValues(alpha: 0.20),
            borderRadius: BorderRadius.circular(99),
            border: Border.all(
              color: highlighted ? kGestureTealBright : kGestureAmber,
              width: highlighted ? 1.8 : 1.3,
            ),
          ),
          child: compact
              ? Icon(
                  Icons.vertical_align_top_rounded,
                  size: 14,
                  color: highlighted ? Colors.white : kGestureTealBright,
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.vertical_align_top_rounded,
                      size: 15,
                      color: highlighted ? Colors.white : kGestureTealBright,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '収納',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: highlighted ? Colors.white : kGestureTealBright,
                      ),
                    ),
                  ],
                ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 3),
      child: Tooltip(
        message: 'ジェスチャーボタン（タップまたは下にドラッグで画面へ戻す · 長押しで設定）',
        child: Listener(
          key: const ValueKey('header-gesture-dock-button'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: _handleHeaderDockPointerDown,
          onPointerMove: _handleHeaderDockPointerMove,
          onPointerUp: (e) => _handleHeaderDockPointerUpOrCancel(
            e.pointer,
            e.position,
            cancelled: false,
          ),
          onPointerCancel: (e) => _handleHeaderDockPointerUpOrCancel(
            e.pointer,
            e.position,
            cancelled: true,
          ),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: _isDraggingFromHeaderDock ? 0.35 : 1.0,
            child: Container(
              width: sizeW,
              height: sizeH,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xD90F172A),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(
                  color: kGestureTealBright.withValues(alpha: 0.85),
                  width: 1.3,
                ),
              ),
              child: GestureShapeIcon(
                shape: 'DR',
                size: compact ? 14 : 16,
                color: kGestureTealBright,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingOrbDragOverlay() {
    final globalPos = _movingOrbGlobalPos;
    if (globalPos == null) return const SizedBox.shrink();
    final stackBox =
        _rootStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize) return const SizedBox.shrink();
    final local = stackBox.globalToLocal(globalPos);
    final isDocking = !_isDraggingFromHeaderDock && _isOrbOverHeaderDock;
    final isPullReady = _isDraggingFromHeaderDock && !_isOrbOverHeaderDock;
    final orbSize = isDocking ? 34.0 : 42.0;

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (_isDraggingFromHeaderDock)
              Positioned(
                top: MediaQuery.of(context).padding.top + 48,
                left: 16,
                right: 16,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: isPullReady
                          ? const Color(0xEB0E7490)
                          : const Color(0xE60F172A),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: isPullReady ? kGestureTealBright : kGestureAmber,
                        width: 1.4,
                      ),
                    ),
                    child: Text(
                      isPullReady
                          ? '離すとこの位置にジェスチャーボタンを配置します'
                          : '下へドラッグして画面に配置（そのまま離すと収納維持）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: local.dx - orbSize / 2,
              top: local.dy - orbSize / 2,
              width: orbSize,
              height: orbSize,
              child: Container(
                key: const ValueKey('floating-orb-drag-ghost'),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDocking || isPullReady
                      ? const Color(0xEB0E7490)
                      : const Color(0xEB92400E),
                  border: Border.all(
                    color: isDocking || isPullReady
                        ? kGestureTealBright
                        : kGestureAmber,
                    width: 2.0,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 10,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: isDocking
                    ? const Icon(
                        Icons.vertical_align_top_rounded,
                        size: 18,
                        color: Colors.white,
                      )
                    : (_isDraggingFromHeaderDock
                        ? const GestureShapeIcon(
                            shape: 'DR',
                            size: 20,
                            color: kGestureTealBright,
                          )
                        : const Icon(
                            Icons.open_with_rounded,
                            size: 19,
                            color: Colors.white,
                          )),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _stepActiveAccount(int delta) {
    final active = _activeInstance;
    if (active == null) return false;
    final allScope = _settings.isHeaderAllAccounts;
    final group = _activeGroup;
    final list = allScope ? _visibleInstances : (group?.accounts ?? const []);
    if (list.length <= 1) {
      _showGestureNotice(
        allScope ? '切り替えられるアカウントが1つしかありません' : 'このSNSのアカウントは1つだけです',
      );
      return false;
    }
    final curIdx = max(
      0,
      list.indexWhere((a) => a.instanceId == active.instanceId),
    );
    final nextIdx = stepTabIndex(
      list.length,
      curIdx,
      delta,
      _settings.gesture.wrapTabs,
    );
    if (nextIdx == null) {
      _showGestureNotice(delta < 0 ? '先頭のアカウントです' : '末尾のアカウントです');
      return false;
    }
    final nextInst = list[nextIdx];
    final nextGroup = _groupForInstance(nextInst);
    final label = _headerLabelForInstance(
      nextInst,
      allScope: allScope,
      knownGroup: nextGroup,
    );
    _activateInstance(nextInst);
    final svcName = nextGroup?.displayName ?? nextInst.name;
    _showGestureNotice(label == svcName ? svcName : '$svcName · $label');
    return true;
  }

  Future<void> _executeMobileGestureAction(String action, String shape) async {
    final ctrl = _currentForegroundController();
    final active = _activeInstance;
    final activeGroup = _activeGroup;
    final activeRt = active != null ? _runtimeMap[active.instanceId] : null;

    switch (action) {
      case 'go-back':
        if (ctrl != null && await ctrl.canGoBack()) {
          if (!mounted) return;
          await ctrl.goBack();
          _showGestureNotice('${shapeArrows(shape)} 戻る');
        } else if (_isGmailOpen && mounted) {
          setState(() => _isGmailOpen = false);
          _syncActiveWebViews();
          _showGestureNotice('${shapeArrows(shape)} Gmailを閉じました');
        } else {
          _showGestureNotice('これ以上戻れません');
        }
      case 'go-forward':
        if (ctrl != null && await ctrl.canGoForward()) {
          if (!mounted) return;
          await ctrl.goForward();
          _showGestureNotice('${shapeArrows(shape)} 進む');
        } else {
          _showGestureNotice('これ以上進めません');
        }
      case 'reload':
        await _reloadActiveTab();
        _showGestureNotice('${shapeArrows(shape)} 再読み込み');
      case 'home':
        if (_isGmailOpen) {
          final g = _ensureGmailController();
          if (mounted) {
            setState(() {
              _gmailRuntime = _gmailRuntime.copyWith(
                isSleeping: false,
                isLoading: true,
                progress: 5,
                clearError: true,
              );
            });
          }
          await g.loadUrl(_gmailUrl);
          _showGestureNotice('${shapeArrows(shape)} Gmail 受信トレイ');
        } else if (active != null) {
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
          _showGestureNotice('${shapeArrows(shape)} ホームへ移動');
        }
      case 'previous-tab':
        _stepActiveSubTab(-1);
      case 'next-tab':
        _stepActiveSubTab(1);
      case 'new-tab':
        if (active != null && !_isGmailOpen) {
          _openUrlInNewSubTab(active, active.url, activate: false);
        }
      case 'close-tab':
        if (active != null && !_isGmailOpen) {
          final extra = _activeExtraTabFor(active.instanceId);
          if (extra != null) {
            _closeExtraSubTab(active.instanceId, extra.tabId);
            _showGestureNotice('タブを閉じました');
          } else {
            _showGestureNotice('メインタブは閉じられません');
          }
        }
      case 'previous-service':
        _stepActiveService(-1);
      case 'next-service':
        _stepActiveService(1);
      case 'previous-account':
        _stepActiveAccount(-1);
      case 'next-account':
        _stepActiveAccount(1);
      case 'scroll-top':
        await ctrl?.scrollToEdge(toTop: true);
        _showGestureNotice('${shapeArrows(shape)} 一番上へ');
      case 'scroll-bottom':
        await ctrl?.scrollToEdge(toTop: false);
        _showGestureNotice('${shapeArrows(shape)} 一番下へ');
      case 'toggle-gmail':
        _toggleInAppGmail();
        _showGestureNotice(
          _isGmailOpen ? 'アプリ内Gmailを開きました' : '元のSNSへ戻りました',
        );
      case 'open-follow-counter':
        if (active != null && !_isGmailOpen) {
          final resolved = _resolveCounterTarget(active);
          if (resolved.target != null) {
            await _showFollowCounterSheet(
              resolved.target!,
              crossSiteSourceName: resolved.isCrossSite
                  ? (activeGroup?.displayName ?? active.name)
                  : null,
            );
          } else if (resolved.effectiveService != null) {
            _showGestureNotice(
              '${_serviceDisplayName(resolved.effectiveService!)} を追加するとカウントできます',
            );
          }
        }
      case 'toggle-header':
        await _toggleHeaderCollapsed();
        _showGestureNotice(
          _settings.isHeaderCollapsed ? 'ヘッダーを折り畳みました' : 'ヘッダーを展開しました',
        );
      case 'toggle-bottom-tabs':
        await _toggleBottomTabsCollapsed();
        _showGestureNotice(
          _settings.isBottomTabsCollapsed ? '下部タブを折り畳みました' : '下部タブを展開しました',
        );
      case 'open-catalog':
        await _openCatalog();
      case 'sleep-tab':
        if (active != null && !_isGmailOpen) {
          _sleepInstance(active.instanceId);
        }
      case 'open-external':
        if (_isGmailOpen) {
          final url = isHttpOrHttpsUrl(_gmailRuntime.currentUrl)
              ? _gmailRuntime.currentUrl
              : _gmailUrl;
          await _openExternalUrlSafely(url);
        } else if (active != null) {
          final url = isHttpOrHttpsUrl(activeRt?.currentUrl)
              ? activeRt!.currentUrl
              : active.url;
          await _openExternalUrlSafely(url);
        }
      case 'gesture:settings':
        await _openGestureSettings();
    }
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
    final dialogTitle = _multiProfileSupported
        ? '「${grp?.displayName ?? inst.name} · $curAccLabel」を編集'
        : '「${grp?.displayName ?? inst.name}」を編集';

    final updated = await showDialog<ServiceInstance>(
      context: context,
      builder: (ctx) => _EditInstanceDialog(
        instance: inst,
        dialogTitle: dialogTitle,
        initialAccountLabel: curAccLabel,
        multiProfileSupported: _multiProfileSupported,
      ),
    );

    if (!mounted || updated == null) return;
    final idx =
        _instances.indexWhere((i) => i.instanceId == inst.instanceId);
    if (idx == -1) return;

    final oldGroupKey = serviceGroupKey(inst);
    final newGroupKey = serviceGroupKey(updated);
    final urlChanged = updated.url != inst.url;

    setState(() {
      _instances[idx] = updated;
      if (oldGroupKey != newGroupKey &&
          _lastActiveByGroup[oldGroupKey] == inst.instanceId) {
        _lastActiveByGroup.remove(oldGroupKey);
        _lastActiveByGroup[newGroupKey] = updated.instanceId;
      }
      if (urlChanged) {
        final curRt = _runtimeMap[inst.instanceId];
        if (curRt != null) {
          _runtimeMap[inst.instanceId] = curRt.copyWith(
            currentUrl: updated.url,
            clearError: true,
          );
        }
      }
    });
    await _persist();
    if (urlChanged) {
      final ctrl = _controllers[inst.instanceId];
      if (ctrl != null && !ctrl.isDisposed) {
        await ctrl.loadUrl(updated.url);
      }
    }
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
        content: Text(
          '「$displayTitle」を一覧から削除しますか？\n※ ログイン記憶は保持され、「ログイン記憶」からいつでも呼び出せます。',
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
    if (!mounted || ok != true) return;

    final wasActive = _settings.activeInstanceId == inst.instanceId;
    final removedCtrl = _controllers.remove(inst.instanceId);
    removedCtrl?.dispose();
    _disposeExtraSubTabsFor(inst.instanceId);
    _runtimeMap.remove(inst.instanceId);
    _crossSiteIdentities.remove(inst.instanceId);
    _bridgeEventTimestamps.remove(inst.instanceId);
    if (_lastActiveByGroup[groupKey] == inst.instanceId) {
      _lastActiveByGroup.remove(groupKey);
    }
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
    await _archiveInstances([inst]);
    _showSnack('「$displayTitle」を削除しました（ログイン記憶は保持）');
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
          '「${group.displayName}」（全${group.accounts.length}アカウント）を一覧から削除しますか？\n※ ログイン記憶は保持され、「ログイン記憶」からいつでも呼び出せます。',
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
    if (!mounted || ok != true) return;

    final archivedBatch = List<ServiceInstance>.from(group.accounts);
    final ids = group.accounts.map((a) => a.instanceId).toSet();
    _lastActiveByGroup.remove(group.key);
    for (final acc in group.accounts) {
      final ctrl = _controllers.remove(acc.instanceId);
      ctrl?.dispose();
      _disposeExtraSubTabsFor(acc.instanceId);
      _runtimeMap.remove(acc.instanceId);
      _crossSiteIdentities.remove(acc.instanceId);
      _bridgeEventTimestamps.remove(acc.instanceId);
    }
    setState(() {
      _instances.removeWhere((i) => ids.contains(i.instanceId));
    });
    _ensureSafeActiveAndLoad();
    await _persist();
    await _archiveInstances(archivedBatch);
    _showSnack('「${group.displayName}」を削除しました（ログイン記憶は保持）');
  }

  void _showTimedSnackBar(
    SnackBar snackBar, {
    Duration duration = const Duration(milliseconds: 2200),
  }) {
    if (!mounted) return;
    _snackDismissTimer?.cancel();
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    final controller = messenger.showSnackBar(snackBar);
    // Android でユーザー補助サービス（アクセシビリティ機能）が有効だと
    // SnackBarAction 付きの SnackBar が自動で閉じない Flutter の仕様を回避し、
    // 常に指定秒数で確実に閉じるように明示タイマーを併用する。
    _snackDismissTimer = Timer(duration, () {
      _snackDismissTimer = null;
      if (!mounted) return;
      try {
        controller.close();
      } catch (_) {}
    });
  }

  void _showSnack(String message) {
    _showTimedSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
      duration: const Duration(seconds: 2),
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
    final activeExtraTab =
        active != null ? _activeExtraTabFor(active.instanceId) : null;
    final activeRt = active == null
        ? null
        : (activeExtraTab?.runtime ?? _runtimeMap[active.instanceId]);
    final visible = _visibleInstances;
    final groups = _serviceGroups;
    final tabsCollapsed = _settings.isBottomTabsCollapsed;
    final headerCollapsed = _settings.isHeaderCollapsed;
    final otherUnread = _otherGroupsUnread;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_isGmailOpen) {
          final gCtrl = _gmailController;
          if (gCtrl != null && await gCtrl.canGoBack()) {
            await gCtrl.goBack();
            return;
          }
          if (mounted) {
            setState(() => _isGmailOpen = false);
            _syncActiveWebViews();
          }
          return;
        }
        final ctrl = _currentForegroundController();
        if (ctrl != null && await ctrl.canGoBack()) {
          await ctrl.goBack();
          return;
        }
        if (active != null && activeExtraTab != null) {
          _closeExtraSubTab(active.instanceId, activeExtraTab.tabId);
          return;
        }
        if (context.mounted) {
          SystemNavigator.pop();
        }
      },
      child: Stack(
        key: _rootStackKey,
        children: [
          Scaffold(
            drawer: _buildDrawer(groups, activeGroup),
            appBar: headerCollapsed
                ? null
                : AppBar(
                    toolbarHeight: 44,
                    titleSpacing: 4,
                    title: _isGmailOpen
                        ? const Text(
                            'Gmail',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : active == null
                        ? const Text('OmniSNS')
                        : active.isDesktopUa
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  Theme.of(context).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              'PC',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                    actions: [
                      if (tabsCollapsed)
                        Padding(
                          padding: const EdgeInsets.only(right: 2),
                          child: ActionChip(
                            visualDensity: VisualDensity.compact,
                            labelPadding:
                                const EdgeInsets.symmetric(horizontal: 4),
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
                      _buildHeaderGestureDockSlot(compact: false),
                      IconButton(
                        key: const ValueKey('header-gmail-button'),
                    icon: Icon(
                      _isGmailOpen
                          ? Icons.mark_email_read_rounded
                          : Icons.mail_outline_rounded,
                      color: _isGmailOpen ? const Color(0xFFEA4335) : null,
                    ),
                    visualDensity: VisualDensity.compact,
                    tooltip: _isGmailOpen
                        ? 'Gmail を閉じて元のSNSへ戻る'
                        : 'アプリ内で Gmail を開く（SNS認証メール確認用）',
                    onPressed: _toggleInAppGmail,
                  ),
                  if (_isGmailOpen || active != null)
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
                      final ctrl = _currentForegroundController();
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
                          if (_isGmailOpen) {
                            final g = _ensureGmailController();
                            setState(() {
                              _gmailRuntime = _gmailRuntime.copyWith(
                                isSleeping: false,
                                isLoading: true,
                                progress: 5,
                                clearError: true,
                              );
                            });
                            await g.loadUrl(_gmailUrl);
                          } else if (active != null) {
                            final extra = _activeExtraTabFor(active.instanceId);
                            if (extra != null && !extra.controller.isDisposed) {
                              extra.runtime = extra.runtime.copyWith(
                                isLoading: true,
                                progress: 5,
                                clearError: true,
                              );
                              setState(() {});
                              await extra.controller.loadUrl(active.url);
                            } else {
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
                          }
                        case 'toggle-desktop-ua':
                          if (active != null && !_isGmailOpen) {
                            await _toggleDesktopMode(active);
                          }
                        case 'account-filter':
                          await _showAccountFilterSheet();
                        case 'jev-filter':
                          await _showJevSettingsSheet();
                        case 'toggle-header':
                          await _toggleHeaderCollapsed();
                        case 'toggle-bottom-tabs':
                          await _toggleBottomTabsCollapsed();
                        case 'follow-counter':
                          if (active != null) {
                            final resolved = _resolveCounterTarget(active);
                            if (resolved.target != null) {
                              await _showFollowCounterSheet(
                                resolved.target!,
                                crossSiteSourceName: resolved.isCrossSite
                                    ? (activeGroup?.displayName ?? active.name)
                                    : null,
                              );
                            } else if (resolved.effectiveService != null) {
                              _showSnack(
                                '${_serviceDisplayName(resolved.effectiveService!)} を追加するとカウントできます',
                              );
                            }
                          }
                        case 'sleep':
                          if (active != null) _sleepInstance(active.instanceId);
                        case 'copy-url':
                          final copyUrl = _isGmailOpen
                              ? _gmailRuntime.currentUrl
                              : (activeRt?.currentUrl ?? active?.url ?? '');
                          if (copyUrl.isNotEmpty) {
                            await Clipboard.setData(ClipboardData(text: copyUrl));
                            _showSnack('現在のURLをコピーしました');
                          }
                        case 'external':
                          if (_isGmailOpen) {
                            final url = isHttpOrHttpsUrl(_gmailRuntime.currentUrl)
                                ? _gmailRuntime.currentUrl
                                : _gmailUrl;
                            await _openExternalUrlSafely(url);
                          } else if (active != null) {
                            final url = isHttpOrHttpsUrl(activeRt?.currentUrl)
                                ? activeRt!.currentUrl
                                : active.url;
                            await _openExternalUrlSafely(url);
                          }
                        case 'archived-logins':
                          await _openCatalog(initialCategory: 'archived');
                        case 'gesture-settings':
                          await _openGestureSettings();
                        case 'settings':
                          await _openSettings();
                      }
                    },
                    itemBuilder: (_) => [
                      if (_isGmailOpen || active != null) ...[
                        const PopupMenuItem(value: 'back', child: Text('戻る')),
                        const PopupMenuItem(
                          value: 'forward',
                          child: Text('進む'),
                        ),
                        const PopupMenuItem(
                          value: 'reload',
                          child: Text('再読み込み'),
                        ),
                        PopupMenuItem(
                          value: 'home',
                          child: Text(
                            _isGmailOpen
                                ? 'Gmail 受信トレイへ戻る'
                                : 'DM/ホーム画面へ戻る',
                          ),
                        ),
                        if (active != null && !_isGmailOpen)
                          PopupMenuItem(
                            value: 'toggle-desktop-ua',
                            child: Text(
                              active.isDesktopUa
                                  ? 'スマホ版サイトに戻す（現在PC版）'
                                  : 'PC版サイトで表示',
                            ),
                          ),
                        PopupMenuItem(
                          value: 'account-filter',
                          child: Text(
                            _settings.accountFilter.isActive
                                ? '条件フィルタ: ${_settings.accountFilter.summaryLabel}（ON）'
                                : 'アカウント条件フィルタ（F/FW）',
                          ),
                        ),
                        PopupMenuItem(
                          value: 'jev-filter',
                          child: Text(
                            _jev.isActive
                                ? '分類フィルタ: ${_jev.category}（ON）'
                                : '分類フィルタ（Jev）',
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'toggle-header',
                          child: Text('ヘッダーを折り畳む'),
                        ),
                        PopupMenuItem(
                          value: 'toggle-bottom-tabs',
                          child: Text(
                            tabsCollapsed ? '下部タブを展開' : '下部タブを折り畳む',
                          ),
                        ),
                        if (active != null && !_isGmailOpen) ...[
                          () {
                            final resolved = _resolveCounterTarget(active);
                            final counterInst = resolved.target;
                            final winH = _settings.followWindowHours;
                            final fCount = counterInst
                                    ?.effectiveFollowCountInWindow(winH) ??
                                0;
                            final ufCount = counterInst
                                    ?.effectiveUnfollowCountInWindow(winH) ??
                                0;
                            final prefix = resolved.isCrossSite &&
                                    resolved.effectiveService != null
                                ? '${_serviceDisplayName(resolved.effectiveService!)} '
                                : '';
                            return PopupMenuItem(
                              value: 'follow-counter',
                              child: Text(
                                ufCount > 0
                                    ? '$prefixフォロー/解除 (直近${winH}h +$fCount / -$ufCount)'
                                    : '$prefixフォロー/解除 (直近${winH}h $fCount回)',
                              ),
                            );
                          }(),
                          const PopupMenuItem(
                            value: 'sleep',
                            child: Text('タブ休止（メモリ解放）'),
                          ),
                        ],
                        const PopupMenuItem(
                          value: 'copy-url',
                          child: Text('現在のURLをコピー'),
                        ),
                        const PopupMenuItem(
                          value: 'external',
                          child: Text('外部ブラウザで開く'),
                        ),
                        const PopupMenuDivider(),
                      ],
                      PopupMenuItem(
                        value: 'archived-logins',
                        child: Text(
                          _archivedInstances.isNotEmpty
                              ? 'ログイン記憶を呼び出す (${_archivedInstances.length})'
                              : 'ログイン記憶',
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'gesture-settings',
                        child: Text('タッチジェスチャー設定'),
                      ),
                      const PopupMenuItem(
                        value: 'settings',
                        child: Text('アプリ設定'),
                      ),
                    ],
                  ),
                ],
                bottom: (_isGmailOpen ? _gmailRuntime.isLoading : activeRt?.isLoading == true)
                    ? PreferredSize(
                        preferredSize: const Size.fromHeight(2.5),
                        child: LinearProgressIndicator(
                          minHeight: 2.5,
                          value: () {
                            final p = _isGmailOpen
                                ? _gmailRuntime.progress
                                : (activeRt?.progress ?? 0);
                            return p > 0 && p < 100 ? p / 100 : null;
                          }(),
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
            if (!headerCollapsed && _isGmailOpen)
              _buildInAppGmailBar()
            else if (!headerCollapsed && active != null && activeGroup != null)
              _buildAccountSwitcherBar(activeGroup, active),
            if (!_isGmailOpen &&
                active != null &&
                (_extraTabs[active.instanceId]?.isNotEmpty ?? false))
              _buildSubTabStrip(active),
            if (!_isGmailOpen &&
                active != null &&
                _settings.accountFilter.isActive)
              _buildAccountFilterStatusBar(active),
            if (!_isGmailOpen &&
                active != null &&
                (_jev.isActive ||
                    _jev.totalApiCalls > 0 ||
                    (_jev.enabled && _jev.lastError != null)))
              _buildJevStatusBar(active),
            Expanded(
              child: SafeArea(
                top: false,
                bottom: tabsCollapsed,
                child: KeyedSubtree(
                  key: _viewportKey,
                  child: _buildViewport(visible, active, activeRt),
                ),
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
          if (_movingOrbGlobalPos != null) _buildFloatingOrbDragOverlay(),
        ],
      ),
    );
  }

  Widget _buildCollapsedAccountStrip(
    ServiceInstance active,
    _ServiceGroup? activeGroup,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final allScope = _settings.isHeaderAllAccounts;
    final accounts = allScope
        ? _visibleInstances
        : (activeGroup?.accounts ?? <ServiceInstance>[active]);
    if (accounts.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final iconOnly = allScope && constraints.maxWidth < 110;
        return ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
          itemCount: accounts.length,
          itemBuilder: (context, idx) {
            final inst = accounts[idx];
            final isCurrent = inst.instanceId == active.instanceId;
            final rt = _runtimeMap[inst.instanceId];
            final unread =
                inst.notificationsEnabled ? (rt?.unreadCount ?? 0) : 0;
            final grp = _groupForInstance(inst);
            final label = _headerLabelForInstance(
              inst,
              allScope: allScope,
              knownGroup: grp,
            );
            final svcColor = parseHexColor(inst.colorHex);
            return Padding(
              padding: EdgeInsets.only(right: iconOnly ? 3 : 4),
              child: Tooltip(
                message: '${grp?.displayName ?? inst.name} · $label',
                child: InkWell(
                  key: ValueKey('collapsed-account-pill-${inst.instanceId}'),
                  borderRadius: BorderRadius.circular(99),
                  onTap: () {
                    if (!isCurrent) _activateInstance(inst);
                  },
                  onLongPress: () => _showInstanceActionSheet(inst),
                  child: iconOnly
                      ? Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: svcColor.withValues(
                              alpha: rt?.isSleeping == true && !isCurrent
                                  ? 0.55
                                  : 1.0,
                            ),
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: isCurrent
                                  ? colorScheme.primary
                                  : Colors.transparent,
                              width: isCurrent ? 1.8 : 0,
                            ),
                          ),
                          child: Text(
                            inst.badge,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 8.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        )
                      : Container(
                          padding:
                              EdgeInsets.fromLTRB(allScope ? 4 : 7, 0, 7, 0),
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? colorScheme.primaryContainer
                                : colorScheme.surface,
                            borderRadius: BorderRadius.circular(99),
                            border: Border.all(
                              color: isCurrent
                                  ? colorScheme.primary
                                  : colorScheme.outlineVariant,
                              width: isCurrent ? 1.2 : 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (allScope) ...[
                                Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: svcColor.withValues(
                                      alpha:
                                          rt?.isSleeping == true ? 0.55 : 1.0,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    inst.badge,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 7.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                              ] else ...[
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: rt?.isLoading == true
                                        ? colorScheme.primary
                                        : rt?.isSleeping == true
                                            ? Colors.grey
                                            : Colors.green,
                                  ),
                                ),
                                const SizedBox(width: 4),
                              ],
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 72),
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: isCurrent
                                        ? FontWeight.bold
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                              if (unread > 0) ...[
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
                                    unread > 99 ? '99+' : '$unread',
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
              ),
            );
          },
        );
      },
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
    final resolvedCounter =
        active != null ? _resolveCounterTarget(active) : null;
    final counterTarget = resolvedCounter?.target;
    final winH = _settings.followWindowHours;
    final todayFollows =
        counterTarget?.effectiveFollowCountInWindow(winH) ?? 0;
    final todayUnfollows =
        counterTarget?.effectiveUnfollowCountInWindow(winH) ?? 0;
    final hasAnyToday = todayFollows > 0 || todayUnfollows > 0;
    final crossSiteBadge = resolvedCounter != null &&
            resolvedCounter.isCrossSite &&
            counterTarget != null
        ? '${counterTarget.badge} '
        : '';
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
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 30, minHeight: 34),
                      tooltip: 'メニュー',
                      onPressed: () => Scaffold.of(scaffoldCtx).openDrawer(),
                    ),
                  ),
                  if (_isGmailOpen) ...[
                    const Expanded(
                      child: Text(
                        'Gmail',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    InkWell(
                      key: const ValueKey('gmail-close-chip'),
                      borderRadius: BorderRadius.circular(99),
                      onTap: _toggleInAppGmail,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEA4335).withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                            color: const Color(0xFFEA4335).withValues(alpha: 0.55),
                          ),
                        ),
                        child: const Text(
                          'SNSへ戻る',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFEA4335),
                          ),
                        ),
                      ),
                    ),
                  ] else if (active != null) ...[
                    Expanded(
                      child: _buildCollapsedAccountStrip(active, activeGroup),
                    ),
                    const SizedBox(width: 2),
                    Tooltip(
                      message: _settings.accountFilter.isActive
                          ? '条件フィルタ ON（${_settings.accountFilter.summaryLabel}）· 長押しで設定'
                          : 'アカウント条件フィルタ（F/FW）· タップ/長押しで設定',
                      child: InkWell(
                        key: const ValueKey('collapsed-account-filter-chip'),
                        borderRadius: BorderRadius.circular(99),
                        onTap: _quickToggleAccountFilter,
                        onLongPress: _showAccountFilterSheet,
                        child: Container(
                          width: 26,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _settings.accountFilter.isActive
                                ? colorScheme.tertiaryContainer
                                : colorScheme.surface,
                            borderRadius: BorderRadius.circular(99),
                            border: Border.all(
                              color: _settings.accountFilter.isActive
                                  ? colorScheme.tertiary
                                  : colorScheme.outlineVariant,
                            ),
                          ),
                          child: Icon(
                            Icons.tune_rounded,
                            size: 14.5,
                            color: _settings.accountFilter.isActive
                                ? colorScheme.onTertiaryContainer
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 3),
                    Tooltip(
                      message: _jev.isActive
                          ? '分類フィルタ ON（${_jev.category}）· 長押しで設定'
                          : '分類フィルタ OFF（${_jev.category}）· 長押しで設定',
                      child: InkWell(
                        key: const ValueKey('collapsed-jev-filter-chip'),
                        borderRadius: BorderRadius.circular(99),
                        onTap: () async {
                          if (!_jev.hasApiKey) {
                            await _showJevSettingsSheet();
                          } else {
                            final next = !_jev.enabled;
                            final reset = await _jev.updateSettings(enabled: next);
                            _syncJevConfigToAllControllers(resetJudged: reset);
                            _showSnack(
                              next
                                  ? 'Jev 分類フィルタ ON（「${_jev.category}」）'
                                  : 'Jev 分類フィルタ OFF',
                            );
                          }
                        },
                        onLongPress: _showJevSettingsSheet,
                        child: Container(
                          width: 26,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _jev.isActive
                                ? colorScheme.primaryContainer
                                : colorScheme.surface,
                            borderRadius: BorderRadius.circular(99),
                            border: Border.all(
                              color: _jev.isActive
                                  ? colorScheme.primary
                                  : colorScheme.outlineVariant,
                            ),
                          ),
                          child: Icon(
                            _jev.isActive
                                ? Icons.filter_alt_rounded
                                : Icons.filter_alt_outlined,
                            size: 14.5,
                            color: _jev.isActive
                                ? colorScheme.onPrimaryContainer
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 3),
                    Tooltip(
                      message: todayUnfollows > 0
                          ? '直近$winH時間 · フォロー $todayFollows / 解除 $todayUnfollows'
                          : '直近$winH時間 · フォロー $todayFollows',
                      child: InkWell(
                        key: const ValueKey('follow-counter-chip'),
                        borderRadius: BorderRadius.circular(99),
                        onTap: () {
                          if (counterTarget != null) {
                            _showFollowCounterSheet(
                              counterTarget,
                              crossSiteSourceName:
                                  resolvedCounter?.isCrossSite == true
                                      ? (activeGroup?.displayName ?? active.name)
                                      : null,
                            );
                          } else if (resolvedCounter?.effectiveService != null) {
                            _showSnack(
                              '${_serviceDisplayName(resolvedCounter!.effectiveService!)} を追加するとカウントできます',
                            );
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: hasAnyToday
                                ? colorScheme.tertiaryContainer
                                : colorScheme.surface,
                            borderRadius: BorderRadius.circular(99),
                            border: Border.all(
                              color: hasAnyToday
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
                                color: hasAnyToday
                                    ? colorScheme.onTertiaryContainer
                                    : colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                todayUnfollows > 0
                                    ? '$crossSiteBadge$todayFollows/-$todayUnfollows'
                                    : '$crossSiteBadge$todayFollows',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: hasAnyToday
                                      ? colorScheme.onTertiaryContainer
                                      : colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
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
                    const SizedBox(width: 3),
                    InkWell(
                      borderRadius: BorderRadius.circular(99),
                      onTap: _toggleBottomTabsCollapsed,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
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
                            const Text('タブ', style: TextStyle(fontSize: 10)),
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
                  _buildHeaderGestureDockSlot(compact: true),
                  IconButton(
                    key: const ValueKey('header-gmail-button'),
                    icon: Icon(
                      _isGmailOpen
                          ? Icons.mark_email_read_rounded
                          : Icons.mail_outline_rounded,
                      size: 18,
                      color: _isGmailOpen ? const Color(0xFFEA4335) : null,
                    ),
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 34),
                    tooltip: _isGmailOpen
                        ? 'Gmail を閉じて元のSNSへ戻る'
                        : 'アプリ内で Gmail を開く（SNS認証メール確認用）',
                    onPressed: _toggleInAppGmail,
                  ),
                  if (_isGmailOpen || active != null)
                    IconButton(
                      key: const ValueKey('header-reload-button'),
                      icon: const Icon(Icons.refresh_rounded, size: 19),
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 34),
                      tooltip: '再読み込み',
                      onPressed: _reloadActiveTab,
                    ),
                  IconButton(
                    key: const ValueKey('header-expand-button'),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 22),
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 34),
                    tooltip: 'ヘッダーを展開',
                    onPressed: _toggleHeaderCollapsed,
                  ),
                ],
              ),
            ),
            if (_isGmailOpen
                ? _gmailRuntime.isLoading
                : activeRt != null && activeRt.isLoading)
              LinearProgressIndicator(
                minHeight: 2,
                value: () {
                  final p = _isGmailOpen
                      ? _gmailRuntime.progress
                      : (activeRt?.progress ?? 0);
                  return p > 0 && p < 100 ? p / 100 : null;
                }(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInAppGmailBar() {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('inapp-gmail-bar'),
      color: colorScheme.surfaceContainerLow,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              visualDensity: VisualDensity.compact,
              tooltip: '戻る',
              onPressed: _gmailRuntime.canGoBack
                  ? () => _gmailController?.goBack()
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              visualDensity: VisualDensity.compact,
              tooltip: '進む',
              onPressed: _gmailRuntime.canGoForward
                  ? () => _gmailController?.goForward()
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.home_outlined, size: 18),
              visualDensity: VisualDensity.compact,
              tooltip: 'Gmail 受信トレイへ戻る',
              onPressed: () {
                final g = _ensureGmailController();
                setState(() {
                  _gmailRuntime = _gmailRuntime.copyWith(
                    isLoading: true,
                    progress: 5,
                    clearError: true,
                  );
                });
                g.loadUrl(_gmailUrl);
              },
            ),
            const Spacer(),
            FilledButton.tonalIcon(
              key: const ValueKey('gmail-back-to-sns-button'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 28),
              ),
              onPressed: _toggleInAppGmail,
              icon: const Icon(Icons.close_rounded, size: 15),
              label: const Text(
                '元のSNSへ戻る',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
              ),
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
    final resolvedCounter = _resolveCounterTarget(active);
    final counterTarget = resolvedCounter.target;
    final winH = _settings.followWindowHours;
    final windowFollows = counterTarget?.effectiveFollowCountInWindow(winH) ?? 0;
    final windowUnfollows =
        counterTarget?.effectiveUnfollowCountInWindow(winH) ?? 0;
    final hasAnyWindow = windowFollows > 0 || windowUnfollows > 0;
    final crossSitePrefix = resolvedCounter.isCrossSite && counterTarget != null
        ? '${counterTarget.badge} '
        : '';
    final allScope = _settings.isHeaderAllAccounts;
    final headerAccounts = allScope ? _visibleInstances : group.accounts;
    final hasMultipleServices = _serviceGroups.length >= 2;
    final showStrip = allScope
        ? headerAccounts.isNotEmpty
        : (_multiProfileSupported || group.accounts.length >= 2);
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
            if (hasMultipleServices)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 2, 6),
                child: Tooltip(
                  message: allScope
                      ? '全SNSのアカウントをヘッダーに表示中（タップで「${group.displayName}」のみに切替）'
                      : '「${group.displayName}」のアカウントのみ表示中（タップで全SNSのアカウントを表示）',
                  child: InkWell(
                    key: const ValueKey('header-account-scope-toggle'),
                    borderRadius: BorderRadius.circular(99),
                    onTap: _toggleHeaderAccountScope,
                    child: Container(
                      height: 28,
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: allScope
                            ? colorScheme.secondaryContainer
                            : colorScheme.surface,
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(
                          color: allScope
                              ? colorScheme.secondary
                              : colorScheme.outlineVariant,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            allScope
                                ? Icons.layers_rounded
                                : Icons.filter_list_rounded,
                            size: 13,
                            color: allScope
                                ? colorScheme.onSecondaryContainer
                                : colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 2.5),
                          Text(
                            allScope ? '全' : group.badge,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: allScope
                                  ? colorScheme.onSecondaryContainer
                                  : colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: showStrip
                  ? ListView(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.fromLTRB(
                        hasMultipleServices ? 4 : 8,
                        5,
                        4,
                        5,
                      ),
                      children: [
                        for (var i = 0; i < headerAccounts.length; i++)
                          Builder(
                            builder: (context) {
                              final inst = headerAccounts[i];
                              final isCurrent =
                                  inst.instanceId == active.instanceId;
                              final rt = _runtimeMap[inst.instanceId];
                              final unread = inst.notificationsEnabled
                                  ? (rt?.unreadCount ?? 0)
                                  : 0;
                              final instGroup = allScope
                                  ? _groupForInstance(inst)
                                  : group;
                              final label = _headerLabelForInstance(
                                inst,
                                allScope: allScope,
                                knownGroup: instGroup,
                              );
                              final svcColor = parseHexColor(inst.colorHex);
                              final statusColor = rt?.isLoading == true
                                  ? colorScheme.primary
                                  : rt?.isSleeping == true
                                      ? Colors.grey
                                      : Colors.green;
                              return Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: InkWell(
                                  key: ValueKey(
                                    'header-account-pill-${inst.instanceId}',
                                  ),
                                  borderRadius: BorderRadius.circular(99),
                                  onTap: () {
                                    if (!isCurrent) _activateInstance(inst);
                                  },
                                  onLongPress: () =>
                                      _showInstanceActionSheet(inst),
                                  child: Container(
                                    padding: EdgeInsets.fromLTRB(
                                      allScope ? 4 : 9,
                                      0,
                                      8,
                                      0,
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
                                        if (allScope) ...[
                                          SizedBox(
                                            width: 19,
                                            height: 19,
                                            child: Stack(
                                              clipBehavior: Clip.none,
                                              children: [
                                                Container(
                                                  width: 18,
                                                  height: 18,
                                                  decoration: BoxDecoration(
                                                    color: svcColor.withValues(
                                                      alpha:
                                                          rt?.isSleeping == true
                                                              ? 0.62
                                                              : 1.0,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      5,
                                                    ),
                                                  ),
                                                  alignment: Alignment.center,
                                                  child: Text(
                                                    inst.badge,
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 8.5,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                    ),
                                                  ),
                                                ),
                                                Positioned(
                                                  right: -1.5,
                                                  bottom: -1.5,
                                                  child: Container(
                                                    width: 7,
                                                    height: 7,
                                                    decoration: BoxDecoration(
                                                      shape: BoxShape.circle,
                                                      color: statusColor,
                                                      border: Border.all(
                                                        color: isCurrent
                                                            ? colorScheme
                                                                .primaryContainer
                                                            : colorScheme
                                                                .surface,
                                                        width: 1.2,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 5),
                                        ] else ...[
                                          Container(
                                            width: 7,
                                            height: 7,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: statusColor,
                                            ),
                                          ),
                                          const SizedBox(width: 5),
                                        ],
                                        ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 112,
                                          ),
                                          child: Text(
                                            label,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: isCurrent
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
                        if (allScope || _multiProfileSupported)
                          InkWell(
                            key: const ValueKey('header-add-account-button'),
                            borderRadius: BorderRadius.circular(99),
                            onTap: allScope
                                ? _showCrossServiceAddAccountSheet
                                : _addAccountForActiveService,
                            child: Container(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
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
                                    allScope ? '追加' : 'アカウント追加',
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
                  : const SizedBox.shrink(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 5, 2, 5),
              child: Tooltip(
                message: _settings.accountFilter.isActive
                    ? '条件フィルタ ON（${_settings.accountFilter.summaryLabel}）· 長押しで設定'
                    : 'アカウント条件フィルタ（F/FW）· タップ/長押しで設定',
                child: InkWell(
                  key: const ValueKey('account-filter-chip'),
                  borderRadius: BorderRadius.circular(99),
                  onTap: _quickToggleAccountFilter,
                  onLongPress: _showAccountFilterSheet,
                  child: Container(
                    width: 30,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _settings.accountFilter.isActive
                          ? colorScheme.tertiaryContainer
                          : colorScheme.surface,
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(
                        color: _settings.accountFilter.isActive
                            ? colorScheme.tertiary
                            : colorScheme.outlineVariant,
                      ),
                    ),
                    child: Icon(
                      Icons.tune_rounded,
                      size: 16,
                      color: _settings.accountFilter.isActive
                          ? colorScheme.onTertiaryContainer
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 5, 2, 5),
              child: Tooltip(
                message: _jev.isActive
                    ? '分類フィルタ ON（${_jev.category}）· 長押しで設定'
                    : '分類フィルタ OFF（${_jev.category}）· 長押しで設定',
                child: InkWell(
                  key: const ValueKey('jev-filter-chip'),
                  borderRadius: BorderRadius.circular(99),
                  onTap: () async {
                    if (!_jev.hasApiKey) {
                      await _showJevSettingsSheet();
                    } else {
                      final next = !_jev.enabled;
                      final reset = await _jev.updateSettings(enabled: next);
                      _syncJevConfigToAllControllers(resetJudged: reset);
                      _showSnack(
                        next
                            ? 'Jev 分類フィルタ ON（「${_jev.category}」）'
                            : 'Jev 分類フィルタ OFF',
                      );
                    }
                  },
                  onLongPress: _showJevSettingsSheet,
                  child: Container(
                    width: 30,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _jev.isActive
                          ? colorScheme.primaryContainer
                          : colorScheme.surface,
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(
                        color: _jev.isActive
                            ? colorScheme.primary
                            : colorScheme.outlineVariant,
                      ),
                    ),
                    child: Icon(
                      _jev.isActive
                          ? Icons.filter_alt_rounded
                          : Icons.filter_alt_outlined,
                      size: 16,
                      color: _jev.isActive
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 5, 8, 5),
              child: Tooltip(
                message: windowUnfollows > 0
                    ? '$crossSitePrefix直近$winH時間 · フォロー $windowFollows / 解除 $windowUnfollows'
                    : '$crossSitePrefix直近$winH時間 · フォロー $windowFollows',
                child: InkWell(
                  key: const ValueKey('follow-counter-chip'),
                  borderRadius: BorderRadius.circular(99),
                  onTap: () {
                    if (counterTarget != null) {
                      _showFollowCounterSheet(
                        counterTarget,
                        crossSiteSourceName:
                            resolvedCounter.isCrossSite ? group.displayName : null,
                      );
                    } else if (resolvedCounter.effectiveService != null) {
                      _showSnack(
                        '${_serviceDisplayName(resolvedCounter.effectiveService!)} を追加するとカウントできます',
                      );
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: hasAnyWindow
                          ? colorScheme.tertiaryContainer
                          : colorScheme.surface,
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(
                        color: hasAnyWindow
                            ? colorScheme.tertiary
                            : colorScheme.outlineVariant,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.person_add_alt_1_rounded,
                          size: 13,
                          color: hasAnyWindow
                              ? colorScheme.onTertiaryContainer
                              : colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          windowUnfollows > 0
                              ? '$crossSitePrefix$windowFollows/-$windowUnfollows'
                              : '$crossSitePrefix$windowFollows',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: hasAnyWindow
                                ? colorScheme.onTertiaryContainer
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
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
    if (!_isGmailOpen && active == null) {
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
    final liveSubTabs = <_ExtraSubTab>[
      for (final id in liveIds)
        for (final sub in _extraTabs[id] ?? const <_ExtraSubTab>[])
          if (!sub.controller.isDisposed) sub,
    ];
    final hasGmailView =
        _gmailController != null && !_gmailController!.isDisposed;
    final gmailStackIndex =
        hasGmailView ? (liveIds.length + liveSubTabs.length) : -1;
    final activeExtra =
        active != null ? _activeExtraTabFor(active.instanceId) : null;
    int activeIndex = -1;
    if (_isGmailOpen) {
      activeIndex = gmailStackIndex;
    } else if (active != null) {
      if (activeExtra != null) {
        final subIdx = liveSubTabs.indexWhere(
          (t) => t.tabId == activeExtra.tabId,
        );
        if (subIdx >= 0) {
          activeIndex = liveIds.length + subIdx;
        }
      } else {
        activeIndex = liveIds.indexOf(active.instanceId);
      }
    }
    final isSleeping = _isGmailOpen
        ? !hasGmailView
        : (active == null ||
            (activeExtra == null &&
                (activeRt?.isSleeping == true ||
                    !_controllers.containsKey(active.instanceId))));
    final currentLoadError =
        _isGmailOpen ? _gmailRuntime.loadError : activeRt?.loadError;
    final hasError = currentLoadError != null;
    final showWebView = !isSleeping && !hasError && activeIndex >= 0;

    return Stack(
      children: [
        if (liveIds.isNotEmpty || liveSubTabs.isNotEmpty || hasGmailView)
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
                  for (final sub in liveSubTabs)
                    OmniWebViewWidget(
                      key: ValueKey('wv-sub-${sub.tabId}'),
                      controller: sub.controller,
                    ),
                  if (hasGmailView)
                    OmniWebViewWidget(
                      key: const ValueKey('wv-inapp-gmail'),
                      controller: _gmailController!,
                    ),
                ],
              ),
            ),
          ),
        if (!_isGmailOpen && isSleeping && active != null)
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
                      Text(currentLoadError, textAlign: TextAlign.center),
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
                              final url = _isGmailOpen
                                  ? (isHttpOrHttpsUrl(_gmailRuntime.currentUrl)
                                      ? _gmailRuntime.currentUrl
                                      : _gmailUrl)
                                  : (isHttpOrHttpsUrl(activeRt?.currentUrl)
                                      ? activeRt!.currentUrl
                                      : active?.url);
                              if (url != null) {
                                _openExternalUrlSafely(url);
                              }
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
        if (_settings.gesture.enabled)
          Positioned.fill(
            child: MobileGestureOverlay(
              key: _gestureOverlayKey,
              settings: _settings.gesture,
              onAction: (action, shape) {
                _executeMobileGestureAction(action, shape);
              },
              onLiveScroll: _handleGestureLiveScroll,
              onHandleMoved: (xFrac, yFrac) {
                _updateGestureSettings(
                  _settings.gesture.copyWith(
                    handleXFraction: xFrac,
                    handleYFraction: yFrac,
                  ),
                );
              },
              onOpenSettings: _openGestureSettings,
              onDockToHeader: _dockGestureToHeader,
              onHandleMoveDragChanged: _handleOverlayMoveDragChanged,
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
              title: Text(
                _multiProfileSupported ? 'アカウント名・URLを編集' : '表示名・URLを編集',
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _editInstance(inst);
              },
            ),
            if (_instances.length >= 2)
              ListTile(
                title: const Text('ヘッダーの並び順を変更'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _showAccountReorderSheet();
                },
              ),
            ListTile(
              title: Text(
                inst.isDesktopUa ? 'スマホ版サイトに戻す（現在PC版）' : 'PC版サイトで表示',
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _toggleDesktopMode(inst);
              },
            ),
            ListTile(
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
                          'Android · v1.8.5',
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
                    child: FilledButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        _openCatalog();
                      },
                      child: const Text('サービスを追加'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        _openGestureSettings();
                      },
                      child: const Text('タッチジェスチャー設定'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        _openSettings();
                      },
                      child: const Text('アプリ設定'),
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

  Widget _buildSubTabStrip(ServiceInstance active) {
    final colorScheme = Theme.of(context).colorScheme;
    final extras = _extraTabs[active.instanceId] ?? const <_ExtraSubTab>[];
    final activeTid = _activeSubTabId[active.instanceId];
    final mainRt = _runtimeMap[active.instanceId];
    final mainTitle = (mainRt?.title.trim().isNotEmpty ?? false)
        ? mainRt!.title
        : active.name;

    return Material(
      color: colorScheme.surfaceContainerLow,
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                children: [
                  _buildSubTabPill(
                    label: mainTitle,
                    selected: activeTid == null,
                    isLoading: mainRt?.isLoading == true,
                    onTap: () {
                      setState(() => _activeSubTabId.remove(active.instanceId));
                      _syncActiveWebViews();
                    },
                  ),
                  for (final sub in extras)
                    _buildSubTabPill(
                      label: sub.runtime.title.trim().isEmpty
                          ? '新しいタブ'
                          : sub.runtime.title,
                      selected: activeTid == sub.tabId,
                      isLoading: sub.runtime.isLoading,
                      onTap: () {
                        setState(
                          () => _activeSubTabId[active.instanceId] = sub.tabId,
                        );
                        _syncActiveWebViews();
                      },
                      onClose: () =>
                          _closeExtraSubTab(active.instanceId, sub.tabId),
                    ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: '裏タブで新しいタブを開く',
              onPressed: () =>
                  _openUrlInNewSubTab(active, active.url, activate: false),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubTabPill({
    required String label,
    required bool selected,
    bool isLoading = false,
    required VoidCallback onTap,
    VoidCallback? onClose,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 160),
          padding: EdgeInsets.fromLTRB(9, 0, onClose != null ? 4 : 9, 0),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? colorScheme.primaryContainer
                : colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? colorScheme.primary
                  : colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading) ...[
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: selected
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (onClose != null) ...[
                const SizedBox(width: 2),
                InkWell(
                  borderRadius: BorderRadius.circular(99),
                  onTap: onClose,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      Icons.close,
                      size: 13,
                      color: selected
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAccountFilterStatusBar(ServiceInstance active) {
    final colorScheme = Theme.of(context).colorScheme;
    final af = _settings.accountFilter;
    final live = _currentAccountFilterLiveState(active);
    final summary = af.summaryLabel;
    final busy = live.pending > 0
        ? '（取得中 ${live.pending}件）'
        : (live.autoFetching ? '（次ページ取得中…）' : '');
    final statusText = live.active
        ? '条件[$summary] 表示 ${live.matched}件 / 非表示 ${live.hidden}件$busy'
        : '条件フィルタ ON（$summary）';

    return Material(
      key: const ValueKey('account-filter-status-bar'),
      color: colorScheme.tertiaryContainer.withValues(alpha: 0.35),
      child: InkWell(
        onTap: _showAccountFilterSheet,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.tune_rounded,
                size: 13,
                color: colorScheme.tertiary,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '条件変更',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.tertiary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAccountFilterSheet() async {
    if (!mounted) return;
    final result = await showModalBottomSheet<AccountFilterSettings>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AccountFilterSheet(
        initial: _settings.accountFilter,
      ),
    );
    if (!mounted || result == null) return;
    final sanitized = result.sanitized();
    await _updateAccountFilterSettings(
      sanitized,
      toastMessage: sanitized.isActive
          ? '条件フィルタを適用しました（${sanitized.summaryLabel}）'
          : 'アカウント条件フィルタをOFFにしました',
    );
  }

  Widget _buildJevStatusBar(ServiceInstance active) {
    final colorScheme = Theme.of(context).colorScheme;
    final live = _currentJevLiveState(active);
    final costLabel = JevService.formatCostCompact(_jev.totalCostUsd);
    final extra = _jevCheckingCount > 0
        ? '（判定中…）'
        : (live.autoFetching ? '（次ページ取得中…）' : '');
    final statusText = _jev.isActive && live.active
        ? '分類「${_jev.category}」表示 ${live.matched}件 / 非表示 ${live.hidden}件$extra · 費用 $costLabel'
        : _jev.isActive
            ? 'Jev 分類「${_jev.category}」ON · 費用 $costLabel'
            : 'Jev 分類フィルタ OFF · 費用 $costLabel';
    final hasErr = _jev.enabled && _jev.lastError != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: colorScheme.surfaceContainerLow,
          child: InkWell(
            onTap: _showJevSettingsSheet,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      statusText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '設定',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (hasErr)
          Material(
            color: colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _jev.lastError!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onErrorContainer,
                          ),
                    ),
                  ),
                  TextButton(
                    onPressed: _showJevSettingsSheet,
                    child: const Text('設定'),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    onPressed: () {
                      _jev.clearError();
                    },
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _showJevSettingsSheet() async {
    await _jev.ensureLoaded();
    if (!mounted) return;
    final catCtrl = TextEditingController(text: _jev.category);
    final keyCtrl = TextEditingController(text: _jev.apiKey);
    var enabled = _jev.hasApiKey ? _jev.enabled : true;
    var threshold = _jev.threshold.clamp(0.40, 0.85);
    var obscure = true;
    var testing = false;
    ({bool ok, String message})? testResult;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final scheme = Theme.of(ctx).colorScheme;
          final chips = <String>[];
          for (final c in _jev.recentCategories) {
            if (!chips.any((x) => x.toLowerCase() == c.toLowerCase())) {
              chips.add(c);
            }
          }
          for (final p in kJevPresetCategories) {
            if (!chips.any((x) => x.toLowerCase() == p.toLowerCase())) {
              chips.add(p);
            }
          }
          final currentCatLower = catCtrl.text.trim().toLowerCase();

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                MediaQuery.viewInsetsOf(ctx).bottom + 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Jev 分類フィルタ',
                      style: Theme.of(ctx)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'フォロー中・フォロワー一覧のアイコン画像と名前・自己紹介を Jev（TypeSafe AI）で判定し、入力した分類に一致するアカウントだけを表示します。',
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest
                            .withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: ListenableBuilder(
                        listenable: _jev,
                        builder: (context, _) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Jev 利用費用',
                                  style: Theme.of(ctx).textTheme.labelLarge,
                                ),
                                const Spacer(),
                                if (_jev.totalApiCalls > 0)
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                    ),
                                    onPressed: () async {
                                      await _jev.resetUsageStats();
                                    },
                                    child: const Text('費用をリセット'),
                                  ),
                              ],
                            ),
                            Text(
                              '累計: ${JevService.formatCostCompact(_jev.totalCostUsd)}',
                              style: Theme.of(ctx)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            Text(
                              '今回の起動中: ${JevService.formatCostCompact(_jev.sessionCostUsd)}',
                              style: Theme.of(ctx).textTheme.bodySmall,
                            ),
                            Text(
                              '通信 ${_jev.totalApiCalls}回 · 判定 ${_jev.totalJudgedAccounts}件 · 入力 ${_jev.totalInputTokens} tok · キャッシュ ${_jev.cacheEntries}件',
                              style: Theme.of(ctx)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: catCtrl,
                      maxLength: 60,
                      decoration: const InputDecoration(
                        labelText: '表示したい分類（自由入力）',
                        hintText: '例: 女の子、カフェ、イラスト、大学生、猫…',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onChanged: (_) => setModalState(() {}),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final c in chips.take(10))
                          ChoiceChip(
                            label: Text(c),
                            selected: c.toLowerCase() == currentCatLower,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) {
                              catCtrl.text = c;
                              setModalState(() {});
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('この分類に一致するアカウントのみ表示'),
                      value: enabled,
                      onChanged: (v) => setModalState(() => enabled = v),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: keyCtrl,
                      obscureText: obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'TypeSafe API キー',
                        hintText: 'Bearer トークンを入力',
                        helperText: 'この端末内にのみ保存されます',
                        border: const OutlineInputBorder(),
                        suffixIcon: TextButton(
                          onPressed: () =>
                              setModalState(() => obscure = !obscure),
                          child: Text(obscure ? '表示' : '隠す'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Text(
                          '一致判定のしきい値: ${(threshold * 100).round()}%',
                          style: Theme.of(ctx).textTheme.labelMedium,
                        ),
                        const Spacer(),
                        Text(
                          threshold <= 0.48
                              ? '広めに表示'
                              : (threshold >= 0.70 ? '確実な一致のみ' : '標準'),
                          style: Theme.of(ctx)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                    Slider(
                      value: threshold.clamp(0.40, 0.85),
                      min: 0.40,
                      max: 0.85,
                      divisions: 9,
                      label: '${(threshold * 100).round()}%',
                      onChanged: (v) => setModalState(() => threshold = v),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton(
                          onPressed: testing
                              ? null
                              : () async {
                                  setModalState(() {
                                    testing = true;
                                    testResult = null;
                                  });
                                  final res = await _jev.testConnection(
                                    keyCtrl.text,
                                    candidateCategory: catCtrl.text,
                                  );
                                  if (ctx.mounted) {
                                    setModalState(() {
                                      testing = false;
                                      testResult = res;
                                    });
                                  }
                                },
                          child: Text(testing ? 'テスト中…' : '接続テスト'),
                        ),
                        TextButton(
                          onPressed: () async {
                            await _jev.clearCache();
                            _syncJevConfigToAllControllers(resetJudged: true);
                            if (mounted) {
                              _showSnack('判定キャッシュを消去しました');
                            }
                          },
                          child: const Text('判定履歴を消去'),
                        ),
                      ],
                    ),
                    if (testResult case final r?) ...[
                      const SizedBox(height: 8),
                      Text(
                        r.message,
                        style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                              color: r.ok ? scheme.primary : scheme.error,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('キャンセル'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: () async {
                              final trimmedKey = keyCtrl.text.trim();
                              final trimmedCat = catCtrl.text.trim().isEmpty
                                  ? JevService.defaultCategory
                                  : catCtrl.text.trim();
                              final reset = await _jev.updateSettings(
                                apiKey: trimmedKey,
                                category: trimmedCat,
                                enabled: enabled && trimmedKey.isNotEmpty,
                                threshold: threshold,
                              );
                              _syncJevConfigToAllControllers(
                                resetJudged: reset,
                              );
                              if (ctx.mounted) Navigator.of(ctx).pop();
                              if (mounted) {
                                _showSnack(
                                  _jev.isActive
                                      ? 'Jev 分類「${_jev.category}」を適用しました'
                                      : 'Jev 分類フィルタ設定を保存しました',
                                );
                              }
                            },
                            child: const Text('保存して適用'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    catCtrl.dispose();
    keyCtrl.dispose();
  }
}

class _FollowCounterSheet extends StatefulWidget {
  const _FollowCounterSheet({
    required this.targetInstanceId,
    required this.crossSiteSourceName,
    required this.multiProfileSupported,
    required this.getInstances,
    required this.getServiceGroups,
    required this.getFollowSyncSettings,
    required this.getFollowWindowHours,
    required this.onChangeFollowWindowHours,
    required this.formatSyncClock,
    required this.onAdjustFollow,
    required this.onResetFollow,
    required this.onAdjustUnfollow,
    required this.onResetUnfollow,
    required this.onSetHandle,
    required this.onSaveSyncCredentials,
    required this.onSyncNow,
    required this.onOpenExternalUrl,
    required this.onShowSnack,
  });

  final String targetInstanceId;
  final String? crossSiteSourceName;
  final bool multiProfileSupported;
  final List<ServiceInstance> Function() getInstances;
  final List<_ServiceGroup> Function() getServiceGroups;
  final FollowSyncSettings Function() getFollowSyncSettings;
  final int Function() getFollowWindowHours;
  final Future<void> Function(int hours) onChangeFollowWindowHours;
  final String Function(int? unixSecs) formatSyncClock;
  final Future<void> Function(String instanceId, int delta) onAdjustFollow;
  final Future<void> Function(String instanceId, bool resetTotal) onResetFollow;
  final Future<void> Function(String instanceId, int delta) onAdjustUnfollow;
  final Future<void> Function(String instanceId, bool resetTotal)
      onResetUnfollow;
  final Future<String?> Function(String instanceId, String rawHandle)
      onSetHandle;
  final Future<void> Function({
    required String githubToken,
    required String gistId,
  }) onSaveSyncCredentials;
  final Future<String> Function() onSyncNow;
  final Future<void> Function(String url) onOpenExternalUrl;
  final void Function(String message) onShowSnack;

  @override
  State<_FollowCounterSheet> createState() => _FollowCounterSheetState();
}

class _FollowCounterSheetState extends State<_FollowCounterSheet> {
  late final TextEditingController _handleCtrl;
  late final TextEditingController _tokenCtrl;
  late final TextEditingController _gistCtrl;
  late final TextEditingController _windowHoursCtrl;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.getInstances().cast<ServiceInstance?>().firstWhere(
          (i) => i?.instanceId == widget.targetInstanceId,
          orElse: () => null,
        );
    final fs = widget.getFollowSyncSettings();
    _handleCtrl = TextEditingController(text: initial?.detectedHandle ?? '');
    _tokenCtrl = TextEditingController(text: fs.githubToken);
    _gistCtrl = TextEditingController(text: fs.gistId);
    _windowHoursCtrl =
        TextEditingController(text: '${widget.getFollowWindowHours()}');
  }

  @override
  void dispose() {
    _handleCtrl.dispose();
    _tokenCtrl.dispose();
    _gistCtrl.dispose();
    _windowHoursCtrl.dispose();
    super.dispose();
  }

  Future<void> _applyWindowHours(int hours) async {
    final clamped = hours.clamp(minFollowWindowHours, maxFollowWindowHours);
    _windowHoursCtrl.text = '$clamped';
    await widget.onChangeFollowWindowHours(clamped);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final instances = widget.getInstances();
    final current = instances.cast<ServiceInstance?>().firstWhere(
          (i) => i?.instanceId == widget.targetInstanceId,
          orElse: () => null,
        );
    if (current == null) return const SizedBox.shrink();

    final groups = widget.getServiceGroups();
    final grp = groups.cast<_ServiceGroup?>().firstWhere(
          (g) => g?.key == serviceGroupKey(current),
          orElse: () => null,
        );
    final siblingIdx = grp == null
        ? 0
        : max(
            0,
            grp.accounts.indexWhere((a) => a.instanceId == current.instanceId),
          );
    final accLabel = accountDisplayLabel(
      current,
      siblingIdx,
      baseServiceName: grp?.displayName,
    );
    final baseTitle = widget.multiProfileSupported
        ? '${grp?.displayName ?? current.name} · $accLabel'
        : (grp?.displayName ?? current.name);
    final withHandle = current.detectedHandle != null &&
            !baseTitle.contains('@${current.detectedHandle}')
        ? '$baseTitle (@${current.detectedHandle})'
        : baseTitle;
    final title = widget.crossSiteSourceName != null
        ? '$withHandle（${widget.crossSiteSourceName}タブ内）'
        : withHandle;

    final now = DateTime.now();
    final windowHours = widget.getFollowWindowHours();
    final followCount = current.effectiveFollowCountInWindow(windowHours, now);
    final unfollowCount =
        current.effectiveUnfollowCountInWindow(windowHours, now);
    var allFollowSum = 0;
    var allUnfollowSum = 0;
    for (final inst in instances) {
      allFollowSum += inst.effectiveFollowCountInWindow(windowHours, now);
      allUnfollowSum += inst.effectiveUnfollowCountInWindow(windowHours, now);
    }
    final colorScheme = Theme.of(context).colorScheme;
    final fs = widget.getFollowSyncSettings();
    final hasCloud = fs.githubToken.trim().isNotEmpty;
    final syncBadge = hasCloud ? 'クラウド同期' : '未設定';
    final syncClock = widget.formatSyncClock(fs.lastSyncAt);
    final syncStatusLine = fs.lastSyncStatus != null
        ? (syncClock.isNotEmpty
            ? '${fs.lastSyncStatus}（$syncClock）'
            : fs.lastSyncStatus!)
        : (hasCloud
            ? 'GitHub 非公開 Gist で PC・スマホ間を自動同期します'
            : 'GitHub Token を設定すると PC・スマホ間で自動同期されます');

    final snsLiveParts = <String>[];
    if (current.snsFollowingCount != null) {
      snsLiveParts.add('フォロー中 ${current.snsFollowingCount}人');
    }
    if (current.snsFollowersCount != null) {
      snsLiveParts.add('フォロワー ${current.snsFollowersCount}人');
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
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
                          'フォロー・アンフォロー カウンター',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '集計時間（指定時間内のフォロー・解除数を集計）',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final h in const [1, 3, 6, 12, 24])
                          ChoiceChip(
                            key: ValueKey('follow-window-preset-$h'),
                            label: Text('$h時間', style: const TextStyle(fontSize: 11.5)),
                            visualDensity: VisualDensity.compact,
                            selected: windowHours == h,
                            onSelected: (_) => _applyWindowHours(h),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('自由指定: 直近', style: TextStyle(fontSize: 12)),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 66,
                          child: TextField(
                            key: const ValueKey('follow-window-hours-input'),
                            controller: _windowHoursCtrl,
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 6,
                              ),
                              border: OutlineInputBorder(),
                            ),
                            style: const TextStyle(fontSize: 13),
                            onSubmitted: (v) {
                              final parsed = int.tryParse(v.trim());
                              if (parsed != null) _applyWindowHours(parsed);
                            },
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text('時間', style: TextStyle(fontSize: 12)),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          key: const ValueKey('follow-window-apply'),
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          onPressed: () {
                            final parsed =
                                int.tryParse(_windowHoursCtrl.text.trim());
                            if (parsed != null) {
                              _applyWindowHours(parsed);
                            }
                          },
                          child: const Text('適用', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(10),
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
                          Text(
                            '直近$windowHours時間のフォロー',
                            style: const TextStyle(fontSize: 11),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$followCount',
                            key: const ValueKey('follow-sheet-today'),
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  key: const ValueKey('follow-sheet-dec'),
                                  style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                  ),
                                  onPressed: followCount > 0
                                      ? () async {
                                          await widget.onAdjustFollow(
                                            current.instanceId,
                                            -1,
                                          );
                                          if (mounted) setState(() {});
                                        }
                                      : null,
                                  child: const Text('−1'),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: FilledButton.tonal(
                                  key: const ValueKey('follow-sheet-inc'),
                                  style: FilledButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                  ),
                                  onPressed: () async {
                                    await widget.onAdjustFollow(
                                      current.instanceId,
                                      1,
                                    );
                                    if (mounted) setState(() {});
                                  },
                                  child: const Text('＋1'),
                                ),
                              ),
                            ],
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 28),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: followCount > 0
                                ? () async {
                                    await widget.onResetFollow(
                                      current.instanceId,
                                      false,
                                    );
                                    if (mounted) setState(() {});
                                  }
                                : null,
                            child: const Text('リセット', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.redAccent.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            '直近$windowHours時間の解除',
                            style: const TextStyle(fontSize: 11),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$unfollowCount',
                            key: const ValueKey('unfollow-sheet-today'),
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: Colors.redAccent,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  key: const ValueKey('unfollow-sheet-dec'),
                                  style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                  ),
                                  onPressed: unfollowCount > 0
                                      ? () async {
                                          await widget.onAdjustUnfollow(
                                            current.instanceId,
                                            -1,
                                          );
                                          if (mounted) setState(() {});
                                        }
                                      : null,
                                  child: const Text('−1'),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: OutlinedButton(
                                  key: const ValueKey('unfollow-sheet-inc'),
                                  style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    foregroundColor: Colors.redAccent,
                                    side: BorderSide(
                                      color: Colors.redAccent
                                          .withValues(alpha: 0.55),
                                    ),
                                  ),
                                  onPressed: () async {
                                    await widget.onAdjustUnfollow(
                                      current.instanceId,
                                      1,
                                    );
                                    if (mounted) setState(() {});
                                  },
                                  child: const Text('＋1'),
                                ),
                              ),
                            ],
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 28),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: unfollowCount > 0
                                ? () async {
                                    await widget.onResetUnfollow(
                                      current.instanceId,
                                      false,
                                    );
                                    if (mounted) setState(() {});
                                  }
                                : null,
                            child: const Text('リセット', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (snsLiveParts.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: colorScheme.primary.withValues(alpha: 0.32),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'SNS実数',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          snsLiveParts.join(' · '),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _handleCtrl,
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixText: '@',
                        labelText: '同期アカウントID（自動検出）',
                        hintText: '例: darksan560',
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () async {
                      final err = await widget.onSetHandle(
                        current.instanceId,
                        _handleCtrl.text,
                      );
                      if (err != null) {
                        widget.onShowSnack(err);
                      } else {
                        widget.onShowSnack('同期アカウントIDを更新しました');
                      }
                      if (mounted) setState(() {});
                    },
                    child: const Text('設定'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  title: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'PC・スマホ同期設定',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          syncBadge,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'クラウド同期 (GitHub非公開Gist)',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 24),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => widget.onOpenExternalUrl(
                            'https://github.com/settings/tokens/new?scopes=gist&description=OmniSNS%20Follow%20Sync',
                          ),
                          child: const Text(
                            'Token作成',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _tokenCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'GitHub Token (gist権限)',
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 12.5),
                      onChanged: (val) {
                        final parsed = parseSharedSyncConfig(val);
                        if (parsed != null) {
                          _tokenCtrl.text = parsed.token;
                          _gistCtrl.text = parsed.gistId;
                          widget.onShowSnack('コピーした同期設定を自動入力しました');
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _gistCtrl,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Gist ID（空欄で自動作成）',
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        FilledButton.tonal(
                          onPressed: _isSyncing
                              ? null
                              : () async {
                                  final tk = _tokenCtrl.text.trim();
                                  final gid = _gistCtrl.text.trim();
                                  if (tk.isNotEmpty &&
                                      !isValidGitHubToken(tk)) {
                                    widget.onShowSnack(
                                      'GitHub Token の形式が不正です（空白や改行を含めないでください）',
                                    );
                                    return;
                                  }
                                  if (!isValidGistId(gid)) {
                                    widget.onShowSnack(
                                      'Gist ID の形式が不正です（半角英数字・ハイフン・アンダースコアのみ有効）',
                                    );
                                    return;
                                  }
                                  setState(() => _isSyncing = true);
                                  await widget.onSaveSyncCredentials(
                                    githubToken: tk,
                                    gistId: gid,
                                  );
                                  try {
                                    final msg = await widget.onSyncNow();
                                    if (mounted) {
                                      _gistCtrl.text =
                                          widget.getFollowSyncSettings().gistId;
                                    }
                                    widget.onShowSnack(msg);
                                  } catch (e) {
                                    widget.onShowSnack(formatSafeSyncError(e));
                                  } finally {
                                    if (mounted) {
                                      setState(() => _isSyncing = false);
                                    }
                                  }
                                },
                          child: Text(
                            _isSyncing ? '同期中...' : '保存して今すぐ同期',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            final tk = _tokenCtrl.text.trim();
                            final gid = _gistCtrl.text.trim();
                            if (tk.isEmpty) {
                              widget.onShowSnack('先にTokenを入力してください');
                              return;
                            }
                            if (!isValidGitHubToken(tk) ||
                                !isValidGistId(gid)) {
                              widget.onShowSnack(
                                'GitHub Token または Gist ID の形式が不正です',
                              );
                              return;
                            }
                            await Clipboard.setData(
                              ClipboardData(
                                text: encodeSharedSyncConfig(tk, gid),
                              ),
                            );
                            widget.onShowSnack('同期設定をコピーしました（PC側へ貼付可）');
                          },
                          child: const Text(
                            '設定コピー',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                        OutlinedButton(
                          onPressed: _isSyncing
                              ? null
                              : () async {
                                  final clip = await Clipboard.getData(
                                    Clipboard.kTextPlain,
                                  );
                                  if (!mounted) return;
                                  final parsed = parseSharedSyncConfig(
                                    clip?.text ?? '',
                                  );
                                  if (parsed == null) {
                                    widget.onShowSnack(
                                      'クリップボードに有効な同期設定がありません',
                                    );
                                    return;
                                  }
                                  _tokenCtrl.text = parsed.token;
                                  _gistCtrl.text = parsed.gistId;
                                  setState(() => _isSyncing = true);
                                  await widget.onSaveSyncCredentials(
                                    githubToken: parsed.token,
                                    gistId: parsed.gistId,
                                  );
                                  try {
                                    final msg = await widget.onSyncNow();
                                    if (mounted) {
                                      _gistCtrl.text =
                                          widget.getFollowSyncSettings().gistId;
                                    }
                                    widget.onShowSnack(msg);
                                  } catch (e) {
                                    widget.onShowSnack(formatSafeSyncError(e));
                                  } finally {
                                    if (mounted) {
                                      setState(() => _isSyncing = false);
                                    }
                                  }
                                },
                          child: const Text(
                            '貼付して適用',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        syncStatusLine,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              if (instances.length >= 2) ...[
                const Divider(height: 16),
                Text(
                  allUnfollowSum > 0
                      ? '全アカウント合計（直近$windowHours時間）: フォロー $allFollowSum回 / 解除 $allUnfollowSum回'
                      : '全アカウント合計（直近$windowHours時間）: $allFollowSum 回',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                '指定時間内のフォロー・解除（フォロー中ユーザーのブロックを含む）を自動カウントし、同一 @アカウント のPC・スマホ間で合算共有されます。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditInstanceDialog extends StatefulWidget {
  const _EditInstanceDialog({
    required this.instance,
    required this.dialogTitle,
    required this.initialAccountLabel,
    required this.multiProfileSupported,
  });

  final ServiceInstance instance;
  final String dialogTitle;
  final String initialAccountLabel;
  final bool multiProfileSupported;

  @override
  State<_EditInstanceDialog> createState() => _EditInstanceDialogState();
}

class _EditInstanceDialogState extends State<_EditInstanceDialog> {
  late final TextEditingController _accCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late bool _notify;

  @override
  void initState() {
    super.initState();
    _accCtrl = TextEditingController(text: widget.initialAccountLabel);
    _nameCtrl = TextEditingController(text: widget.instance.name);
    _urlCtrl = TextEditingController(text: widget.instance.url);
    _notify = widget.instance.notificationsEnabled;
  }

  @override
  void dispose() {
    _accCtrl.dispose();
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inst = widget.instance;
    return AlertDialog(
      title: Text(widget.dialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.multiProfileSupported) ...[
              TextField(
                controller: _accCtrl,
                decoration: const InputDecoration(
                  labelText: 'アカウント名（ヘッダー表示名）',
                  hintText: '例: メイン / サブ / 仕事用',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'サービス表示名',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'ホーム / DM画面 URL',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _notify,
              onChanged: (v) => setState(() => _notify = v ?? true),
              title: const Text('未読バッジ監視'),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () {
            final normalized = normalizeServiceUrl(_urlCtrl.text);
            if (normalized == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('有効なURLを入力してください')),
              );
              return;
            }
            final trimmedAcc = _accCtrl.text.trim();
            Navigator.of(context).pop(
              inst.copyWith(
                name: _nameCtrl.text.trim().isEmpty
                    ? inst.name
                    : _nameCtrl.text.trim(),
                accountLabel: widget.multiProfileSupported
                    ? (trimmedAcc.isEmpty ? null : trimmedAcc)
                    : inst.accountLabel,
                clearAccountLabel:
                    widget.multiProfileSupported && trimmedAcc.isEmpty,
                url: normalized,
                notificationsEnabled: _notify,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _AccountFilterSheet extends StatefulWidget {
  const _AccountFilterSheet({required this.initial});

  final AccountFilterSettings initial;

  @override
  State<_AccountFilterSheet> createState() => _AccountFilterSheetState();
}

class _AccountFilterSheetState extends State<_AccountFilterSheet> {
  late bool _enabled;
  late bool _followingGtFollowers;
  late final TextEditingController _minFollowingCtrl;
  late final TextEditingController _maxFollowingCtrl;
  late final TextEditingController _minFollowersCtrl;
  late final TextEditingController _maxFollowersCtrl;

  @override
  void initState() {
    super.initState();
    final af = widget.initial;
    _enabled = af.hasAnyCondition ? af.enabled : true;
    _followingGtFollowers = af.followingGreaterThanFollowers;
    _minFollowingCtrl =
        TextEditingController(text: af.minFollowing?.toString() ?? '');
    _maxFollowingCtrl =
        TextEditingController(text: af.maxFollowing?.toString() ?? '');
    _minFollowersCtrl =
        TextEditingController(text: af.minFollowers?.toString() ?? '');
    _maxFollowersCtrl =
        TextEditingController(text: af.maxFollowers?.toString() ?? '');
  }

  @override
  void dispose() {
    _minFollowingCtrl.dispose();
    _maxFollowingCtrl.dispose();
    _minFollowersCtrl.dispose();
    _maxFollowersCtrl.dispose();
    super.dispose();
  }

  int? _parseCount(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    if (n == null || n < 0) return null;
    return n > AccountFilterSettings.maxBound
        ? AccountFilterSettings.maxBound
        : n;
  }

  void _applyPreset({
    int? minFollowing,
    int? maxFollowing,
    int? minFollowers,
    int? maxFollowers,
    bool followingGt = false,
  }) {
    setState(() {
      _enabled = true;
      _minFollowingCtrl.text = minFollowing?.toString() ?? '';
      _maxFollowingCtrl.text = maxFollowing?.toString() ?? '';
      _minFollowersCtrl.text = minFollowers?.toString() ?? '';
      _maxFollowersCtrl.text = maxFollowers?.toString() ?? '';
      _followingGtFollowers = followingGt;
    });
  }

  void _save() {
    final minF = _parseCount(_minFollowingCtrl.text);
    final maxF = _parseCount(_maxFollowingCtrl.text);
    final minFw = _parseCount(_minFollowersCtrl.text);
    final maxFw = _parseCount(_maxFollowersCtrl.text);
    final next = AccountFilterSettings(
      enabled: _enabled,
      minFollowing: minF,
      maxFollowing: maxF,
      minFollowers: minFw,
      maxFollowers: maxFw,
      followingGreaterThanFollowers: _followingGtFollowers,
    ).sanitized();
    Navigator.of(context).pop(next);
  }

  void _clear() {
    Navigator.of(context).pop(const AccountFilterSettings());
  }

  @override
  Widget build(BuildContext context) {
    final insetBottom = MediaQuery.of(context).viewInsets.bottom;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, insetBottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'アカウント条件フィルタ（F / FW）',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'フォロー中・フォロワー一覧や検索結果で、条件を満たすアカウントのみ表示します（無料・APIキー不要）',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const ValueKey('af-sheet-enabled'),
              contentPadding: EdgeInsets.zero,
              title: const Text('条件フィルタを有効にする'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ActionChip(
                  label: const Text('フォロー多め (F>FW)'),
                  onPressed: () => _applyPreset(followingGt: true),
                ),
                ActionChip(
                  label: const Text('F 100以上'),
                  onPressed: () => _applyPreset(minFollowing: 100),
                ),
                ActionChip(
                  label: const Text('FW 100以上'),
                  onPressed: () => _applyPreset(minFollowers: 100),
                ),
                ActionChip(
                  label: const Text('F 100以上 & F>FW'),
                  onPressed: () =>
                      _applyPreset(minFollowing: 100, followingGt: true),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'フォロー数（Following）',
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('af-sheet-min-following'),
                    controller: _minFollowingCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '以上',
                      hintText: '指定なし',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('〜'),
                ),
                Expanded(
                  child: TextField(
                    key: const ValueKey('af-sheet-max-following'),
                    controller: _maxFollowingCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '以下',
                      hintText: '指定なし',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'フォロワー数（Followers）',
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('af-sheet-min-followers'),
                    controller: _minFollowersCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '以上',
                      hintText: '指定なし',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('〜'),
                ),
                Expanded(
                  child: TextField(
                    key: const ValueKey('af-sheet-max-followers'),
                    controller: _maxFollowersCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '以下',
                      hintText: '指定なし',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            CheckboxListTile(
              key: const ValueKey('af-sheet-following-gt'),
              contentPadding: EdgeInsets.zero,
              title: const Text('フォロー数の方が多いユーザーのみ表示'),
              subtitle: const Text('フォロー数 > フォロワー数'),
              value: _followingGtFollowers,
              onChanged: (v) =>
                  setState(() => _followingGtFollowers = v ?? false),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton(
                  key: const ValueKey('af-sheet-clear'),
                  onPressed: _clear,
                  child: const Text('クリア'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('キャンセル'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('af-sheet-save'),
                  onPressed: _save,
                  child: const Text('保存して適用'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
