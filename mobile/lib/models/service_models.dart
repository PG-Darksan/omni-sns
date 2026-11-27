import 'dart:ui';
import 'gesture_models.dart';

/// Android WebView の既定プロファイル名（AndroidX WebKit `Profile.DEFAULT_PROFILE_NAME` 準拠）
const String defaultWebViewProfileName = 'Default';

const int defaultFollowWindowHours = 24;
const int minFollowWindowHours = 1;
const int maxFollowWindowHours = 168;
const int maxEventRetentionSecs = 7 * 24 * 3600 + 3600;
const int maxEventsPerDevice = 4000;

List<int> pruneEventTimestamps(
  Iterable<int> events,
  int minExclusive,
  int retentionCutoff,
) {
  final out = <int>[
    for (final t in events)
      if (t > minExclusive && t >= retentionCutoff) t,
  ]..sort();
  if (out.length > maxEventsPerDevice) {
    return out.sublist(out.length - maxEventsPerDevice);
  }
  return out;
}

int countEventsInWindow(
  Iterable<int> events,
  int minExclusive,
  int cutoff,
) {
  var c = 0;
  for (final t in events) {
    if (t > minExclusive && t >= cutoff) c++;
  }
  return c;
}

void applyWindowDelta({
  required List<int> events,
  required List<int> deductions,
  required int resetAt,
  required int now,
  required int cutoff,
  required int curEffective,
  required int delta,
}) {
  final retentionCutoff = now > maxEventRetentionSecs
      ? now - maxEventRetentionSecs
      : 0;
  final prunedE = pruneEventTimestamps(events, resetAt, retentionCutoff);
  final prunedD = pruneEventTimestamps(deductions, resetAt, retentionCutoff);
  events
    ..clear()
    ..addAll(prunedE);
  deductions
    ..clear()
    ..addAll(prunedD);
  final eventTs = now > resetAt ? now : resetAt + 1;

  if (delta > 0) {
    final steps = delta > 1000 ? 1000 : delta;
    for (var i = 0; i < steps; i++) {
      final idx = deductions.lastIndexWhere((t) => t > resetAt && t >= cutoff);
      if (idx >= 0) {
        deductions.removeAt(idx);
      } else {
        events.add(eventTs);
      }
    }
  } else if (delta < 0) {
    final absDelta = -delta;
    final steps = absDelta < curEffective
        ? (absDelta > 1000 ? 1000 : absDelta)
        : (curEffective > 1000 ? 1000 : curEffective);
    for (var i = 0; i < steps; i++) {
      final idx = events.lastIndexWhere((t) => t > resetAt && t >= cutoff);
      if (idx >= 0) {
        events.removeAt(idx);
      } else {
        deductions.add(eventTs);
      }
    }
  }

  final nextE = pruneEventTimestamps(events, resetAt, retentionCutoff);
  final nextD = pruneEventTimestamps(deductions, resetAt, retentionCutoff);
  events
    ..clear()
    ..addAll(nextE);
  deductions
    ..clear()
    ..addAll(nextD);
}

List<int> _parseEventList(dynamic raw) {
  if (raw is! List) return <int>[];
  final out = <int>[];
  for (final item in raw) {
    final v = _clampNonNegInt(item, 0x7FFFFFFFFFFFFFFF);
    if (v != null && v > 0) out.add(v);
  }
  out.sort();
  if (out.length > maxEventsPerDevice) {
    return out.sublist(out.length - maxEventsPerDevice);
  }
  return out;
}

bool _intListEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<String> sanitizeCatalogOrder(Iterable<dynamic> raw) {
  final seen = <String>{};
  final out = <String>[];
  for (final item in raw) {
    if (item is! String) continue;
    final trimmed = item.trim();
    if (trimmed.isNotEmpty && seen.add(trimmed)) {
      out.add(trimmed);
    }
  }
  return out;
}

List<CatalogService> sortCatalogServices(
  List<CatalogService> catalog,
  List<String> catalogOrder,
) {
  if (catalogOrder.isEmpty) return List<CatalogService>.from(catalog);
  final rank = <String, int>{};
  for (var i = 0; i < catalogOrder.length; i++) {
    rank.putIfAbsent(catalogOrder[i], () => i);
  }
  final out = List<CatalogService>.from(catalog);
  out.sort((a, b) {
    final ra = rank[a.id];
    final rb = rank[b.id];
    if (ra != null && rb != null) return ra.compareTo(rb);
    if (ra != null) return -1;
    if (rb != null) return 1;
    return 0;
  });
  return out;
}

/// インスタンスIDごとに独立した Android WebView プロファイル名を生成する。
String makeProfileNameForInstance(String instanceId) {
  final cleaned = instanceId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
  final trimmed =
      cleaned.length > 48 ? cleaned.substring(0, 48) : cleaned;
  final body = trimmed.isEmpty ? 'account' : trimmed;
  return 'omnisns_$body';
}

class CategoryMeta {
  const CategoryMeta({
    required this.id,
    required this.label,
    required this.description,
  });

  final String id;
  final String label;
  final String description;

  factory CategoryMeta.fromJson(Map<String, dynamic> json) {
    return CategoryMeta(
      id: json['id'] as String? ?? 'custom',
      label: json['label'] as String? ?? '',
      description: json['description'] as String? ?? '',
    );
  }
}

class CatalogService {
  const CatalogService({
    required this.id,
    required this.name,
    required this.aliases,
    required this.category,
    required this.url,
    required this.homeUrl,
    required this.colorHex,
    required this.badge,
    required this.description,
    this.note,
    this.requiresCustomUrl = false,
    this.defaultPinned = false,
  });

  final String id;
  final String name;
  final List<String> aliases;
  final String category;
  final String url;
  final String homeUrl;
  final String colorHex;
  final String badge;
  final String description;
  final String? note;
  final bool requiresCustomUrl;
  final bool defaultPinned;

  factory CatalogService.fromJson(Map<String, dynamic> json) {
    final rawAliases = json['aliases'];
    return CatalogService(
      id: json['id'] as String? ?? 'custom',
      name: json['name'] as String? ?? 'SNS',
      aliases: rawAliases is List
          ? rawAliases.map((e) => e.toString()).toList()
          : const [],
      category: json['category'] as String? ?? 'custom',
      url: json['url'] as String? ?? 'https://example.com/',
      homeUrl: json['homeUrl'] as String? ?? 'https://example.com/',
      colorHex: json['color'] as String? ?? '#3B82F6',
      badge: json['badge'] as String? ?? 'SN',
      description: json['description'] as String? ?? '',
      note: json['note'] as String?,
      requiresCustomUrl: json['requiresCustomUrl'] as bool? ?? false,
      defaultPinned: json['defaultPinned'] as bool? ?? false,
    );
  }
}

/// ローカル日付を `YYYY-MM-DD` 形式で返す（フォロー回数日次リセット判定用）。
String formatLocalYmd(DateTime dt) {
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// `YYYY-MM-DD` 形式の妥当なカレンダー日付かを検証する。
bool isValidYmd(String s) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return false;
  final y = int.tryParse(s.substring(0, 4));
  final m = int.tryParse(s.substring(5, 7));
  final d = int.tryParse(s.substring(8, 10));
  if (y == null || m == null || d == null) return false;
  if (y < 2020 || y > 2100 || m < 1 || m > 12 || d < 1) return false;
  final dt = DateTime(y, m, d);
  return dt.year == y && dt.month == m && dt.day == d;
}

/// 妥当な `YYYY-MM-DD` の翌日を返す（タイムゾーン差 +1日許容の上限算出用）。
String nextYmd(String ymd) {
  if (!isValidYmd(ymd)) return ymd;
  final y = int.parse(ymd.substring(0, 4));
  final m = int.parse(ymd.substring(5, 7));
  final d = int.parse(ymd.substring(8, 10));
  return formatLocalYmd(DateTime(y, m, d + 1));
}

String? _asNonEmptyString(dynamic v) {
  if (v is! String) return null;
  final t = v.trim();
  return t.isEmpty ? null : t;
}

int? _clampNonNegInt(dynamic v, [int maxVal = 0xFFFFFFFF]) {
  if (v is! num || !v.isFinite) return null;
  final i = v.toInt();
  if (i < 0) return null;
  return i > maxVal ? maxVal : i;
}

int? _clampSignedInt(dynamic v, int minVal, int maxVal) {
  if (v is! num || !v.isFinite) return null;
  final i = v.toInt();
  if (i < minVal) return minVal;
  if (i > maxVal) return maxVal;
  return i;
}

class ServiceInstance {
  const ServiceInstance({
    required this.instanceId,
    required this.serviceId,
    required this.name,
    this.accountLabel,
    this.profileName,
    required this.category,
    required this.url,
    required this.colorHex,
    required this.badge,
    required this.notificationsEnabled,
    required this.order,
    this.uaMode = 'mobile',
    this.followCountToday = 0,
    this.followCountTotal = 0,
    this.unfollowCountToday = 0,
    this.unfollowCountTotal = 0,
    this.followCountDate,
    this.followEvents = const [],
    this.unfollowEvents = const [],
    this.detectedHandle,
    this.snsFollowingCount,
    this.snsFollowersCount,
  });

  final String instanceId;
  final String serviceId;
  final String name;
  final String? accountLabel;
  final String? profileName;
  final String category;
  final String url;
  final String colorHex;
  final String badge;
  final bool notificationsEnabled;
  final int order;
  final String uaMode;
  final int followCountToday;

  bool get isDesktopUa => uaMode == 'desktop';
  final int followCountTotal;
  final int unfollowCountToday;
  final int unfollowCountTotal;
  final String? followCountDate;
  final List<int> followEvents;
  final List<int> unfollowEvents;
  final String? detectedHandle;
  final int? snsFollowingCount;
  final int? snsFollowersCount;

  /// 実際に Android WebView に適用するプロファイル名を返す。
  String get effectiveProfileName {
    final p = profileName?.trim();
    if (p != null && p.isNotEmpty) return p;
    return makeProfileNameForInstance(instanceId);
  }

  /// 本日分の有効なフォロー回数（日付が変わっていれば自動で 0）。
  int effectiveFollowCountToday([DateTime? now]) {
    final today = formatLocalYmd(now ?? DateTime.now());
    return followCountDate == today ? followCountToday : 0;
  }

  /// 本日分の有効なアンフォロー回数（日付が変わっていれば自動で 0）。
  int effectiveUnfollowCountToday([DateTime? now]) {
    final today = formatLocalYmd(now ?? DateTime.now());
    return followCountDate == today ? unfollowCountToday : 0;
  }

  /// 指定時間内（直近 `windowHours` 時間）の有効なフォロー回数。
  /// 同期レジャー投影済み（`followEvents` が空で `detectedHandle` がある）場合は投影値を返す。
  int effectiveFollowCountInWindow(int windowHours, [DateTime? now]) {
    if (followEvents.isNotEmpty) {
      final h = windowHours.clamp(minFollowWindowHours, maxFollowWindowHours);
      final nowSecs = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
      final cutoff = nowSecs > h * 3600 ? nowSecs - h * 3600 : 0;
      return countEventsInWindow(followEvents, 0, cutoff);
    }
    return followCountToday;
  }

  /// 指定時間内（直近 `windowHours` 時間）の有効なアンフォロー（解除）回数。
  int effectiveUnfollowCountInWindow(int windowHours, [DateTime? now]) {
    if (unfollowEvents.isNotEmpty) {
      final h = windowHours.clamp(minFollowWindowHours, maxFollowWindowHours);
      final nowSecs = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
      final cutoff = nowSecs > h * 3600 ? nowSecs - h * 3600 : 0;
      return countEventsInWindow(unfollowEvents, 0, cutoff);
    }
    return unfollowCountToday;
  }

  /// 指定時間ウィンドウ方式でフォロー回数を delta (+1 / -1) 増減した新しいインスタンスを返す。
  ServiceInstance withFollowWindowDelta(
    int delta, {
    required int windowHours,
    DateTime? now,
  }) {
    final dt = now ?? DateTime.now();
    final today = formatLocalYmd(dt);
    final nowSecs = dt.millisecondsSinceEpoch ~/ 1000;
    final h = windowHours.clamp(minFollowWindowHours, maxFollowWindowHours);
    final cutoff = nowSecs > h * 3600 ? nowSecs - h * 3600 : 0;
    final retentionCutoff =
        nowSecs > maxEventRetentionSecs ? nowSecs - maxEventRetentionSecs : 0;
    final nextEvents =
        pruneEventTimestamps(followEvents, 0, retentionCutoff);
    if (delta > 0) {
      final steps = delta > 1000 ? 1000 : delta;
      for (var i = 0; i < steps; i++) {
        nextEvents.add(nowSecs);
      }
    } else if (delta < 0) {
      final steps = (-delta) > 1000 ? 1000 : -delta;
      for (var i = 0; i < steps; i++) {
        final pos = nextEvents.lastIndexWhere((t) => t >= cutoff);
        if (pos >= 0) {
          nextEvents.removeAt(pos);
        } else {
          break;
        }
      }
    }
    final finalEvents =
        pruneEventTimestamps(nextEvents, 0, retentionCutoff);
    final nextCount = countEventsInWindow(finalEvents, 0, cutoff);
    final nextUfCount = countEventsInWindow(unfollowEvents, 0, cutoff);
    return copyWith(
      followCountToday: nextCount,
      followCountTotal: nextCount,
      unfollowCountToday: nextUfCount,
      unfollowCountTotal: nextUfCount,
      followCountDate: today,
      followEvents: finalEvents,
    );
  }

  /// 指定時間ウィンドウ方式でフォロー回数をリセットした新しいインスタンスを返す。
  ServiceInstance withFollowWindowReset({
    required int windowHours,
    DateTime? now,
  }) {
    final dt = now ?? DateTime.now();
    final today = formatLocalYmd(dt);
    final nowSecs = dt.millisecondsSinceEpoch ~/ 1000;
    final h = windowHours.clamp(minFollowWindowHours, maxFollowWindowHours);
    final cutoff = nowSecs > h * 3600 ? nowSecs - h * 3600 : 0;
    final nextUfCount = countEventsInWindow(unfollowEvents, 0, cutoff);
    return copyWith(
      followCountToday: 0,
      followCountTotal: 0,
      unfollowCountToday: nextUfCount,
      unfollowCountTotal: nextUfCount,
      followCountDate: today,
      followEvents: const [],
    );
  }

  /// 指定時間ウィンドウ方式でアンフォロー回数を delta (+1 / -1) 増減した新しいインスタンスを返す。
  ServiceInstance withUnfollowWindowDelta(
    int delta, {
    required int windowHours,
    DateTime? now,
  }) {
    final dt = now ?? DateTime.now();
    final today = formatLocalYmd(dt);
    final nowSecs = dt.millisecondsSinceEpoch ~/ 1000;
    final h = windowHours.clamp(minFollowWindowHours, maxFollowWindowHours);
    final cutoff = nowSecs > h * 3600 ? nowSecs - h * 3600 : 0;
    final retentionCutoff =
        nowSecs > maxEventRetentionSecs ? nowSecs - maxEventRetentionSecs : 0;
    final nextEvents =
        pruneEventTimestamps(unfollowEvents, 0, retentionCutoff);
    if (delta > 0) {
      final steps = delta > 1000 ? 1000 : delta;
      for (var i = 0; i < steps; i++) {
        nextEvents.add(nowSecs);
      }
    } else if (delta < 0) {
      final steps = (-delta) > 1000 ? 1000 : -delta;
      for (var i = 0; i < steps; i++) {
        final pos = nextEvents.lastIndexWhere((t) => t >= cutoff);
        if (pos >= 0) {
          nextEvents.removeAt(pos);
        } else {
          break;
        }
      }
    }
    final finalEvents =
        pruneEventTimestamps(nextEvents, 0, retentionCutoff);
    final nextFCount = countEventsInWindow(followEvents, 0, cutoff);
    final nextUfCount = countEventsInWindow(finalEvents, 0, cutoff);
    return copyWith(
      followCountToday: nextFCount,
      followCountTotal: nextFCount,
      unfollowCountToday: nextUfCount,
      unfollowCountTotal: nextUfCount,
      followCountDate: today,
      unfollowEvents: finalEvents,
    );
  }

  /// 指定時間ウィンドウ方式でアンフォロー回数をリセットした新しいインスタンスを返す。
  ServiceInstance withUnfollowWindowReset({
    required int windowHours,
    DateTime? now,
  }) {
    final dt = now ?? DateTime.now();
    final today = formatLocalYmd(dt);
    final nowSecs = dt.millisecondsSinceEpoch ~/ 1000;
    final h = windowHours.clamp(minFollowWindowHours, maxFollowWindowHours);
    final cutoff = nowSecs > h * 3600 ? nowSecs - h * 3600 : 0;
    final nextFCount = countEventsInWindow(followEvents, 0, cutoff);
    return copyWith(
      followCountToday: nextFCount,
      followCountTotal: nextFCount,
      unfollowCountToday: 0,
      unfollowCountTotal: 0,
      followCountDate: today,
      unfollowEvents: const [],
    );
  }

  /// フォロー回数を delta (+1 / -1) 増減した新しいインスタンスを返す。
  ServiceInstance withFollowDelta(int delta, [DateTime? now]) {
    final today = formatLocalYmd(now ?? DateTime.now());
    final sameDay = followCountDate == today;
    final baseToday = sameDay ? followCountToday : 0;
    final nextToday = (baseToday + delta).clamp(0, 999999);
    final nextTotal = (followCountTotal + delta).clamp(0, 99999999);
    return copyWith(
      followCountToday: nextToday,
      followCountTotal: nextTotal,
      unfollowCountToday: sameDay ? unfollowCountToday : 0,
      followCountDate: today,
    );
  }

  /// フォロー回数をリセットした新しいインスタンスを返す。
  ServiceInstance withFollowReset({required bool resetTotal, DateTime? now}) {
    final today = formatLocalYmd(now ?? DateTime.now());
    final sameDay = followCountDate == today;
    return copyWith(
      followCountToday: 0,
      followCountTotal: resetTotal ? 0 : followCountTotal,
      unfollowCountToday: sameDay ? unfollowCountToday : 0,
      followCountDate: today,
    );
  }

  /// アンフォロー回数を delta (+1 / -1) 増減した新しいインスタンスを返す。
  ServiceInstance withUnfollowDelta(int delta, [DateTime? now]) {
    final today = formatLocalYmd(now ?? DateTime.now());
    final sameDay = followCountDate == today;
    final baseToday = sameDay ? unfollowCountToday : 0;
    final nextToday = (baseToday + delta).clamp(0, 999999);
    final nextTotal = (unfollowCountTotal + delta).clamp(0, 99999999);
    return copyWith(
      followCountToday: sameDay ? followCountToday : 0,
      unfollowCountToday: nextToday,
      unfollowCountTotal: nextTotal,
      followCountDate: today,
    );
  }

  /// アンフォロー回数をリセットした新しいインスタンスを返す。
  ServiceInstance withUnfollowReset({required bool resetTotal, DateTime? now}) {
    final today = formatLocalYmd(now ?? DateTime.now());
    final sameDay = followCountDate == today;
    return copyWith(
      followCountToday: sameDay ? followCountToday : 0,
      unfollowCountToday: 0,
      unfollowCountTotal: resetTotal ? 0 : unfollowCountTotal,
      followCountDate: today,
    );
  }

  ServiceInstance copyWith({
    String? name,
    String? accountLabel,
    bool clearAccountLabel = false,
    String? profileName,
    String? url,
    String? colorHex,
    String? badge,
    bool? notificationsEnabled,
    int? order,
    String? uaMode,
    int? followCountToday,
    int? followCountTotal,
    int? unfollowCountToday,
    int? unfollowCountTotal,
    String? followCountDate,
    List<int>? followEvents,
    List<int>? unfollowEvents,
    String? detectedHandle,
    bool clearDetectedHandle = false,
    int? snsFollowingCount,
    int? snsFollowersCount,
    bool clearSnsStats = false,
  }) {
    return ServiceInstance(
      instanceId: instanceId,
      serviceId: serviceId,
      name: name ?? this.name,
      accountLabel:
          clearAccountLabel ? null : (accountLabel ?? this.accountLabel),
      profileName: profileName ?? this.profileName,
      category: category,
      url: url ?? this.url,
      colorHex: colorHex ?? this.colorHex,
      badge: badge ?? this.badge,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      order: order ?? this.order,
      uaMode: uaMode ?? this.uaMode,
      followCountToday: followCountToday ?? this.followCountToday,
      followCountTotal: followCountTotal ?? this.followCountTotal,
      unfollowCountToday: unfollowCountToday ?? this.unfollowCountToday,
      unfollowCountTotal: unfollowCountTotal ?? this.unfollowCountTotal,
      followCountDate: followCountDate ?? this.followCountDate,
      followEvents: followEvents ?? this.followEvents,
      unfollowEvents: unfollowEvents ?? this.unfollowEvents,
      detectedHandle: clearDetectedHandle
          ? null
          : (detectedHandle ?? this.detectedHandle),
      snsFollowingCount:
          clearSnsStats ? null : (snsFollowingCount ?? this.snsFollowingCount),
      snsFollowersCount:
          clearSnsStats ? null : (snsFollowersCount ?? this.snsFollowersCount),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'instanceId': instanceId,
      'serviceId': serviceId,
      'name': name,
      if (accountLabel != null && accountLabel!.trim().isNotEmpty)
        'accountLabel': accountLabel!.trim(),
      'profileName': effectiveProfileName,
      'category': category,
      'url': url,
      'colorHex': colorHex,
      'badge': badge,
      'notificationsEnabled': notificationsEnabled,
      'order': order,
      if (uaMode == 'desktop') 'uaMode': 'desktop',
      'followCountToday': followCountToday,
      'followCountTotal': followCountTotal,
      'unfollowCountToday': unfollowCountToday,
      'unfollowCountTotal': unfollowCountTotal,
      if (followCountDate != null && followCountDate!.isNotEmpty)
        'followCountDate': followCountDate,
      if (followEvents.isNotEmpty) 'followEvents': followEvents,
      if (unfollowEvents.isNotEmpty) 'unfollowEvents': unfollowEvents,
      if (detectedHandle != null && detectedHandle!.trim().isNotEmpty)
        'detectedHandle': detectedHandle!.trim(),
      if (snsFollowingCount != null) 'snsFollowingCount': snsFollowingCount,
      if (snsFollowersCount != null) 'snsFollowersCount': snsFollowersCount,
    };
  }

  factory ServiceInstance.fromJson(Map<String, dynamic> json, int index) {
    final safeName = _asNonEmptyString(json['name']) ?? 'SNS';
    final rawLabel = _asNonEmptyString(json['accountLabel']);
    final rawProfile = _asNonEmptyString(json['profileName']);
    final rawFollowDate = _asNonEmptyString(json['followCountDate']);
    final validDate =
        (rawFollowDate != null && isValidYmd(rawFollowDate))
            ? rawFollowDate
            : null;
    final rawHandle = normalizeAccountHandle(
      json['detectedHandle'] is String ? json['detectedHandle'] as String : null,
    );
    final rawUrl = json['url'] is String ? json['url'] as String : '';
    final rawNotif = json['notificationsEnabled'];
    final today = formatLocalYmd(DateTime.now());
    final nowSecs = nowUnixSecs();
    final retentionCutoff =
        nowSecs > maxEventRetentionSecs ? nowSecs - maxEventRetentionSecs : 0;
    final rawFollowToday = _clampNonNegInt(json['followCountToday'], 999999) ?? 0;
    final rawUnfollowToday =
        _clampNonNegInt(json['unfollowCountToday'], 999999) ?? 0;
    var parsedFollowEvents = _parseEventList(json['followEvents']);
    var parsedUnfollowEvents = _parseEventList(json['unfollowEvents']);
    if (parsedFollowEvents.isEmpty &&
        !json.containsKey('followEvents') &&
        validDate == today &&
        rawFollowToday > 0) {
      parsedFollowEvents = List<int>.filled(
        rawFollowToday > 1000 ? 1000 : rawFollowToday,
        nowSecs,
      );
    }
    if (parsedUnfollowEvents.isEmpty &&
        !json.containsKey('unfollowEvents') &&
        validDate == today &&
        rawUnfollowToday > 0) {
      parsedUnfollowEvents = List<int>.filled(
        rawUnfollowToday > 1000 ? 1000 : rawUnfollowToday,
        nowSecs,
      );
    }
    parsedFollowEvents =
        pruneEventTimestamps(parsedFollowEvents, 0, retentionCutoff);
    parsedUnfollowEvents =
        pruneEventTimestamps(parsedUnfollowEvents, 0, retentionCutoff);
    return ServiceInstance(
      instanceId: _asNonEmptyString(json['instanceId']) ?? 'svc-$index',
      serviceId: _asNonEmptyString(json['serviceId']) ?? 'custom',
      name: safeName,
      accountLabel: rawLabel,
      profileName: rawProfile,
      category: _asNonEmptyString(json['category']) ?? 'custom',
      url: normalizeServiceUrl(rawUrl) ?? 'https://example.com/',
      colorHex: _asNonEmptyString(json['colorHex']) ?? '#3B82F6',
      badge: _asNonEmptyString(json['badge']) ?? makeBadgeText(safeName),
      notificationsEnabled: rawNotif is bool ? rawNotif : true,
      order: (json['order'] as num?)?.toInt() ?? index,
      uaMode: json['uaMode'] == 'desktop' ? 'desktop' : 'mobile',
      followCountToday: rawFollowToday,
      followCountTotal:
          _clampNonNegInt(json['followCountTotal'], 99999999) ?? 0,
      unfollowCountToday: rawUnfollowToday,
      unfollowCountTotal:
          _clampNonNegInt(json['unfollowCountTotal'], 99999999) ?? 0,
      followCountDate: validDate,
      followEvents: parsedFollowEvents,
      unfollowEvents: parsedUnfollowEvents,
      detectedHandle: rawHandle,
      snsFollowingCount: _clampNonNegInt(json['snsFollowingCount']),
      snsFollowersCount: _clampNonNegInt(json['snsFollowersCount']),
    );
  }
}

/// タブ削除後もログイン記憶（WebView Multi-Profile）を保持するための退避モデル
class ArchivedInstance {
  const ArchivedInstance({
    required this.instance,
    required this.archivedAt,
  });

  final ServiceInstance instance;
  final int archivedAt;

  Map<String, dynamic> toJson() {
    return {
      'instance': instance.toJson(),
      'archivedAt': archivedAt,
    };
  }

  static ArchivedInstance? fromJson(Map<String, dynamic> json, int index) {
    final rawInst = json['instance'];
    if (rawInst is! Map<String, dynamic>) return null;
    final inst = ServiceInstance.fromJson(rawInst, index);
    final ts = (json['archivedAt'] as num?)?.toInt() ??
        (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    return ArchivedInstance(instance: inst, archivedAt: ts);
  }
}

/// アカウント条件フィルタ設定（フォロー数・フォロワー数・フォロー多め絞り込み）。
class AccountFilterSettings {
  const AccountFilterSettings({
    this.enabled = false,
    this.minFollowing,
    this.maxFollowing,
    this.minFollowers,
    this.maxFollowers,
    this.followingGreaterThanFollowers = false,
  });

  static const int maxBound = 1000000000;

  final bool enabled;
  final int? minFollowing;
  final int? maxFollowing;
  final int? minFollowers;
  final int? maxFollowers;
  final bool followingGreaterThanFollowers;

  bool get hasAnyCondition =>
      minFollowing != null ||
      maxFollowing != null ||
      minFollowers != null ||
      maxFollowers != null ||
      followingGreaterThanFollowers;

  bool get isActive => enabled && hasAnyCondition;

  AccountFilterSettings sanitized() {
    var minF = minFollowing?.clamp(0, maxBound);
    var maxF = maxFollowing?.clamp(0, maxBound);
    if (minF != null && maxF != null && minF > maxF) {
      final t = minF;
      minF = maxF;
      maxF = t;
    }
    var minFw = minFollowers?.clamp(0, maxBound);
    var maxFw = maxFollowers?.clamp(0, maxBound);
    if (minFw != null && maxFw != null && minFw > maxFw) {
      final t = minFw;
      minFw = maxFw;
      maxFw = t;
    }
    final hasAny = minF != null ||
        maxF != null ||
        minFw != null ||
        maxFw != null ||
        followingGreaterThanFollowers;
    return AccountFilterSettings(
      enabled: enabled && hasAny,
      minFollowing: minF,
      maxFollowing: maxF,
      minFollowers: minFw,
      maxFollowers: maxFw,
      followingGreaterThanFollowers: followingGreaterThanFollowers,
    );
  }

  String get summaryLabel {
    final parts = <String>[];
    if (minFollowing != null && maxFollowing != null) {
      parts.add('F $minFollowing〜$maxFollowing');
    } else if (minFollowing != null) {
      parts.add('F $minFollowing以上');
    } else if (maxFollowing != null) {
      parts.add('F $maxFollowing以下');
    }
    if (minFollowers != null && maxFollowers != null) {
      parts.add('FW $minFollowers〜$maxFollowers');
    } else if (minFollowers != null) {
      parts.add('FW $minFollowers以上');
    } else if (maxFollowers != null) {
      parts.add('FW $maxFollowers以下');
    }
    if (followingGreaterThanFollowers) {
      parts.add('F>FW');
    }
    return parts.join(' · ');
  }

  AccountFilterSettings copyWith({
    bool? enabled,
    int? minFollowing,
    bool clearMinFollowing = false,
    int? maxFollowing,
    bool clearMaxFollowing = false,
    int? minFollowers,
    bool clearMinFollowers = false,
    int? maxFollowers,
    bool clearMaxFollowers = false,
    bool? followingGreaterThanFollowers,
  }) {
    return AccountFilterSettings(
      enabled: enabled ?? this.enabled,
      minFollowing:
          clearMinFollowing ? null : (minFollowing ?? this.minFollowing),
      maxFollowing:
          clearMaxFollowing ? null : (maxFollowing ?? this.maxFollowing),
      minFollowers:
          clearMinFollowers ? null : (minFollowers ?? this.minFollowers),
      maxFollowers:
          clearMaxFollowers ? null : (maxFollowers ?? this.maxFollowers),
      followingGreaterThanFollowers:
          followingGreaterThanFollowers ?? this.followingGreaterThanFollowers,
    );
  }

  Map<String, dynamic> toJsConfig() {
    final s = sanitized();
    return {
      'enabled': s.isActive,
      'minFollowing': s.minFollowing,
      'maxFollowing': s.maxFollowing,
      'minFollowers': s.minFollowers,
      'maxFollowers': s.maxFollowers,
      'followingGreaterThanFollowers': s.followingGreaterThanFollowers,
    };
  }

  Map<String, dynamic> toJson() {
    final s = sanitized();
    return {
      'enabled': s.enabled,
      if (s.minFollowing != null) 'minFollowing': s.minFollowing,
      if (s.maxFollowing != null) 'maxFollowing': s.maxFollowing,
      if (s.minFollowers != null) 'minFollowers': s.minFollowers,
      if (s.maxFollowers != null) 'maxFollowers': s.maxFollowers,
      'followingGreaterThanFollowers': s.followingGreaterThanFollowers,
    };
  }

  factory AccountFilterSettings.fromJson(Map<String, dynamic> json) {
    return AccountFilterSettings(
      enabled: json['enabled'] as bool? ?? false,
      minFollowing: _clampNonNegInt(json['minFollowing'], maxBound),
      maxFollowing: _clampNonNegInt(json['maxFollowing'], maxBound),
      minFollowers: _clampNonNegInt(json['minFollowers'], maxBound),
      maxFollowers: _clampNonNegInt(json['maxFollowers'], maxBound),
      followingGreaterThanFollowers:
          json['followingGreaterThanFollowers'] as bool? ?? false,
    ).sanitized();
  }
}

class AppSettings {
  const AppSettings({
    this.isDarkMode = true,
    this.activeInstanceId,
    this.isBottomTabsCollapsed = false,
    this.isHeaderCollapsed = false,
    this.headerAccountScope = 'all',
    this.followWindowHours = defaultFollowWindowHours,
    this.catalogOrder = const [],
    this.gesture = const MobileGestureSettings(),
    this.accountFilter = const AccountFilterSettings(),
  });

  final bool isDarkMode;
  final String? activeInstanceId;
  final bool isBottomTabsCollapsed;
  final bool isHeaderCollapsed;
  /// ヘッダーのアカウント切替バーの表示範囲: 'all'（全SNS横断）または 'service'（現在SNSのみ）
  final String headerAccountScope;
  final int followWindowHours;
  final List<String> catalogOrder;
  final MobileGestureSettings gesture;
  final AccountFilterSettings accountFilter;

  bool get isHeaderAllAccounts => headerAccountScope != 'service';

  AppSettings copyWith({
    bool? isDarkMode,
    String? activeInstanceId,
    bool clearActive = false,
    bool? isBottomTabsCollapsed,
    bool? isHeaderCollapsed,
    String? headerAccountScope,
    int? followWindowHours,
    List<String>? catalogOrder,
    MobileGestureSettings? gesture,
    AccountFilterSettings? accountFilter,
  }) {
    final nextScope = headerAccountScope ?? this.headerAccountScope;
    final safeScope = nextScope == 'service' ? 'service' : 'all';
    return AppSettings(
      isDarkMode: isDarkMode ?? this.isDarkMode,
      activeInstanceId:
          clearActive ? null : (activeInstanceId ?? this.activeInstanceId),
      isBottomTabsCollapsed:
          isBottomTabsCollapsed ?? this.isBottomTabsCollapsed,
      isHeaderCollapsed: isHeaderCollapsed ?? this.isHeaderCollapsed,
      headerAccountScope: safeScope,
      followWindowHours: (followWindowHours ?? this.followWindowHours)
          .clamp(minFollowWindowHours, maxFollowWindowHours),
      catalogOrder: catalogOrder ?? this.catalogOrder,
      gesture: gesture ?? this.gesture,
      accountFilter: (accountFilter ?? this.accountFilter).sanitized(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'isDarkMode': isDarkMode,
      'activeInstanceId': activeInstanceId,
      'isBottomTabsCollapsed': isBottomTabsCollapsed,
      'isHeaderCollapsed': isHeaderCollapsed,
      'headerAccountScope': headerAccountScope,
      'followWindowHours': followWindowHours,
      if (catalogOrder.isNotEmpty) 'catalogOrder': catalogOrder,
      'gesture': gesture.toJson(),
      'accountFilter': accountFilter.toJson(),
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final rawGesture = json['gesture'];
    final rawAccountFilter = json['accountFilter'];
    final rawHours = (json['followWindowHours'] as num?)?.toInt();
    final rawCatalogOrder = json['catalogOrder'];
    final rawScope = (json['headerAccountScope'] as String?)?.trim();
    return AppSettings(
      isDarkMode: json['isDarkMode'] as bool? ?? true,
      activeInstanceId: json['activeInstanceId'] as String?,
      isBottomTabsCollapsed: json['isBottomTabsCollapsed'] as bool? ?? false,
      isHeaderCollapsed: json['isHeaderCollapsed'] as bool? ?? false,
      headerAccountScope: rawScope == 'service' ? 'service' : 'all',
      followWindowHours: (rawHours ?? defaultFollowWindowHours)
          .clamp(minFollowWindowHours, maxFollowWindowHours),
      catalogOrder: rawCatalogOrder is List
          ? sanitizeCatalogOrder(rawCatalogOrder)
          : const [],
      gesture: rawGesture is Map<String, dynamic>
          ? MobileGestureSettings.fromJson(rawGesture)
          : const MobileGestureSettings(),
      accountFilter: rawAccountFilter is Map<String, dynamic>
          ? AccountFilterSettings.fromJson(rawAccountFilter)
          : const AccountFilterSettings(),
    );
  }
}

class TabRuntimeState {
  const TabRuntimeState({
    required this.currentUrl,
    required this.title,
    this.progress = 0,
    this.unreadCount = 0,
    this.isLoading = false,
    this.isSleeping = true,
    this.canGoBack = false,
    this.canGoForward = false,
    this.loadError,
  });

  final String currentUrl;
  final String title;
  final int progress;
  final int unreadCount;
  final bool isLoading;
  final bool isSleeping;
  final bool canGoBack;
  final bool canGoForward;
  final String? loadError;

  TabRuntimeState copyWith({
    String? currentUrl,
    String? title,
    int? progress,
    int? unreadCount,
    bool? isLoading,
    bool? isSleeping,
    bool? canGoBack,
    bool? canGoForward,
    String? loadError,
    bool clearError = false,
  }) {
    return TabRuntimeState(
      currentUrl: currentUrl ?? this.currentUrl,
      title: title ?? this.title,
      progress: progress ?? this.progress,
      unreadCount: unreadCount ?? this.unreadCount,
      isLoading: isLoading ?? this.isLoading,
      isSleeping: isSleeping ?? this.isSleeping,
      canGoBack: canGoBack ?? this.canGoBack,
      canGoForward: canGoForward ?? this.canGoForward,
      loadError: clearError ? null : (loadError ?? this.loadError),
    );
  }

  /// UI 上の見た目が同一かどうか（同一なら setState を省略して再ビルドを減らす）。
  ///
  /// 進捗バーはアクティブタブにしか表示されないため、非表示タブでは
  /// [includeProgress] を false にして progress だけの変化を無視できる。
  bool sameVisualState(TabRuntimeState other, {bool includeProgress = true}) {
    return currentUrl == other.currentUrl &&
        title == other.title &&
        (!includeProgress || progress == other.progress) &&
        unreadCount == other.unreadCount &&
        isLoading == other.isLoading &&
        isSleeping == other.isSleeping &&
        canGoBack == other.canGoBack &&
        canGoForward == other.canGoForward &&
        loadError == other.loadError;
  }
}

/// WebViewの `; wv)` トークンを除いたクリーンなスマホ版 Android Chrome UA を返す。
String buildMobileUserAgent() {
  return 'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/136.0.0.0 Mobile Safari/537.36';
}

/// スマホ上で PC 版サイトを表示するためのデスクトップ Chrome UA を返す。
String buildDesktopUserAgent() {
  return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/136.0.0.0 Safari/537.36';
}

String buildUserAgentForMode(String uaMode) {
  return uaMode == 'desktop' ? buildDesktopUserAgent() : buildMobileUserAgent();
}

/// 安全な http / https URL（ホスト名あり）かを判定する。
bool isHttpOrHttpsUrl(String? rawUrl) {
  final trimmed = rawUrl?.trim();
  if (trimmed == null || trimmed.isEmpty) return false;
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null) return false;
  return (parsed.scheme == 'http' || parsed.scheme == 'https') &&
      parsed.host.isNotEmpty;
}

/// URL入力を検証し、安全な http/https URL に正規化する
String? normalizeServiceUrl(String rawInput) {
  final trimmed = rawInput.trim();
  if (trimmed.isEmpty) return null;

  final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z\d+\-.]*://').hasMatch(trimmed);
  final candidate = hasScheme ? trimmed : 'https://$trimmed';

  final parsed = Uri.tryParse(candidate);
  if (parsed == null) return null;
  if (parsed.scheme != 'https' && parsed.scheme != 'http') return null;
  if (parsed.host.isEmpty) return null;
  return parsed.toString();
}

/// ページタイトルから未読件数を抽出する
int parseUnreadCountFromTitle(String title) {
  if (title.isEmpty) return 0;

  final startMatch =
      RegExp(r'^\s*[(\[]\s*(\d+)\+?\s*[)\]]').firstMatch(title);
  if (startMatch != null) {
    final n = int.tryParse(startMatch.group(1) ?? '') ?? 0;
    return n.clamp(0, 999);
  }

  final inlineMatch = RegExp(r'[(\[](\d{1,3})\+?[)\]]').firstMatch(title);
  if (inlineMatch != null) {
    final n = int.tryParse(inlineMatch.group(1) ?? '') ?? 0;
    return n.clamp(0, 999);
  }

  if (RegExp(r'^\s*[•●🔴]').hasMatch(title)) {
    return 1;
  }

  return 0;
}

String makeBadgeText(String name) {
  final cleaned = name.trim();
  if (cleaned.isEmpty) return 'SN';

  final asciiWords = RegExp(r'[A-Za-z0-9]+')
      .allMatches(cleaned)
      .map((m) => m.group(0)!)
      .toList();
  if (asciiWords.length >= 2) {
    return '${asciiWords[0][0]}${asciiWords[1][0]}'.toUpperCase();
  }
  if (asciiWords.length == 1 && asciiWords[0].length >= 2) {
    return asciiWords[0].substring(0, 2).toUpperCase();
  }
  final runes = cleaned.runes.take(2).toList();
  return String.fromCharCodes(runes).toUpperCase();
}

Color parseHexColor(String hex) {
  final clean = hex.replaceFirst('#', '');
  if (clean.length == 6) {
    final val = int.tryParse('FF$clean', radix: 16);
    if (val != null) return Color(val);
  }
  return const Color(0xFF3B82F6);
}

/// 同一SNSをグルーピングするためのキーを返す。
String serviceGroupKey(ServiceInstance inst) {
  final sid = inst.serviceId.trim();
  if (sid.isNotEmpty && sid != 'custom') {
    return sid;
  }
  final parsed = Uri.tryParse(inst.url);
  if (parsed != null && parsed.host.isNotEmpty) {
    return 'custom:${parsed.host.toLowerCase()}';
  }
  return 'custom:${inst.instanceId}';
}

/// 「メイン」「アカウント 3」等の自動付与ラベル（未命名状態）かを判定する。
bool isGenericAccountLabel(String? label, {String? prevHandle}) {
  final trimmed = label?.trim() ?? '';
  if (trimmed.isEmpty) return true;
  if (trimmed == 'メイン') return true;
  if (RegExp(r'^アカウント\s*\d+$').hasMatch(trimmed)) return true;
  final ph = prevHandle?.trim().replaceFirst(RegExp(r'^@+'), '');
  if (ph != null && ph.isNotEmpty) {
    final stripped = trimmed.replaceFirst(RegExp(r'^@+'), '');
    if (stripped.toLowerCase() == ph.toLowerCase()) return true;
  }
  return false;
}

/// ログイン記憶（アーカイブ済みアカウント）の分かりやすい表示タイトルを返す。
String formatArchivedAccountTitle(ServiceInstance inst) {
  final label = inst.accountLabel?.trim() ?? '';
  final handle =
      inst.detectedHandle?.trim().replaceFirst(RegExp(r'^@+'), '') ?? '';
  if (handle.isNotEmpty) {
    if (label.isEmpty ||
        label == inst.name ||
        isGenericAccountLabel(label) ||
        label.replaceFirst(RegExp(r'^@+'), '').toLowerCase() ==
            handle.toLowerCase()) {
      return '${inst.name} · @$handle';
    }
    return '${inst.name} · $label (@$handle)';
  }
  return (label.isNotEmpty && label != inst.name)
      ? '${inst.name} · $label'
      : inst.name;
}

/// 同一SNS内でのアカウント表示名（ヘッダー切替チップ用）を返す。
String accountDisplayLabel(
  ServiceInstance inst,
  int siblingIndex, {
  String? baseServiceName,
}) {
  final explicit = inst.accountLabel?.trim();
  final handle = inst.detectedHandle?.trim().replaceFirst(RegExp(r'^@+'), '');
  if (explicit != null && explicit.isNotEmpty) {
    if (handle != null && handle.isNotEmpty && isGenericAccountLabel(explicit)) {
      return '@$handle';
    }
    return explicit;
  }
  if (handle != null && handle.isNotEmpty) {
    return '@$handle';
  }

  final rawName = inst.name.trim();
  final base = baseServiceName?.trim();
  if (base != null && base.isNotEmpty && rawName.isNotEmpty) {
    if (rawName == base) {
      return siblingIndex == 0 ? 'メイン' : 'アカウント ${siblingIndex + 1}';
    }
    if (rawName.startsWith(base)) {
      final rest = rawName.substring(base.length).trim();
      final numMatch = RegExp(r'^\((\d+)\)$').firstMatch(rest);
      if (numMatch != null) {
        return 'アカウント ${numMatch.group(1)}';
      }
      final cleaned = rest.replaceFirst(RegExp(r'^[-–—・:/／\s]+'), '').trim();
      if (cleaned.isNotEmpty) return cleaned;
    }
    return rawName;
  }
  return siblingIndex == 0 ? 'メイン' : 'アカウント ${siblingIndex + 1}';
}

/// 複数SNSを横断してヘッダーに並べる際のアカウント表示名を返す。
/// - ユーザー命名のカスタムラベルがあればそれを優先
/// - 検出済み @handle があれば `@handle` を表示
/// - 未命名かつ未検出で同一SNSに1垢のみの場合はSNS名（例: Instagram / Bluesky）を返す
String crossServiceAccountDisplayLabel(
  ServiceInstance inst,
  int siblingIndex,
  int siblingCount, {
  String? baseServiceName,
}) {
  final explicit = inst.accountLabel?.trim();
  final handle = inst.detectedHandle?.trim().replaceFirst(RegExp(r'^@+'), '');
  if (explicit != null && explicit.isNotEmpty && !isGenericAccountLabel(explicit)) {
    return explicit;
  }
  if (handle != null && handle.isNotEmpty) {
    return '@$handle';
  }
  final base = baseServiceName?.trim();
  if (siblingCount <= 1) {
    if (base != null && base.isNotEmpty) return base;
    final rawName = inst.name.trim();
    if (rawName.isNotEmpty) return rawName;
  }
  return accountDisplayLabel(
    inst,
    siblingIndex,
    baseServiceName: baseServiceName,
  );
}

/// 既存アカウント名と重複しない次の既定アカウント名を返す。
String nextDefaultAccountLabel(Iterable<String> existingLabels) {
  final used = existingLabels
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();
  if (used.isEmpty) return 'メイン';
  var n = used.length + 1;
  while (used.contains('アカウント $n')) {
    n += 1;
  }
  return 'アカウント $n';
}

/// レガシーデータ（profileName 未付与）のマイグレーション。
/// 各SNSの1つ目の既存アカウントは `Default` プロファイルを引き継ぎ（ログイン維持）、
/// 2つ目以降は独立プロファイル名を割り当てる。
List<ServiceInstance> assignProfilesForMigration(
  List<ServiceInstance> instances,
) {
  final seenDefaultGroups = <String>{};
  return instances.map((inst) {
    final gkey = serviceGroupKey(inst);
    final existing = inst.profileName?.trim();
    if (existing != null && existing.isNotEmpty) {
      if (existing == defaultWebViewProfileName) {
        if (seenDefaultGroups.add(gkey)) {
          return inst;
        }
        // 同一サービス内で Default が重複していたら2つ目以降を分離
        return inst.copyWith(
          profileName: makeProfileNameForInstance(inst.instanceId),
        );
      }
      return inst;
    }

    if (seenDefaultGroups.add(gkey)) {
      return inst.copyWith(profileName: defaultWebViewProfileName);
    }
    return inst.copyWith(
      profileName: makeProfileNameForInstance(inst.instanceId),
    );
  }).toList();
}

/// 同期用アカウントハンドルを正規化する（Rust `normalize_account_handle` と同一仕様）。
String? normalizeAccountHandle(String? raw) {
  if (raw == null) return null;
  var clean = raw.trim();
  while (clean.startsWith('@')) {
    clean = clean.substring(1);
  }
  clean = clean.trim().toLowerCase();
  if (clean.isEmpty || clean.length > 64) return null;
  if (!RegExp(r'^[a-z0-9._:-]+$').hasMatch(clean)) return null;
  return clean;
}

/// PC・スマホ共通のアカウント同期キー (`<serviceId>:<handle>`) を生成する。
String? makeAccountSyncKey(String serviceId, String? handle) {
  final norm = normalizeAccountHandle(handle);
  if (norm == null) return null;
  final svc = serviceId.trim().toLowerCase();
  if (svc.isEmpty) return null;
  return '$svc:$norm';
}

int nowUnixSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// 端末ごとのフォロー・アンフォロー回数エントリ（Rust `DeviceFollowEntry` と完全互換 JSON）。
class DeviceFollowEntry {
  DeviceFollowEntry({
    this.today = 0,
    this.total = 0,
    this.todayEpoch = 0,
    this.totalEpoch = 0,
    this.unfollowToday = 0,
    this.unfollowTotal = 0,
    this.unfollowTodayEpoch = 0,
    this.unfollowTotalEpoch = 0,
    List<int>? followEvents,
    List<int>? followDeductions,
    List<int>? unfollowEvents,
    List<int>? unfollowDeductions,
    this.updatedAt = 0,
  })  : followEvents = followEvents ?? <int>[],
        followDeductions = followDeductions ?? <int>[],
        unfollowEvents = unfollowEvents ?? <int>[],
        unfollowDeductions = unfollowDeductions ?? <int>[];

  int today;
  int total;
  int todayEpoch;
  int totalEpoch;
  int unfollowToday;
  int unfollowTotal;
  int unfollowTodayEpoch;
  int unfollowTotalEpoch;
  List<int> followEvents;
  List<int> followDeductions;
  List<int> unfollowEvents;
  List<int> unfollowDeductions;
  int updatedAt;

  DeviceFollowEntry clone() => DeviceFollowEntry(
        today: today,
        total: total,
        todayEpoch: todayEpoch,
        totalEpoch: totalEpoch,
        unfollowToday: unfollowToday,
        unfollowTotal: unfollowTotal,
        unfollowTodayEpoch: unfollowTodayEpoch,
        unfollowTotalEpoch: unfollowTotalEpoch,
        followEvents: List<int>.from(followEvents),
        followDeductions: List<int>.from(followDeductions),
        unfollowEvents: List<int>.from(unfollowEvents),
        unfollowDeductions: List<int>.from(unfollowDeductions),
        updatedAt: updatedAt,
      );

  bool equalsValue(DeviceFollowEntry other) =>
      today == other.today &&
      total == other.total &&
      todayEpoch == other.todayEpoch &&
      totalEpoch == other.totalEpoch &&
      unfollowToday == other.unfollowToday &&
      unfollowTotal == other.unfollowTotal &&
      unfollowTodayEpoch == other.unfollowTodayEpoch &&
      unfollowTotalEpoch == other.unfollowTotalEpoch &&
      _intListEquals(followEvents, other.followEvents) &&
      _intListEquals(followDeductions, other.followDeductions) &&
      _intListEquals(unfollowEvents, other.unfollowEvents) &&
      _intListEquals(unfollowDeductions, other.unfollowDeductions) &&
      updatedAt == other.updatedAt;

  Map<String, dynamic> toJson() => {
        'today': today,
        'total': total,
        'todayEpoch': todayEpoch,
        'totalEpoch': totalEpoch,
        'unfollowToday': unfollowToday,
        'unfollowTotal': unfollowTotal,
        'unfollowTodayEpoch': unfollowTodayEpoch,
        'unfollowTotalEpoch': unfollowTotalEpoch,
        if (followEvents.isNotEmpty) 'followEvents': followEvents,
        if (followDeductions.isNotEmpty) 'followDeductions': followDeductions,
        if (unfollowEvents.isNotEmpty) 'unfollowEvents': unfollowEvents,
        if (unfollowDeductions.isNotEmpty)
          'unfollowDeductions': unfollowDeductions,
        'updatedAt': updatedAt,
      };

  factory DeviceFollowEntry.fromJson(Map<String, dynamic> json) {
    return DeviceFollowEntry(
      today: _clampSignedInt(json['today'], -999999, 999999) ?? 0,
      total: _clampSignedInt(json['total'], -99999999, 99999999) ?? 0,
      todayEpoch: _clampNonNegInt(json['todayEpoch']) ?? 0,
      totalEpoch: _clampNonNegInt(json['totalEpoch']) ?? 0,
      unfollowToday:
          _clampSignedInt(json['unfollowToday'], -999999, 999999) ?? 0,
      unfollowTotal:
          _clampSignedInt(json['unfollowTotal'], -99999999, 99999999) ?? 0,
      unfollowTodayEpoch: _clampNonNegInt(json['unfollowTodayEpoch']) ?? 0,
      unfollowTotalEpoch: _clampNonNegInt(json['unfollowTotalEpoch']) ?? 0,
      followEvents: _parseEventList(json['followEvents']),
      followDeductions: _parseEventList(json['followDeductions']),
      unfollowEvents: _parseEventList(json['unfollowEvents']),
      unfollowDeductions: _parseEventList(json['unfollowDeductions']),
      updatedAt: _clampNonNegInt(json['updatedAt'], 0x7FFFFFFFFFFFFFFF) ?? 0,
    );
  }
}

/// 同一 SNS アカウントの端末間合算レジャー（Rust `AccountFollowLedger` と完全互換）。
class AccountFollowLedger {
  AccountFollowLedger({
    this.date = '',
    this.resetEpoch = 0,
    this.totalResetEpoch = 0,
    this.unfollowResetEpoch = 0,
    this.unfollowTotalResetEpoch = 0,
    this.followResetAt = 0,
    this.unfollowResetAt = 0,
    Map<String, DeviceFollowEntry>? devices,
    this.snsFollowing,
    this.snsFollowers,
    this.snsUpdatedAt = 0,
  }) : devices = devices ?? {};

  String date;
  int resetEpoch;
  int totalResetEpoch;
  int unfollowResetEpoch;
  int unfollowTotalResetEpoch;
  int followResetAt;
  int unfollowResetAt;
  Map<String, DeviceFollowEntry> devices;
  int? snsFollowing;
  int? snsFollowers;
  int snsUpdatedAt;

  AccountFollowLedger clone() => AccountFollowLedger(
        date: date,
        resetEpoch: resetEpoch,
        totalResetEpoch: totalResetEpoch,
        unfollowResetEpoch: unfollowResetEpoch,
        unfollowTotalResetEpoch: unfollowTotalResetEpoch,
        followResetAt: followResetAt,
        unfollowResetAt: unfollowResetAt,
        devices: {for (final e in devices.entries) e.key: e.value.clone()},
        snsFollowing: snsFollowing,
        snsFollowers: snsFollowers,
        snsUpdatedAt: snsUpdatedAt,
      );

  void rollDate(String today) {
    final maxAllowed = nextYmd(today);
    if (!isValidYmd(date) ||
        date.compareTo(today) < 0 ||
        date.compareTo(maxAllowed) > 0) {
      date = today;
      for (final entry in devices.values) {
        entry.today = 0;
        entry.todayEpoch = resetEpoch;
        entry.unfollowToday = 0;
        entry.unfollowTodayEpoch = unfollowResetEpoch;
      }
    }
  }

  (int, int) effectiveCounts(String today) {
    // 端末間のタイムゾーン差（+1日以内）で当日分が 0 に凍結されないよう <= today+1日 を有効とする
    final maxAllowed = nextYmd(today);
    final activeDay = isValidYmd(date) &&
        date.compareTo(today) >= 0 &&
        date.compareTo(maxAllowed) <= 0;
    var sumToday = 0;
    var sumTotal = 0;
    for (final entry in devices.values) {
      if (activeDay && entry.todayEpoch >= resetEpoch) {
        sumToday += entry.today;
      }
      if (entry.totalEpoch >= totalResetEpoch) {
        sumTotal += entry.total;
      }
    }
    return (
      sumToday.clamp(0, 999999),
      sumTotal.clamp(0, 99999999),
    );
  }

  (int, int) effectiveUnfollowCounts(String today) {
    final maxAllowed = nextYmd(today);
    final activeDay = isValidYmd(date) &&
        date.compareTo(today) >= 0 &&
        date.compareTo(maxAllowed) <= 0;
    var sumToday = 0;
    var sumTotal = 0;
    for (final entry in devices.values) {
      if (activeDay && entry.unfollowTodayEpoch >= unfollowResetEpoch) {
        sumToday += entry.unfollowToday;
      }
      if (entry.unfollowTotalEpoch >= unfollowTotalResetEpoch) {
        sumTotal += entry.unfollowTotal;
      }
    }
    return (
      sumToday.clamp(0, 999999),
      sumTotal.clamp(0, 99999999),
    );
  }

  /// 指定時間内（直近 `windowHours` 時間）の合算フォロー数を返す。
  int effectiveWindowFollowCount(int nowSecs, int windowHours) {
    final h = windowHours.clamp(minFollowWindowHours, maxFollowWindowHours);
    final cutoff = nowSecs > h * 3600 ? nowSecs - h * 3600 : 0;
    var sum = 0;
    for (final entry in devices.values) {
      final hasEvents =
          entry.followEvents.isNotEmpty || entry.followDeductions.isNotEmpty;
      if (hasEvents) {
        sum += countEventsInWindow(entry.followEvents, followResetAt, cutoff);
        sum -=
            countEventsInWindow(entry.followDeductions, followResetAt, cutoff);
      } else if (entry.today > 0 &&
          entry.todayEpoch >= resetEpoch &&
          entry.updatedAt > followResetAt &&
          entry.updatedAt >= cutoff) {
        sum += entry.today;
      }
    }
    return sum.clamp(0, 999999);
  }

  /// 指定時間内（直近 `windowHours` 時間）の合算アンフォロー（解除）数を返す。
  int effectiveWindowUnfollowCount(int nowSecs, int windowHours) {
    final h = windowHours.clamp(minFollowWindowHours, maxFollowWindowHours);
    final cutoff = nowSecs > h * 3600 ? nowSecs - h * 3600 : 0;
    var sum = 0;
    for (final entry in devices.values) {
      final hasEvents = entry.unfollowEvents.isNotEmpty ||
          entry.unfollowDeductions.isNotEmpty;
      if (hasEvents) {
        sum +=
            countEventsInWindow(entry.unfollowEvents, unfollowResetAt, cutoff);
        sum -= countEventsInWindow(
            entry.unfollowDeductions, unfollowResetAt, cutoff);
      } else if (entry.unfollowToday > 0 &&
          entry.unfollowTodayEpoch >= unfollowResetEpoch &&
          entry.updatedAt > unfollowResetAt &&
          entry.updatedAt >= cutoff) {
        sum += entry.unfollowToday;
      }
    }
    return sum.clamp(0, 999999);
  }

  int maxFollowEventTs() {
    var mx = followResetAt;
    for (final entry in devices.values) {
      for (final t in entry.followEvents) {
        if (t > mx) mx = t;
      }
      for (final t in entry.followDeductions) {
        if (t > mx) mx = t;
      }
      if (entry.followEvents.isEmpty && entry.today > 0 && entry.updatedAt > mx) {
        mx = entry.updatedAt;
      }
    }
    return mx;
  }

  int maxUnfollowEventTs() {
    var mx = unfollowResetAt;
    for (final entry in devices.values) {
      for (final t in entry.unfollowEvents) {
        if (t > mx) mx = t;
      }
      for (final t in entry.unfollowDeductions) {
        if (t > mx) mx = t;
      }
      if (entry.unfollowEvents.isEmpty &&
          entry.unfollowToday > 0 &&
          entry.updatedAt > mx) {
        mx = entry.updatedAt;
      }
    }
    return mx;
  }

  /// 相手側レジャーを CRDT マージする。ローカルに変化があれば true。
  bool mergeFrom(AccountFollowLedger other, String today) {
    var changed = false;

    // 破損日付や遠未来日付（today+1日超）によるレジャー汚染を防止
    final maxAllowed = nextYmd(today);
    String? sanitizeDate(String d) {
      if (!isValidYmd(d) || d.compareTo(maxAllowed) > 0) return null;
      return d;
    }

    final localDate = sanitizeDate(date);
    final remoteDate = sanitizeDate(other.date);
    final candidates = <String>[];
    if (localDate != null) candidates.add(localDate);
    if (remoteDate != null) candidates.add(remoteDate);
    if (isValidYmd(today)) candidates.add(today);
    candidates.sort();
    final targetDate = candidates.isEmpty ? today : candidates.last;

    if (date != targetDate) {
      if (localDate == null || localDate.compareTo(targetDate) < 0) {
        for (final entry in devices.values) {
          entry.today = 0;
          entry.todayEpoch = resetEpoch;
          entry.unfollowToday = 0;
          entry.unfollowTodayEpoch = unfollowResetEpoch;
        }
      }
      date = targetDate;
      changed = true;
    }

    if (other.resetEpoch > resetEpoch) {
      resetEpoch = other.resetEpoch;
      for (final entry in devices.values) {
        if (entry.todayEpoch < resetEpoch) {
          entry.today = 0;
          entry.todayEpoch = resetEpoch;
        }
      }
      changed = true;
    }

    if (other.totalResetEpoch > totalResetEpoch) {
      totalResetEpoch = other.totalResetEpoch;
      for (final entry in devices.values) {
        if (entry.totalEpoch < totalResetEpoch) {
          entry.total = 0;
          entry.totalEpoch = totalResetEpoch;
        }
      }
      changed = true;
    }

    if (other.unfollowResetEpoch > unfollowResetEpoch) {
      unfollowResetEpoch = other.unfollowResetEpoch;
      for (final entry in devices.values) {
        if (entry.unfollowTodayEpoch < unfollowResetEpoch) {
          entry.unfollowToday = 0;
          entry.unfollowTodayEpoch = unfollowResetEpoch;
        }
      }
      changed = true;
    }

    if (other.unfollowTotalResetEpoch > unfollowTotalResetEpoch) {
      unfollowTotalResetEpoch = other.unfollowTotalResetEpoch;
      for (final entry in devices.values) {
        if (entry.unfollowTotalEpoch < unfollowTotalResetEpoch) {
          entry.unfollowTotal = 0;
          entry.unfollowTotalEpoch = unfollowTotalResetEpoch;
        }
      }
      changed = true;
    }

    if (other.followResetAt > followResetAt) {
      followResetAt = other.followResetAt;
      for (final entry in devices.values) {
        entry.followEvents.removeWhere((t) => t <= followResetAt);
        entry.followDeductions.removeWhere((t) => t <= followResetAt);
      }
      changed = true;
    }

    if (other.unfollowResetAt > unfollowResetAt) {
      unfollowResetAt = other.unfollowResetAt;
      for (final entry in devices.values) {
        entry.unfollowEvents.removeWhere((t) => t <= unfollowResetAt);
        entry.unfollowDeductions.removeWhere((t) => t <= unfollowResetAt);
      }
      changed = true;
    }

    final otherSameDay = remoteDate == targetDate;
    for (final item in other.devices.entries) {
      final normalized = item.value.clone();
      if (!otherSameDay || normalized.todayEpoch < resetEpoch) {
        normalized.today = 0;
        normalized.todayEpoch = resetEpoch;
      }
      if (normalized.totalEpoch < totalResetEpoch) {
        normalized.total = 0;
        normalized.totalEpoch = totalResetEpoch;
      }
      if (!otherSameDay || normalized.unfollowTodayEpoch < unfollowResetEpoch) {
        normalized.unfollowToday = 0;
        normalized.unfollowTodayEpoch = unfollowResetEpoch;
      }
      if (normalized.unfollowTotalEpoch < unfollowTotalResetEpoch) {
        normalized.unfollowTotal = 0;
        normalized.unfollowTotalEpoch = unfollowTotalResetEpoch;
      }
      normalized.followEvents
        ..removeWhere((t) => t <= followResetAt)
        ..sort();
      normalized.followDeductions
        ..removeWhere((t) => t <= followResetAt)
        ..sort();
      normalized.unfollowEvents
        ..removeWhere((t) => t <= unfollowResetAt)
        ..sort();
      normalized.unfollowDeductions
        ..removeWhere((t) => t <= unfollowResetAt)
        ..sort();
      final local = devices[item.key];
      if (local == null) {
        devices[item.key] = normalized;
        changed = true;
      } else if (normalized.updatedAt > local.updatedAt) {
        if (!local.equalsValue(normalized)) {
          devices[item.key] = normalized;
          changed = true;
        }
      } else if (normalized.updatedAt == local.updatedAt) {
        // 同一秒衝突時はエポックとカウントを対でマージし、リセット済みカウントの復活と他フィールド後退を両方防ぐ
        final mergedEntry = local.clone();
        if (normalized.todayEpoch > mergedEntry.todayEpoch) {
          mergedEntry.todayEpoch = normalized.todayEpoch;
          mergedEntry.today = normalized.today;
        } else if (normalized.todayEpoch == mergedEntry.todayEpoch &&
            normalized.today > mergedEntry.today) {
          mergedEntry.today = normalized.today;
        }
        if (normalized.totalEpoch > mergedEntry.totalEpoch) {
          mergedEntry.totalEpoch = normalized.totalEpoch;
          mergedEntry.total = normalized.total;
        } else if (normalized.totalEpoch == mergedEntry.totalEpoch &&
            normalized.total > mergedEntry.total) {
          mergedEntry.total = normalized.total;
        }
        if (normalized.unfollowTodayEpoch > mergedEntry.unfollowTodayEpoch) {
          mergedEntry.unfollowTodayEpoch = normalized.unfollowTodayEpoch;
          mergedEntry.unfollowToday = normalized.unfollowToday;
        } else if (normalized.unfollowTodayEpoch ==
                mergedEntry.unfollowTodayEpoch &&
            normalized.unfollowToday > mergedEntry.unfollowToday) {
          mergedEntry.unfollowToday = normalized.unfollowToday;
        }
        if (normalized.unfollowTotalEpoch > mergedEntry.unfollowTotalEpoch) {
          mergedEntry.unfollowTotalEpoch = normalized.unfollowTotalEpoch;
          mergedEntry.unfollowTotal = normalized.unfollowTotal;
        } else if (normalized.unfollowTotalEpoch ==
                mergedEntry.unfollowTotalEpoch &&
            normalized.unfollowTotal > mergedEntry.unfollowTotal) {
          mergedEntry.unfollowTotal = normalized.unfollowTotal;
        }
        if (normalized.followEvents.length > mergedEntry.followEvents.length) {
          mergedEntry.followEvents = normalized.followEvents;
        }
        if (normalized.followDeductions.length >
            mergedEntry.followDeductions.length) {
          mergedEntry.followDeductions = normalized.followDeductions;
        }
        if (normalized.unfollowEvents.length >
            mergedEntry.unfollowEvents.length) {
          mergedEntry.unfollowEvents = normalized.unfollowEvents;
        }
        if (normalized.unfollowDeductions.length >
            mergedEntry.unfollowDeductions.length) {
          mergedEntry.unfollowDeductions = normalized.unfollowDeductions;
        }
        if (!local.equalsValue(mergedEntry)) {
          devices[item.key] = mergedEntry;
          changed = true;
        }
      }
    }

    if (other.snsUpdatedAt > snsUpdatedAt ||
        (other.snsUpdatedAt == snsUpdatedAt &&
            ((snsFollowing == null && other.snsFollowing != null) ||
                (snsFollowers == null && other.snsFollowers != null)))) {
      final nextFlwng = other.snsFollowing ?? snsFollowing;
      final nextFlwrs = other.snsFollowers ?? snsFollowers;
      if (snsFollowing != nextFlwng ||
          snsFollowers != nextFlwrs ||
          snsUpdatedAt != other.snsUpdatedAt) {
        snsFollowing = nextFlwng;
        snsFollowers = nextFlwrs;
        snsUpdatedAt = other.snsUpdatedAt;
        changed = true;
      }
    }

    return changed;
  }

  Map<String, dynamic> toJson() => {
        'date': date,
        'resetEpoch': resetEpoch,
        'totalResetEpoch': totalResetEpoch,
        'unfollowResetEpoch': unfollowResetEpoch,
        'unfollowTotalResetEpoch': unfollowTotalResetEpoch,
        'followResetAt': followResetAt,
        'unfollowResetAt': unfollowResetAt,
        'devices': {for (final e in devices.entries) e.key: e.value.toJson()},
        if (snsFollowing != null) 'snsFollowing': snsFollowing,
        if (snsFollowers != null) 'snsFollowers': snsFollowers,
        'snsUpdatedAt': snsUpdatedAt,
      };

  factory AccountFollowLedger.fromJson(Map<String, dynamic> json) {
    final rawDevices = json['devices'];
    final devices = <String, DeviceFollowEntry>{};
    if (rawDevices is Map) {
      for (final entry in rawDevices.entries) {
        if (entry.value is Map) {
          devices[entry.key.toString()] = DeviceFollowEntry.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
    }
    return AccountFollowLedger(
      date: (json['date'] is String ? json['date'] as String : ''),
      resetEpoch: _clampNonNegInt(json['resetEpoch']) ?? 0,
      totalResetEpoch: _clampNonNegInt(json['totalResetEpoch']) ?? 0,
      unfollowResetEpoch: _clampNonNegInt(json['unfollowResetEpoch']) ?? 0,
      unfollowTotalResetEpoch:
          _clampNonNegInt(json['unfollowTotalResetEpoch']) ?? 0,
      followResetAt:
          _clampNonNegInt(json['followResetAt'], 0x7FFFFFFFFFFFFFFF) ?? 0,
      unfollowResetAt:
          _clampNonNegInt(json['unfollowResetAt'], 0x7FFFFFFFFFFFFFFF) ?? 0,
      devices: devices,
      snsFollowing: _clampNonNegInt(json['snsFollowing']),
      snsFollowers: _clampNonNegInt(json['snsFollowers']),
      snsUpdatedAt:
          _clampNonNegInt(json['snsUpdatedAt'], 0x7FFFFFFFFFFFFFFF) ?? 0,
    );
  }
}

/// 全アカウント分のクロスデバイス同期レジャー（Rust `FollowSyncLedger` と完全互換）。
class FollowSyncLedger {
  FollowSyncLedger({
    this.version = 1,
    Map<String, AccountFollowLedger>? accounts,
  }) : accounts = accounts ?? {};

  int version;
  Map<String, AccountFollowLedger> accounts;

  FollowSyncLedger clone() => FollowSyncLedger(
        version: version,
        accounts: {for (final e in accounts.entries) e.key: e.value.clone()},
      );

  bool mergeFrom(FollowSyncLedger other, String today) {
    var changed = false;
    for (final entry in other.accounts.entries) {
      final local = accounts[entry.key];
      if (local == null) {
        final fresh = AccountFollowLedger()..mergeFrom(entry.value, today);
        accounts[entry.key] = fresh;
        changed = true;
      } else {
        if (local.mergeFrom(entry.value, today)) {
          changed = true;
        }
      }
    }
    return changed;
  }

  bool hasNewerDataThan(FollowSyncLedger other, String today) {
    final probe = other.clone();
    return probe.mergeFrom(this, today);
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'accounts': {for (final e in accounts.entries) e.key: e.value.toJson()},
      };

  factory FollowSyncLedger.fromJson(Map<String, dynamic> json) {
    final rawAccounts = json['accounts'];
    final accounts = <String, AccountFollowLedger>{};
    if (rawAccounts is Map) {
      for (final entry in rawAccounts.entries) {
        if (entry.value is Map) {
          accounts[entry.key.toString()] = AccountFollowLedger.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
    }
    return FollowSyncLedger(
      version: (json['version'] as num?)?.toInt() ?? 1,
      accounts: accounts,
    );
  }
}

/// クロスデバイス同期設定。
class FollowSyncSettings {
  const FollowSyncSettings({
    this.deviceId = '',
    this.githubToken = '',
    this.gistId = '',
    this.lastSyncAt,
    this.lastSyncStatus,
  });

  final String deviceId;
  final String githubToken;
  final String gistId;
  final int? lastSyncAt;
  final String? lastSyncStatus;

  FollowSyncSettings copyWith({
    String? deviceId,
    String? githubToken,
    String? gistId,
    int? lastSyncAt,
    String? lastSyncStatus,
  }) {
    return FollowSyncSettings(
      deviceId: deviceId ?? this.deviceId,
      githubToken: githubToken ?? this.githubToken,
      gistId: gistId ?? this.gistId,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastSyncStatus: lastSyncStatus ?? this.lastSyncStatus,
    );
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'githubToken': githubToken,
        'gistId': gistId,
        if (lastSyncAt != null) 'lastSyncAt': lastSyncAt,
        if (lastSyncStatus != null) 'lastSyncStatus': lastSyncStatus,
      };

  factory FollowSyncSettings.fromJson(Map<String, dynamic> json) {
    return FollowSyncSettings(
      deviceId: _asNonEmptyString(json['deviceId']) ?? '',
      githubToken: _asNonEmptyString(json['githubToken']) ?? '',
      gistId: _asNonEmptyString(json['gistId']) ?? '',
      lastSyncAt: _clampNonNegInt(json['lastSyncAt'], 0x7FFFFFFFFFFFFFFF),
      lastSyncStatus:
          json['lastSyncStatus'] is String ? json['lastSyncStatus'] as String : null,
    );
  }
}

/// レジャーの指定時間内合算値・SNS実数を全インスタンスへ投影する。
(List<ServiceInstance>, bool) projectLedgerToInstances(
  List<ServiceInstance> instances,
  FollowSyncLedger ledger,
  String today, {
  int windowHours = defaultFollowWindowHours,
  int? nowSecs,
}) {
  var changed = false;
  final h = windowHours.clamp(minFollowWindowHours, maxFollowWindowHours);
  final now = nowSecs ?? nowUnixSecs();
  final cutoff = now > h * 3600 ? now - h * 3600 : 0;
  final out = instances.map((inst) {
    final key = makeAccountSyncKey(inst.serviceId, inst.detectedHandle);
    final acc = key != null ? ledger.accounts[key] : null;
    if (acc == null) {
      final fCnt = countEventsInWindow(inst.followEvents, 0, cutoff);
      final uCnt = countEventsInWindow(inst.unfollowEvents, 0, cutoff);
      if (inst.followCountToday != fCnt ||
          inst.followCountTotal != fCnt ||
          inst.unfollowCountToday != uCnt ||
          inst.unfollowCountTotal != uCnt ||
          inst.followCountDate != today) {
        changed = true;
        return inst.copyWith(
          followCountToday: fCnt,
          followCountTotal: fCnt,
          unfollowCountToday: uCnt,
          unfollowCountTotal: uCnt,
          followCountDate: today,
        );
      }
      return inst;
    }
    final sumFollow = acc.effectiveWindowFollowCount(now, h);
    final sumUnfollow = acc.effectiveWindowUnfollowCount(now, h);
    final nextFlwng = acc.snsFollowing ?? inst.snsFollowingCount;
    final nextFlwrs = acc.snsFollowers ?? inst.snsFollowersCount;
    if (inst.followCountToday != sumFollow ||
        inst.followCountTotal != sumFollow ||
        inst.unfollowCountToday != sumUnfollow ||
        inst.unfollowCountTotal != sumUnfollow ||
        inst.followCountDate != today ||
        inst.snsFollowingCount != nextFlwng ||
        inst.snsFollowersCount != nextFlwrs) {
      changed = true;
      return inst.copyWith(
        followCountToday: sumFollow,
        followCountTotal: sumFollow,
        unfollowCountToday: sumUnfollow,
        unfollowCountTotal: sumUnfollow,
        followCountDate: today,
        snsFollowingCount: nextFlwng,
        snsFollowersCount: nextFlwrs,
      );
    }
    return inst;
  }).toList();
  return (out, changed);
}

/// 現在表示中のURLから対応する主要SNSカタログIDを推定する。
/// 例: Threadsタブ内で `https://www.instagram.com/...` を開いた際に `'instagram'` を返す。
String? detectPlatformServiceFromUrl(String? rawUrl) {
  final trimmed = rawUrl?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return null;
  bool matchesHost(String domain) => host == domain || host.endsWith('.$domain');
  if (matchesHost('instagram.com')) return 'instagram';
  if (matchesHost('threads.com') || matchesHost('threads.net')) return 'threads';
  if (matchesHost('bsky.app') || matchesHost('bsky.social')) return 'bluesky';
  if (matchesHost('mixi.social')) return 'mixi2';
  if (matchesHost('x.com') || matchesHost('twitter.com')) return 'x';
  if (matchesHost('tiktok.com')) return 'tiktok';
  if (matchesHost('facebook.com')) return 'facebook';
  if (matchesHost('messenger.com')) return 'messenger';
  if (matchesHost('note.com')) return 'note';
  if (matchesHost('youtube.com')) return 'youtube';
  if (matchesHost('twitch.tv')) return 'twitch';
  if (matchesHost('reddit.com')) return 'reddit';
  if (matchesHost('pinterest.com') || matchesHost('pinterest.jp')) {
    return 'pinterest';
  }
  if (matchesHost('linkedin.com')) return 'linkedin';
  if (matchesHost('tumblr.com')) return 'tumblr';
  if (matchesHost('pixiv.net')) return 'pixiv';
  return null;
}

/// タブ内で別SNS（例: Threadsタブ内から Instagram を開いた場合）を表示している際、
/// 表示中サービスのアカウントインスタンスへカウンター対象を切り替える。
/// 該当サービスが一覧に未登録、または別ハンドルのみの候補しかない場合は null を返し誤帰属を防ぐ。
ServiceInstance? resolveCounterTargetInstance({
  required ServiceInstance source,
  required List<ServiceInstance> instances,
  String? currentUrl,
  String? explicitService,
  String? handleHint,
  Map<String, String> lastActiveByGroup = const {},
}) {
  final normService = explicitService?.trim().toLowerCase();
  final effectiveService = (normService != null && normService.isNotEmpty)
      ? normService
      : (detectPlatformServiceFromUrl(currentUrl) ?? source.serviceId);

  if (effectiveService == source.serviceId) {
    return source;
  }

  final candidates =
      instances.where((i) => i.serviceId == effectiveService).toList();
  if (candidates.isEmpty) {
    return null;
  }

  // 1. 判明しているハンドル（クロスサイト検出ハンドルを優先、無ければ元インスタンスのハンドル）
  final normHint = normalizeAccountHandle(handleHint);
  final knownHandle = normHint ?? normalizeAccountHandle(source.detectedHandle);
  if (knownHandle != null) {
    for (final c in candidates) {
      if (c.detectedHandle == knownHandle) return c;
    }
  }

  // クロスサイトでハンドルが判明している場合、別ハンドルが紐づいた候補への誤帰属・上書きを防ぐ
  final fallbackPool = knownHandle != null
      ? candidates.where((c) => c.detectedHandle == null).toList()
      : candidates;
  if (fallbackPool.isEmpty) {
    return null;
  }

  // 2. 対象サービスで直近アクティブだったアカウント
  final rememberedId = lastActiveByGroup[effectiveService];
  if (rememberedId != null) {
    for (final c in fallbackPool) {
      if (c.instanceId == rememberedId) return c;
    }
  }

  // 4. アカウントラベル一致
  final srcLabel = source.accountLabel?.trim();
  if (srcLabel != null && srcLabel.isNotEmpty) {
    for (final c in fallbackPool) {
      if (c.accountLabel?.trim() == srcLabel) return c;
    }
  }

  return fallbackPool.first;
}
