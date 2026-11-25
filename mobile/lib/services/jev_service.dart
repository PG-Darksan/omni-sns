import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef PreparedAvatar = ({String base64, String format});

typedef AvatarPreparer = Future<PreparedAvatar?> Function(String url);

typedef JevHttpPoster = Future<({int statusCode, String body})> Function({
  required String apiKey,
  required Map<String, dynamic> body,
  required bool includeImageHeader,
});

/// よく使う分類プリセット
const List<String> kJevPresetCategories = <String>[
  '女の子',
  'カフェ・グルメ',
  'イラスト・絵師',
  'ペット・動物',
  'ファッション・美容',
  '写真・カメラ',
];

class JevAccountCandidate {
  const JevAccountCandidate({
    required this.username,
    this.displayName = '',
    this.bio = '',
    this.avatarUrl = '',
    this.avatarBase64,
    this.avatarFormat,
    this.platform = 'instagram',
  });

  final String username;
  final String displayName;
  final String bio;
  final String avatarUrl;
  final String? avatarBase64;
  final String? avatarFormat;
  final String platform;

  String get platformLabel => switch (platform.trim().toLowerCase()) {
        'instagram' => 'Instagram',
        'tiktok' => 'TikTok',
        'threads' => 'Threads',
        'bluesky' => 'Bluesky',
        'x' || 'twitter' => 'X',
        'facebook' => 'Facebook',
        'youtube' => 'YouTube',
        'mastodon' => 'Mastodon',
        'misskey' => 'Misskey',
        'mixi2' => 'mixi2',
        'reddit' => 'Reddit',
        'note' => 'note',
        _ => 'SNS',
      };

  bool get hasInlineAvatarBase64 =>
      avatarBase64 != null && avatarBase64!.trim().isNotEmpty;

  String get avatarId {
    final rawUrl = avatarUrl.trim();
    if (rawUrl.isNotEmpty) {
      final uri = Uri.tryParse(rawUrl);
      final nonEmpty =
          uri?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const <String>[];
      if (nonEmpty.isNotEmpty) {
        final last = nonEmpty.last
            .replaceFirst(RegExp(r'@[a-z0-9]+$', caseSensitive: false), '');
        if (nonEmpty.length >= 2 &&
            RegExp(r'^\d+x\d+\.[a-z0-9]+$', caseSensitive: false).hasMatch(last)) {
          return '${nonEmpty[nonEmpty.length - 2]}_$last'.toLowerCase();
        }
        return last.toLowerCase();
      }
      return rawUrl.toLowerCase();
    }
    final b64 = avatarBase64?.trim() ?? '';
    if (b64.isNotEmpty) {
      final start = b64.length > 24 ? b64.length - 24 : 0;
      return 'b64_${b64.length}_${b64.substring(start)}';
    }
    return '';
  }

  String cacheKey(String category) {
    final cat = JevService.categoryCacheToken(category);
    final plat = platform.trim().toLowerCase();
    final u = username.trim().toLowerCase();
    final d = displayName.trim().toLowerCase();
    final bioPart = bio.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
    final shortBio = bioPart.length > 48 ? bioPart.substring(0, 48) : bioPart;
    return '$cat|$plat|$u|$d|$avatarId|$shortBio';
  }
}

/// TypeSafe AI System One (`jev-latest`) を用いた自由入力分類フィルタサービス（Android / Dart 版）。
class JevService extends ChangeNotifier {
  JevService({
    JevHttpPoster? poster,
    AvatarPreparer? avatarPreparer,
    bool inMemoryOnly = false,
  })  : _poster = poster ?? _defaultPostSystemOne,
        _avatarPreparer = avatarPreparer ?? defaultPrepareAvatar,
        _inMemoryOnly = inMemoryOnly,
        _loaded = inMemoryOnly;

  static const endpoint = 'https://api.typesafe.ai/v1/systemone';
  static const modelName = 'jev-latest';
  static const defaultCategory = '女の子';
  static const defaultThreshold = 0.55;
  static const batchSize = 8;
  static const inputUsdPerMTok = 0.042;
  static const usdToJpyRate = 155.0;
  static const avatarTargetPx = 320;

  static const _settingsPrefKey = 'omnisns_jev_settings_v1';
  static const _cachePrefKey = 'omnisns_jev_cache_v1';
  static const _cacheMaxAge = Duration(days: 90);
  static const _maxCacheEntries = 4000;
  static const _maxRecentCategories = 10;

  final JevHttpPoster _poster;
  final AvatarPreparer _avatarPreparer;
  final bool _inMemoryOnly;
  bool _loaded;
  Future<void>? _loading;
  int _nonceCounter = 0;

  String _apiKey = '';
  bool _enabled = false;
  String _category = defaultCategory;
  List<String> _recentCategories = <String>[defaultCategory];
  double _threshold = defaultThreshold;
  String? lastError;

  int _totalInputTokens = 0;
  int _totalApiCalls = 0;
  int _totalJudgedAccounts = 0;
  double _totalCostUsd = 0.0;

  int _sessionInputTokens = 0;
  int _sessionApiCalls = 0;
  double _sessionCostUsd = 0.0;

  final _cache = <String, ({double noul, DateTime at, bool hasImage})>{};
  final _avatarMemory = <String, PreparedAvatar>{};

  String get apiKey => _apiKey;
  bool get hasApiKey => _apiKey.trim().isNotEmpty;
  bool get enabled => _enabled;
  bool get isActive => _enabled && hasApiKey;
  String get category => _category;
  List<String> get recentCategories => List.unmodifiable(_recentCategories);
  double get threshold => _threshold;
  int get cacheEntries => _cache.length;

  int get totalInputTokens => _totalInputTokens;
  int get totalApiCalls => _totalApiCalls;
  int get totalJudgedAccounts => _totalJudgedAccounts;
  double get totalCostUsd => _totalCostUsd;
  double get totalCostJpy => _totalCostUsd * usdToJpyRate;

  int get sessionInputTokens => _sessionInputTokens;
  int get sessionApiCalls => _sessionApiCalls;
  double get sessionCostUsd => _sessionCostUsd;
  double get sessionCostJpy => _sessionCostUsd * usdToJpyRate;

  static String normalizeCategory(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return defaultCategory;
    return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
  }

  static bool isFemalePresetCategory(String category) {
    final norm = normalizeCategory(category).toLowerCase();
    const presets = <String>{
      '女の子',
      'おんなのこ',
      '女性',
      '女子',
      '女性のみ',
      '女の子のみ',
      '女性個人',
      '女性アカウント',
      '女性個人アカウント',
      'female',
      'girl',
      'girls',
      'woman',
      'women',
    };
    return presets.contains(norm);
  }

  static String categoryCacheToken(String category) {
    if (isFemalePresetCategory(category)) return '__preset_female__';
    return normalizeCategory(category).toLowerCase();
  }

  static String formatUsd(double usd) {
    if (!usd.isFinite || usd <= 0) return r'$0';
    if (usd < 0.0001) return '\$${usd.toStringAsFixed(6)}';
    if (usd < 0.01) {
      final s = usd.toStringAsFixed(5).replaceFirst(RegExp(r'0+$'), '');
      return '\$${s.endsWith('.') ? '${s}0' : s}';
    }
    if (usd < 1) return '\$${usd.toStringAsFixed(4)}';
    return '\$${usd.toStringAsFixed(2)}';
  }

  static String formatJpy(double usd) {
    if (!usd.isFinite || usd <= 0) return '¥0';
    final jpy = usd * usdToJpyRate;
    if (jpy < 0.01) return '約¥${jpy.toStringAsFixed(4)}';
    if (jpy < 1) return '約¥${jpy.toStringAsFixed(2)}';
    if (jpy < 100) return '約¥${jpy.toStringAsFixed(1)}';
    return '約¥${jpy.round()}';
  }

  static String formatCostCompact(double usd) {
    if (!usd.isFinite || usd <= 0) return r'$0 (¥0)';
    return '${formatUsd(usd)} (${formatJpy(usd)})';
  }

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawSettings = prefs.getString(_settingsPrefKey);
      if (rawSettings != null && rawSettings.isNotEmpty) {
        final json = jsonDecode(rawSettings) as Map<String, dynamic>;
        _apiKey = (json['apiKey'] as String?)?.trim() ?? '';
        _enabled = (json['enabled'] as bool?) ?? false;
        _category = normalizeCategory((json['category'] as String?) ?? defaultCategory);
        final rawRecents = json['recentCategories'];
        if (rawRecents is List) {
          _recentCategories = rawRecents
              .whereType<String>()
              .map(normalizeCategory)
              .toSet()
              .take(_maxRecentCategories)
              .toList();
        }
        if (_recentCategories.isEmpty) {
          _recentCategories = <String>[_category];
        }
        _threshold =
            ((json['threshold'] as num?)?.toDouble() ?? defaultThreshold)
                .clamp(0.35, 0.90);
        _totalInputTokens = (json['totalInputTokens'] as num?)?.toInt() ?? 0;
        _totalApiCalls = (json['totalApiCalls'] as num?)?.toInt() ?? 0;
        _totalJudgedAccounts =
            (json['totalJudgedAccounts'] as num?)?.toInt() ?? 0;
        _totalCostUsd = (json['totalCostUsd'] as num?)?.toDouble() ?? 0.0;
      }

      final rawCache = prefs.getString(_cachePrefKey);
      if (rawCache != null && rawCache.isNotEmpty) {
        final json = jsonDecode(rawCache) as Map<String, dynamic>;
        final now = DateTime.now();
        for (final entry in json.entries) {
          final value = entry.value;
          if (value is Map) {
            final noul = (value['p'] as num?)?.toDouble();
            final epoch = (value['t'] as num?)?.toInt();
            final hasImg = value['img'] == 1 || value['img'] == true;
            if (noul != null && noul.isFinite && epoch != null) {
              final at = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
              if (now.difference(at) <= _cacheMaxAge) {
                _cache[entry.key] = (noul: noul, at: at, hasImage: hasImg);
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Jev 設定の読み込みに失敗: $e');
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  /// 設定を更新し、カテゴリまたはしきい値が変化したかを返す。
  Future<bool> updateSettings({
    String? apiKey,
    bool? enabled,
    String? category,
    double? threshold,
  }) async {
    await ensureLoaded();
    final prevCatToken = categoryCacheToken(_category);
    final prevThreshold = _threshold;

    if (apiKey != null) _apiKey = apiKey.trim();
    if (category != null) {
      final norm = normalizeCategory(category);
      _category = norm;
      _recentCategories.removeWhere(
        (x) => x.toLowerCase() == norm.toLowerCase(),
      );
      _recentCategories.insert(0, norm);
      if (_recentCategories.length > _maxRecentCategories) {
        _recentCategories =
            _recentCategories.take(_maxRecentCategories).toList();
      }
    }
    if (enabled != null) _enabled = enabled;
    if (threshold != null && threshold.isFinite) {
      _threshold = threshold.clamp(0.35, 0.90);
    }
    lastError = null;
    notifyListeners();
    if (!_inMemoryOnly) await _saveSettings();

    final nextCatToken = categoryCacheToken(_category);
    return prevCatToken != nextCatToken ||
        (prevThreshold - _threshold).abs() > 0.0001;
  }

  Future<void> resetUsageStats() async {
    await ensureLoaded();
    _totalInputTokens = 0;
    _totalApiCalls = 0;
    _totalJudgedAccounts = 0;
    _totalCostUsd = 0.0;
    _sessionInputTokens = 0;
    _sessionApiCalls = 0;
    _sessionCostUsd = 0.0;
    notifyListeners();
    if (!_inMemoryOnly) await _saveSettings();
  }

  Future<void> clearCache() async {
    _cache.clear();
    _avatarMemory.clear();
    if (!_inMemoryOnly) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_cachePrefKey);
      } catch (_) {}
    }
    notifyListeners();
  }

  void clearError() {
    if (lastError != null) {
      lastError = null;
      notifyListeners();
    }
  }

  Map<String, dynamic> jsConfigPayload({bool resetJudged = false}) {
    return <String, dynamic>{
      'enabled': isActive,
      'category': _category,
      'threshold': _threshold,
      'resetJudged': resetJudged,
    };
  }

  Future<Map<String, bool>> judgeAccounts(
    List<JevAccountCandidate> candidates,
  ) async {
    await ensureLoaded();
    if (!isActive || candidates.isEmpty) return const <String, bool>{};

    final activeCategory = _category;
    final activeThreshold = _threshold;
    final activeKey = _apiKey.trim();

    final result = <String, bool>{};
    final pending = <JevAccountCandidate>[];
    final seenKeys = <String>{};

    for (final c in candidates) {
      final user = c.username.trim();
      if (user.isEmpty) continue;
      final ckey = c.cacheKey(activeCategory);
      final hit = _cache[ckey];
      final needsAvatarUpgrade = hit != null && !hit.hasImage && c.hasInlineAvatarBase64;
      if (hit != null &&
          !needsAvatarUpgrade &&
          DateTime.now().difference(hit.at) <= _cacheMaxAge) {
        result[user] = hit.noul >= activeThreshold;
      } else if (seenKeys.add(ckey)) {
        pending.add(c);
      }
    }

    if (pending.isEmpty) return result;

    final batches = <List<JevAccountCandidate>>[
      for (var i = 0; i < pending.length; i += batchSize)
        pending.sublist(i, (i + batchSize).clamp(0, pending.length)),
    ];

    var cacheDirty = false;
    var index = 0;
    Future<void> worker() async {
      while (index < batches.length) {
        final batch = batches[index++];
        final avatars = await _prepareBatchAvatars(batch);
        final probs = await _queryBatch(
          batch,
          category: activeCategory,
          avatars: avatars,
          key: activeKey,
        );
        if (probs == null) continue;
        final now = DateTime.now();
        for (var i = 0; i < batch.length; i++) {
          final c = batch[i];
          final p = probs[c.username];
          if (p == null) continue;
          _cache[c.cacheKey(activeCategory)] = (
            noul: p,
            at: now,
            hasImage: avatars.containsKey(i),
          );
          result[c.username] = p >= activeThreshold;
          cacheDirty = true;
        }
      }
    }

    await Future.wait([
      for (var w = 0; w < (batches.length < 2 ? batches.length : 2); w++) worker(),
    ]);
    if (cacheDirty && !_inMemoryOnly) unawaited(_saveCache());
    return result;
  }

  Future<({bool ok, String message})> testConnection(
    String candidateKey, {
    String? candidateCategory,
  }) async {
    await ensureLoaded();
    final trimmed = candidateKey.trim();
    if (trimmed.isEmpty) {
      return (ok: false, message: 'TypeSafe API キーを入力してください');
    }
    final cat = normalizeCategory(candidateCategory ?? _category);
    final testIconB64 =
        base64Encode(makeSolidPng(width: avatarTargetPx, height: avatarTargetPx));
    final femaleMode = isFemalePresetCategory(cat);
    final sample = femaleMode
        ? <JevAccountCandidate>[
            JevAccountCandidate(
              username: 'hanako_sato_04',
              displayName: '佐藤 花子',
              avatarBase64: testIconB64,
              avatarFormat: 'png',
            ),
            JevAccountCandidate(
              username: 'taro_yamada_1998',
              displayName: '山田 太郎',
              avatarBase64: testIconB64,
              avatarFormat: 'png',
            ),
          ]
        : <JevAccountCandidate>[
            JevAccountCandidate(
              username: 'sample_match_01',
              displayName: '$cat 好き',
              bio: '$cat について発信しています',
              avatarBase64: testIconB64,
              avatarFormat: 'png',
            ),
            JevAccountCandidate(
              username: 'system_notice_bot',
              displayName: '公式お知らせBot',
              bio: '自動配信アカウント',
              avatarBase64: testIconB64,
              avatarFormat: 'png',
            ),
          ];

    final avatars = await _prepareBatchAvatars(sample);
    final beforeCost = _totalCostUsd;
    final probs = await _queryBatch(
      sample,
      category: cat,
      avatars: avatars,
      key: trimmed,
      recordError: true,
    );
    if (probs == null || probs.isEmpty) {
      return (ok: false, message: lastError ?? 'Jev からの応答を取得できませんでした');
    }
    final pA = ((probs[sample[0].username] ?? 0) * 100).round();
    final pB = ((probs[sample[1].username] ?? 0) * 100).round();
    final deltaUsd = math.max(0.0, _totalCostUsd - beforeCost);
    final lblA = femaleMode ? '佐藤花子' : '一致サンプル';
    final lblB = femaleMode ? '山田太郎' : '非一致サンプル';
    return (
      ok: true,
      message:
          'Jev に接続できました（分類「$cat」一致確率: $lblA $pA% / $lblB $pB% · 今回の通信費 ${formatCostCompact(deltaUsd)}）',
    );
  }

  Future<Map<int, PreparedAvatar>> _prepareBatchAvatars(
    List<JevAccountCandidate> batch,
  ) async {
    final out = <int, PreparedAvatar>{};
    await Future.wait([
      for (var i = 0; i < batch.length; i++)
        () async {
          final prepared = await _resolveAvatar(batch[i]);
          if (prepared != null) out[i] = prepared;
        }(),
    ]);
    return out;
  }

  Future<PreparedAvatar?> _resolveAvatar(JevAccountCandidate c) async {
    final id = c.avatarId;
    if (id.isNotEmpty) {
      final cached = _avatarMemory[id];
      if (cached != null) return cached;
    }

    final inlineB64 = _cleanBase64(c.avatarBase64);
    if (inlineB64 != null) {
      final prepared = (base64: inlineB64, format: _normalizeFormat(c.avatarFormat));
      if (id.isNotEmpty) _putAvatarMemory(id, prepared);
      return prepared;
    }

    final url = c.avatarUrl.trim();
    if (url.isEmpty) return null;
    try {
      final prepared = await _avatarPreparer(url);
      if (prepared != null && prepared.base64.isNotEmpty) {
        final clean = _cleanBase64(prepared.base64);
        if (clean != null) {
          final normalized = (
            base64: clean,
            format: _normalizeFormat(prepared.format),
          );
          if (id.isNotEmpty) _putAvatarMemory(id, normalized);
          return normalized;
        }
      }
    } catch (_) {}
    return null;
  }

  void _putAvatarMemory(String id, PreparedAvatar avatar) {
    if (_avatarMemory.length >= 200) {
      _avatarMemory.remove(_avatarMemory.keys.first);
    }
    _avatarMemory[id] = avatar;
  }

  static String? _cleanBase64(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty) return null;
    final comma = s.indexOf(',');
    if (s.startsWith('data:') && comma >= 0) {
      s = s.substring(comma + 1);
    }
    s = s.replaceAll(RegExp(r'\s+'), '');
    return s.length >= 32 ? s : null;
  }

  static String _normalizeFormat(String? fmt) {
    final lower = (fmt ?? '').trim().toLowerCase();
    if (lower == 'png' || lower.endsWith('/png')) return 'png';
    return 'jpg';
  }

  Future<Map<String, double>?> _queryBatch(
    List<JevAccountCandidate> batch, {
    required String category,
    required Map<int, PreparedAvatar> avatars,
    required String key,
    bool recordError = true,
  }) async {
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}${_nonceCounter++}';
    try {
      final hasImages = avatars.isNotEmpty;
      final res = await _poster(
        apiKey: key,
        body: buildRequestBody(
          batch,
          category: category,
          avatars: avatars,
          nonce: nonce,
        ),
        includeImageHeader: hasImages,
      );

      if (hasImages &&
          (res.statusCode == 400 ||
              res.statusCode == 415 ||
              res.statusCode == 422)) {
        final fallbackRes = await _poster(
          apiKey: key,
          body: buildRequestBody(
            batch,
            category: category,
            avatars: const {},
            nonce: '${nonce}_txt',
          ),
          includeImageHeader: false,
        );
        return _handleResponse(fallbackRes, batch, recordError: recordError);
      }
      return _handleResponse(res, batch, recordError: recordError);
    } catch (e) {
      final msg = 'Jev への通信に失敗しました: $e';
      if (recordError && lastError != msg) {
        lastError = msg;
        notifyListeners();
      }
      return null;
    }
  }

  Map<String, double>? _handleResponse(
    ({int statusCode, String body}) res,
    List<JevAccountCandidate> batch, {
    required bool recordError,
  }) {
    if (res.statusCode != 200) {
      final msg = switch (res.statusCode) {
        401 || 403 => 'Jev API キーが無効です（HTTP ${res.statusCode}）',
        402 => 'TypeSafe API のクレジット残高が不足しています（HTTP 402）',
        429 => 'Jev のリクエスト上限に達しました。しばらく待ってから再試行してください',
        _ => 'Jev エラー（HTTP ${res.statusCode}）',
      };
      if (recordError && lastError != msg) {
        lastError = msg;
        notifyListeners();
      }
      return null;
    }
    lastError = null;
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    _recordUsage(decoded, accountCount: batch.length);
    notifyListeners();
    return parseResponseProbabilities(decoded, batch);
  }

  void _recordUsage(
    Map<String, dynamic> responseJson, {
    required int accountCount,
  }) {
    final usage = responseJson['usage'];
    var inputTokens = 0;
    double? explicitUsd;
    if (usage is Map) {
      inputTokens =
          ((usage['input_tokens'] ?? usage['prompt_tokens'] ?? 0) as num)
              .toInt();
      final rawCost =
          usage['cost_usd'] ?? usage['total_cost'] ?? usage['cost'];
      if (rawCost is num && rawCost.isFinite && rawCost >= 0) {
        explicitUsd = rawCost.toDouble();
      }
    }
    final costUsd = explicitUsd ?? ((inputTokens / 1e6) * inputUsdPerMTok);
    _totalInputTokens += inputTokens;
    _totalApiCalls += 1;
    _totalJudgedAccounts += accountCount;
    _totalCostUsd += costUsd;

    _sessionInputTokens += inputTokens;
    _sessionApiCalls += 1;
    _sessionCostUsd += costUsd;

    if (!_inMemoryOnly) {
      unawaited(_saveSettings());
    }
  }

  static Map<String, dynamic> buildRequestBody(
    List<JevAccountCandidate> batch, {
    required String category,
    Map<int, PreparedAvatar> avatars = const {},
    String nonce = 'jev0',
  }) {
    final normCategory = normalizeCategory(category);
    final femaleMode = isFemalePresetCategory(normCategory);

    final labels = <String>[];
    for (final c in batch) {
      final lbl = c.platformLabel;
      if (!labels.contains(lbl)) labels.add(lbl);
    }
    final platformScope = labels.isEmpty
        ? 'SNS'
        : (labels.length == 1 ? labels.single : 'SNS (${labels.join(' / ')})');

    final state = StringBuffer();
    if (femaleMode) {
      state
        ..writeln(
          'Task: Judge whether each numbered $platformScope account is a FEMALE individual\'s personal account '
          'using BOTH its profile icon image (when provided in the question) and its @username, display_name, and bio/snippet (when provided).',
        )
        ..writeln(
          '- True (female personal account): '
          '(1) Profile icon shows a woman/girl or feminine personal portrait/selfie/avatar of a female user, OR '
          '(2) @username, display_name, or bio contains a Japanese or foreign female given name in kanji, hiragana, katakana, or romaji '
          '(e.g. 花子, 美咲, 結衣, 葵, 陽菜, 凛, さくら, みゆ, あや, まな, ゆい, りな, もも, なな, まい, えり, かな, みなみ, はるか, まりな, ゆか, ちひろ, あかり, ほのか, '
          'hanako, misaki, yui, aoi, hina, sakura, miyu, aya, mana, rina, momo, nana, mai, eri, kana, minami, haruka, marina, yuka, akari, honoka, etc.) '
          'or female self-identifiers (女子, 女の子, ママ, ちゃん, OL, JD, JK, ♀, she/her, girl, miss), '
          'WITHOUT male face/portrait or business/shop indicators.',
        )
        ..writeln(
          '- False (do NOT show — non-female): '
          'Male personal accounts (male face/portrait icon or male given name / 男子 / パパ / 俺 / 僕 / くん / Mr.), '
          'shops, cafes, salons, restaurants, brands, companies, schools, clubs, event/official/media/bot accounts '
          '(logos, storefronts, flyers, menus, products), '
          'or gender-unknown accounts where neither the profile icon nor the text indicates a female person '
          '(e.g. default grey silhouette, landscape, food, pet, or object icon paired with a gender-neutral handle).',
        )
        ..writeln()
        ..writeln('Accounts:');
    } else {
      final safeCat = normCategory.replaceAll('"', "'");
      state
        ..writeln(
          'Task: Judge whether each numbered $platformScope account matches the user-specified target category: "$safeCat"',
        )
        ..writeln(
          'Use ALL available clues: its profile icon image (when provided in the question), @username, display_name, and bio/snippet (when provided).',
        )
        ..writeln(
          '- True (matches "$safeCat"): The profile icon image, @username, display_name, or bio/snippet clearly indicates that this account belongs to or strongly matches the category "$safeCat".',
        )
        ..writeln(
          '- False (does NOT match "$safeCat"): The account belongs to a different category, is clearly unrelated, or lacks sufficient visual or textual evidence to conclude that it matches "$safeCat".',
        )
        ..writeln()
        ..writeln('Accounts:');
    }

    final assets = <String, Map<String, dynamic>>{};
    final questions = <String, Map<String, dynamic>>{};
    final safeCatQ = normCategory.replaceAll('"', "'");

    for (var i = 0; i < batch.length; i++) {
      final item = batch[i];
      final snsLabel = item.platformLabel;
      final u = item.username.trim().replaceAll('"', '');
      var d = item.displayName
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim()
          .replaceAll('"', "'");
      if (d.length > 80) d = d.substring(0, 80);
      final displayLabel = d.isEmpty ? '(none)' : d;
      var bio = item.bio
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim()
          .replaceAll('"', "'");
      if (bio.length > 140) bio = bio.substring(0, 140);

      if (bio.isEmpty) {
        state.writeln('#$i: [$snsLabel] @username="$u" | display_name="$displayLabel"');
      } else {
        state.writeln(
          '#$i: [$snsLabel] @username="$u" | display_name="$displayLabel" | bio="$bio"',
        );
      }

      final avatar = avatars[i];
      String iconClause;
      if (avatar != null && avatar.base64.isNotEmpty) {
        final ref = 'jevimg_${nonce}_$i';
        assets[ref] = {
          'type': 'image',
          'format': _normalizeFormat(avatar.format),
          'data_base64': avatar.base64,
        };
        iconClause = 'profile_icon: $ref';
      } else {
        iconClause = 'profile_icon: (unavailable)';
      }

      final bioClause = bio.isEmpty ? '' : ', bio: "$bio"';
      if (femaleMode) {
        questions['q_$i'] = {
          'type': 'noul',
          'instructions':
              'Account #$i ($snsLabel @$u, display_name: "$displayLabel"$bioClause), $iconClause — '
              'Is this a female person\'s personal $snsLabel account?',
          'criteria': {
            'true':
                'Personal $snsLabel account of a female individual (from profile icon and/or name/bio)',
            'false':
                'Male person, shop/brand/organization/club/bot, or gender-unknown account',
          },
        };
      } else {
        questions['q_$i'] = {
          'type': 'noul',
          'instructions':
              'Account #$i ($snsLabel @$u, display_name: "$displayLabel"$bioClause), $iconClause — '
              'Does this $snsLabel account match the target category "$safeCatQ"?',
          'criteria': {
            'true':
                'Account clearly matches the category "$safeCatQ" based on profile icon, @username, display_name, and/or bio',
            'false':
                'Account does not match "$safeCatQ" or lacks sufficient indication',
          },
        };
      }
    }

    return {
      'model': modelName,
      'state': state.toString().trimRight(),
      if (assets.isNotEmpty) 'assets': assets,
      'questions': questions,
    };
  }

  static Map<String, double> parseResponseProbabilities(
    Map<String, dynamic> json,
    List<JevAccountCandidate> batch,
  ) {
    final out = <String, double>{};
    final answers = json['answers'];
    if (answers is! Map) return out;
    for (var i = 0; i < batch.length; i++) {
      final raw = answers['q_$i'];
      if (raw is! Map) continue;
      double? prob = (raw['noul'] as num?)?.toDouble();
      if (prob == null && raw['probabilities'] is Map) {
        final probs = raw['probabilities'] as Map;
        prob = (probs['true'] as num?)?.toDouble();
      }
      if (prob != null && prob.isFinite) {
        out[batch[i].username] = prob.clamp(0.0, 1.0);
      }
    }
    return out;
  }

  static Future<({int statusCode, String body})> _defaultPostSystemOne({
    required String apiKey,
    required Map<String, dynamic> body,
    required bool includeImageHeader,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client
          .postUrl(Uri.parse(endpoint))
          .timeout(const Duration(seconds: 20));
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('Authorization', 'Bearer ${apiKey.trim()}');
      if (includeImageHeader) {
        req.headers.set('TypeSafe-Danger-Zone-Images', 'true');
      }
      final payloadBytes = utf8.encode(jsonEncode(body));
      req.contentLength = payloadBytes.length;
      req.add(payloadBytes);
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final respBody = await resp.transform(utf8.decoder).join();
      return (statusCode: resp.statusCode, body: respBody);
    } finally {
      client.close(force: true);
    }
  }

  static Future<PreparedAvatar?> defaultPrepareAvatar(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    final hostLower = uri.host.toLowerCase();
    final referer = (hostLower.contains('tiktok') ||
            hostLower.contains('musical.ly') ||
            hostLower.contains('byteimg'))
        ? 'https://www.tiktok.com/'
        : ((hostLower.contains('bsky.app') ||
                hostLower.contains('bsky.social') ||
                hostLower.contains('bsky.network'))
            ? 'https://bsky.app/'
            : (hostLower.contains('threads')
                ? 'https://www.threads.com/'
                : ((hostLower.contains('instagram') ||
                        hostLower.contains('fbcdn'))
                    ? 'https://www.instagram.com/'
                    : ((hostLower.contains('twimg.com') ||
                            hostLower.contains('x.com'))
                        ? 'https://x.com/'
                        : null))));

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    Uint8List bodyBytes;
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 6));
      req.headers.set('Accept', 'image/jpeg,image/png,image/webp,image/*,*/*;q=0.8');
      req.headers.set(
        'User-Agent',
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/136.0 Mobile Safari/537.36',
      );
      if (referer != null) {
        req.headers.set('Referer', referer);
      }
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        builder.add(chunk);
        if (builder.length > 4 * 1024 * 1024) break;
      }
      bodyBytes = builder.toBytes();
    } finally {
      client.close(force: true);
    }
    if (bodyBytes.isEmpty) return null;

    ui.Codec? codec;
    ui.Image? src;
    ui.Picture? picture;
    ui.Image? outImage;
    try {
      codec = await ui.instantiateImageCodec(bodyBytes);
      final frame = await codec.getNextFrame();
      src = frame.image;
      const target = avatarTargetPx;
      final t = target.toDouble();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, t, t),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF),
      );
      final sw = src.width.toDouble();
      final sh = src.height.toDouble();
      if (sw <= 0 || sh <= 0) return null;
      final scale = math.max(t / sw, t / sh);
      final dw = sw * scale;
      final dh = sh * scale;
      final dx = (t - dw) / 2;
      final dy = (t - dh) / 2;
      canvas.drawImageRect(
        src,
        ui.Rect.fromLTWH(0, 0, sw, sh),
        ui.Rect.fromLTWH(dx, dy, dw, dh),
        ui.Paint()..filterQuality = ui.FilterQuality.low,
      );
      picture = recorder.endRecording();
      outImage = await picture.toImage(target, target);
      final byteData =
          await outImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      final pngBytes = byteData.buffer
          .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
      return (base64: base64Encode(pngBytes), format: 'png');
    } finally {
      outImage?.dispose();
      picture?.dispose();
      src?.dispose();
      codec?.dispose();
    }
  }

  static Uint8List makeSolidPng({
    int width = avatarTargetPx,
    int height = avatarTargetPx,
    int r = 245,
    int g = 232,
    int b = 238,
  }) {
    final rowLen = 1 + width * 3;
    final raw = Uint8List(rowLen * height);
    for (var y = 0; y < height; y++) {
      final offset = y * rowLen;
      raw[offset] = 0;
      for (var x = 0; x < width; x++) {
        final px = offset + 1 + x * 3;
        raw[px] = r;
        raw[px + 1] = g;
        raw[px + 2] = b;
      }
    }
    final idatData = Uint8List.fromList(zlib.encode(raw));
    final ihdr = ByteData(13)
      ..setUint32(0, width)
      ..setUint32(4, height)
      ..setUint8(8, 8)
      ..setUint8(9, 2)
      ..setUint8(10, 0)
      ..setUint8(11, 0)
      ..setUint8(12, 0);

    final out = BytesBuilder(copy: false)
      ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      ..add(_pngChunk('IHDR', ihdr.buffer.asUint8List()))
      ..add(_pngChunk('IDAT', idatData))
      ..add(_pngChunk('IEND', const []));
    return out.toBytes();
  }

  static Uint8List _pngChunk(String type, List<int> data) {
    final typeBytes = ascii.encode(type);
    final lenBytes = ByteData(4)..setUint32(0, data.length);
    final crcInput = Uint8List(typeBytes.length + data.length)
      ..setRange(0, typeBytes.length, typeBytes)
      ..setRange(typeBytes.length, typeBytes.length + data.length, data);
    final crcBytes = ByteData(4)..setUint32(0, _crc32(crcInput));
    return (BytesBuilder(copy: false)
          ..add(lenBytes.buffer.asUint8List())
          ..add(typeBytes)
          ..add(data)
          ..add(crcBytes.buffer.asUint8List()))
        .toBytes();
  }

  static int _crc32(Uint8List bytes) {
    var crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc ^= b;
      for (var k = 0; k < 8; k++) {
        crc = (crc & 1) != 0 ? (0xEDB88320 ^ (crc >>> 1)) : (crc >>> 1);
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _settingsPrefKey,
        jsonEncode({
          'apiKey': _apiKey,
          'enabled': _enabled,
          'category': _category,
          'recentCategories': _recentCategories,
          'threshold': _threshold,
          'totalInputTokens': _totalInputTokens,
          'totalApiCalls': _totalApiCalls,
          'totalJudgedAccounts': _totalJudgedAccounts,
          'totalCostUsd': _totalCostUsd,
        }),
      );
    } catch (e) {
      debugPrint('Jev 設定の保存に失敗: $e');
    }
  }

  Future<void> _saveCache() async {
    try {
      if (_cache.length > _maxCacheEntries) {
        final sorted = _cache.entries.toList()
          ..sort((a, b) => b.value.at.compareTo(a.value.at));
        _cache
          ..clear()
          ..addEntries(sorted.take(_maxCacheEntries));
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cachePrefKey,
        jsonEncode({
          for (final entry in _cache.entries)
            entry.key: {
              'p': double.parse(entry.value.noul.toStringAsFixed(4)),
              't': entry.value.at.millisecondsSinceEpoch ~/ 1000,
              if (entry.value.hasImage) 'img': 1,
            },
        }),
      );
    } catch (_) {}
  }
}
