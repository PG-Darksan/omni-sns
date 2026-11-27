import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

typedef OmniWebViewProgressCallback = void Function(int progress);
typedef OmniWebViewPageStartedCallback = void Function(String url);
typedef OmniWebViewPageFinishedCallback = void Function(
  String url,
  String title,
  bool canGoBack,
  bool canGoForward,
  bool hadError,
);
typedef OmniWebViewTitleChangedCallback = void Function(String title);
typedef OmniWebViewHistoryChangedCallback = void Function(
  String url,
  bool canGoBack,
  bool canGoForward,
);
typedef OmniWebViewErrorCallback = void Function(
  String description,
  int errorCode,
);
typedef OmniWebViewExternalSchemeCallback = void Function(String url);
typedef OmniWebViewFollowDetectedCallback = void Function(
  String source,
  String service,
);
typedef OmniWebViewUnfollowDetectedCallback = void Function(
  String source,
  String service,
);
typedef OmniWebViewAccountIdentityCallback = void Function(
  String service,
  String handle,
  int? following,
  int? followers,
);
/// [activate] が true の場合は新規タブを開いた直後にそのタブへ切り替える（F/FW バッジのタップ等）。
typedef OmniWebViewOpenNewTabCallback = void Function(String url, bool activate);
typedef OmniWebViewJevGetConfigCallback = void Function();
typedef OmniWebViewJevCheckAccountsCallback = void Function(
  String reqId,
  String payloadJson,
);
typedef OmniWebViewJevStateCallback = void Function(
  bool active,
  int matched,
  int hidden,
  bool autoFetching,
);
typedef OmniWebViewAccountFilterGetConfigCallback = void Function();
typedef OmniWebViewAccountFilterStateCallback = void Function(
  bool active,
  int matched,
  int hidden,
  int pending,
  bool autoFetching,
);

/// Android ネイティブ WebView マルチプロファイル管理ブリッジ
class OmniWebViewManager {
  OmniWebViewManager._();

  static const String viewType = 'com.pgdarksan.omnisns/webview';
  static const MethodChannel _channel = MethodChannel(
    'com.pgdarksan.omnisns/webview_manager',
  );

  /// 端末の Android System WebView が Multi-Profile API に対応しているかを確認する。
  static Future<bool> isMultiProfileSupported() async {
    try {
      final supported =
          await _channel.invokeMethod<bool>('isMultiProfileSupported');
      return supported ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 全プロファイルの Cookie / WebStorage を消去する。
  static Future<void> clearAllCookies() async {
    try {
      await _channel.invokeMethod<bool>('clearAllCookies');
    } catch (_) {}
  }

  /// 指定プロファイルの Cookie / WebStorage のみを消去する。
  static Future<void> clearProfileData(String profileName) async {
    try {
      await _channel.invokeMethod<bool>(
        'clearProfileData',
        <String, dynamic>{'profileName': profileName},
      );
    } catch (_) {}
  }

  /// 指定プロファイル（Default 以外）をストレージごと削除する。
  static Future<void> deleteProfile(String profileName) async {
    try {
      await _channel.invokeMethod<bool>(
        'deleteProfile',
        <String, dynamic>{'profileName': profileName},
      );
    } catch (_) {}
  }

  /// Android Keystore (AES-256-GCM) に機密文字列を暗号化保存する。
  /// ネイティブチャネル非対応環境（テスト VM 等）では `false` を返す。
  static Future<bool> secureSetSecret(String key, String value) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'secureSetSecret',
        <String, dynamic>{'key': key, 'value': value},
      );
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Android Keystore (AES-256-GCM) から機密文字列を復号して読み出す。
  /// `(supported, value)` を返す。テスト VM 等でネイティブチャネル非対応時は `(false, null)`。
  static Future<(bool, String?)> secureGetSecret(String key) async {
    try {
      final val = await _channel.invokeMethod<String>(
        'secureGetSecret',
        <String, dynamic>{'key': key},
      );
      return (true, val);
    } on MissingPluginException {
      return (false, null);
    } catch (_) {
      return (false, null);
    }
  }

  /// Android Keystore に保存した機密文字列を削除する。
  static Future<bool> secureDeleteSecret(String key) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'secureDeleteSecret',
        <String, dynamic>{'key': key},
      );
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// 各アカウントタブに対応する Android ネイティブ WebView コントローラ
class OmniWebViewController {
  OmniWebViewController({
    required this.initialUrl,
    required this.profileName,
    required this.userAgent,
    this.serviceId = '',
    bool initiallyActive = false,
    this.onProgress,
    this.onPageStarted,
    this.onPageFinished,
    this.onTitleChanged,
    this.onHistoryChanged,
    this.onWebResourceError,
    this.onExternalScheme,
    this.onFollowDetected,
    this.onUnfollowDetected,
    this.onAccountIdentity,
    this.onOpenNewTab,
    this.onJevGetConfig,
    this.onJevCheckAccounts,
    this.onJevState,
    this.onAccountFilterGetConfig,
    this.onAccountFilterState,
  })  : _pendingUrl = initialUrl,
        _isActive = initiallyActive;

  final String initialUrl;
  final String profileName;
  final String userAgent;
  final String serviceId;

  final OmniWebViewProgressCallback? onProgress;
  final OmniWebViewPageStartedCallback? onPageStarted;
  final OmniWebViewPageFinishedCallback? onPageFinished;
  final OmniWebViewTitleChangedCallback? onTitleChanged;
  final OmniWebViewHistoryChangedCallback? onHistoryChanged;
  final OmniWebViewErrorCallback? onWebResourceError;
  final OmniWebViewExternalSchemeCallback? onExternalScheme;
  final OmniWebViewFollowDetectedCallback? onFollowDetected;
  final OmniWebViewUnfollowDetectedCallback? onUnfollowDetected;
  final OmniWebViewAccountIdentityCallback? onAccountIdentity;
  final OmniWebViewOpenNewTabCallback? onOpenNewTab;
  final OmniWebViewJevGetConfigCallback? onJevGetConfig;
  final OmniWebViewJevCheckAccountsCallback? onJevCheckAccounts;
  final OmniWebViewJevStateCallback? onJevState;
  final OmniWebViewAccountFilterGetConfigCallback? onAccountFilterGetConfig;
  final OmniWebViewAccountFilterStateCallback? onAccountFilterState;

  MethodChannel? _channel;
  String? _pendingUrl;
  bool _isActive;
  bool _pendingActiveSync = false;
  bool _disposed = false;

  /// 最後に観測した http(s) URL（PlatformView 再生成時の自動復元に使う）
  String? _lastKnownUrl;

  /// 一度でもネイティブ View を生成したか
  bool _hasCreatedView = false;

  /// 現在のネイティブ View から読み込みイベントを1件でも受信したか
  bool _sawLoadEvent = false;

  /// アクティブ化後に読み込みが始まらない場合の保険タイマー
  Timer? _activationWatchdog;

  static const Duration _activationWatchdogDelay = Duration(milliseconds: 2500);

  bool get isDisposed => _disposed;
  bool get isActive => _isActive;

  /// PlatformView 生成時にネイティブ側で即座に読み込む URL を返す（返した URL は消費される）。
  ///
  /// MethodChannel のアタッチを待たずに生成と同時に読み込みを開始することで、
  /// 新規タブの表示開始を早め、再生成された View が白紙のまま残る問題も防ぐ。
  String? takeCreationLoadUrl() {
    if (_disposed) return null;
    final pending = _pendingUrl;
    if (pending != null && pending.trim().isNotEmpty) {
      _pendingUrl = null;
      return pending.trim();
    }
    if (_hasCreatedView) {
      return _lastKnownUrl ?? initialUrl;
    }
    return null;
  }

  void attachPlatformView(int viewId) {
    if (_disposed) return;
    _hasCreatedView = true;
    _sawLoadEvent = false;
    _channel?.setMethodCallHandler(null);
    final ch = MethodChannel('com.pgdarksan.omnisns/webview_$viewId');
    ch.setMethodCallHandler(_handleNativeCall);
    _channel = ch;

    // 作成前からアタッチまでに setActive が呼ばれた場合のみネイティブ側へ追従通知する
    if (_pendingActiveSync) {
      _pendingActiveSync = false;
      setActive(_isActive, force: true);
    }

    final urlToLoad = _pendingUrl;
    _pendingUrl = null;
    if (urlToLoad != null && urlToLoad.isNotEmpty) {
      loadUrl(urlToLoad);
    }
    if (_isActive) {
      _armActivationWatchdog();
    }
  }

  /// Flutter TLHC では非表示タブでも Android View.isShown が true のままになるため、
  /// 現在表示中のアクティブタブかどうかを明示的にネイティブ側へ通知する。
  Future<void> setActive(bool active, {bool force = false}) async {
    if (_disposed) return;
    final changed = _isActive != active;
    _isActive = active;
    if (active) {
      // 未アタッチの場合は attachPlatformView 側でウォッチドッグを開始する
      if (_channel != null) _armActivationWatchdog();
    } else {
      _activationWatchdog?.cancel();
      _activationWatchdog = null;
    }
    if (!changed && !force) return;
    final ch = _channel;
    if (ch == null) {
      _pendingActiveSync = true;
      return;
    }
    try {
      await ch.invokeMethod<void>(
        'setActive',
        <String, dynamic>{'active': active},
      );
    } catch (_) {}
  }

  /// アクティブなタブでネイティブ View から読み込みイベントが一切届かない場合のみ、
  /// 一定時間後に自動で再読み込みする（手動で再読み込みボタンを押す必要をなくす保険）。
  void _armActivationWatchdog() {
    if (_disposed || _sawLoadEvent) return;
    _activationWatchdog?.cancel();
    _activationWatchdog = Timer(_activationWatchdogDelay, () {
      _activationWatchdog = null;
      if (_disposed || !_isActive || _sawLoadEvent || _channel == null) return;
      reload(fallbackUrl: _lastKnownUrl);
    });
  }

  void _markLoadEvent() {
    _sawLoadEvent = true;
    _activationWatchdog?.cancel();
    _activationWatchdog = null;
  }

  void _rememberUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      _lastKnownUrl = trimmed;
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (_disposed) return null;
    final args = call.arguments;
    final map = args is Map ? args : const <dynamic, dynamic>{};

    switch (call.method) {
      case 'onProgress':
        final progress = (map['progress'] as num?)?.toInt() ?? 0;
        _markLoadEvent();
        onProgress?.call(progress);
      case 'onPageStarted':
        final url = map['url'] as String? ?? '';
        _markLoadEvent();
        _rememberUrl(url);
        onPageStarted?.call(url);
      case 'onPageFinished':
        final url = map['url'] as String? ?? '';
        final title = map['title'] as String? ?? '';
        final canGoBack = map['canGoBack'] as bool? ?? false;
        final canGoForward = map['canGoForward'] as bool? ?? false;
        final hadError = map['hadError'] as bool? ?? false;
        _markLoadEvent();
        if (!hadError) _rememberUrl(url);
        onPageFinished?.call(url, title, canGoBack, canGoForward, hadError);
      case 'onTitleChanged':
        final title = map['title'] as String? ?? '';
        onTitleChanged?.call(title);
      case 'onHistoryChanged':
        final url = map['url'] as String? ?? '';
        final canGoBack = map['canGoBack'] as bool? ?? false;
        final canGoForward = map['canGoForward'] as bool? ?? false;
        _rememberUrl(url);
        onHistoryChanged?.call(url, canGoBack, canGoForward);
      case 'onWebResourceError':
        final description = map['description'] as String? ?? 'Unknown error';
        final errorCode = (map['errorCode'] as num?)?.toInt() ?? -1;
        _markLoadEvent();
        onWebResourceError?.call(description, errorCode);
      case 'onExternalScheme':
        final url = map['url'] as String? ?? '';
        if (url.isNotEmpty) {
          onExternalScheme?.call(url);
        }
      case 'onFollowDetected':
        final source = map['source'] as String? ?? 'auto';
        final service = map['service'] as String? ?? '';
        onFollowDetected?.call(source, service);
      case 'onUnfollowDetected':
        final source = map['source'] as String? ?? 'auto';
        final service = map['service'] as String? ?? '';
        onUnfollowDetected?.call(source, service);
      case 'onAccountIdentity':
        final service = map['service'] as String? ?? '';
        final handle = map['handle'] as String? ?? '';
        final following = (map['following'] as num?)?.toInt();
        final followers = (map['followers'] as num?)?.toInt();
        if (handle.isNotEmpty) {
          onAccountIdentity?.call(service, handle, following, followers);
        }
      case 'onOpenNewTab':
        final url = map['url'] as String? ?? '';
        final activate = map['activate'] == true;
        if (url.isNotEmpty) {
          onOpenNewTab?.call(url, activate);
        }
      case 'onJevGetConfig':
        onJevGetConfig?.call();
      case 'onJevCheckAccounts':
        final reqId = map['reqId'] as String? ?? '';
        final payload = map['payload'] as String? ?? '[]';
        if (reqId.isNotEmpty) {
          onJevCheckAccounts?.call(reqId, payload);
        }
      case 'onJevState':
        final active = map['active'] == true;
        final matched = (map['matched'] as num?)?.toInt() ?? 0;
        final hidden = (map['hidden'] as num?)?.toInt() ?? 0;
        final autoFetching = map['autoFetching'] == true;
        onJevState?.call(active, matched, hidden, autoFetching);
      case 'onAccountFilterGetConfig':
        onAccountFilterGetConfig?.call();
      case 'onAccountFilterState':
        final active = map['active'] == true;
        final matched = (map['matched'] as num?)?.toInt() ?? 0;
        final hidden = (map['hidden'] as num?)?.toInt() ?? 0;
        final pending = (map['pending'] as num?)?.toInt() ?? 0;
        final autoFetching = map['autoFetching'] == true;
        onAccountFilterState?.call(
          active,
          matched,
          hidden,
          pending,
          autoFetching,
        );
    }
    return null;
  }

  Future<void> loadUrl(String url) async {
    if (_disposed) return;
    final ch = _channel;
    if (ch == null) {
      _pendingUrl = url;
      return;
    }
    try {
      await ch.invokeMethod<void>('loadUrl', <String, dynamic>{'url': url});
    } catch (_) {}
  }

  Future<void> reload({String? fallbackUrl}) async {
    if (_disposed) return;
    final effectiveFallback =
        (fallbackUrl != null && fallbackUrl.trim().isNotEmpty)
            ? fallbackUrl.trim()
            : initialUrl;
    final ch = _channel;
    if (ch == null) {
      _pendingUrl = effectiveFallback;
      return;
    }
    try {
      await ch.invokeMethod<void>(
        'reload',
        <String, dynamic>{'fallbackUrl': effectiveFallback},
      );
    } catch (_) {}
  }

  Future<void> goBack() async {
    if (_disposed) return;
    try {
      await _channel?.invokeMethod<void>('goBack');
    } catch (_) {}
  }

  Future<void> goForward() async {
    if (_disposed) return;
    try {
      await _channel?.invokeMethod<void>('goForward');
    } catch (_) {}
  }

  Future<bool> canGoBack() async {
    if (_disposed) return false;
    try {
      return await _channel?.invokeMethod<bool>('canGoBack') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> canGoForward() async {
    if (_disposed) return false;
    try {
      return await _channel?.invokeMethod<bool>('canGoForward') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<String?> getTitle() async {
    if (_disposed) return null;
    try {
      return await _channel?.invokeMethod<String>('getTitle');
    } catch (_) {
      return null;
    }
  }

  Future<String?> getUrl() async {
    if (_disposed) return null;
    try {
      return await _channel?.invokeMethod<String>('getUrl');
    } catch (_) {
      return null;
    }
  }

  Future<void> scrollBy(double dx, double dy) async {
    if (_disposed) return;
    try {
      await _channel?.invokeMethod<void>(
        'scrollBy',
        <String, dynamic>{'dx': dx, 'dy': dy},
      );
    } catch (_) {}
  }

  Future<void> scrollToEdge({required bool toTop}) async {
    if (_disposed) return;
    try {
      await _channel?.invokeMethod<void>(
        'scrollToEdge',
        <String, dynamic>{'toTop': toTop},
      );
    } catch (_) {}
  }

  Future<void> setUserAgent(String userAgent, {bool reload = true}) async {
    if (_disposed) return;
    try {
      await _channel?.invokeMethod<void>(
        'setUserAgent',
        <String, dynamic>{'userAgent': userAgent, 'reload': reload},
      );
    } catch (_) {}
  }

  Future<void> evaluateJavascript(String script) async {
    if (_disposed) return;
    try {
      await _channel?.invokeMethod<void>(
        'evaluateJavascript',
        <String, dynamic>{'script': script},
      );
    } catch (_) {}
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _activationWatchdog?.cancel();
    _activationWatchdog = null;
    _channel?.setMethodCallHandler(null);
    _channel = null;
  }
}

/// Android ネイティブ `OmniWebView` を描画する PlatformView ウィジェット
class OmniWebViewWidget extends StatelessWidget {
  const OmniWebViewWidget({
    super.key,
    required this.controller,
  });

  final OmniWebViewController controller;

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: OmniWebViewManager.viewType,
      surfaceFactory: (context, platformController) {
        return AndroidViewSurface(
          controller: platformController as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        );
      },
      onCreatePlatformView: (params) {
        // 生成と同時にネイティブ側で読み込みを開始し、MethodChannel アタッチ待ちの遅延をなくす
        final creationLoadUrl = controller.takeCreationLoadUrl();
        return PlatformViewsService.initSurfaceAndroidView(
          id: params.id,
          viewType: OmniWebViewManager.viewType,
          layoutDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
          creationParams: <String, dynamic>{
            'profileName': controller.profileName,
            'initialUrl': controller.initialUrl,
            'userAgent': controller.userAgent,
            'serviceId': controller.serviceId,
            'isActive': controller.isActive,
            'autoLoad': creationLoadUrl != null,
            'autoLoadUrl': creationLoadUrl ?? '',
          },
          creationParamsCodec: const StandardMessageCodec(),
        )
          ..addOnPlatformViewCreatedListener((id) {
            params.onPlatformViewCreated(id);
            controller.attachPlatformView(id);
          })
          ..create();
      },
    );
  }
}
