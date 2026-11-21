import 'dart:ui';

enum UserAgentMode {
  desktop,
  mobile;

  String get value => name;

  static UserAgentMode fromString(String? raw) {
    return raw == 'desktop' ? UserAgentMode.desktop : UserAgentMode.mobile;
  }
}

class CategoryMeta {
  const CategoryMeta({
    required this.id,
    required this.label,
    required this.description,
    this.isMatchingGroup = false,
  });

  final String id;
  final String label;
  final String description;
  final bool isMatchingGroup;

  factory CategoryMeta.fromJson(Map<String, dynamic> json) {
    return CategoryMeta(
      id: json['id'] as String? ?? 'custom',
      label: json['label'] as String? ?? '',
      description: json['description'] as String? ?? '',
      isMatchingGroup: json['isMatchingGroup'] as bool? ?? false,
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
    required this.defaultUa,
    required this.description,
    this.note,
    this.requiresCustomUrl = false,
    this.isAdultOrMatching = false,
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
  final UserAgentMode defaultUa;
  final String description;
  final String? note;
  final bool requiresCustomUrl;
  final bool isAdultOrMatching;
  final bool defaultPinned;

  /// Android向け推奨初期UA:
  /// PC必須/推奨サービスはdesktop、それ以外はスマホ最適化のためmobileを既定にする。
  UserAgentMode get recommendedAndroidUa {
    const desktopRequiredIds = {
      'whatsapp',
      'snapchat',
      'mixi2',
      'tokyo-calendar-date',
      'google-messages',
    };
    if (desktopRequiredIds.contains(id)) {
      return UserAgentMode.desktop;
    }
    return UserAgentMode.mobile;
  }

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
      defaultUa: UserAgentMode.fromString(json['defaultUa'] as String?),
      description: json['description'] as String? ?? '',
      note: json['note'] as String?,
      requiresCustomUrl: json['requiresCustomUrl'] as bool? ?? false,
      isAdultOrMatching: json['isAdultOrMatching'] as bool? ?? false,
      defaultPinned: json['defaultPinned'] as bool? ?? false,
    );
  }
}

class ServiceInstance {
  const ServiceInstance({
    required this.instanceId,
    required this.serviceId,
    required this.name,
    required this.category,
    required this.url,
    required this.colorHex,
    required this.badge,
    required this.uaMode,
    required this.isAdultOrMatching,
    required this.notificationsEnabled,
    required this.order,
  });

  final String instanceId;
  final String serviceId;
  final String name;
  final String category;
  final String url;
  final String colorHex;
  final String badge;
  final UserAgentMode uaMode;
  final bool isAdultOrMatching;
  final bool notificationsEnabled;
  final int order;

  ServiceInstance copyWith({
    String? name,
    String? url,
    String? colorHex,
    String? badge,
    UserAgentMode? uaMode,
    bool? isAdultOrMatching,
    bool? notificationsEnabled,
    int? order,
  }) {
    return ServiceInstance(
      instanceId: instanceId,
      serviceId: serviceId,
      name: name ?? this.name,
      category: category,
      url: url ?? this.url,
      colorHex: colorHex ?? this.colorHex,
      badge: badge ?? this.badge,
      uaMode: uaMode ?? this.uaMode,
      isAdultOrMatching: isAdultOrMatching ?? this.isAdultOrMatching,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      order: order ?? this.order,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'instanceId': instanceId,
      'serviceId': serviceId,
      'name': name,
      'category': category,
      'url': url,
      'colorHex': colorHex,
      'badge': badge,
      'uaMode': uaMode.value,
      'isAdultOrMatching': isAdultOrMatching,
      'notificationsEnabled': notificationsEnabled,
      'order': order,
    };
  }

  factory ServiceInstance.fromJson(Map<String, dynamic> json, int index) {
    final name = (json['name'] as String?)?.trim();
    final safeName = (name == null || name.isEmpty) ? 'SNS' : name;
    return ServiceInstance(
      instanceId: json['instanceId'] as String? ?? 'svc-$index',
      serviceId: json['serviceId'] as String? ?? 'custom',
      name: safeName,
      category: json['category'] as String? ?? 'custom',
      url: normalizeServiceUrl(json['url'] as String? ?? '') ??
          'https://example.com/',
      colorHex: json['colorHex'] as String? ?? '#3B82F6',
      badge: (json['badge'] as String?) ?? makeBadgeText(safeName),
      uaMode: UserAgentMode.fromString(json['uaMode'] as String?),
      isAdultOrMatching: json['isAdultOrMatching'] as bool? ?? false,
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      order: json['order'] as int? ?? index,
    );
  }
}

class AppSettings {
  const AppSettings({
    this.isDarkMode = true,
    this.showMatchingServices = true,
    this.lockPin = '',
    this.activeInstanceId,
  });

  final bool isDarkMode;
  final bool showMatchingServices;
  final String lockPin;
  final String? activeInstanceId;

  AppSettings copyWith({
    bool? isDarkMode,
    bool? showMatchingServices,
    String? lockPin,
    String? activeInstanceId,
    bool clearActive = false,
  }) {
    return AppSettings(
      isDarkMode: isDarkMode ?? this.isDarkMode,
      showMatchingServices: showMatchingServices ?? this.showMatchingServices,
      lockPin: lockPin ?? this.lockPin,
      activeInstanceId:
          clearActive ? null : (activeInstanceId ?? this.activeInstanceId),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'isDarkMode': isDarkMode,
      'showMatchingServices': showMatchingServices,
      'lockPin': lockPin,
      'activeInstanceId': activeInstanceId,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      isDarkMode: json['isDarkMode'] as bool? ?? true,
      showMatchingServices: json['showMatchingServices'] as bool? ?? true,
      lockPin: json['lockPin'] as String? ?? '',
      activeInstanceId: json['activeInstanceId'] as String?,
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

/// WebViewの `; wv)` トークンを除いたクリーンなChrome互換UAを返す
String buildUserAgent(UserAgentMode mode) {
  if (mode == UserAgentMode.desktop) {
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/136.0.0.0 Safari/537.36';
  }
  return 'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/136.0.0.0 Mobile Safari/537.36';
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
