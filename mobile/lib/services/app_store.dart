import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/service_models.dart';

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
  static const _archivedInstancesKey = 'omnisns_archived_instances_v1';
  static const _settingsKey = 'omnisns_settings_v1';
  static const _followSyncSettingsKey = 'omnisns_follow_sync_settings_v1';
  static const _followSyncLedgerKey = 'omnisns_follow_sync_ledger_v1';

  static String _generateAndroidDeviceId() {
    final r = Random();
    final hex = List.generate(
      8,
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
        final list = jsonDecode(rawInstances) as List<dynamic>;
        final parsed = List.generate(
          list.length,
          (idx) => ServiceInstance.fromJson(
            list[idx] as Map<String, dynamic>,
            idx,
          ),
        )
            .where((i) => !_isRemovedService(i))
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));

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
        instances = createDefaultInstances(catalog);
        needsMigrationPersist = true;
      }
    } else {
      instances = createDefaultInstances(catalog);
    }

    final rawSettings = prefs.getString(_settingsKey);
    AppSettings settings;
    if (rawSettings != null && rawSettings.isNotEmpty) {
      try {
        settings = AppSettings.fromJson(
          jsonDecode(rawSettings) as Map<String, dynamic>,
        );
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
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final ordered = List.generate(
      instances.length,
      (idx) => instances[idx].copyWith(order: idx).toJson(),
    );
    await prefs.setString(_instancesKey, jsonEncode(ordered));
    await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
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

  Future<void> saveArchivedInstances(List<ArchivedInstance> archived) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = archived.take(100).map((e) => e.toJson()).toList();
    await prefs.setString(_archivedInstancesKey, jsonEncode(encoded));
  }

  Future<(FollowSyncSettings, FollowSyncLedger)> loadFollowSyncState() async {
    final prefs = await SharedPreferences.getInstance();
    FollowSyncSettings syncSettings = const FollowSyncSettings();
    final rawSync = prefs.getString(_followSyncSettingsKey);
    if (rawSync != null && rawSync.isNotEmpty) {
      try {
        syncSettings = FollowSyncSettings.fromJson(
          jsonDecode(rawSync) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    var needsSave = false;
    if (syncSettings.deviceId.trim().isEmpty) {
      syncSettings = syncSettings.copyWith(deviceId: _generateAndroidDeviceId());
      needsSave = true;
    }

    var ledger = FollowSyncLedger();
    final rawLedger = prefs.getString(_followSyncLedgerKey);
    if (rawLedger != null && rawLedger.isNotEmpty) {
      try {
        ledger = FollowSyncLedger.fromJson(
          jsonDecode(rawLedger) as Map<String, dynamic>,
        );
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
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _followSyncSettingsKey,
      jsonEncode(syncSettings.toJson()),
    );
    await prefs.setString(_followSyncLedgerKey, jsonEncode(ledger.toJson()));
  }
}
