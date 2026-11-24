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

class _HomeScreenState extends State<HomeScreen> {
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

  final JevService _jev = JevService();
  final Map<String, OmniWebViewController> _controllers = {};
  final Map<String, TabRuntimeState> _runtimeMap = {};
  final Map<String, List<_ExtraSubTab>> _extraTabs = {};
  final Map<String, String?> _activeSubTabId = {};
  final Map<String, _JevTabLiveState> _jevLiveByKey = {};
  int _jevCheckingCount = 0;
  int _subTabSeq = 0;
  final Map<String, String> _lastActiveByGroup = {};
  final Map<String, ({String service, String handle})> _crossSiteIdentities = {};
  final GlobalKey<MobileGestureOverlayState> _gestureOverlayKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _jev.addListener(_onJevChanged);
    unawaited(_jev.ensureLoaded());
    _bootstrap();
  }

  void _onJevChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _jev.removeListener(_onJevChanged);
    _jev.dispose();
    _cloudSyncDebounce?.cancel();
    _cloudSyncPeriodic?.cancel();
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
    final catalogData = await widget.store.loadCatalog();
    final (settings, loadedInstances) =
        await widget.store.loadState(catalogData.services);
    final archivedInstances =
        await widget.store.loadArchivedInstances(loadedInstances);
    final (followSyncSettings, followLedger) =
        await widget.store.loadFollowSyncState();
    final today = formatLocalYmd(DateTime.now());
    final (instances, _) =
        projectLedgerToInstances(loadedInstances, followLedger, today);
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

  Future<void> _persistArchived() async {
    await widget.store.saveArchivedInstances(_archivedInstances);
  }

  String _formatArchivedDisplayTitle(ServiceInstance inst) {
    final label = inst.accountLabel?.trim();
    final base = (label != null && label.isNotEmpty && label != inst.name)
        ? '${inst.name} · $label'
        : inst.name;
    final h = inst.detectedHandle?.trim();
    return (h != null && h.isNotEmpty) ? '$base (@$h)' : base;
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

    late final OmniWebViewController controller;
    controller = OmniWebViewController(
      initialUrl: instance.url,
      profileName: _multiProfileSupported
          ? instance.effectiveProfileName
          : defaultWebViewProfileName,
      userAgent: buildUserAgentForMode(instance.uaMode),
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
      onFollowDetected: (_, service) {
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => instance,
            );
        if (src == null) return;
        final resolved = _resolveCounterTarget(
          src,
          explicitService: service,
        );
        if (resolved.target != null) {
          _adjustFollowCount(resolved.target!.instanceId, 1);
        }
      },
      onUnfollowDetected: (_, service) {
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => instance,
            );
        if (src == null) return;
        final resolved = _resolveCounterTarget(
          src,
          explicitService: service,
        );
        if (resolved.target != null) {
          _adjustUnfollowCount(resolved.target!.instanceId, 1);
        }
      },
      onAccountIdentity: (service, handle, following, followers) {
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => instance,
            );
        if (src == null) return;
        final normSvc = service.trim().toLowerCase();
        final normHandle = normalizeAccountHandle(handle);
        if (normSvc.isNotEmpty &&
            normSvc != src.serviceId &&
            normHandle != null) {
          _crossSiteIdentities[src.instanceId] =
              (service: normSvc, handle: normHandle);
        }
        final resolved = _resolveCounterTarget(
          src,
          explicitService: normSvc,
          handleHint: handle,
        );
        if (resolved.target != null) {
          _handleAccountIdentity(
            resolved.target!.instanceId,
            handle,
            following: following,
            followers: followers,
          );
        }
      },
      onOpenNewTab: (url) {
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => instance,
            );
        if (src != null) {
          _openUrlInNewSubTab(src, url, activate: false);
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
    late final _ExtraSubTab subTab;
    late final OmniWebViewController ctrl;
    ctrl = OmniWebViewController(
      initialUrl: targetUrl,
      profileName: _multiProfileSupported
          ? instance.effectiveProfileName
          : defaultWebViewProfileName,
      userAgent: buildUserAgentForMode(instance.uaMode),
      onProgress: (progress) {
        subTab.runtime = subTab.runtime.copyWith(
          progress: progress,
          isLoading: progress < 100,
          isSleeping: false,
        );
        if (mounted) setState(() {});
      },
      onPageStarted: (url) {
        subTab.runtime = subTab.runtime.copyWith(
          currentUrl: isHttpOrHttpsUrl(url) ? url : subTab.runtime.currentUrl,
          isLoading: true,
          isSleeping: false,
          clearError: true,
        );
        if (mounted) setState(() {});
      },
      onPageFinished: (url, title, canBack, canFwd, hadError) {
        final safeTitle = title.trim().isEmpty ? initialTitle : title;
        final validUrl = isHttpOrHttpsUrl(url);
        subTab.runtime = subTab.runtime.copyWith(
          currentUrl: validUrl ? url : subTab.runtime.currentUrl,
          title: safeTitle,
          progress: 100,
          isLoading: false,
          isSleeping: false,
          canGoBack: canBack,
          canGoForward: canFwd,
          clearError: !hadError && validUrl,
        );
        if (mounted) setState(() {});
      },
      onTitleChanged: (title) {
        final safeTitle = title.trim().isEmpty ? initialTitle : title;
        subTab.runtime = subTab.runtime.copyWith(title: safeTitle);
        if (mounted) setState(() {});
      },
      onHistoryChanged: (url, canBack, canFwd) {
        subTab.runtime = subTab.runtime.copyWith(
          currentUrl: isHttpOrHttpsUrl(url) ? url : subTab.runtime.currentUrl,
          canGoBack: canBack,
          canGoForward: canFwd,
        );
        if (mounted) setState(() {});
      },
      onWebResourceError: (description, errorCode) {
        subTab.runtime = subTab.runtime.copyWith(
          isLoading: false,
          loadError: '$description ($errorCode)',
        );
        if (mounted) setState(() {});
      },
      onExternalScheme: (url) => _openExternalUrlSafely(url),
      onFollowDetected: (_, service) {
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => instance,
            );
        if (src == null) return;
        final resolved = _resolveCounterTarget(src, explicitService: service);
        if (resolved.target != null) {
          _adjustFollowCount(resolved.target!.instanceId, 1);
        }
      },
      onUnfollowDetected: (_, service) {
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => instance,
            );
        if (src == null) return;
        final resolved = _resolveCounterTarget(src, explicitService: service);
        if (resolved.target != null) {
          _adjustUnfollowCount(resolved.target!.instanceId, 1);
        }
      },
      onAccountIdentity: (service, handle, following, followers) {
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => instance,
            );
        if (src == null) return;
        final resolved = _resolveCounterTarget(
          src,
          explicitService: service.trim().toLowerCase(),
          handleHint: handle,
        );
        if (resolved.target != null) {
          _handleAccountIdentity(
            resolved.target!.instanceId,
            handle,
            following: following,
            followers: followers,
          );
        }
      },
      onOpenNewTab: (url) {
        final src = _instances.cast<ServiceInstance?>().firstWhere(
              (i) => i?.instanceId == instance.instanceId,
              orElse: () => instance,
            );
        if (src != null) {
          _openUrlInNewSubTab(src, url, activate: false);
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
    }
    if (mounted) {
      setState(() {});
      HapticFeedback.mediumImpact();
      if (!activate) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('新規タブで開きました（全$totalTabsタブ）'),
              duration: const Duration(seconds: 3),
              action: SnackBarAction(
                label: '開く',
                onPressed: () {
                  if (!mounted) return;
                  final stillExists = (_extraTabs[instance.instanceId] ?? [])
                      .any((t) => t.tabId == tabId);
                  if (stillExists) {
                    setState(() {
                      _isGmailOpen = false;
                      _activeSubTabId[instance.instanceId] = tabId;
                    });
                  }
                },
              ),
            ),
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
    if (_activeSubTabId[instanceId] == tabId) {
      if (list.isEmpty) {
        _activeSubTabId.remove(instanceId);
      } else {
        final nextIdx = (idx - 1).clamp(0, list.length - 1);
        _activeSubTabId[instanceId] = idx == 0 ? null : list[nextIdx].tabId;
      }
    }
    if (list.isEmpty) {
      _extraTabs.remove(instanceId);
    }
    if (mounted) setState(() {});
  }

  void _disposeExtraSubTabsFor(String instanceId) {
    final list = _extraTabs.remove(instanceId);
    if (list != null) {
      for (final t in list) {
        t.controller.dispose();
        _jevLiveByKey.remove('sub:${t.tabId}');
      }
    }
    _activeSubTabId.remove(instanceId);
    _jevLiveByKey.remove('main:$instanceId');
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
      _isGmailOpen = false;
      _settings = _settings.copyWith(activeInstanceId: inst.instanceId);
    });
    _ensureController(inst);
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
      return;
    }
    _ensureGmailController();
    setState(() {
      _isGmailOpen = true;
    });
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
    final token = _followSyncSettings.githubToken.trim();
    if (token.isEmpty) {
      throw Exception('GitHub Personal Access Token（gist 権限）を入力してください');
    }

    final today = formatLocalYmd(DateTime.now());
    try {
      final res = await FollowSyncService.syncWithGitHubGist(
        token: token,
        gistId: _followSyncSettings.gistId,
        localLedger: _followLedger,
        today: today,
      );
      _followLedger.mergeFrom(res.mergedLedger, today);
      final (projected, _) =
          projectLedgerToInstances(_instances, _followLedger, today);
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
      final errText = e.toString().replaceFirst('Exception: ', '');
      if (mounted) {
        setState(() {
          _followSyncSettings = _followSyncSettings.copyWith(
            lastSyncStatus: '同期エラー: $errText',
          );
        });
      }
      await widget.store
          .saveFollowSyncState(_followSyncSettings, _followLedger);
      if (!silent) rethrow;
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
    final inst = _instances[idx];
    final prevHandle = inst.detectedHandle;
    final prevToday = inst.effectiveFollowCountToday();
    final prevTotal = inst.followCountTotal;
    final prevUfToday = inst.effectiveUnfollowCountToday();
    final prevUfTotal = inst.unfollowCountTotal;

    var uiChanged = false;
    var ledgerChanged = false;

    var nextInst = inst;
    if (prevHandle != norm) {
      nextInst = nextInst.copyWith(detectedHandle: norm);
      uiChanged = true;
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
      final now = nowUnixSecs();
      final existed = _followLedger.accounts.containsKey(key);
      final acc = _followLedger.accounts.putIfAbsent(
        key,
        () => AccountFollowLedger(date: today),
      );
      acc.rollDate(today);
      if (!existed) ledgerChanged = true;

      final devId = _followSyncSettings.deviceId;
      if (prevHandle == null &&
          (prevToday > 0 ||
              prevTotal > 0 ||
              prevUfToday > 0 ||
              prevUfTotal > 0) &&
          devId.isNotEmpty &&
          !acc.devices.containsKey(devId)) {
        acc.devices[devId] = DeviceFollowEntry(
          today: prevToday,
          total: prevTotal,
          todayEpoch: acc.resetEpoch,
          totalEpoch: acc.totalResetEpoch,
          unfollowToday: prevUfToday,
          unfollowTotal: prevUfTotal,
          unfollowTodayEpoch: acc.unfollowResetEpoch,
          unfollowTotalEpoch: acc.unfollowTotalResetEpoch,
          updatedAt: now,
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
    final (projected, projChanged) =
        projectLedgerToInstances(updatedList, _followLedger, today);

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
      setState(() {
        _instances[idx] = _instances[idx].copyWith(clearDetectedHandle: true);
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
    final today = formatLocalYmd(DateTime.now());
    final inst = _instances[idx];
    final syncKey = makeAccountSyncKey(inst.serviceId, inst.detectedHandle);

    if (syncKey != null && _followSyncSettings.deviceId.isNotEmpty) {
      final devId = _followSyncSettings.deviceId;
      final now = nowUnixSecs();
      final prevToday = inst.effectiveFollowCountToday();
      final prevTotal = inst.followCountTotal;
      final prevUfToday = inst.effectiveUnfollowCountToday();
      final prevUfTotal = inst.unfollowCountTotal;

      final acc = _followLedger.accounts.putIfAbsent(
        syncKey,
        () => AccountFollowLedger(date: today),
      );
      acc.rollDate(today);

      if (!acc.devices.containsKey(devId)) {
        final seed = acc.devices.isEmpty &&
            (prevToday > 0 ||
                prevTotal > 0 ||
                prevUfToday > 0 ||
                prevUfTotal > 0);
        acc.devices[devId] = DeviceFollowEntry(
          today: seed ? prevToday : 0,
          total: seed ? prevTotal : 0,
          todayEpoch: acc.resetEpoch,
          totalEpoch: acc.totalResetEpoch,
          unfollowToday: seed ? prevUfToday : 0,
          unfollowTotal: seed ? prevUfTotal : 0,
          unfollowTodayEpoch: acc.unfollowResetEpoch,
          unfollowTotalEpoch: acc.unfollowTotalResetEpoch,
          updatedAt: now,
        );
      }

      final (curToday, curTotal) = acc.effectiveCounts(today);
      final entry = acc.devices[devId]!;
      if (entry.todayEpoch < acc.resetEpoch) {
        entry.today = 0;
        entry.todayEpoch = acc.resetEpoch;
      }
      if (entry.totalEpoch < acc.totalResetEpoch) {
        entry.total = 0;
        entry.totalEpoch = acc.totalResetEpoch;
      }
      if (delta >= 0) {
        entry.today += delta;
        entry.total += delta;
      } else {
        final absDelta = -delta;
        entry.today -= min(absDelta, curToday);
        entry.total -= min(absDelta, curTotal);
      }
      entry.updatedAt = max(now, entry.updatedAt + 1);

      final (projected, _) =
          projectLedgerToInstances(_instances, _followLedger, today);
      setState(() {
        _instances = projected;
      });
      await _persistAllWithFollowSync();
      _notifyFollowLedgerChanged();
      return;
    }

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
    final today = formatLocalYmd(DateTime.now());
    final inst = _instances[idx];
    final syncKey = makeAccountSyncKey(inst.serviceId, inst.detectedHandle);

    if (syncKey != null) {
      final now = nowUnixSecs();
      final acc = _followLedger.accounts.putIfAbsent(
        syncKey,
        () => AccountFollowLedger(date: today),
      );
      acc.rollDate(today);
      acc.resetEpoch += 1;
      for (final entry in acc.devices.values) {
        entry.today = 0;
        entry.todayEpoch = acc.resetEpoch;
        entry.updatedAt = max(now, entry.updatedAt + 1);
      }
      if (resetTotal) {
        acc.totalResetEpoch += 1;
        for (final entry in acc.devices.values) {
          entry.total = 0;
          entry.totalEpoch = acc.totalResetEpoch;
          entry.updatedAt = max(now, entry.updatedAt + 1);
        }
      }
      final (projected, _) =
          projectLedgerToInstances(_instances, _followLedger, today);
      setState(() {
        _instances = projected;
      });
      await _persistAllWithFollowSync();
      _notifyFollowLedgerChanged();
      return;
    }

    setState(() {
      _instances[idx] = _instances[idx].withFollowReset(resetTotal: resetTotal);
    });
    await _persist();
  }

  Future<void> _adjustUnfollowCount(String instanceId, int delta) async {
    final idx = _instances.indexWhere((i) => i.instanceId == instanceId);
    if (idx == -1) return;
    final today = formatLocalYmd(DateTime.now());
    final inst = _instances[idx];
    final syncKey = makeAccountSyncKey(inst.serviceId, inst.detectedHandle);

    if (syncKey != null && _followSyncSettings.deviceId.isNotEmpty) {
      final devId = _followSyncSettings.deviceId;
      final now = nowUnixSecs();
      final prevToday = inst.effectiveFollowCountToday();
      final prevTotal = inst.followCountTotal;
      final prevUfToday = inst.effectiveUnfollowCountToday();
      final prevUfTotal = inst.unfollowCountTotal;

      final acc = _followLedger.accounts.putIfAbsent(
        syncKey,
        () => AccountFollowLedger(date: today),
      );
      acc.rollDate(today);

      if (!acc.devices.containsKey(devId)) {
        final seed = acc.devices.isEmpty &&
            (prevToday > 0 ||
                prevTotal > 0 ||
                prevUfToday > 0 ||
                prevUfTotal > 0);
        acc.devices[devId] = DeviceFollowEntry(
          today: seed ? prevToday : 0,
          total: seed ? prevTotal : 0,
          todayEpoch: acc.resetEpoch,
          totalEpoch: acc.totalResetEpoch,
          unfollowToday: seed ? prevUfToday : 0,
          unfollowTotal: seed ? prevUfTotal : 0,
          unfollowTodayEpoch: acc.unfollowResetEpoch,
          unfollowTotalEpoch: acc.unfollowTotalResetEpoch,
          updatedAt: now,
        );
      }

      final (curToday, curTotal) = acc.effectiveUnfollowCounts(today);
      final entry = acc.devices[devId]!;
      if (entry.unfollowTodayEpoch < acc.unfollowResetEpoch) {
        entry.unfollowToday = 0;
        entry.unfollowTodayEpoch = acc.unfollowResetEpoch;
      }
      if (entry.unfollowTotalEpoch < acc.unfollowTotalResetEpoch) {
        entry.unfollowTotal = 0;
        entry.unfollowTotalEpoch = acc.unfollowTotalResetEpoch;
      }
      if (delta >= 0) {
        entry.unfollowToday += delta;
        entry.unfollowTotal += delta;
      } else {
        final absDelta = -delta;
        entry.unfollowToday -= min(absDelta, curToday);
        entry.unfollowTotal -= min(absDelta, curTotal);
      }
      entry.updatedAt = max(now, entry.updatedAt + 1);

      final (projected, _) =
          projectLedgerToInstances(_instances, _followLedger, today);
      setState(() {
        _instances = projected;
      });
      await _persistAllWithFollowSync();
      _notifyFollowLedgerChanged();
      return;
    }

    setState(() {
      _instances[idx] = _instances[idx].withUnfollowDelta(delta);
    });
    await _persist();
  }

  Future<void> _resetUnfollowCount(
    String instanceId, {
    required bool resetTotal,
  }) async {
    final idx = _instances.indexWhere((i) => i.instanceId == instanceId);
    if (idx == -1) return;
    final today = formatLocalYmd(DateTime.now());
    final inst = _instances[idx];
    final syncKey = makeAccountSyncKey(inst.serviceId, inst.detectedHandle);

    if (syncKey != null) {
      final now = nowUnixSecs();
      final acc = _followLedger.accounts.putIfAbsent(
        syncKey,
        () => AccountFollowLedger(date: today),
      );
      acc.rollDate(today);
      acc.unfollowResetEpoch += 1;
      for (final entry in acc.devices.values) {
        entry.unfollowToday = 0;
        entry.unfollowTodayEpoch = acc.unfollowResetEpoch;
        entry.updatedAt = max(now, entry.updatedAt + 1);
      }
      if (resetTotal) {
        acc.unfollowTotalResetEpoch += 1;
        for (final entry in acc.devices.values) {
          entry.unfollowTotal = 0;
          entry.unfollowTotalEpoch = acc.unfollowTotalResetEpoch;
          entry.updatedAt = max(now, entry.updatedAt + 1);
        }
      }
      final (projected, _) =
          projectLedgerToInstances(_instances, _followLedger, today);
      setState(() {
        _instances = projected;
      });
      await _persistAllWithFollowSync();
      _notifyFollowLedgerChanged();
      return;
    }

    setState(() {
      _instances[idx] =
          _instances[idx].withUnfollowReset(resetTotal: resetTotal);
    });
    await _persist();
  }

  String _formatSyncClock(int? unixSecs) {
    if (unixSecs == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Future<void> _showFollowCounterSheet(
    ServiceInstance target, {
    String? crossSiteSourceName,
  }) async {
    final handleCtrl = TextEditingController(text: target.detectedHandle ?? '');
    final tokenCtrl =
        TextEditingController(text: _followSyncSettings.githubToken);
    final gistCtrl = TextEditingController(text: _followSyncSettings.gistId);
    var isSyncing = false;

    try {
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
            final baseTitle = _multiProfileSupported
                ? '${grp?.displayName ?? current.name} · $accLabel'
                : (grp?.displayName ?? current.name);
            final withHandle = current.detectedHandle != null
                ? '$baseTitle (@${current.detectedHandle})'
                : baseTitle;
            final title = crossSiteSourceName != null
                ? '$withHandle（$crossSiteSourceNameタブ内）'
                : withHandle;

            final now = DateTime.now();
            final todayCount = current.effectiveFollowCountToday(now);
            final totalCount = current.followCountTotal;
            final unfollowTodayCount = current.effectiveUnfollowCountToday(now);
            final unfollowTotalCount = current.unfollowCountTotal;
            var allTodaySum = 0;
            var allUnfollowTodaySum = 0;
            for (final inst in _instances) {
              allTodaySum += inst.effectiveFollowCountToday(now);
              allUnfollowTodaySum += inst.effectiveUnfollowCountToday(now);
            }
            final colorScheme = Theme.of(ctx).colorScheme;
            final fs = _followSyncSettings;
            final hasCloud = fs.githubToken.trim().isNotEmpty;
            final syncBadge = hasCloud ? 'クラウド同期' : '未設定';
            final syncClock = _formatSyncClock(fs.lastSyncAt);
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
                  bottom: MediaQuery.of(ctx).viewInsets.bottom,
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
                      const SizedBox(height: 10),
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
                                  color: colorScheme.primary
                                      .withValues(alpha: 0.4),
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
                              color:
                                  colorScheme.primary.withValues(alpha: 0.32),
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
                                await _adjustFollowCount(
                                  current.instanceId,
                                  1,
                                );
                                setSheetState(() {});
                              },
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('＋1'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
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
                      const SizedBox(height: 8),
                      const Text(
                        'アンフォロー（フォロー解除）回数',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.redAccent,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
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
                                  const Text(
                                    '今日のアンフォロー数',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '$unfollowTodayCount',
                                    key: const ValueKey('unfollow-sheet-today'),
                                    style: const TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.redAccent,
                                    ),
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
                                    '累計アンフォロー数',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '$unfollowTotalCount',
                                    key: const ValueKey('unfollow-sheet-total'),
                                    style: const TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              key: const ValueKey('unfollow-sheet-dec'),
                              onPressed: unfollowTodayCount > 0 ||
                                      unfollowTotalCount > 0
                                  ? () async {
                                      await _adjustUnfollowCount(
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
                            child: OutlinedButton.icon(
                              key: const ValueKey('unfollow-sheet-inc'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.redAccent,
                                side: BorderSide(
                                  color: Colors.redAccent.withValues(alpha: 0.55),
                                ),
                              ),
                              onPressed: () async {
                                await _adjustUnfollowCount(
                                  current.instanceId,
                                  1,
                                );
                                setSheetState(() {});
                              },
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('＋1'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: unfollowTodayCount > 0
                                  ? () async {
                                      await _resetUnfollowCount(
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
                              onPressed: unfollowTotalCount > 0 ||
                                      unfollowTodayCount > 0
                                  ? () async {
                                      await _resetUnfollowCount(
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
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: handleCtrl,
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
                              final err = await _setInstanceHandleManual(
                                current.instanceId,
                                handleCtrl.text,
                              );
                              if (err != null) {
                                _showSnack(err);
                              } else {
                                _showSnack('同期アカウントIDを更新しました');
                              }
                              setSheetState(() {});
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
                          tilePadding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          childrenPadding:
                              const EdgeInsets.fromLTRB(12, 0, 12, 12),
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
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () => _openExternalUrlSafely(
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
                              controller: tokenCtrl,
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
                                  tokenCtrl.text = parsed.token;
                                  gistCtrl.text = parsed.gistId;
                                  _showSnack('コピーした同期設定を自動入力しました');
                                }
                              },
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: gistCtrl,
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
                                  onPressed: isSyncing
                                      ? null
                                      : () async {
                                          setSheetState(() => isSyncing = true);
                                          setState(() {
                                            _followSyncSettings =
                                                _followSyncSettings.copyWith(
                                              githubToken:
                                                  tokenCtrl.text.trim(),
                                              gistId: gistCtrl.text.trim(),
                                            );
                                          });
                                          await widget.store
                                              .saveFollowSyncState(
                                            _followSyncSettings,
                                            _followLedger,
                                          );
                                          try {
                                            final msg =
                                                await _syncFollowCloudOnce(
                                              silent: false,
                                            );
                                            gistCtrl.text =
                                                _followSyncSettings.gistId;
                                            _showSnack(msg);
                                          } catch (e) {
                                            _showSnack(
                                              e
                                                  .toString()
                                                  .replaceFirst(
                                                    'Exception: ',
                                                    '',
                                                  ),
                                            );
                                          } finally {
                                            if (ctx.mounted) {
                                              setSheetState(
                                                () => isSyncing = false,
                                              );
                                            }
                                          }
                                        },
                                  child: Text(
                                    isSyncing ? '同期中...' : '保存して今すぐ同期',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                OutlinedButton(
                                  onPressed: () async {
                                    final tk = tokenCtrl.text.trim();
                                    if (tk.isEmpty) {
                                      _showSnack('先にTokenを入力してください');
                                      return;
                                    }
                                    await Clipboard.setData(
                                      ClipboardData(
                                        text: encodeSharedSyncConfig(
                                          tk,
                                          gistCtrl.text.trim(),
                                        ),
                                      ),
                                    );
                                    _showSnack('同期設定をコピーしました（PC側へ貼付可）');
                                  },
                                  child: const Text(
                                    '設定コピー',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                                OutlinedButton(
                                  onPressed: isSyncing
                                      ? null
                                      : () async {
                                          final clip = await Clipboard.getData(
                                            Clipboard.kTextPlain,
                                          );
                                          final parsed = parseSharedSyncConfig(
                                            clip?.text ?? '',
                                          );
                                          if (parsed == null) {
                                            _showSnack(
                                              'クリップボードに有効な同期設定がありません',
                                            );
                                            return;
                                          }
                                          tokenCtrl.text = parsed.token;
                                          gistCtrl.text = parsed.gistId;
                                          setSheetState(() => isSyncing = true);
                                          setState(() {
                                            _followSyncSettings =
                                                _followSyncSettings.copyWith(
                                              githubToken: parsed.token,
                                              gistId: parsed.gistId,
                                            );
                                          });
                                          await widget.store
                                              .saveFollowSyncState(
                                            _followSyncSettings,
                                            _followLedger,
                                          );
                                          try {
                                            final msg =
                                                await _syncFollowCloudOnce(
                                              silent: false,
                                            );
                                            gistCtrl.text =
                                                _followSyncSettings.gistId;
                                            _showSnack(msg);
                                          } catch (e) {
                                            _showSnack(
                                              e
                                                  .toString()
                                                  .replaceFirst(
                                                    'Exception: ',
                                                    '',
                                                  ),
                                            );
                                          } finally {
                                            if (ctx.mounted) {
                                              setSheetState(
                                                () => isSyncing = false,
                                              );
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
                                style: Theme.of(ctx)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_instances.length >= 2) ...[
                        const Divider(height: 16),
                        Text(
                          allUnfollowTodaySum > 0
                              ? '全アカウント合計（今日）: フォロー $allTodaySum回 / 解除 $allUnfollowTodaySum回'
                              : '全アカウント合計（今日）: $allTodaySum 回',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        'Threads・Instagram・Bluesky 等でフォロー／フォロー解除を押すと自動カウントされ、同一 @アカウント のPC・スマホ間で合算共有されます。',
                        style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    } finally {
      handleCtrl.dispose();
      tokenCtrl.dispose();
      gistCtrl.dispose();
    }
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
          onPurgeArchived: _purgeArchivedInstance,
          onPurgeAllArchived: _purgeAllArchivedInstances,
        ),
      ),
    );
    if (req == null) return;

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
    final active = _activeInstance;
    final activeGroup = _activeGroup;
    final updated = await Navigator.of(context).push<AppSettings>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          settings: _settings,
          activeServiceName:
              (!_isGmailOpen && active != null) ? (activeGroup?.displayName ?? active.name) : null,
          activeDesktopMode: (!_isGmailOpen && active != null) ? active.isDesktopUa : null,
          onToggleDesktopMode: (!_isGmailOpen && active != null)
              ? (desktop) => _toggleDesktopMode(active, forceDesktop: desktop)
              : null,
          jevSummary: _jev.isActive
              ? 'ON · 分類「${_jev.category}」· 累計 ${JevService.formatCostCompact(_jev.totalCostUsd)}'
              : 'OFF · 分類「${_jev.category}」· 累計 ${JevService.formatCostCompact(_jev.totalCostUsd)}',
          onOpenJevSettings: () => _showJevSettingsSheet(),
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
            if (_gmailController != null && !_gmailController!.isDisposed) {
              await _reloadGmail();
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

  Future<void> _updateGestureSettings(MobileGestureSettings next) async {
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

  bool _stepActiveAccount(int delta) {
    final group = _activeGroup;
    final active = _activeInstance;
    if (group == null || active == null || group.accounts.length <= 1) {
      _showGestureNotice('このSNSのアカウントは1つだけです');
      return false;
    }
    final curIdx = max(
      0,
      group.accounts.indexWhere((a) => a.instanceId == active.instanceId),
    );
    final nextIdx = stepTabIndex(
      group.accounts.length,
      curIdx,
      delta,
      _settings.gesture.wrapTabs,
    );
    if (nextIdx == null) {
      _showGestureNotice(delta < 0 ? '先頭のアカウントです' : '末尾のアカウントです');
      return false;
    }
    final nextInst = group.accounts[nextIdx];
    final label = accountDisplayLabel(
      nextInst,
      nextIdx,
      baseServiceName: group.displayName,
    );
    _activateInstance(nextInst);
    _showGestureNotice('${group.displayName} · $label');
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
          await ctrl.goBack();
          _showGestureNotice('${shapeArrows(shape)} 戻る');
        } else if (_isGmailOpen) {
          setState(() => _isGmailOpen = false);
          _showGestureNotice('${shapeArrows(shape)} Gmailを閉じました');
        } else {
          _showGestureNotice('これ以上戻れません');
        }
      case 'go-forward':
        if (ctrl != null && await ctrl.canGoForward()) {
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
          setState(() {
            _gmailRuntime = _gmailRuntime.copyWith(
              isSleeping: false,
              isLoading: true,
              progress: 5,
              clearError: true,
            );
          });
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
          _openUrlInNewSubTab(active, active.url, activate: true);
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
    if (ok != true) return;

    final wasActive = _settings.activeInstanceId == inst.instanceId;
    final removedCtrl = _controllers.remove(inst.instanceId);
    removedCtrl?.dispose();
    _disposeExtraSubTabsFor(inst.instanceId);
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
    if (ok != true) return;

    final archivedBatch = List<ServiceInstance>.from(group.accounts);
    final ids = group.accounts.map((a) => a.instanceId).toSet();
    for (final acc in group.accounts) {
      final ctrl = _controllers.remove(acc.instanceId);
      ctrl?.dispose();
      _disposeExtraSubTabsFor(acc.instanceId);
      _runtimeMap.remove(acc.instanceId);
    }
    setState(() {
      _instances.removeWhere((i) => ids.contains(i.instanceId));
    });
    _ensureSafeActiveAndLoad();
    await _persist();
    await _archiveInstances(archivedBatch);
    _showSnack('「${group.displayName}」を削除しました（ログイン記憶は保持）');
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
      child: Scaffold(
        drawer: _buildDrawer(groups, activeGroup),
        appBar: headerCollapsed
            ? null
            : AppBar(
                toolbarHeight: 50,
                titleSpacing: 4,
                title: _isGmailOpen
                    ? InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () async {
                          await Clipboard.setData(
                            ClipboardData(text: _gmailRuntime.currentUrl),
                          );
                          _showSnack('Gmail のURLをコピーしました');
                        },
                        child: Row(
                          children: [
                            Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: const Color(0xFFEA4335),
                                borderRadius: BorderRadius.circular(7),
                              ),
                              alignment: Alignment.center,
                              child: const Text(
                                'GM',
                                style: TextStyle(
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
                                  const Text(
                                    'Gmail（アプリ内）',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    _gmailRuntime.currentUrl,
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
                      )
                    : active == null
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
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          activeGroup?.displayName ?? active.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      if (active.isDesktopUa) ...[
                                        const SizedBox(width: 5),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 5,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primaryContainer,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            'PC',
                                            style: TextStyle(
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.w700,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onPrimaryContainer,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
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
                            final fCount =
                                counterInst?.effectiveFollowCountToday() ?? 0;
                            final ufCount =
                                counterInst?.effectiveUnfollowCountToday() ?? 0;
                            final prefix = resolved.isCrossSite &&
                                    resolved.effectiveService != null
                                ? '${_serviceDisplayName(resolved.effectiveService!)} '
                                : '';
                            return PopupMenuItem(
                              value: 'follow-counter',
                              child: Text(
                                ufCount > 0
                                    ? '$prefixフォロー/解除 (今日 +$fCount / -$ufCount)'
                                    : '$prefixフォロー/解除 (今日 $fCount回)',
                              ),
                            );
                          }(),
                          const PopupMenuItem(
                            value: 'sleep',
                            child: Text('タブ休止（メモリ解放）'),
                          ),
                        ],
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
                (_jev.isActive ||
                    _jev.totalApiCalls > 0 ||
                    (_jev.enabled && _jev.lastError != null)))
              _buildJevStatusBar(active),
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
    final resolvedCounter =
        active != null ? _resolveCounterTarget(active) : null;
    final counterTarget = resolvedCounter?.target;
    final todayFollows = counterTarget?.effectiveFollowCountToday() ?? 0;
    final todayUnfollows = counterTarget?.effectiveUnfollowCountToday() ?? 0;
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
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 34, minHeight: 34),
                      tooltip: 'メニュー',
                      onPressed: () => Scaffold.of(scaffoldCtx).openDrawer(),
                    ),
                  ),
                  if (_isGmailOpen) ...[
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEA4335),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        'GM',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 8.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'Gmail（アプリ内）',
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
                          horizontal: 7,
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
                            const SizedBox(width: 3),
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
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 34),
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
    final todayFollows = counterTarget?.effectiveFollowCountToday() ?? 0;
    final todayUnfollows = counterTarget?.effectiveUnfollowCountToday() ?? 0;
    final hasAnyToday = todayFollows > 0 || todayUnfollows > 0;
    final crossSitePrefix = resolvedCounter.isCrossSite && counterTarget != null
        ? '${counterTarget.badge} '
        : '';
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
              padding: const EdgeInsets.fromLTRB(4, 5, 2, 5),
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
                child: () {
                  final live = _currentJevLiveState(active);
                  final cat = _jev.category;
                  final shortCat =
                      cat.length > 6 ? '${cat.substring(0, 5)}…' : cat;
                  final activeOn = _jev.isActive;
                  final label = activeOn && live.active
                      ? '$shortCat ${live.matched}件'
                      : '分類:$shortCat';
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: activeOn
                          ? colorScheme.primaryContainer
                          : colorScheme.surface,
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(
                        color: activeOn
                            ? colorScheme.primary
                            : colorScheme.outlineVariant,
                      ),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight:
                            activeOn ? FontWeight.w700 : FontWeight.w600,
                        color: activeOn
                            ? colorScheme.onPrimaryContainer
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 5, 8, 5),
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
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  alignment: Alignment.center,
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
                        size: 13.5,
                        color: hasAnyToday
                            ? colorScheme.onTertiaryContainer
                            : colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        todayUnfollows > 0
                            ? '$crossSitePrefixフォロー $todayFollows / 解除 $todayUnfollows'
                            : '$crossSitePrefixフォロー $todayFollows',
                        style: TextStyle(
                          fontSize: 11,
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
                                      : active!.url);
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
                          'Android · v1.8.0',
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
                    onTap: () {
                      setState(() => _activeSubTabId.remove(active.instanceId));
                    },
                  ),
                  for (final sub in extras)
                    _buildSubTabPill(
                      label: sub.runtime.title.trim().isEmpty
                          ? '新しいタブ'
                          : sub.runtime.title,
                      selected: activeTid == sub.tabId,
                      onTap: () {
                        setState(
                          () => _activeSubTabId[active.instanceId] = sub.tabId,
                        );
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
              tooltip: '新しいタブを開く',
              onPressed: () =>
                  _openUrlInNewSubTab(active, active.url, activate: true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubTabPill({
    required String label,
    required bool selected,
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
