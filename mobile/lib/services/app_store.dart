import 'dart:convert';
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
  static const _settingsKey = 'omnisns_settings_v1';

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
      return ServiceInstance(
        instanceId: 'svc-${svc.id}-default',
        serviceId: svc.id,
        name: svc.name,
        accountLabel: 'メイン',
        category: svc.category,
        url: svc.url,
        colorHex: svc.colorHex,
        badge: svc.badge,
        uaMode: svc.recommendedAndroidUa,
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
    if (rawInstances != null && rawInstances.isNotEmpty) {
      try {
        final list = jsonDecode(rawInstances) as List<dynamic>;
        instances = List.generate(
          list.length,
          (idx) => ServiceInstance.fromJson(
            list[idx] as Map<String, dynamic>,
            idx,
          ),
        )
            .where((i) => !_isRemovedService(i))
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
      } catch (_) {
        instances = createDefaultInstances(catalog);
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
        activeInstanceId: instances.isNotEmpty ? instances.first.instanceId : null,
        clearActive: instances.isEmpty,
      );
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
}
