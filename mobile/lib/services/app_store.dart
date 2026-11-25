import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/service_models.dart';
import 'omni_webview.dart';

class CatalogData {
  const CatalogData({
    required this.categories,
    required this.services,
  });

  final List<CategoryMeta> categories;
  final List<CatalogService> services;
}

class AppStore {
  static const _instancesKey = 'omnisns_instances_v1';
  static const _instancesBackupKey = 'omnisns_instances_v1_corrupt_backup';
  static const _archivedInstancesKey = 'omnisns_archived_instances_v1';
  static const _settingsKey = 'omnisns_settings_v1';
  static const _followSyncSettingsKey = 'omnisns_follow_sync_settings_v1';
  static const _followSyncLedgerKey = 'omnisns_follow_sync_ledger_v1';
  static const _followSyncTokenSecretKey = 'follow_sync_github_token_v1';

  Future<void> _writeQueue = Future<void>.value();

  Future<void> _enqueueWrite(Future<void> Function() action) {
    final next = _writeQueue.catchError((_) {}).then((_) => action());
    _writeQueue = next.catchError((_) {});
    return next;
  }

  static String _generateAndroidDeviceId() {
    Random r;
    try {
      r = Random.secure();
    } catch (_) {
      r = Random();
    }
    final hex = List.generate(
      12,
      (_) => r.nextInt(16).toRadixString(16),
    ).join();
    return 'and-$hex';
  }

  static const Set<String> _removedServiceIds = {
    'x',
    'pairs',
    'with',
    'tapple',
    'omiai',
    'marrish',
    'ange',
    'youbride',
    'bridalnet',
    'tokyo-calendar-date',
    'match',
    'grindr',
    'happymail',
    'wakuwaku',
    'pcmax',
    'ikukuru',
    'meetup',
  };

  static bool _isRemovedService(ServiceInstance inst) {
    if (_removedServiceIds.contains(inst.serviceId)) return true;
    for (final id in _removedServiceIds) {
      if (inst.instanceId == 'svc-$id-default') return true;
    }
    return false;
  }

  Future<CatalogData> loadCatalog() async {
    final raw = await rootBundle.loadString('assets/catalog.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    final categories = (decoded['categories'] as List<dynamic>? ?? const [])
        .map((e) => CategoryMeta.fromJson(e as Map<String, dynamic>))
        .toList();

    final services = (decoded['services'] as List<dynamic>? ?? const [])
        .map((e) => CatalogService.fromJson(e as Map<String, dynamic>))
        .toList();

    return CatalogData(categories: categories, services: services);
  }

  List<ServiceInstance> createDefaultInstances(List<CatalogService> catalog) {
    final pinned = catalog.where((s) => s.defaultPinned).toList();
    return List.generate(pinned.length, (idx) {
      final svc = pinned[idx];
      final instanceId = 'svc-${svc.id}-default';
      return ServiceInstance(
        instanceId: instanceId,
        serviceId: svc.id,
        name: svc.name,
        accountLabel: 'メイン',
        profileName: makeProfileNameForInstance(instanceId),
        category: svc.category,
        url: svc.url,
        colorHex: svc.colorHex,
        badge: svc.badge,
        notificationsEnabled: true,
        order: idx,
      );
    });
  }

  Future<(AppSettings, List<ServiceInstance>)> loadState(
    List<CatalogService> catalog,
  ) async {
    final prefs = await SharedPreferences.getInstance();

    final rawInstances = prefs.getString(_instancesKey);
    List<ServiceInstance> instances;
    var needsMigrationPersist = false;
    if (rawInstances != null && rawInstances.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawInstances);
        if (decoded is! List) {
          throw const FormatException('instances JSON is not a List');
        }
        final parsed = <ServiceInstance>[];
        var skippedCorrupt = false;
        for (var idx = 0; idx < decoded.length; idx++) {
          final item = decoded[idx];
          if (item is! Map) {
            skippedCorrupt = true;
            continue;
          }
          try {
            final inst = ServiceInstance.fromJson(
              Map<String, dynamic>.from(item),
              idx,
            );
            if (!_isRemovedService(inst)) {
              parsed.add(inst);
            }
          } catch (_) {
            skippedCorrupt = true;
          }
        }
        if (skippedCorrupt) {
          await prefs.setString(_instancesBackupKey, rawInstances);
        }
        parsed.sort((a, b) => a.order.compareTo(b.order));

        final migratedProfiles = assignProfilesForMigration(parsed);
        final migrated = migratedProfiles.map((inst) {
          if (inst.serviceId == 'threads') {
            final uri = Uri.tryParse(inst.url);
            if (uri != null &&
                (uri.host.toLowerCase() == 'www.threads.net' ||
                    uri.host.toLowerCase() == 'threads.net')) {
              return inst.copyWith(
                url: uri.replace(host: 'www.threads.com').toString(),
              );
            }
          }
          return inst;
        }).toList();
        for (var i = 0; i < migrated.length; i++) {
          if (migrated[i].profileName != parsed[i].profileName ||
              migrated[i].url != parsed[i].url) {
            needsMigrationPersist = true;
            break;
          }
        }
        instances = migrated;
      } catch (_) {
        // 破損JSONを退避し、ユーザー操作前に _instancesKey を黙って上書きしない
        await prefs.setString(_instancesBackupKey, rawInstances);
        instances = createDefaultInstances(catalog);
        needsMigrationPersist = false;
      }
    } else {
      instances = createDefaultInstances(catalog);
    }

    final rawSettings = prefs.getString(_settingsKey);
    AppSettings settings;
    if (rawSettings != null && rawSettings.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawSettings);
        settings = decoded is Map
            ? AppSettings.fromJson(Map<String, dynamic>.from(decoded))
            : const AppSettings();
      } catch (_) {
        settings = const AppSettings();
      }
    } else {
      settings = const AppSettings();
    }

    final hasValidActive = settings.activeInstanceId != null &&
        instances.any((i) => i.instanceId == settings.activeInstanceId);
    if (!hasValidActive) {
      settings = settings.copyWith(
        activeInstanceId:
            instances.isNotEmpty ? instances.first.instanceId : null,
        clearActive: instances.isEmpty,
      );
    }

    if (needsMigrationPersist) {
      await saveState(settings, instances);
    }

    return (settings, instances);
  }

  Future<void> saveState(
    AppSettings settings,
    List<ServiceInstance> instances,
  ) {
    final ordered = List.generate(
      instances.length,
      (idx) => instances[idx].copyWith(order: idx).toJson(),
    );
    final instancesJson = jsonEncode(ordered);
    final settingsJson = jsonEncode(settings.toJson());
    return _enqueueWrite(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_instancesKey, instancesJson);
      await prefs.setString(_settingsKey, settingsJson);
    });
  }

  Future<List<ArchivedInstance>> loadArchivedInstances(
    List<ServiceInstance> activeInstances,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_archivedInstancesKey);
    if (raw == null || raw.isEmpty) return [];
    final activeIds = activeInstances.map((i) => i.instanceId).toSet();
    final seen = <String>{};
    final result = <ArchivedInstance>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (var i = 0; i < list.length && result.length < 100; i++) {
        final item = list[i];
        if (item is! Map<String, dynamic>) continue;
        final parsed = ArchivedInstance.fromJson(item, i);
        if (parsed == null) continue;
        if (_isRemovedService(parsed.instance)) continue;
        if (activeIds.contains(parsed.instance.instanceId)) continue;
        if (!seen.add(parsed.instance.instanceId)) continue;
        result.add(parsed);
      }
    } catch (_) {
      return [];
    }
    return result;
  }

  Future<void> saveArchivedInstances(List<ArchivedInstance> archived) {
    final encoded = archived.take(100).map((e) => e.toJson()).toList();
    final encodedJson = jsonEncode(encoded);
    return _enqueueWrite(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_archivedInstancesKey, encodedJson);
    });
  }

  Future<(FollowSyncSettings, FollowSyncLedger)> loadFollowSyncState() async {
    final prefs = await SharedPreferences.getInstance();
    FollowSyncSettings syncSettings = const FollowSyncSettings();
    final rawSync = prefs.getString(_followSyncSettingsKey);
    if (rawSync != null && rawSync.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawSync);
        if (decoded is Map) {
          syncSettings = FollowSyncSettings.fromJson(
            Map<String, dynamic>.from(decoded),
          );
        }
      } catch (_) {}
    }
    var needsSave = false;
    if (syncSettings.deviceId.trim().isEmpty) {
      syncSettings = syncSettings.copyWith(deviceId: _generateAndroidDeviceId());
      needsSave = true;
    }

    // Android Keystore (AES-256-GCM) から PAT を復号して読み込む。
    // 旧バージョンの平文 PAT が SharedPreferences に残っている場合は Keystore へ移行して平文を消去する。
    final (secureSupported, secureToken) =
        await OmniWebViewManager.secureGetSecret(_followSyncTokenSecretKey);
    if (secureSupported) {
      final legacyPlaintextToken = syncSettings.githubToken.trim();
      final encryptedToken = (secureToken ?? '').trim();
      if (encryptedToken.isNotEmpty) {
        syncSettings = syncSettings.copyWith(githubToken: encryptedToken);
        if (legacyPlaintextToken.isNotEmpty) {
          // SharedPreferences 側の平文コピーを削除するため再保存
          needsSave = true;
        }
      } else if (legacyPlaintextToken.isNotEmpty) {
        final migrated = await OmniWebViewManager.secureSetSecret(
          _followSyncTokenSecretKey,
          legacyPlaintextToken,
        );
        if (migrated) {
          needsSave = true;
        }
      }
    }

    var ledger = FollowSyncLedger();
    final rawLedger = prefs.getString(_followSyncLedgerKey);
    if (rawLedger != null && rawLedger.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawLedger);
        if (decoded is Map) {
          ledger = FollowSyncLedger.fromJson(
            Map<String, dynamic>.from(decoded),
          );
        }
      } catch (_) {}
    }

    if (needsSave) {
      await saveFollowSyncState(syncSettings, ledger);
    }
    return (syncSettings, ledger);
  }

  Future<void> saveFollowSyncState(
    FollowSyncSettings syncSettings,
    FollowSyncLedger ledger,
  ) {
    final tokenToStore = syncSettings.githubToken.trim();
    final ledgerJson = jsonEncode(ledger.toJson());
    return _enqueueWrite(() async {
      final storedSecurely = await OmniWebViewManager.secureSetSecret(
        _followSyncTokenSecretKey,
        tokenToStore,
      );
      final persistedSettings = storedSecurely
          ? syncSettings.copyWith(githubToken: '')
          : syncSettings;
      final settingsJson = jsonEncode(persistedSettings.toJson());
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_followSyncSettingsKey, settingsJson);
      await prefs.setString(_followSyncLedgerKey, ledgerJson);
    });
  }
}
