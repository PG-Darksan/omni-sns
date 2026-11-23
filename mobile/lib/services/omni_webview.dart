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
typedef OmniWebViewFollowDetectedCallback = void Function(String source);
typedef OmniWebViewAccountIdentityCallback = void Function(
  String service,
  String handle,
  int? following,
  int? followers,
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
}

/// 各アカウントタブに対応する Android ネイティブ WebView コントローラ
class OmniWebViewController {
  OmniWebViewController({
    required this.initialUrl,
    required this.profileName,
    required this.userAgent,
    this.onProgress,
    this.onPageStarted,
    this.onPageFinished,
    this.onTitleChanged,
    this.onHistoryChanged,
    this.onWebResourceError,
    this.onExternalScheme,
    this.onFollowDetected,
    this.onAccountIdentity,
  }) : _pendingUrl = initialUrl;

  final String initialUrl;
  final String profileName;
  final String userAgent;

  final OmniWebViewProgressCallback? onProgress;
  final OmniWebViewPageStartedCallback? onPageStarted;
  final OmniWebViewPageFinishedCallback? onPageFinished;
  final OmniWebViewTitleChangedCallback? onTitleChanged;
  final OmniWebViewHistoryChangedCallback? onHistoryChanged;
  final OmniWebViewErrorCallback? onWebResourceError;
  final OmniWebViewExternalSchemeCallback? onExternalScheme;
  final OmniWebViewFollowDetectedCallback? onFollowDetected;
  final OmniWebViewAccountIdentityCallback? onAccountIdentity;

  MethodChannel? _channel;
  String? _pendingUrl;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  void attachPlatformView(int viewId) {
    if (_disposed) return;
    _channel?.setMethodCallHandler(null);
    final ch = MethodChannel('com.pgdarksan.omnisns/webview_$viewId');
    ch.setMethodCallHandler(_handleNativeCall);
    _channel = ch;

    final urlToLoad = _pendingUrl;
    _pendingUrl = null;
    if (urlToLoad != null && urlToLoad.isNotEmpty) {
      loadUrl(urlToLoad);
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (_disposed) return null;
    final args = call.arguments;
    final map = args is Map ? args : const <dynamic, dynamic>{};

    switch (call.method) {
      case 'onProgress':
        final progress = (map['progress'] as num?)?.toInt() ?? 0;
        onProgress?.call(progress);
      case 'onPageStarted':
        final url = map['url'] as String? ?? '';
        onPageStarted?.call(url);
      case 'onPageFinished':
        final url = map['url'] as String? ?? '';
        final title = map['title'] as String? ?? '';
        final canGoBack = map['canGoBack'] as bool? ?? false;
        final canGoForward = map['canGoForward'] as bool? ?? false;
        final hadError = map['hadError'] as bool? ?? false;
        onPageFinished?.call(url, title, canGoBack, canGoForward, hadError);
      case 'onTitleChanged':
        final title = map['title'] as String? ?? '';
        onTitleChanged?.call(title);
      case 'onHistoryChanged':
        final url = map['url'] as String? ?? '';
        final canGoBack = map['canGoBack'] as bool? ?? false;
        final canGoForward = map['canGoForward'] as bool? ?? false;
        onHistoryChanged?.call(url, canGoBack, canGoForward);
      case 'onWebResourceError':
        final description = map['description'] as String? ?? 'Unknown error';
        final errorCode = (map['errorCode'] as num?)?.toInt() ?? -1;
        onWebResourceError?.call(description, errorCode);
      case 'onExternalScheme':
        final url = map['url'] as String? ?? '';
        if (url.isNotEmpty) {
          onExternalScheme?.call(url);
        }
      case 'onFollowDetected':
        final source = map['source'] as String? ?? 'auto';
        onFollowDetected?.call(source);
      case 'onAccountIdentity':
        final service = map['service'] as String? ?? '';
        final handle = map['handle'] as String? ?? '';
        final following = (map['following'] as num?)?.toInt();
        final followers = (map['followers'] as num?)?.toInt();
        if (handle.isNotEmpty) {
          onAccountIdentity?.call(service, handle, following, followers);
        }
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

  void dispose() {
    if (_disposed) return;
    _disposed = true;
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
        return PlatformViewsService.initSurfaceAndroidView(
          id: params.id,
          viewType: OmniWebViewManager.viewType,
          layoutDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
          creationParams: <String, dynamic>{
            'profileName': controller.profileName,
            'initialUrl': controller.initialUrl,
            'userAgent': controller.userAgent,
            'autoLoad': false,
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
