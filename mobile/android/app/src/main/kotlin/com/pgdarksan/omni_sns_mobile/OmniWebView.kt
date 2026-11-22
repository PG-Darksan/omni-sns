package com.pgdarksan.omni_sns_mobile

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.text.InputType
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewStructure
import android.view.Window
import android.view.autofill.AutofillManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.webkit.CookieManager
import android.webkit.GeolocationPermissions
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import androidx.webkit.Profile
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.ConcurrentHashMap

/**
 * チャット・DM入力欄などパスワード入力欄以外では Android Autofill（Google パスワードマネージャー）を
 * 起動させないカスタム WebView。
 */
@SuppressLint("ViewConstructor")
class OmniWebView(context: Context) : WebView(context) {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var allowAutofillForCurrentFocus: Boolean = false

    @Volatile
    private var jsIndicatesAuthField: Boolean = false

    fun applyAutofillAllowed(allowed: Boolean, fromJs: Boolean = false) {
        if (fromJs) {
            jsIndicatesAuthField = allowed
        }
        allowAutofillForCurrentFocus = allowed

        val applyUi = Runnable {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val targetFlag = if (allowed) {
                    View.IMPORTANT_FOR_AUTOFILL_YES
                } else {
                    View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
                }
                if (importantForAutofill != targetFlag) {
                    importantForAutofill = targetFlag
                }
                if (!allowed) {
                    try {
                        context.getSystemService(AutofillManager::class.java)?.cancel()
                    } catch (_: Throwable) {
                    }
                }
            }
        }

        if (Looper.myLooper() == Looper.getMainLooper()) {
            applyUi.run()
        } else {
            mainHandler.post(applyUi)
        }
    }

    override fun onProvideAutofillVirtualStructure(structure: ViewStructure, flags: Int) {
        if (!allowAutofillForCurrentFocus) {
            // パスワード / ログイン欄以外では OS の Autofill サービスへノードを渡さない
            return
        }
        super.onProvideAutofillVirtualStructure(structure, flags)
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        val conn = super.onCreateInputConnection(outAttrs)
        val inputType = outAttrs.inputType
        val cls = inputType and InputType.TYPE_MASK_CLASS
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        val isPasswordInput = when (cls) {
            InputType.TYPE_CLASS_TEXT ->
                variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            InputType.TYPE_CLASS_NUMBER ->
                variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }

        if (isPasswordInput) {
            applyAutofillAllowed(true)
        } else if (!jsIndicatesAuthField) {
            applyAutofillAllowed(false)
        }
        return conn
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // FlutterView は既定で IMPORTANT_FOR_AUTOFILL_YES_EXCLUDE_DESCENDANTS を設定し
            // 子 PlatformView のパスワード Autofill まで遮断する問題があるため解除しておく。
            // 非パスワード欄の抑制は OmniWebView 自身で厳密に制御する。
            var parentView = parent
            while (parentView != null) {
                if (parentView is FlutterView) {
                    parentView.importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_YES
                    break
                }
                parentView = parentView.parent
            }
        }
    }
}

private class OmniAutofillBridge(private val webView: OmniWebView) {
    @JavascriptInterface
    fun setAutofillAllowed(allowed: Boolean) {
        webView.applyAutofillAllowed(allowed, fromJs = true)
    }
}

/**
 * 全 WebView インスタンス・マルチプロファイル・ファイルピッカーを一元管理するマネージャ。
 */
class OmniWebViewManager(
    private val activity: Activity,
    private val messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    companion object {
        const val VIEW_TYPE = "com.pgdarksan.omnisns/webview"
        const val MANAGER_CHANNEL = "com.pgdarksan.omnisns/webview_manager"
        const val FILE_CHOOSER_REQUEST_CODE = 42071
        private const val TAG = "OmniWebViewManager"

        /**
         * 全フレーム（iframe含む）のドキュメント開始前に注入する Autofill ガードスクリプト。
         * パスワード入力欄・ログインフォームの認証欄にフォーカスした場合のみ Autofill を許可し、
         * DM欄・チャット欄・検索欄などの通常入力欄では Google パスワードマネージャーを抑止する。
         */
        val AUTOFILL_GUARD_JS: String = """
            (function() {
              if (window.__omniAutofillGuardInstalled) return;
              window.__omniAutofillGuardInstalled = true;

              var NON_AUTH_HINT_RE = /(message|msg|chat|dm|reply|comment|post|tweet|caption|bio|status|search|query|filter|compose|note|subject|body|メッセージ|チャット|返信|コメント|投稿|検索|送信|つぶやき|入力)/i;
              var AUTH_AUTOCOMPLETE_TOKENS = {
                'current-password': true,
                'new-password': true,
                'one-time-code': true,
                'username': true,
                'webauthn': true
              };

              function getElementFromEvent(e) {
                var target = null;
                if (e && typeof e.composedPath === 'function') {
                  var path = e.composedPath();
                  if (path && path.length > 0) target = path[0];
                }
                if (!target && e) target = e.target;
                if (!target) return null;
                if (target.nodeType !== 1) target = target.parentElement;
                return target;
              }

              function findEditable(node) {
                if (!node || typeof node.closest !== 'function') return null;
                return node.closest('input, textarea, [contenteditable="true"], [contenteditable=""], [contenteditable="plaintext-only"], [role="textbox"]');
              }

              function isVisible(el) {
                if (!el || !el.isConnected) return false;
                try {
                  var style = window.getComputedStyle(el);
                  if (!style || style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
                    return false;
                  }
                  var rect = el.getBoundingClientRect();
                  return rect.width > 1 && rect.height > 1;
                } catch (_) {
                  return false;
                }
              }

              function hasVisiblePasswordInScope(root) {
                if (!root || typeof root.querySelectorAll !== 'function') return false;
                try {
                  var list = root.querySelectorAll('input[type="password"]');
                  for (var i = 0; i < list.length; i++) {
                    if (isVisible(list[i])) return true;
                  }
                } catch (_) {}
                return false;
              }

              function hasNonAuthHint(el) {
                var combined = [
                  el.getAttribute('name') || '',
                  el.getAttribute('id') || '',
                  el.getAttribute('placeholder') || '',
                  el.getAttribute('aria-label') || '',
                  el.getAttribute('data-testid') || ''
                ].join(' ');
                return NON_AUTH_HINT_RE.test(combined);
              }

              function isAuthInputElement(el) {
                if (!el || !el.tagName) return false;
                var tag = el.tagName.toUpperCase();

                // textarea や contenteditable（Instagram/Discord/Bluesky/Threads 等のDM・チャット欄）は常に非認証欄
                if (tag === 'TEXTAREA') return false;
                if (el.isContentEditable) return false;
                var ce = el.getAttribute('contenteditable');
                if (ce !== null && ce.toLowerCase() !== 'false') return false;
                if (tag !== 'INPUT') return false;

                var type = (el.getAttribute('type') || el.type || 'text').toLowerCase();

                // パスワード入力欄は常に許可
                if (type === 'password') return true;

                // 検索・URL・数値・チェックボックス等は不可
                if (type !== 'text' && type !== 'email' && type !== 'tel') {
                  return false;
                }

                // 検索ロールやチャット/メッセージ系のヒントがある入力欄は不可
                var role = (el.getAttribute('role') || '').toLowerCase();
                if (role === 'searchbox' || role === 'combobox') return false;
                if (hasNonAuthHint(el)) return false;

                // 明示的な認証系 autocomplete トークン
                var ac = (el.getAttribute('autocomplete') || '').toLowerCase().trim();
                if (ac) {
                  var tokens = ac.split(/\s+/);
                  for (var i = 0; i < tokens.length; i++) {
                    if (AUTH_AUTOCOMPLETE_TOKENS[tokens[i]]) return true;
                  }
                }

                // 同一フォーム内に可視のパスワード欄がある場合のみ、ログインID/メール欄として許可
                if (el.form && hasVisiblePasswordInScope(el.form)) {
                  return true;
                }

                // フォームタグを使わないSPAログイン画面（最大6階層上のコンテナに可視パスワード欄があるか）
                var cur = el.parentElement;
                for (var depth = 0; cur && depth < 6; depth++) {
                  if (hasVisiblePasswordInScope(cur)) return true;
                  cur = cur.parentElement;
                }

                return false;
              }

              function markNonAuthEditable(el) {
                if (!el || !el.tagName) return;
                try {
                  var curAc = (el.getAttribute('autocomplete') || '').toLowerCase();
                  if (!curAc || curAc === 'on') {
                    el.setAttribute('autocomplete', 'off');
                  }
                } catch (_) {}
              }

              var lastSent = null;
              var lastSentAt = 0;
              function notifyNative(allowed, force) {
                var now = Date.now();
                if (!force && lastSent === allowed && (now - lastSentAt) < 150) return;
                lastSent = allowed;
                lastSentAt = now;
                try {
                  if (window.OmniAutofillBridge && typeof window.OmniAutofillBridge.setAutofillAllowed === 'function') {
                    window.OmniAutofillBridge.setAutofillAllowed(!!allowed);
                  }
                } catch (_) {}
              }

              function evaluateElement(node, force) {
                var editable = findEditable(node);
                if (!editable) {
                  notifyNative(false, force);
                  return;
                }
                var allowed = isAuthInputElement(editable);
                if (!allowed) {
                  markNonAuthEditable(editable);
                }
                notifyNative(allowed, force);
              }

              document.addEventListener('pointerdown', function(e) {
                evaluateElement(getElementFromEvent(e), true);
              }, true);

              document.addEventListener('touchstart', function(e) {
                evaluateElement(getElementFromEvent(e), true);
              }, { capture: true, passive: true });

              document.addEventListener('focusin', function(e) {
                evaluateElement(getElementFromEvent(e), true);
              }, true);

              document.addEventListener('focusout', function() {
                setTimeout(function() {
                  var active = document.activeElement;
                  if (!active || active === document.body || active === document.documentElement) {
                    notifyNative(false, true);
                  } else {
                    evaluateElement(active, true);
                  }
                }, 0);
              }, true);

              // 初期状態は必ず無効
              notifyNative(false, true);
            })();
        """.trimIndent()
    }

    private val channel = MethodChannel(messenger, MANAGER_CHANNEL)
    private val activeViews = ConcurrentHashMap<Int, OmniWebViewPlatformView>()
    private val pendingDeleteProfiles = ConcurrentHashMap.newKeySet<String>()
    private var filePathCallback: ValueCallback<Array<Uri>>? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    fun createViewFactory(): PlatformViewFactory {
        return OmniWebViewFactory(activity, messenger, this)
    }

    fun isMultiProfileSupported(): Boolean {
        return try {
            WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
        } catch (_: Throwable) {
            false
        }
    }

    internal fun registerView(viewId: Int, view: OmniWebViewPlatformView) {
        activeViews[viewId] = view
    }

    internal fun unregisterView(viewId: Int, profileName: String) {
        activeViews.remove(viewId)
        if (pendingDeleteProfiles.contains(profileName)) {
            tryDeleteProfileIfUnused(profileName)
        }
    }

    internal fun launchFileChooser(
        callback: ValueCallback<Array<Uri>>,
        params: WebChromeClient.FileChooserParams,
    ): Boolean {
        filePathCallback?.onReceiveValue(null)
        filePathCallback = callback
        return try {
            val intent = params.createIntent().apply {
                if (params.mode == WebChromeClient.FileChooserParams.MODE_OPEN_MULTIPLE) {
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                }
            }
            activity.startActivityForResult(intent, FILE_CHOOSER_REQUEST_CODE)
            true
        } catch (_: ActivityNotFoundException) {
            filePathCallback = null
            false
        } catch (_: Throwable) {
            filePathCallback = null
            false
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != FILE_CHOOSER_REQUEST_CODE) return false
        val callback = filePathCallback
        filePathCallback = null
        if (callback == null) return true

        var results: Array<Uri>? = null
        if (resultCode == Activity.RESULT_OK && data != null) {
            val clipData = data.clipData
            if (clipData != null && clipData.itemCount > 0) {
                val uris = ArrayList<Uri>(clipData.itemCount)
                for (i in 0 until clipData.itemCount) {
                    clipData.getItemAt(i).uri?.let { uris.add(it) }
                }
                if (uris.isNotEmpty()) {
                    results = uris.toTypedArray()
                }
            } else {
                results = WebChromeClient.FileChooserParams.parseResult(resultCode, data)
            }
        }
        callback.onReceiveValue(results)
        return true
    }

    fun handleBackForFullscreen(): Boolean {
        for (view in activeViews.values) {
            if (view.exitFullscreenIfActive()) {
                return true
            }
        }
        return false
    }

    fun destroy() {
        channel.setMethodCallHandler(null)
        filePathCallback?.onReceiveValue(null)
        filePathCallback = null
        activeViews.values.toList().forEach { it.dispose() }
        activeViews.clear()
    }

    private fun isProfileInUse(profileName: String): Boolean {
        return activeViews.values.any { it.appliedProfileName == profileName }
    }

    private fun tryDeleteProfileIfUnused(profileName: String) {
        if (!isMultiProfileSupported()) return
        if (profileName.isEmpty() || profileName == Profile.DEFAULT_PROFILE_NAME) {
            pendingDeleteProfiles.remove(profileName)
            return
        }
        if (isProfileInUse(profileName)) {
            return
        }
        mainHandler.post {
            if (isProfileInUse(profileName)) return@post
            try {
                val store = ProfileStore.getInstance()
                if (store.getAllProfileNames().contains(profileName)) {
                    store.deleteProfile(profileName)
                }
                pendingDeleteProfiles.remove(profileName)
            } catch (e: Throwable) {
                Log.w(TAG, "deleteProfile deferred/failed for $profileName: ${e.message}")
            }
        }
    }

    private fun clearProfileDataInternal(profileName: String, onDone: () -> Unit) {
        val multi = isMultiProfileSupported()
        try {
            if (multi && profileName.isNotEmpty() && profileName != Profile.DEFAULT_PROFILE_NAME) {
                val profile = ProfileStore.getInstance().getProfile(profileName)
                if (profile != null) {
                    profile.webStorage.deleteAllData()
                    profile.cookieManager.removeAllCookies {
                        profile.cookieManager.flush()
                        onDone()
                    }
                    return
                }
            }
            WebStorage.getInstance().deleteAllData()
            val cm = CookieManager.getInstance()
            cm.removeAllCookies {
                cm.flush()
                onDone()
            }
        } catch (_: Throwable) {
            onDone()
        }
    }

    private fun clearAllCookiesInternal(onDone: () -> Unit) {
        val cmDefault = CookieManager.getInstance()
        try {
            WebStorage.getInstance().deleteAllData()
        } catch (_: Throwable) {
        }

        if (!isMultiProfileSupported()) {
            cmDefault.removeAllCookies {
                cmDefault.flush()
                onDone()
            }
            return
        }

        val profileNames = try {
            ProfileStore.getInstance().getAllProfileNames()
        } catch (_: Throwable) {
            emptyList()
        }

        val targets = profileNames.distinct().ifEmpty { listOf(Profile.DEFAULT_PROFILE_NAME) }
        var remaining = targets.size

        fun tick() {
            remaining -= 1
            if (remaining <= 0) {
                onDone()
            }
        }

        for (name in targets) {
            try {
                val profile = ProfileStore.getInstance().getProfile(name)
                if (profile != null) {
                    profile.webStorage.deleteAllData()
                    profile.cookieManager.removeAllCookies {
                        profile.cookieManager.flush()
                        tick()
                    }
                } else {
                    tick()
                }
            } catch (_: Throwable) {
                tick()
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isMultiProfileSupported" -> {
                result.success(isMultiProfileSupported())
            }
            "clearAllCookies" -> {
                clearAllCookiesInternal {
                    mainHandler.post { result.success(true) }
                }
            }
            "clearProfileData" -> {
                val profileName = call.argument<String>("profileName") ?: Profile.DEFAULT_PROFILE_NAME
                clearProfileDataInternal(profileName) {
                    mainHandler.post { result.success(true) }
                }
            }
            "deleteProfile" -> {
                val profileName = call.argument<String>("profileName") ?: ""
                if (profileName.isNotEmpty() && profileName != Profile.DEFAULT_PROFILE_NAME && isMultiProfileSupported()) {
                    // 先にCookie/WebStorageも消去し、対象WebViewの破棄後にプロファイル本体を削除する
                    clearProfileDataInternal(profileName) {
                        pendingDeleteProfiles.add(profileName)
                        activeViews.values
                            .filter { it.appliedProfileName == profileName }
                            .forEach { it.dispose() }
                        tryDeleteProfileIfUnused(profileName)
                        mainHandler.post { result.success(true) }
                    }
                } else {
                    result.success(false)
                }
            }
            else -> result.notImplemented()
        }
    }
}

private class OmniWebViewFactory(
    private val activity: Activity,
    private val messenger: BinaryMessenger,
    private val manager: OmniWebViewManager,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?> ?: emptyMap()
        return OmniWebViewPlatformView(activity, messenger, manager, viewId, params)
    }
}

class OmniWebViewPlatformView(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val manager: OmniWebViewManager,
    private val viewId: Int,
    creationParams: Map<String, Any?>,
) : PlatformView, MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "OmniWebViewPlatformView"
        private val AUTH_POPUP_REGEX = Regex(
            "(accounts\\.google\\.com|appleid\\.apple\\.com|login\\.microsoftonline\\.com|login\\.live\\.com|facebook\\.com/(v[0-9.]+/)?dialog|oauth|authorize|signin|sign-in|login|log-in|auth|sso)",
            RegexOption.IGNORE_CASE,
        )
    }

    private val channel = MethodChannel(messenger, "com.pgdarksan.omnisns/webview_$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())
    private val webView: OmniWebView
    val appliedProfileName: String
    private val userAgent: String

    private var disposed = false
    private var popupDialog: Dialog? = null
    private var popupWebView: OmniWebView? = null
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null

    init {
        val requestedProfile = (creationParams["profileName"] as? String)?.trim().orEmpty()
        val initialUrl = (creationParams["initialUrl"] as? String)?.trim().orEmpty()
        userAgent = (creationParams["userAgent"] as? String)?.trim().orEmpty().ifEmpty {
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36"
        }

        // 1. WebView を生成（Activity コンテキストを使用）
        webView = OmniWebView(activity)

        // 2. 【最重要】getSettings() / loadUrl() より前に独立プロファイルを割り当てる
        var resolvedProfile = Profile.DEFAULT_PROFILE_NAME
        if (manager.isMultiProfileSupported() &&
            requestedProfile.isNotEmpty() &&
            requestedProfile != Profile.DEFAULT_PROFILE_NAME
        ) {
            try {
                ProfileStore.getInstance().getOrCreateProfile(requestedProfile)
                WebViewCompat.setProfile(webView, requestedProfile)
                resolvedProfile = requestedProfile
            } catch (e: Throwable) {
                Log.w(TAG, "WebViewCompat.setProfile failed for $requestedProfile: ${e.message}")
            }
        }
        appliedProfileName = resolvedProfile

        // 3. プロファイル専用の CookieManager を有効化（OAuth 用サードパーティCookie含む）
        configureCookies(webView)

        // 4. WebSettings / Autofill ガード / Client 設定
        configureWebViewSettings(webView, userAgent)
        attachAutofillGuard(webView)
        webView.applyAutofillAllowed(false)

        webView.webViewClient = createMainWebViewClient()
        webView.webChromeClient = createMainWebChromeClient()

        channel.setMethodCallHandler(this)
        manager.registerView(viewId, this)

        val autoLoad = creationParams["autoLoad"] as? Boolean ?: false
        if (autoLoad && initialUrl.isNotEmpty()) {
            webView.loadUrl(initialUrl)
        }
    }

    private fun configureCookies(target: WebView) {
        val cm = try {
            if (manager.isMultiProfileSupported()) {
                WebViewCompat.getProfile(target).cookieManager
            } else {
                CookieManager.getInstance()
            }
        } catch (_: Throwable) {
            CookieManager.getInstance()
        }
        cm.setAcceptCookie(true)
        cm.setAcceptThirdPartyCookies(target, true)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebViewSettings(target: WebView, ua: String) {
        target.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            mediaPlaybackRequiresUserGesture = false
            javaScriptCanOpenWindowsAutomatically = true
            setSupportMultipleWindows(true)
            loadWithOverviewMode = true
            useWideViewPort = true
            builtInZoomControls = true
            displayZoomControls = false
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            @Suppress("DEPRECATION")
            saveFormData = false
            userAgentString = ua
        }
    }

    @SuppressLint("AddJavascriptInterface")
    private fun attachAutofillGuard(target: OmniWebView) {
        target.addJavascriptInterface(OmniAutofillBridge(target), "OmniAutofillBridge")
        try {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                WebViewCompat.addDocumentStartJavaScript(
                    target,
                    OmniWebViewManager.AUTOFILL_GUARD_JS,
                    setOf("*"),
                )
            }
        } catch (e: Throwable) {
            Log.w(TAG, "addDocumentStartJavaScript failed: ${e.message}")
        }
    }

    private fun injectAutofillGuardFallback(target: WebView) {
        try {
            target.evaluateJavascript(OmniWebViewManager.AUTOFILL_GUARD_JS, null)
        } catch (_: Throwable) {
        }
    }

    private fun createMainWebViewClient(): WebViewClient {
        return object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest,
            ): Boolean {
                val url = request.url?.toString() ?: return true
                val scheme = request.url?.scheme?.lowercase() ?: return true
                if (scheme == "http" || scheme == "https") {
                    return false
                }
                if (scheme == "mailto" || scheme == "tel") {
                    invokeDart("onExternalScheme", mapOf("url" to url))
                }
                return true
            }

            override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) {
                super.onPageStarted(view, url, favicon)
                webView.applyAutofillAllowed(false)
                invokeDart("onPageStarted", mapOf("url" to (url ?: "")))
            }

            override fun onPageFinished(view: WebView, url: String?) {
                super.onPageFinished(view, url)
                injectAutofillGuardFallback(view)
                invokeDart(
                    "onPageFinished",
                    mapOf(
                        "url" to (url ?: view.url ?: ""),
                        "title" to (view.title ?: ""),
                        "canGoBack" to view.canGoBack(),
                        "canGoForward" to view.canGoForward(),
                    ),
                )
            }

            override fun doUpdateVisitedHistory(view: WebView?, url: String?, isReload: Boolean) {
                super.doUpdateVisitedHistory(view, url, isReload)
                if (view == null) return
                invokeDart(
                    "onHistoryChanged",
                    mapOf(
                        "url" to (url ?: view.url ?: ""),
                        "canGoBack" to view.canGoBack(),
                        "canGoForward" to view.canGoForward(),
                    ),
                )
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                super.onReceivedError(view, request, error)
                if (!request.isForMainFrame) return
                val desc = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    error.description?.toString() ?: "Unknown error"
                } else {
                    "Page load error"
                }
                val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    error.errorCode
                } else {
                    -1
                }
                invokeDart(
                    "onWebResourceError",
                    mapOf("description" to desc, "errorCode" to code),
                )
            }
        }
    }

    private fun createMainWebChromeClient(): WebChromeClient {
        return object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                super.onProgressChanged(view, newProgress)
                invokeDart("onProgress", mapOf("progress" to newProgress))
            }

            override fun onReceivedTitle(view: WebView?, title: String?) {
                super.onReceivedTitle(view, title)
                if (!title.isNullOrEmpty()) {
                    invokeDart("onTitleChanged", mapOf("title" to title))
                }
            }

            override fun onPermissionRequest(request: PermissionRequest) {
                mainHandler.post {
                    try {
                        request.grant(request.resources)
                    } catch (_: Throwable) {
                    }
                }
            }

            override fun onGeolocationPermissionsShowPrompt(
                origin: String,
                callback: GeolocationPermissions.Callback,
            ) {
                callback.invoke(origin, true, true)
            }

            override fun onShowFileChooser(
                webView: WebView,
                filePathCallback: ValueCallback<Array<Uri>>,
                fileChooserParams: FileChooserParams,
            ): Boolean {
                return manager.launchFileChooser(filePathCallback, fileChooserParams)
            }

            override fun onShowCustomView(view: View?, callback: CustomViewCallback?) {
                if (view == null) return
                exitFullscreenIfActive()
                customView = view
                customViewCallback = callback
                val decor = activity.window?.decorView as? FrameLayout ?: return
                decor.addView(
                    view,
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    ),
                )
            }

            override fun onHideCustomView() {
                exitFullscreenIfActive()
            }

            override fun onCreateWindow(
                view: WebView,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: Message?,
            ): Boolean {
                val transport = resultMsg?.obj as? WebView.WebViewTransport ?: return false
                closePopup()

                val child = OmniWebView(activity)
                // 親と同じプロファイルを即座に継承し、OAuth ログイン等のCookie分離を保つ
                if (manager.isMultiProfileSupported() &&
                    appliedProfileName.isNotEmpty() &&
                    appliedProfileName != Profile.DEFAULT_PROFILE_NAME
                ) {
                    try {
                        ProfileStore.getInstance().getOrCreateProfile(appliedProfileName)
                        WebViewCompat.setProfile(child, appliedProfileName)
                    } catch (e: Throwable) {
                        Log.w(TAG, "Popup setProfile failed: ${e.message}")
                    }
                }
                configureCookies(child)
                configureWebViewSettings(child, userAgent)
                attachAutofillGuard(child)
                child.applyAutofillAllowed(false)

                var dialogShown = false
                val titleView = TextView(activity).apply {
                    text = "認証ウィンドウ"
                    setTextColor(Color.WHITE)
                    textSize = 14f
                    maxLines = 1
                    setPadding(24, 0, 12, 0)
                }

                fun ensurePopupDialogShown() {
                    if (dialogShown || disposed) return
                    dialogShown = true
                    val dialog = Dialog(activity).apply {
                        requestWindowFeature(Window.FEATURE_NO_TITLE)
                        setCancelable(true)
                        setOnCancelListener { closePopup() }
                    }
                    val root = LinearLayout(activity).apply {
                        orientation = LinearLayout.VERTICAL
                        setBackgroundColor(Color.parseColor("#0F1219"))
                    }
                    val header = LinearLayout(activity).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        setBackgroundColor(Color.parseColor("#181C26"))
                        setPadding(8, 12, 8, 12)
                    }
                    val closeBtn = ImageButton(activity).apply {
                        setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
                        setBackgroundColor(Color.TRANSPARENT)
                        setColorFilter(Color.WHITE)
                        setOnClickListener { closePopup() }
                    }
                    header.addView(
                        titleView,
                        LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
                    )
                    header.addView(
                        closeBtn,
                        LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.WRAP_CONTENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT,
                        ),
                    )
                    root.addView(
                        header,
                        LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT,
                        ),
                    )
                    root.addView(
                        child,
                        LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            0,
                            1f,
                        ),
                    )
                    dialog.setContentView(root)
                    dialog.window?.setLayout(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                    popupDialog = dialog
                    dialog.show()
                }

                child.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(
                        popupView: WebView,
                        request: WebResourceRequest,
                    ): Boolean {
                        val url = request.url?.toString() ?: return true
                        val scheme = request.url?.scheme?.lowercase() ?: return true
                        if (scheme != "http" && scheme != "https") {
                            if (scheme == "mailto" || scheme == "tel") {
                                invokeDart("onExternalScheme", mapOf("url" to url))
                            }
                            closePopup()
                            return true
                        }
                        if (!dialogShown && !isDialog && !AUTH_POPUP_REGEX.containsMatchIn(url)) {
                            // OAuth 以外の通常 _blank リンクは親タブで開く
                            webView.loadUrl(url)
                            closePopup()
                            return true
                        }
                        ensurePopupDialogShown()
                        return false
                    }

                    override fun onPageStarted(
                        popupView: WebView,
                        url: String?,
                        favicon: android.graphics.Bitmap?,
                    ) {
                        super.onPageStarted(popupView, url, favicon)
                        child.applyAutofillAllowed(false)
                        if (!url.isNullOrEmpty() && url != "about:blank") {
                            if (!dialogShown && !isDialog && !AUTH_POPUP_REGEX.containsMatchIn(url)) {
                                webView.loadUrl(url)
                                closePopup()
                                return
                            }
                            ensurePopupDialogShown()
                            titleView.text = url
                        }
                    }

                    override fun onPageFinished(popupView: WebView, url: String?) {
                        super.onPageFinished(popupView, url)
                        injectAutofillGuardFallback(popupView)
                        if (!popupView.title.isNullOrEmpty()) {
                            titleView.text = popupView.title
                        }
                    }
                }

                child.webChromeClient = object : WebChromeClient() {
                    override fun onReceivedTitle(popupView: WebView?, title: String?) {
                        if (!title.isNullOrEmpty()) {
                            titleView.text = title
                        }
                    }

                    override fun onCloseWindow(window: WebView?) {
                        closePopup()
                    }
                }

                popupWebView = child
                if (isDialog) {
                    ensurePopupDialogShown()
                }
                transport.webView = child
                resultMsg.sendToTarget()
                return true
            }
        }
    }

    fun exitFullscreenIfActive(): Boolean {
        val view = customView ?: return false
        val decor = activity.window?.decorView as? FrameLayout
        decor?.removeView(view)
        customView = null
        try {
            customViewCallback?.onCustomViewHidden()
        } catch (_: Throwable) {
        }
        customViewCallback = null
        return true
    }

    private fun closePopup() {
        val dialog = popupDialog
        popupDialog = null
        try {
            dialog?.dismiss()
        } catch (_: Throwable) {
        }
        val child = popupWebView
        popupWebView = null
        if (child != null) {
            try {
                (child.parent as? ViewGroup)?.removeView(child)
                child.stopLoading()
                child.loadUrl("about:blank")
                child.removeJavascriptInterface("OmniAutofillBridge")
                child.destroy()
            } catch (_: Throwable) {
            }
        }
    }

    private fun invokeDart(method: String, arguments: Any?) {
        if (disposed) return
        mainHandler.post {
            if (!disposed) {
                try {
                    channel.invokeMethod(method, arguments)
                } catch (_: Throwable) {
                }
            }
        }
    }

    override fun getView(): View = webView

    override fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        exitFullscreenIfActive()
        closePopup()
        try {
            (webView.parent as? ViewGroup)?.removeView(webView)
            webView.stopLoading()
            webView.loadUrl("about:blank")
            webView.removeJavascriptInterface("OmniAutofillBridge")
            webView.destroy()
        } catch (_: Throwable) {
        }
        manager.unregisterView(viewId, appliedProfileName)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.success(null)
            return
        }
        when (call.method) {
            "loadUrl" -> {
                val url = call.argument<String>("url")
                if (!url.isNullOrEmpty()) {
                    webView.loadUrl(url)
                }
                result.success(null)
            }
            "reload" -> {
                webView.reload()
                result.success(null)
            }
            "goBack" -> {
                if (!exitFullscreenIfActive() && webView.canGoBack()) {
                    webView.goBack()
                }
                result.success(null)
            }
            "goForward" -> {
                if (webView.canGoForward()) {
                    webView.goForward()
                }
                result.success(null)
            }
            "canGoBack" -> {
                result.success(customView != null || webView.canGoBack())
            }
            "canGoForward" -> {
                result.success(webView.canGoForward())
            }
            "getTitle" -> {
                result.success(webView.title)
            }
            "getUrl" -> {
                result.success(webView.url)
            }
            "getAppliedProfileName" -> {
                result.success(appliedProfileName)
            }
            else -> result.notImplemented()
        }
    }
}
