import 'dart:ui';

/// Android WebView の既定プロファイル名（AndroidX WebKit `Profile.DEFAULT_PROFILE_NAME` 準拠）
const String defaultWebViewProfileName = 'Default';

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
    this.followCountToday = 0,
    this.followCountTotal = 0,
    this.followCountDate,
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
  final int followCountToday;
  final int followCountTotal;
  final String? followCountDate;
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

  /// フォロー回数を delta (+1 / -1) 増減した新しいインスタンスを返す。
  ServiceInstance withFollowDelta(int delta, [DateTime? now]) {
    final today = formatLocalYmd(now ?? DateTime.now());
    final baseToday = followCountDate == today ? followCountToday : 0;
    final nextToday = (baseToday + delta).clamp(0, 999999);
    final nextTotal = (followCountTotal + delta).clamp(0, 99999999);
    return copyWith(
      followCountToday: nextToday,
      followCountTotal: nextTotal,
      followCountDate: today,
    );
  }

  /// フォロー回数をリセットした新しいインスタンスを返す。
  ServiceInstance withFollowReset({required bool resetTotal, DateTime? now}) {
    final today = formatLocalYmd(now ?? DateTime.now());
    return copyWith(
      followCountToday: 0,
      followCountTotal: resetTotal ? 0 : followCountTotal,
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
    int? followCountToday,
    int? followCountTotal,
    String? followCountDate,
    String? detectedHandle,
    bool clearDetectedHandle = false,
    int? snsFollowingCount,
    int? snsFollowersCount,
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
      followCountToday: followCountToday ?? this.followCountToday,
      followCountTotal: followCountTotal ?? this.followCountTotal,
      followCountDate: followCountDate ?? this.followCountDate,
      detectedHandle: clearDetectedHandle
          ? null
          : (detectedHandle ?? this.detectedHandle),
      snsFollowingCount: snsFollowingCount ?? this.snsFollowingCount,
      snsFollowersCount: snsFollowersCount ?? this.snsFollowersCount,
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
      'followCountToday': followCountToday,
      'followCountTotal': followCountTotal,
      if (followCountDate != null && followCountDate!.isNotEmpty)
        'followCountDate': followCountDate,
      if (detectedHandle != null && detectedHandle!.trim().isNotEmpty)
        'detectedHandle': detectedHandle!.trim(),
      if (snsFollowingCount != null) 'snsFollowingCount': snsFollowingCount,
      if (snsFollowersCount != null) 'snsFollowersCount': snsFollowersCount,
    };
  }

  factory ServiceInstance.fromJson(Map<String, dynamic> json, int index) {
    final name = (json['name'] as String?)?.trim();
    final safeName = (name == null || name.isEmpty) ? 'SNS' : name;
    final rawLabel = (json['accountLabel'] as String?)?.trim();
    final rawProfile = (json['profileName'] as String?)?.trim();
    final rawFollowDate = (json['followCountDate'] as String?)?.trim();
    final rawHandle = normalizeAccountHandle(json['detectedHandle'] as String?);
    return ServiceInstance(
      instanceId: json['instanceId'] as String? ?? 'svc-$index',
      serviceId: json['serviceId'] as String? ?? 'custom',
      name: safeName,
      accountLabel: (rawLabel == null || rawLabel.isEmpty) ? null : rawLabel,
      profileName:
          (rawProfile == null || rawProfile.isEmpty) ? null : rawProfile,
      category: json['category'] as String? ?? 'custom',
      url: normalizeServiceUrl(json['url'] as String? ?? '') ??
          'https://example.com/',
      colorHex: json['colorHex'] as String? ?? '#3B82F6',
      badge: (json['badge'] as String?) ?? makeBadgeText(safeName),
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      order: json['order'] as int? ?? index,
      followCountToday:
          ((json['followCountToday'] as num?)?.toInt() ?? 0).clamp(0, 999999),
      followCountTotal: ((json['followCountTotal'] as num?)?.toInt() ?? 0)
          .clamp(0, 99999999),
      followCountDate:
          (rawFollowDate == null || rawFollowDate.isEmpty) ? null : rawFollowDate,
      detectedHandle: rawHandle,
      snsFollowingCount: (json['snsFollowingCount'] as num?)?.toInt(),
      snsFollowersCount: (json['snsFollowersCount'] as num?)?.toInt(),
    );
  }
}

class AppSettings {
  const AppSettings({
    this.isDarkMode = true,
    this.activeInstanceId,
    this.isBottomTabsCollapsed = false,
    this.isHeaderCollapsed = false,
  });

  final bool isDarkMode;
  final String? activeInstanceId;
  final bool isBottomTabsCollapsed;
  final bool isHeaderCollapsed;

  AppSettings copyWith({
    bool? isDarkMode,
    String? activeInstanceId,
    bool clearActive = false,
    bool? isBottomTabsCollapsed,
    bool? isHeaderCollapsed,
  }) {
    return AppSettings(
      isDarkMode: isDarkMode ?? this.isDarkMode,
      activeInstanceId:
          clearActive ? null : (activeInstanceId ?? this.activeInstanceId),
      isBottomTabsCollapsed:
          isBottomTabsCollapsed ?? this.isBottomTabsCollapsed,
      isHeaderCollapsed: isHeaderCollapsed ?? this.isHeaderCollapsed,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'isDarkMode': isDarkMode,
      'activeInstanceId': activeInstanceId,
      'isBottomTabsCollapsed': isBottomTabsCollapsed,
      'isHeaderCollapsed': isHeaderCollapsed,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      isDarkMode: json['isDarkMode'] as bool? ?? true,
      activeInstanceId: json['activeInstanceId'] as String?,
      isBottomTabsCollapsed: json['isBottomTabsCollapsed'] as bool? ?? false,
      isHeaderCollapsed: json['isHeaderCollapsed'] as bool? ?? false,
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
}

/// WebViewの `; wv)` トークンを除いたクリーンなスマホ版 Android Chrome UA を返す。
String buildMobileUserAgent() {
  return 'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/136.0.0.0 Mobile Safari/537.36';
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

/// 同一SNS内でのアカウント表示名（ヘッダー切替チップ用）を返す。
String accountDisplayLabel(
  ServiceInstance inst,
  int siblingIndex, {
  String? baseServiceName,
}) {
  final explicit = inst.accountLabel?.trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;

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

/// 端末ごとのフォロー回数エントリ（Rust `DeviceFollowEntry` と完全互換 JSON）。
class DeviceFollowEntry {
  DeviceFollowEntry({
    this.today = 0,
    this.total = 0,
    this.todayEpoch = 0,
    this.totalEpoch = 0,
    this.updatedAt = 0,
  });

  int today;
  int total;
  int todayEpoch;
  int totalEpoch;
  int updatedAt;

  DeviceFollowEntry clone() => DeviceFollowEntry(
        today: today,
        total: total,
        todayEpoch: todayEpoch,
        totalEpoch: totalEpoch,
        updatedAt: updatedAt,
      );

  bool equalsValue(DeviceFollowEntry other) =>
      today == other.today &&
      total == other.total &&
      todayEpoch == other.todayEpoch &&
      totalEpoch == other.totalEpoch &&
      updatedAt == other.updatedAt;

  Map<String, dynamic> toJson() => {
        'today': today,
        'total': total,
        'todayEpoch': todayEpoch,
        'totalEpoch': totalEpoch,
        'updatedAt': updatedAt,
      };

  factory DeviceFollowEntry.fromJson(Map<String, dynamic> json) {
    return DeviceFollowEntry(
      today: (json['today'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      todayEpoch: (json['todayEpoch'] as num?)?.toInt() ?? 0,
      totalEpoch: (json['totalEpoch'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 同一 SNS アカウントの端末間合算レジャー（Rust `AccountFollowLedger` と完全互換）。
class AccountFollowLedger {
  AccountFollowLedger({
    this.date = '',
    this.resetEpoch = 0,
    this.totalResetEpoch = 0,
    Map<String, DeviceFollowEntry>? devices,
    this.snsFollowing,
    this.snsFollowers,
    this.snsUpdatedAt = 0,
  }) : devices = devices ?? {};

  String date;
  int resetEpoch;
  int totalResetEpoch;
  Map<String, DeviceFollowEntry> devices;
  int? snsFollowing;
  int? snsFollowers;
  int snsUpdatedAt;

  AccountFollowLedger clone() => AccountFollowLedger(
        date: date,
        resetEpoch: resetEpoch,
        totalResetEpoch: totalResetEpoch,
        devices: {for (final e in devices.entries) e.key: e.value.clone()},
        snsFollowing: snsFollowing,
        snsFollowers: snsFollowers,
        snsUpdatedAt: snsUpdatedAt,
      );

  void rollDate(String today) {
    if (date.isEmpty) {
      date = today;
    } else if (date.compareTo(today) < 0) {
      date = today;
      for (final entry in devices.values) {
        entry.today = 0;
        entry.todayEpoch = resetEpoch;
      }
    }
  }

  (int, int) effectiveCounts(String today) {
    final sameDay = date == today;
    var sumToday = 0;
    var sumTotal = 0;
    for (final entry in devices.values) {
      if (sameDay && entry.todayEpoch >= resetEpoch) {
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

  /// 相手側レジャーを CRDT マージする。ローカルに変化があれば true。
  bool mergeFrom(AccountFollowLedger other, String today) {
    var changed = false;

    final candidates = [date, other.date, today]
        .where((s) => s.isNotEmpty)
        .toList()
      ..sort();
    final targetDate = candidates.isEmpty ? today : candidates.last;

    if (date != targetDate) {
      if (date.compareTo(targetDate) < 0) {
        for (final entry in devices.values) {
          entry.today = 0;
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

    final otherSameDay = other.date == targetDate;
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
      final local = devices[item.key];
      if (local == null) {
        devices[item.key] = normalized;
        changed = true;
      } else {
        final remoteNewer = normalized.updatedAt > local.updatedAt ||
            (normalized.updatedAt == local.updatedAt &&
                (normalized.total > local.total ||
                    normalized.today > local.today));
        if (remoteNewer && !local.equalsValue(normalized)) {
          devices[item.key] = normalized;
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
      date: (json['date'] as String?) ?? '',
      resetEpoch: (json['resetEpoch'] as num?)?.toInt() ?? 0,
      totalResetEpoch: (json['totalResetEpoch'] as num?)?.toInt() ?? 0,
      devices: devices,
      snsFollowing: (json['snsFollowing'] as num?)?.toInt(),
      snsFollowers: (json['snsFollowers'] as num?)?.toInt(),
      snsUpdatedAt: (json['snsUpdatedAt'] as num?)?.toInt() ?? 0,
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
        final cloned = entry.value.clone()..rollDate(today);
        accounts[entry.key] = cloned;
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
    this.lanEnabled = true,
    this.githubToken = '',
    this.gistId = '',
    this.lastSyncAt,
    this.lastSyncStatus,
  });

  final String deviceId;
  final bool lanEnabled;
  final String githubToken;
  final String gistId;
  final int? lastSyncAt;
  final String? lastSyncStatus;

  FollowSyncSettings copyWith({
    String? deviceId,
    bool? lanEnabled,
    String? githubToken,
    String? gistId,
    int? lastSyncAt,
    String? lastSyncStatus,
  }) {
    return FollowSyncSettings(
      deviceId: deviceId ?? this.deviceId,
      lanEnabled: lanEnabled ?? this.lanEnabled,
      githubToken: githubToken ?? this.githubToken,
      gistId: gistId ?? this.gistId,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastSyncStatus: lastSyncStatus ?? this.lastSyncStatus,
    );
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'lanEnabled': lanEnabled,
        'githubToken': githubToken,
        'gistId': gistId,
        if (lastSyncAt != null) 'lastSyncAt': lastSyncAt,
        if (lastSyncStatus != null) 'lastSyncStatus': lastSyncStatus,
      };

  factory FollowSyncSettings.fromJson(Map<String, dynamic> json) {
    return FollowSyncSettings(
      deviceId: (json['deviceId'] as String?)?.trim() ?? '',
      lanEnabled: json['lanEnabled'] as bool? ?? true,
      githubToken: (json['githubToken'] as String?)?.trim() ?? '',
      gistId: (json['gistId'] as String?)?.trim() ?? '',
      lastSyncAt: (json['lastSyncAt'] as num?)?.toInt(),
      lastSyncStatus: json['lastSyncStatus'] as String?,
    );
  }
}

/// レジャーの合算値・SNS実数を全インスタンスへ投影する。
(List<ServiceInstance>, bool) projectLedgerToInstances(
  List<ServiceInstance> instances,
  FollowSyncLedger ledger,
  String today,
) {
  var changed = false;
  final out = instances.map((inst) {
    final key = makeAccountSyncKey(inst.serviceId, inst.detectedHandle);
    if (key == null) return inst;
    final acc = ledger.accounts[key];
    if (acc == null) return inst;
    final (sumToday, sumTotal) = acc.effectiveCounts(today);
    final nextFlwng = acc.snsFollowing ?? inst.snsFollowingCount;
    final nextFlwrs = acc.snsFollowers ?? inst.snsFollowersCount;
    if (inst.followCountToday != sumToday ||
        inst.followCountTotal != sumTotal ||
        inst.followCountDate != today ||
        inst.snsFollowingCount != nextFlwng ||
        inst.snsFollowersCount != nextFlwrs) {
      changed = true;
      return inst.copyWith(
        followCountToday: sumToday,
        followCountTotal: sumTotal,
        followCountDate: today,
        snsFollowingCount: nextFlwng,
        snsFollowersCount: nextFlwrs,
      );
    }
    return inst;
  }).toList();
  return (out, changed);
}
