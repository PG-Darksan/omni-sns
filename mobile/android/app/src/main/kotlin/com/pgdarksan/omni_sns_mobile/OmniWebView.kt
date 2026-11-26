package com.pgdarksan.omni_sns_mobile

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.app.Dialog
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.text.InputType
import android.text.TextUtils
import android.util.Base64
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
import android.webkit.RenderProcessGoneDetail
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
import androidx.core.content.ContextCompat
import androidx.webkit.Profile
import androidx.webkit.ProfileStore
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import java.security.KeyStore
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

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
                // JSスレッドとUIスレッドの順序逆転を防ぐため、最新の揮発フラグを参照する
                val currentAllowed = allowAutofillForCurrentFocus
                val targetFlag = if (currentAllowed) {
                    View.IMPORTANT_FOR_AUTOFILL_YES
                } else {
                    View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
                }
                if (importantForAutofill != targetFlag) {
                    importantForAutofill = targetFlag
                }
                if (!currentAllowed && hasFocus()) {
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

private class OmniAutofillBridge(
    private val webView: OmniWebView,
    private val expectedToken: String,
) {
    @JavascriptInterface
    fun setAutofillAllowed(token: String?, allowed: Boolean) {
        if (token != expectedToken) return
        webView.applyAutofillAllowed(allowed, fromJs = true)
    }
}

private class OmniFollowBridge(
    private val expectedToken: String,
    private val onFollow: (String, String) -> Unit,
    private val onUnfollow: (String, String) -> Unit,
    private val onIdentity: (String, String, Int, Int) -> Unit,
    private val onOpenNewTabCb: (String, Boolean) -> Unit,
    private val onJevGetConfigCb: () -> Unit,
    private val onJevCheckAccountsCb: (String, String) -> Unit,
    private val onJevStateCb: (Boolean, Int, Int, Boolean) -> Unit,
) {
    @JavascriptInterface
    fun onFollowDetected(token: String?, source: String?, service: String?) {
        if (token != expectedToken) return
        onFollow(source?.ifEmpty { "auto" } ?: "auto", service?.trim().orEmpty())
    }

    @JavascriptInterface
    fun onUnfollowDetected(token: String?, source: String?, service: String?) {
        if (token != expectedToken) return
        onUnfollow(source?.ifEmpty { "auto" } ?: "auto", service?.trim().orEmpty())
    }

    @JavascriptInterface
    fun onAccountIdentity(token: String?, service: String?, handle: String?, following: Int, followers: Int) {
        if (token != expectedToken) return
        val cleanHandle = handle?.trim().orEmpty()
        if (cleanHandle.isNotEmpty()) {
            onIdentity(service?.trim().orEmpty(), cleanHandle, following, followers)
        }
    }

    @JavascriptInterface
    fun onOpenNewTab(token: String?, url: String?) {
        if (token != expectedToken) return
        val clean = url?.trim().orEmpty()
        if (clean.startsWith("http://", ignoreCase = true) || clean.startsWith("https://", ignoreCase = true)) {
            onOpenNewTabCb(clean, false)
        }
    }

    /** F/FW バッジのタップ用: 新規タブを作成してそのタブへ即座に切り替える。 */
    @JavascriptInterface
    fun onOpenNewTabActivate(token: String?, url: String?) {
        if (token != expectedToken) return
        val clean = url?.trim().orEmpty()
        if (clean.startsWith("http://", ignoreCase = true) || clean.startsWith("https://", ignoreCase = true)) {
            onOpenNewTabCb(clean, true)
        }
    }

    @JavascriptInterface
    fun onJevGetConfig(token: String?) {
        if (token != expectedToken) return
        onJevGetConfigCb()
    }

    @JavascriptInterface
    fun onJevCheckAccounts(token: String?, reqId: String?, payloadJson: String?) {
        if (token != expectedToken) return
        val id = reqId?.trim().orEmpty()
        if (id.isNotEmpty()) {
            onJevCheckAccountsCb(id, payloadJson?.trim().orEmpty())
        }
    }

    @JavascriptInterface
    fun onJevState(token: String?, active: Boolean, matched: Int, hidden: Int, autoFetching: Boolean) {
        if (token != expectedToken) return
        onJevStateCb(active, matched, hidden, autoFetching)
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
        const val PERMISSION_REQUEST_CODE = 42072
        private const val TAG = "OmniWebViewManager"
        private const val SECURE_PREFS_NAME = "omnisns_secure_secrets_v1"
        private const val KEYSTORE_ALIAS = "omnisns_secret_aes_gcm_v1"
        private val secureRandom = SecureRandom()

        val FOLLOW_ALLOWED_ORIGINS: Set<String> = setOf(
            "https://instagram.com",
            "https://*.instagram.com",
            "https://threads.net",
            "https://*.threads.net",
            "https://threads.com",
            "https://*.threads.com",
            "https://bsky.app",
            "https://*.bsky.app",
            "https://bsky.social",
            "https://*.bsky.social",
            "https://x.com",
            "https://*.x.com",
            "https://twitter.com",
            "https://*.twitter.com",
            "https://mixi.social",
            "https://*.mixi.social",
            "https://tiktok.com",
            "https://*.tiktok.com",
            "https://facebook.com",
            "https://*.facebook.com",
            "https://messenger.com",
            "https://*.messenger.com",
            "https://note.com",
            "https://*.note.com",
            "https://youtube.com",
            "https://*.youtube.com",
            "https://twitch.tv",
            "https://*.twitch.tv",
            "https://reddit.com",
            "https://*.reddit.com",
            "https://pinterest.com",
            "https://*.pinterest.com",
            "https://pinterest.jp",
            "https://*.pinterest.jp",
            "https://linkedin.com",
            "https://*.linkedin.com",
            "https://tumblr.com",
            "https://*.tumblr.com",
            "https://pixiv.net",
            "https://*.pixiv.net",
            "https://mastodon.social",
            "https://*.mastodon.social",
            "https://misskey.io",
            "https://*.misskey.io",
        )

        val PROFILE_STATS_ALLOWED_ORIGINS: Set<String> = setOf(
            "https://instagram.com",
            "https://*.instagram.com",
            "https://threads.net",
            "https://*.threads.net",
            "https://threads.com",
            "https://*.threads.com",
            "https://bsky.app",
            "https://*.bsky.app",
            "https://bsky.social",
            "https://*.bsky.social",
        )

        fun generateBridgeToken(): String {
            val bytes = ByteArray(16)
            secureRandom.nextBytes(bytes)
            val sb = StringBuilder(32)
            for (b in bytes) {
                val v = b.toInt() and 0xFF
                sb.append("0123456789abcdef"[v ushr 4])
                sb.append("0123456789abcdef"[v and 0x0F])
            }
            return sb.toString()
        }

        fun detectPlatformServiceFromHost(rawHost: String?): String? {
            val h = rawHost?.trim()?.lowercase().orEmpty()
            if (h.isEmpty()) return null
            fun matches(domain: String) = h == domain || h.endsWith(".$domain")
            return when {
                matches("instagram.com") -> "instagram"
                matches("threads.net") || matches("threads.com") -> "threads"
                matches("bsky.app") || matches("bsky.social") -> "bluesky"
                matches("mixi.social") -> "mixi2"
                matches("x.com") || matches("twitter.com") -> "x"
                matches("tiktok.com") -> "tiktok"
                matches("facebook.com") || matches("messenger.com") -> "facebook"
                matches("note.com") -> "note"
                matches("youtube.com") -> "youtube"
                matches("twitch.tv") -> "twitch"
                matches("reddit.com") -> "reddit"
                matches("pinterest.com") || matches("pinterest.jp") -> "pinterest"
                matches("linkedin.com") -> "linkedin"
                matches("tumblr.com") -> "tumblr"
                matches("pixiv.net") -> "pixiv"
                matches("mastodon.social") -> "mastodon"
                matches("misskey.io") -> "misskey"
                else -> null
            }
        }

        fun detectPlatformServiceFromHttpsUrl(rawUrl: String?): String? {
            if (rawUrl.isNullOrBlank()) return null
            return try {
                val uri = Uri.parse(rawUrl.trim())
                if (!uri.scheme.equals("https", ignoreCase = true)) return null
                detectPlatformServiceFromHost(uri.host)
            } catch (_: Throwable) {
                null
            }
        }

        fun buildAutofillGuardJs(token: String): String =
            AUTOFILL_GUARD_JS.replace("__OMNISNS_AUTOFILL_TOKEN__", token)

        fun buildFollowTrackerJs(token: String): String =
            FOLLOW_TRACKER_JS.replace("__OMNISNS_FOLLOW_TOKEN__", token)

        fun buildProfileStatsJs(token: String): String =
            PROFILE_STATS_JS.replace("__OMNISNS_FOLLOW_TOKEN__", token)

        fun buildLongPressNewTabJs(token: String): String =
            LONG_PRESS_NEW_TAB_JS.replace("__OMNISNS_FOLLOW_TOKEN__", token)

        fun buildJevFilterJs(token: String): String =
            JEV_FILTER_JS.replace("__OMNISNS_FOLLOW_TOKEN__", token)

        /**
         * 全フレーム（iframe含む）のドキュメント開始前に注入する Autofill ガードスクリプト。
         * パスワード入力欄・ログインフォームの認証欄にフォーカスした場合のみ Autofill を許可し、
         * DM欄・チャット欄・検索欄などの通常入力欄では Google パスワードマネージャーを抑止する。
         */
        val AUTOFILL_GUARD_JS: String = """
            (function() {
              if (window.__omniAutofillGuardInstalled) return;
              window.__omniAutofillGuardInstalled = true;
              var __omniToken = "__OMNISNS_AUTOFILL_TOKEN__";
              var __omniBridge = window.OmniAutofillBridge;

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
                  var bridge = __omniBridge || window.OmniAutofillBridge;
                  if (bridge && typeof bridge.setAutofillAllowed === 'function') {
                    bridge.setAutofillAllowed(__omniToken, !!allowed);
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

              // トップフレームのみ初期状態を無効化（背景広告iframe等が親フォームのAutofillを潰さないようにする）
              if (window === window.top) {
                notifyNative(false, true);
              }
            })();
        """.trimIndent()

        /**
         * Threads / Instagram / Bluesky / mixi2 等のフォロー・アンフォロー操作を検知してネイティブへ通知するスクリプト。
         * fetch / XMLHttpRequest のAPI成功を優先検知し、DOMボタン状態遷移をフォールバックとする。
         */
        val FOLLOW_TRACKER_JS: String = """
            (function() {
              if (window !== window.top) return;
              if (window.__omniFollowTrackerInstalled) return;
              window.__omniFollowTrackerInstalled = true;
              var __omniFollowToken = "__OMNISNS_FOLLOW_TOKEN__";
              var __omniFollowChannel = window.OmniFollowChannel;
              var __omniFollowBridge = window.OmniFollowBridge;

              var NEGATIVE_FOLLOW_RE = /(フォロー中|フォロー済|フォロー解除|フォローをやめる|フォローを外す|フォロワー|リクエスト済|リクエスト中|承認待ち|解除|following|unfollow|followers|requested|pending|remove|cancel|block|mute)/i;
              var EXACT_FOLLOW_TEXT_RE = /^(?:[+＋]\s*)?(?:フォロー|フォローする|フォローバック|フォローバックする|フォローを返す|follow|follow\s+back)$/i;
              var ARIA_FOLLOW_RE = /^(?:(?:[+＋]\s*)?(?:フォロー|フォローする|フォローバック|follow|follow\s+back)|.+?(?:をフォロー|をフォローする|をフォローバック)|follow\s+@?[\w.\-\u3040-\u30ff\u4e00-\u9faf]+.*)$/i;
              var POST_FOLLOW_STATE_RE = /(フォロー中|フォロー済|フォロー解除|リクエスト済|リクエスト中|承認待ち|following|unfollow|requested|pending|チェック|check)/i;

              var EXACT_UNFOLLOW_TEXT_RE = /^(?:フォロー中|フォロー済|フォロー済み|フォロー解除|フォローを解除|フォローをやめる|フォローを外す|リクエスト済|リクエスト済み|リクエスト中|承認待ち|following|unfollow|requested)$/i;
              var CONFIRM_UNFOLLOW_TEXT_RE = /^(?:フォロー解除|フォローを解除|フォローをやめる|フォローを外す|unfollow)$/i;
              var ARIA_UNFOLLOW_RE = /^(?:(?:フォロー中|フォロー解除|フォローをやめる|following|unfollow)|.+?(?:のフォローを解除|のフォローをやめる|をアンフォロー)|unfollow\s+@?[\w.\-\u3040-\u30ff\u4e00-\u9faf]+.*)$/i;
              var NON_UNFOLLOW_RE = /(フォロワー|followers|ブロック|block|ミュート|mute|報告|report|削除|remove\s+follower)/i;

              function makeChannelState() {
                return {
                  lastNetworkStartAt: 0,
                  lastNetworkAt: 0,
                  lastDomEmitAt: 0,
                  lastAnyEmitAt: 0,
                  inFlight: 0,
                  recentTargetKeys: Object.create(null),
                  emittedInteractions: Object.create(null)
                };
              }
              var states = {
                follow: makeChannelState(),
                unfollow: makeChannelState()
              };

              var userInteractionSeq = 0;
              var lastUserInteractionAt = 0;
              var lastPointerDownAt = 0;
              var lastClickedTargetHandle = '';
              var lastClickedTargetAt = 0;

              function bumpUserInteraction(fromPointerDown) {
                var now = Date.now();
                if (fromPointerDown) {
                  userInteractionSeq++;
                  lastPointerDownAt = now;
                  lastUserInteractionAt = now;
                } else if (now - lastPointerDownAt > 500) {
                  userInteractionSeq++;
                  lastUserInteractionAt = now;
                } else {
                  lastUserInteractionAt = now;
                }
              }

              document.addEventListener('pointerdown', function(e) {
                if (e && (e.isTrusted === false || (typeof e.button === 'number' && e.button !== 0))) return;
                bumpUserInteraction(true);
              }, true);

              document.addEventListener('keydown', function(e) {
                if (e && e.isTrusted !== false && (e.key === 'Enter' || e.key === ' ')) {
                  bumpUserInteraction(true);
                }
              }, true);

              function currentInteractionId() {
                var now = Date.now();
                if (userInteractionSeq > 0 && now - lastUserInteractionAt <= 3000) {
                  return userInteractionSeq;
                }
                return 0;
              }

              function detectCurrentService() {
                try {
                  var h = (window.location && window.location.hostname ? window.location.hostname : '').toLowerCase();
                  function matchDom(d) { return h === d || (h.length > d.length && h.slice(-(d.length + 1)) === '.' + d); }
                  if (matchDom('instagram.com')) return 'instagram';
                  if (matchDom('threads.net') || matchDom('threads.com')) return 'threads';
                  if (matchDom('bsky.app') || matchDom('bsky.social')) return 'bluesky';
                  if (matchDom('mixi.social')) return 'mixi2';
                  if (matchDom('x.com') || matchDom('twitter.com')) return 'x';
                  if (matchDom('tiktok.com')) return 'tiktok';
                  if (matchDom('facebook.com') || matchDom('messenger.com')) return 'facebook';
                  if (matchDom('note.com')) return 'note';
                  if (matchDom('youtube.com')) return 'youtube';
                  if (matchDom('twitch.tv')) return 'twitch';
                  if (matchDom('reddit.com')) return 'reddit';
                  if (matchDom('pinterest.com') || matchDom('pinterest.jp')) return 'pinterest';
                  if (matchDom('linkedin.com')) return 'linkedin';
                  if (matchDom('tumblr.com')) return 'tumblr';
                  if (matchDom('pixiv.net')) return 'pixiv';
                  if (matchDom('mastodon.social')) return 'mastodon';
                  if (matchDom('misskey.io')) return 'misskey';
                } catch (_) {}
                return '';
              }

              function emitRelation(action, source, targetKey, interactionId) {
                var st = states[action];
                if (!st) return;
                var now = Date.now();
                if (interactionId && interactionId > 0) {
                  for (var ik in st.emittedInteractions) {
                    if (now - st.emittedInteractions[ik] > 15000) delete st.emittedInteractions[ik];
                  }
                  if (st.emittedInteractions[interactionId]) {
                    if (source === 'network') {
                      st.lastNetworkAt = now;
                      if (targetKey) st.recentTargetKeys[targetKey] = now;
                    }
                    return;
                  }
                }
                if (targetKey) {
                  for (var k in st.recentTargetKeys) {
                    if (now - st.recentTargetKeys[k] > 15000) delete st.recentTargetKeys[k];
                  }
                  if (st.recentTargetKeys[targetKey] && now - st.recentTargetKeys[targetKey] < 5000) {
                    return;
                  }
                }
                if (source === 'network') {
                  if (now - st.lastDomEmitAt < 2500) {
                    st.lastNetworkAt = now;
                    if (targetKey) st.recentTargetKeys[targetKey] = now;
                    if (interactionId && interactionId > 0) st.emittedInteractions[interactionId] = now;
                    return;
                  }
                  if (!targetKey && now - st.lastAnyEmitAt < 1200) {
                    st.lastNetworkAt = now;
                    return;
                  }
                  st.lastNetworkAt = now;
                  st.lastAnyEmitAt = now;
                  if (targetKey) st.recentTargetKeys[targetKey] = now;
                  if (interactionId && interactionId > 0) st.emittedInteractions[interactionId] = now;
                } else {
                  if (now - st.lastAnyEmitAt < 2500) return;
                  st.lastDomEmitAt = now;
                  st.lastAnyEmitAt = now;
                  if (interactionId && interactionId > 0) st.emittedInteractions[interactionId] = now;
                }
                try {
                  if (typeof window.__omniOnFollowAction === 'function') {
                    var fallbackHandle = (lastClickedTargetHandle && now - lastClickedTargetAt <= 5000)
                      ? lastClickedTargetHandle
                      : '';
                    window.__omniOnFollowAction(action, targetKey || '', fallbackHandle);
                  }
                } catch (_) {}
                try {
                  var svc = detectCurrentService();
                  var ch = __omniFollowChannel || window.OmniFollowChannel;
                  if (ch && typeof ch.postMessage === 'function') {
                    ch.postMessage(JSON.stringify({
                      token: __omniFollowToken,
                      type: action === 'unfollow' ? 'unfollow' : 'follow',
                      source: source || 'auto',
                      service: svc
                    }));
                  } else {
                    var br = __omniFollowBridge || window.OmniFollowBridge;
                    if (br) {
                      if (action === 'unfollow' && typeof br.onUnfollowDetected === 'function') {
                        br.onUnfollowDetected(__omniFollowToken, source || 'auto', svc);
                      } else if (action === 'follow' && typeof br.onFollowDetected === 'function') {
                        br.onFollowDetected(__omniFollowToken, source || 'auto', svc);
                      }
                    }
                  }
                } catch (_) {}
              }

              function bodyToSearchString(body) {
                if (!body) return '';
                try {
                  if (typeof body === 'string') return body.slice(0, 8192);
                  if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
                    return body.toString().slice(0, 8192);
                  }
                  if (typeof FormData !== 'undefined' && body instanceof FormData) {
                    var parts = [];
                    body.forEach(function(v, k) {
                      if (typeof v === 'string') parts.push(k + '=' + v.slice(0, 256));
                    });
                    return parts.join('&').slice(0, 8192);
                  }
                } catch (_) {}
                return '';
              }

              function extractTargetKey(url, decodedBody) {
                try {
                  var m = /\/friendships\/(?:create|destroy)\/([^\/?#]+)/i.exec(url) ||
                          /\/web\/friendships\/([^\/?#]+)\/(?:follow|unfollow)/i.exec(url) ||
                          /\/api\/v1\/accounts\/([^\/?#]+)\/(?:follow|unfollow)/i.exec(url);
                  if (m && m[1]) return String(m[1]).trim().toLowerCase();

                  m = /"(?:target_user_id|targetUserId|to_user_id|subscribee_id|subject|rkey)"\s*:\s*"?([a-z0-9:._-]+)"?/i.exec(decodedBody) ||
                      /(?:^|&)(?:target_user_id|to_user_id)=([a-z0-9._-]+)/i.exec(decodedBody);
                  if (m && m[1]) return String(m[1]).trim().toLowerCase();

                  m = /"(?:user_id|profile_id|userId)"\s*:\s*"?([a-z0-9:._-]+)"?/i.exec(decodedBody) ||
                      /(?:^|&)user_id=([a-z0-9._-]+)/i.exec(decodedBody) ||
                      /[?&]user_id=([a-z0-9._-]+)/i.exec(url);
                  if (m && m[1]) return String(m[1]).trim().toLowerCase();
                } catch (_) {}
                return '';
              }

              function detectRelationApiRequest(rawUrl, method, rawBody) {
                try {
                  var m = (method || 'GET').toUpperCase();
                  if (m !== 'POST') return null;
                  var url = String(rawUrl || '');
                  var lowerUrl = url.toLowerCase();
                  var body = bodyToSearchString(rawBody);
                  var decodedBody = body;
                  try {
                    if (body.indexOf('%') >= 0) decodedBody = decodeURIComponent(body.replace(/\+/g, ' '));
                  } catch (_) {}
                  var lowerBody = decodedBody.toLowerCase();

                  if (/\/friendships\/destroy(?:\/|\?|$)/i.test(lowerUrl) ||
                      /\/web\/friendships\/[^\/?#]+\/unfollow(?:\/|\?|$)/i.test(lowerUrl)) {
                    return { action: 'unfollow', targetKey: extractTargetKey(url, decodedBody) };
                  }

                  if (/\/friendships\/create(?:\/|\?|$)/i.test(lowerUrl) ||
                      /\/web\/friendships\/[^\/?#]+\/follow(?:\/|\?|$)/i.test(lowerUrl)) {
                    if (!/unfollow|destroy/i.test(lowerUrl)) {
                      return { action: 'follow', targetKey: extractTargetKey(url, decodedBody) };
                    }
                    return null;
                  }

                  if (/\/(?:api\/)?graphql(?:\/|\?|$)/i.test(lowerUrl)) {
                    var fnameMatch = /(?:fb_api_req_friendly_name|friendlyname)["'=\s:]+([a-z0-9_]+)/i.exec(decodedBody);
                    var fname = fnameMatch ? fnameMatch[1] : '';
                    if (fname) {
                      if (/remove.?follower|block|mute|restrict|suggestion|recommend|list|count|query|fetch|load|get|status|info|chaining|similar|show|check|batch|many|bulk|sync|refresh|feed|timeline|modal|dialog|sheet/i.test(fname)) {
                        return null;
                      }
                      if (/unfollow/i.test(fname) ||
                          (/(?:friendship|follow)/i.test(fname) && /(?:destroy|delete|cancel)/i.test(fname))) {
                        return { action: 'unfollow', targetKey: extractTargetKey(url, decodedBody) };
                      }
                      if (/follow/i.test(fname) && /(?:mutation|create|add)/i.test(fname) &&
                          !/unfollow|destroy|remove|cancel|follower|following/i.test(fname)) {
                        return { action: 'follow', targetKey: extractTargetKey(url, decodedBody) };
                      }
                      return null;
                    }
                    if (/usebarcelonaunfollowmutation|barcelonaunfollowmutation|polarisfriendshipsunfollow|polarisunfollowmutation|usepolarisunfollowmutation|polarisuserunfollowmutation|igwebprofileunfollowmutation|textpostappunfollowmutation|friendingcometunfollowmutation|polarisfriendshipsdestroy/i.test(lowerBody)) {
                      return { action: 'unfollow', targetKey: extractTargetKey(url, decodedBody) };
                    }
                    if (/usebarcelonafollowmutation|barcelonafollowmutation|polarisfriendshipsfollow|polarisfollowmutation|usepolarisfollowmutation|polarisuserfollowmutation|igwebprofilefollowmutation|textpostappfollowmutation|friendingcometfollowmutation/i.test(lowerBody) &&
                        !/unfollow|destroy/i.test(lowerBody)) {
                      return { action: 'follow', targetKey: extractTargetKey(url, decodedBody) };
                    }
                    return null;
                  }

                  if (lowerUrl.indexOf('com.atproto.repo.createrecord') >= 0 &&
                      lowerBody.indexOf('app.bsky.graph.follow') >= 0) {
                    return { action: 'follow', targetKey: extractTargetKey(url, decodedBody) };
                  }
                  if (lowerUrl.indexOf('com.atproto.repo.deleterecord') >= 0 &&
                      lowerBody.indexOf('app.bsky.graph.follow') >= 0) {
                    return { action: 'unfollow', targetKey: extractTargetKey(url, decodedBody) };
                  }

                  if (/\/api\/v1\/accounts\/[^\/?#]+\/unfollow(?:\?|$)/i.test(lowerUrl)) {
                    return { action: 'unfollow', targetKey: extractTargetKey(url, decodedBody) };
                  }
                  if (/\/api\/v1\/accounts\/[^\/?#]+\/follow(?:\?|$)/i.test(lowerUrl)) {
                    return { action: 'follow', targetKey: extractTargetKey(url, decodedBody) };
                  }
                  if (/\/api\/following\/delete(?:\?|$)/i.test(lowerUrl)) {
                    return { action: 'unfollow', targetKey: extractTargetKey(url, decodedBody) };
                  }
                  if (/\/api\/following\/create(?:\?|$)/i.test(lowerUrl)) {
                    return { action: 'follow', targetKey: extractTargetKey(url, decodedBody) };
                  }
                  if (/\/api\/commit\/follow\/user/i.test(lowerUrl)) {
                    if (/[?&]type=1(?:&|$)/i.test(lowerUrl) || /(?:^|&)type=1(?:&|$)|"type"\s*:\s*1/i.test(lowerBody)) {
                      return { action: 'follow', targetKey: extractTargetKey(url, decodedBody) };
                    }
                    if (/[?&]type=0(?:&|$)/i.test(lowerUrl) || /(?:^|&)type=0(?:&|$)|"type"\s*:\s*0/i.test(lowerBody)) {
                      return { action: 'unfollow', targetKey: extractTargetKey(url, decodedBody) };
                    }
                  }
                } catch (_) {}
                return null;
              }

              try {
                var origFetch = window.fetch;
                if (typeof origFetch === 'function') {
                  window.fetch = function(input, init) {
                    var isInternal = !!(init && init.__omniStatsInternal);
                    if (isInternal) return origFetch.apply(this, arguments);
                    var reqUrl = '';
                    var reqMethod = 'GET';
                    var reqBody = null;
                    try {
                      if (typeof input === 'string') {
                        reqUrl = input;
                      } else if (input && typeof input === 'object') {
                        reqUrl = input.url || '';
                        if (input.method) reqMethod = input.method;
                      }
                      if (init && typeof init === 'object') {
                        if (init.method) reqMethod = init.method;
                        if (init.body !== undefined) reqBody = init.body;
                      }
                    } catch (_) {}
                    var relReq = detectRelationApiRequest(reqUrl, reqMethod, reqBody);
                    var reqInteractionId = 0;
                    var st = relReq ? states[relReq.action] : null;
                    if (relReq && st) {
                      st.lastNetworkStartAt = Date.now();
                      st.inFlight++;
                      reqInteractionId = currentInteractionId();
                    }
                    var promise = origFetch.apply(this, arguments);
                    if (relReq && st && promise && typeof promise.then === 'function') {
                      promise.then(function(res) {
                        st.inFlight = Math.max(0, st.inFlight - 1);
                        try {
                          if (res && res.ok) emitRelation(relReq.action, 'network', relReq.targetKey, reqInteractionId);
                        } catch (_) {}
                      }, function() {
                        st.inFlight = Math.max(0, st.inFlight - 1);
                      });
                    } else if (relReq && st) {
                      st.inFlight = Math.max(0, st.inFlight - 1);
                    }
                    return promise;
                  };
                }
              } catch (_) {}

              try {
                var origOpen = XMLHttpRequest.prototype.open;
                var origSend = XMLHttpRequest.prototype.send;
                if (typeof origOpen === 'function' && typeof origSend === 'function') {
                  XMLHttpRequest.prototype.open = function(method, url) {
                    try {
                      this.__omniMethod = method;
                      this.__omniUrl = url;
                    } catch (_) {}
                    return origOpen.apply(this, arguments);
                  };
                  XMLHttpRequest.prototype.send = function(body) {
                    try {
                      var relReq = detectRelationApiRequest(this.__omniUrl, this.__omniMethod, body);
                      var st = relReq ? states[relReq.action] : null;
                      if (relReq && st) {
                        st.lastNetworkStartAt = Date.now();
                        st.inFlight++;
                        var reqInteractionId = currentInteractionId();
                        var done = false;
                        var finish = function() {
                          if (!done) {
                            done = true;
                            st.inFlight = Math.max(0, st.inFlight - 1);
                          }
                        };
                        this.addEventListener('load', function() {
                          finish();
                          try {
                            if (this.status >= 200 && this.status < 300) {
                              emitRelation(relReq.action, 'network', relReq.targetKey, reqInteractionId);
                            }
                          } catch (_) {}
                        }, { once: true });
                        this.addEventListener('error', finish, { once: true });
                        this.addEventListener('abort', finish, { once: true });
                        this.addEventListener('timeout', finish, { once: true });
                      }
                    } catch (_) {}
                    return origSend.apply(this, arguments);
                  };
                }
              } catch (_) {}

              function normalizeLabel(s) {
                return String(s || '').replace(/\s+/g, ' ').trim();
              }

              function readElementLabels(el) {
                var text = '';
                var aria = '';
                try {
                  text = normalizeLabel(el.innerText || el.textContent || '');
                  aria = normalizeLabel(el.getAttribute('aria-label') || '');
                  if (!aria) {
                    var svg = el.querySelector('svg[aria-label], [aria-label]');
                    if (svg) aria = normalizeLabel(svg.getAttribute('aria-label') || '');
                  }
                } catch (_) {}
                return { text: text, aria: aria };
              }

              function isFollowButtonElement(el) {
                if (!el || el.disabled) return false;
                try {
                  if (el.getAttribute('aria-disabled') === 'true') return false;
                  if (el.closest('nav')) return false;
                  if (el.tagName && el.tagName.toUpperCase() === 'A') {
                    var href = (el.getAttribute('href') || '').toLowerCase();
                    if (/\/(following|followers)(?:\/|\?|$)/.test(href)) return false;
                  }
                  var labels = readElementLabels(el);
                  if (labels.text && NEGATIVE_FOLLOW_RE.test(labels.text)) return false;
                  if (labels.aria && NEGATIVE_FOLLOW_RE.test(labels.aria)) return false;
                  if (labels.text && labels.text.length <= 24 && EXACT_FOLLOW_TEXT_RE.test(labels.text)) {
                    return true;
                  }
                  if (!labels.text && labels.aria && labels.aria.length <= 64 && ARIA_FOLLOW_RE.test(labels.aria)) {
                    return true;
                  }
                  if (labels.text && labels.text.length <= 4 && /^[+＋]$/.test(labels.text) &&
                      labels.aria && labels.aria.length <= 64 && ARIA_FOLLOW_RE.test(labels.aria)) {
                    return true;
                  }
                } catch (_) {}
                return false;
              }

              function isUnfollowButtonElement(el) {
                if (!el || el.disabled) return false;
                try {
                  if (el.getAttribute('aria-disabled') === 'true') return false;
                  if (el.closest('nav')) return false;
                  if (el.tagName && el.tagName.toUpperCase() === 'A') {
                    var href = (el.getAttribute('href') || '').toLowerCase();
                    if (/\/(following|followers)(?:\/|\?|$)/.test(href)) return false;
                  }
                  var labels = readElementLabels(el);
                  if (labels.text && NON_UNFOLLOW_RE.test(labels.text)) return false;
                  if (labels.aria && NON_UNFOLLOW_RE.test(labels.aria)) return false;
                  if (labels.text && labels.text.length <= 24 && EXACT_UNFOLLOW_TEXT_RE.test(labels.text)) {
                    return true;
                  }
                  if (!labels.text && labels.aria && labels.aria.length <= 64 && ARIA_UNFOLLOW_RE.test(labels.aria)) {
                    return true;
                  }
                } catch (_) {}
                return false;
              }

              function isElementHidden(el) {
                try {
                  if (!el.isConnected) return true;
                  var style = window.getComputedStyle(el);
                  if (!style || style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
                    return true;
                  }
                  var rect = el.getBoundingClientRect();
                  return rect.width < 1 || rect.height < 1;
                } catch (_) {
                  return false;
                }
              }

              function extractHandleNearButton(btn) {
                try {
                  if (!btn) return '';
                  var row = btn.closest ? btn.closest('[data-omni-ff-row]') : null;
                  if (row) {
                    var rh = (row.getAttribute('data-omni-ff-row') || '').trim().toLowerCase();
                    if (rh) return rh;
                  }
                  var labels = readElementLabels(btn);
                  var aria = labels.aria || '';
                  var am = /^@?([a-z0-9._-]{1,40})\s*(?:をフォロー|のフォロー)/i.exec(aria) ||
                           /^(?:follow|unfollow)\s+@?([a-z0-9._-]{1,40})/i.exec(aria);
                  if (am && am[1]) return am[1].toLowerCase();
                  var cur = btn.parentElement;
                  for (var d = 0; d < 6 && cur && cur !== document.body; d++) {
                    if (typeof window.__omniExtractHandleFromRow === 'function') {
                      var eh = window.__omniExtractHandleFromRow(cur);
                      if (eh) return eh;
                    }
                    var imgs = cur.querySelectorAll ? cur.querySelectorAll('img[alt]') : [];
                    for (var j = 0; j < imgs.length && j < 4; j++) {
                      var alt = (imgs[j].getAttribute('alt') || '').trim();
                      var im = /^@?([a-z0-9._-]{1,40})(?:のプロフィール写真|'s profile picture)/i.exec(alt);
                      if (im && im[1]) return im[1].toLowerCase();
                    }
                    cur = cur.parentElement;
                  }
                  if (typeof window.__omniResolveProfileHandle === 'function') {
                    return window.__omniResolveProfileHandle() || '';
                  }
                } catch (_) {}
                return '';
              }

              document.addEventListener('click', function(e) {
                try {
                  if (e && (e.isTrusted === false || e.button !== 0 || e.ctrlKey || e.metaKey)) return;
                  bumpUserInteraction(false);
                  var clickInteractionId = currentInteractionId();
                  var target = e.target;
                  if (!target) return;
                  if (target.nodeType !== 1) target = target.parentElement;
                  if (!target || typeof target.closest !== 'function') return;
                  var btn = target.closest('button, [role="button"], a');
                  if (!btn) return;

                  var isFollowBtn = isFollowButtonElement(btn);
                  var isUnfollowBtn = !isFollowBtn && isUnfollowButtonElement(btn);
                  if (!isFollowBtn && !isUnfollowBtn) return;

                  var clickedAt = Date.now();
                  var clickedHandle = extractHandleNearButton(btn);
                  if (clickedHandle) {
                    lastClickedTargetHandle = clickedHandle;
                    lastClickedTargetAt = clickedAt;
                  }
                  var hadDialog = !!document.querySelector('[role="dialog"]');
                  var inDialog = !!btn.closest('[role="dialog"]');
                  var initialLabels = readElementLabels(btn);

                  if (isFollowBtn) {
                    var fst = states.follow;
                    setTimeout(function() {
                      try {
                        if (fst.inFlight > 0 ||
                            fst.lastNetworkStartAt >= clickedAt - 300 ||
                            fst.lastNetworkAt >= clickedAt - 300 ||
                            fst.lastAnyEmitAt >= clickedAt - 300) {
                          return;
                        }
                        if (!hadDialog) {
                          var dlg = document.querySelector('[role="dialog"]');
                          if (dlg) {
                            var dlgBtns = dlg.querySelectorAll('button, [role="button"]');
                            for (var i = 0; i < dlgBtns.length; i++) {
                              if (dlgBtns[i] !== btn && isFollowButtonElement(dlgBtns[i])) {
                                return;
                              }
                            }
                          }
                        }
                        if (isElementHidden(btn)) {
                          emitRelation('follow', 'dom', clickedHandle, clickInteractionId);
                          return;
                        }
                        if (btn.getAttribute('aria-pressed') === 'true') {
                          emitRelation('follow', 'dom', clickedHandle, clickInteractionId);
                          return;
                        }
                        var after = readElementLabels(btn);
                        if ((after.text && POST_FOLLOW_STATE_RE.test(after.text)) ||
                            (after.aria && POST_FOLLOW_STATE_RE.test(after.aria))) {
                          emitRelation('follow', 'dom', clickedHandle, clickInteractionId);
                          return;
                        }
                        if ((after.text !== initialLabels.text || after.aria !== initialLabels.aria) &&
                            !isFollowButtonElement(btn)) {
                          emitRelation('follow', 'dom', clickedHandle, clickInteractionId);
                        }
                      } catch (_) {}
                    }, 1000);
                  } else if (isUnfollowBtn) {
                    var ust = states.unfollow;
                    var isConfirmBtn = inDialog && CONFIRM_UNFOLLOW_TEXT_RE.test(initialLabels.text || '');
                    setTimeout(function() {
                      try {
                        if (ust.inFlight > 0 ||
                            ust.lastNetworkStartAt >= clickedAt - 300 ||
                            ust.lastNetworkAt >= clickedAt - 300 ||
                            ust.lastAnyEmitAt >= clickedAt - 300) {
                          return;
                        }
                        if (!hadDialog) {
                          var dlg2 = document.querySelector('[role="dialog"]');
                          if (dlg2) {
                            return;
                          }
                        }
                        if (isConfirmBtn && isElementHidden(btn)) {
                          emitRelation('unfollow', 'dom', clickedHandle, clickInteractionId);
                          return;
                        }
                        var afterU = readElementLabels(btn);
                        if ((afterU.text && EXACT_FOLLOW_TEXT_RE.test(afterU.text)) ||
                            (!afterU.text && afterU.aria && ARIA_FOLLOW_RE.test(afterU.aria))) {
                          emitRelation('unfollow', 'dom', clickedHandle, clickInteractionId);
                        }
                      } catch (_) {}
                    }, 1000);
                  }
                } catch (_) {}
              }, true);
            })();
        """.trimIndent()

        /**
         * Instagram / Threads / Bluesky のフォロワー一覧・フィード等で、ページ遷移なしで
         * 各ユーザーのフォロー数・フォロワー数・投稿数・非公開状態をインライン取得＆表示し、
         * ログイン中アカウント自身のハンドルと SNS 実数もホスト（Dart側）へ通知するスクリプト。
         */
        private val PROFILE_STATS_JS_PART_1: String = """
(function() {
  if (window !== window.top) return;
  if (window.__omniProfileStatsInstalled) return;
  window.__omniProfileStatsInstalled = true;
  var __omniFollowToken = "__OMNISNS_FOLLOW_TOKEN__";
  var __omniFollowChannel = window.OmniFollowChannel;
  var __omniFollowBridge = window.OmniFollowBridge;

  var host = (window.location && window.location.hostname || '').toLowerCase();
  if (!host || host === 'localhost' || host === '127.0.0.1') return;

  // 認証・メール・決済系ホストでは動作させない
  if (/^(?:mail|accounts|login|auth|oauth|sso|id|signin|signup|checkout|pay)\./i.test(host) ||
      /(?:^|\.)(?:google\.com|googleapis\.com|gstatic\.com|appleid\.apple\.com|microsoftonline\.com|live\.com|recaptcha\.net|hcaptcha\.com|stripe\.com|paypal\.com|cloudflare\.com)$/i.test(host)) {
    return;
  }

  function detectPlatform(h) {
    if (h === 'instagram.com' || h.endsWith('.instagram.com')) return 'instagram';
    if (h === 'threads.com' || h.endsWith('.threads.com') || h === 'threads.net' || h.endsWith('.threads.net')) return 'threads';
    if (h === 'bsky.app' || h.endsWith('.bsky.app')) return 'bluesky';
    if (h === 'tiktok.com' || h.endsWith('.tiktok.com')) return 'tiktok';
    if (h === 'facebook.com' || h.endsWith('.facebook.com') || h === 'messenger.com' || h.endsWith('.messenger.com')) return 'facebook';
    if (h === 'mixi.social' || h.endsWith('.mixi.social')) return 'mixi2';
    if (h === 'mixi.jp' || h.endsWith('.mixi.jp')) return 'mixi';
    if (h === 'reddit.com' || h.endsWith('.reddit.com')) return 'reddit';
    if (/(?:^|\.)pinterest\.[a-z.]+$/i.test(h)) return 'pinterest';
    if (h === 'tumblr.com' || h.endsWith('.tumblr.com')) return 'tumblr';
    if (h === 'weibo.com' || h.endsWith('.weibo.com') || h === 'weibo.cn' || h.endsWith('.weibo.cn')) return 'weibo';
    if (h === 'vk.com' || h.endsWith('.vk.com')) return 'vk';
    if (h === 'pixiv.net' || h.endsWith('.pixiv.net')) return 'pixiv';
    if (h === 'twitch.tv' || h.endsWith('.twitch.tv')) return 'twitch';
    if (h === 'linkedin.com' || h.endsWith('.linkedin.com')) return 'linkedin';
    if (h === 'behance.net' || h.endsWith('.behance.net')) return 'behance';
    if (h === 'dribbble.com' || h.endsWith('.dribbble.com')) return 'dribbble';
    if (h === 'deviantart.com' || h.endsWith('.deviantart.com')) return 'deviantart';
    if (h === 'ameblo.jp' || h.endsWith('.ameblo.jp') || h === 'ameba.jp' || h.endsWith('.ameba.jp')) return 'ameba';
    if (h === 'x.com' || h.endsWith('.x.com') || h === 'twitter.com' || h.endsWith('.twitter.com')) return 'x';
    if (/mastodon|mstdn|pawoo\.net|fedibird\.com|baraag\.net/i.test(h)) return 'mastodon';
    if (/misskey/i.test(h)) return 'misskey';
    return 'generic';
  }

  var platform = detectPlatform(host);
  var isChatOnlyPlatform = /(?:^|\.)(?:discord\.com|telegram\.org|whatsapp\.com|slack\.com|teams\.microsoft\.com|chatwork\.com|element\.io|steamcommunity\.com|tinder\.com|bumble\.com|okcupid\.com|badoo\.com|pof\.com)$/i.test(host);

  var RESERVED_SEGMENTS = {
    explore: 1, direct: 1, reels: 1, reel: 1, p: 1, tv: 1, stories: 1, accounts: 1,
    about: 1, legal: 1, developer: 1, developers: 1, settings: 1, search: 1, activity: 1,
    notifications: 1, messages: 1, messaging: 1, home: 1, login: 1, signup: 1, hashtag: 1, tags: 1,
    profile: 1, profiles: 1, lists: 1, feeds: 1, moderation: 1, post: 1, posts: 1, intent: 1, challenge: 1,
    privacy: 1, terms: 1, help: 1, support: 1, download: 1, apps: 1, api: 1, graphql: 1,
    web: 1, static: 1, assets: 1, following: 1, followers: 1, saved: 1, tagged: 1,
    channel: 1, audio: 1, locations: 1, directory: 1, nametag: 1, session: 1, oauth: 1,
    watch: 1, video: 1, videos: 1, live: 1, groups: 1, marketplace: 1, events: 1, pages: 1,
    friends: 1, bookmarks: 1, discover: 1, trending: 1, topics: 1, news: 1, jobs: 1,
    feed: 1, inbox: 1, chat: 1, channels: 1, community: 1, communities: 1, notes: 1,
    my: 1, me: 1, dashboard: 1, create: 1, edit: 1, upload: 1, share: 1, status: 1,
    artworks: 1, novels: 1, manga: 1, illustrations: 1, ranking: 1, contest: 1,
    shots: 1, galleries: 1, projects: 1, work: 1, hire: 1, pro: 1, premium: 1,
    r: 1, comments: 1, submit: 1, wiki: 1, prefs: 1, im: 1, photo: 1, photos: 1, music: 1
  };

  var CACHE_KEY = 'omnisns_ff_cache_v3_' + platform + '_' + host.replace(/[^a-z0-9.-]/g, '');
  var REL_SET_KEY = 'omnisns_rel_sets_v1_' + platform + '_' + host.replace(/[^a-z0-9.-]/g, '');
  var FOLLOWED_AT_KEY = 'omnisns_followed_at_v1_' + platform + '_' + host.replace(/[^a-z0-9.-]/g, '');
  var CACHE_TTL_MS = 6 * 60 * 60 * 1000;
  var FOLLOWED_AT_TTL_MS = 180 * 24 * 60 * 60 * 1000;
  var MAX_CACHE_ENTRIES = 600;
  var MAX_FOLLOWED_AT_ENTRIES = 3000;
  var statsMap = Object.create(null);
  var followedAtMap = Object.create(null);
  var userIdMap = Object.create(null);
  var idToHandleMap = Object.create(null);
  var privateMap = Object.create(null);
  var failedMap = Object.create(null);
  var inFlight = Object.create(null);
  var relQueriedMap = Object.create(null);
  var selfFollowersSet = Object.create(null);
  var selfFollowingSet = Object.create(null);
  var queue = [];
  var queuedSet = Object.create(null);
  var activeWorkers = 0;
  var igConcurrency = 2;
  var queueStartTimer = null;
  var relBatchTimer = null;
  var relBatchRunning = false;
  var backoffUntil = 0;
  var consecutiveFailures = 0;
  var preferredIgRoute = '';
  var routeFailCount = Object.create(null);
  var deadRouteUntil = Object.create(null);
  var selfHandle = '';
  var selfDid = '';
  var selfIdFetchStarted = false;
  var selfDidFetchStarted = false;
  var lastPostedIdentityKey = '';
  var persistTimer = null;
  var relSetPersistTimer = null;
  var renderTimer = null;
  var appliedThemeMode = '';
  var pageBooted = false;
  var lastScrollScanAt = 0;

  var capturedHeaders = Object.create(null);
  var capturedProfileGql = null;
  var capturedMisskeyToken = '';

  function runWhenIdle(fn, timeoutMs) {
    if (typeof window.requestIdleCallback === 'function') {
      window.requestIdleCallback(fn, { timeout: timeoutMs || 600 });
    } else {
      setTimeout(fn, 16);
    }
  }

  function injectInstagramPreconnects() {
    if (platform !== 'instagram') return;
    try {
      var head = document.head || document.documentElement;
      if (!head || document.getElementById('omni-ig-preconnect')) return;
      var hosts = ['https://static.cdninstagram.com', 'https://scontent.cdninstagram.com', 'https://i.instagram.com'];
      for (var i = 0; i < hosts.length; i++) {
        var link = document.createElement('link');
        if (i === 0) link.id = 'omni-ig-preconnect';
        link.rel = 'preconnect';
        link.href = hosts[i];
        link.crossOrigin = 'anonymous';
        head.appendChild(link);
      }
    } catch (_) {}
  }

  function getCookieValue(name) {
    try {
      var cookies = document.cookie ? document.cookie.split(';') : [];
      var prefix = name + '=';
      for (var i = 0; i < cookies.length; i++) {
        var c = cookies[i].trim();
        if (c.indexOf(prefix) === 0) {
          return decodeURIComponent(c.slice(prefix.length));
        }
      }
    } catch (_) {}
    return '';
  }

  function getStorage() {
    try {
      if (window.localStorage) return window.localStorage;
    } catch (_) {}
    try {
      if (window.sessionStorage) return window.sessionStorage;
    } catch (_) {}
    return null;
  }

  function loadCache() {
    try {
      var st = getStorage();
      if (!st) return;
      var raw = st.getItem(CACHE_KEY);
      if (raw) {
        var parsed = JSON.parse(raw);
        if (parsed && typeof parsed === 'object') {
          var now = Date.now();
          for (var k in parsed) {
            var e = parsed[k];
            if (e && typeof e === 'object' && now - (e.ts || 0) < CACHE_TTL_MS) {
              statsMap[k] = {
                followers: typeof e.followers === 'number' ? e.followers : null,
                following: typeof e.following === 'number' ? e.following : null,
                posts: typeof e.posts === 'number' ? e.posts : null,
                isPrivate: typeof e.isPrivate === 'boolean' ? e.isPrivate : null,
                iFollow: typeof e.iFollow === 'boolean' ? e.iFollow : null,
                followsMe: typeof e.followsMe === 'boolean' ? e.followsMe : null,
                ts: e.ts || now
              };
              if (typeof e.isPrivate === 'boolean') privateMap[k] = e.isPrivate;
            }
          }
        }
      }
      var rawSets = st.getItem(REL_SET_KEY);
      if (rawSets) {
        var ps = JSON.parse(rawSets);
        if (ps && typeof ps === 'object') {
          if (Array.isArray(ps.followers)) {
            for (var fi = 0; fi < ps.followers.length; fi++) selfFollowersSet[ps.followers[fi]] = true;
          }
          if (Array.isArray(ps.following)) {
            for (var gi = 0; gi < ps.following.length; gi++) selfFollowingSet[ps.following[gi]] = true;
          }
        }
      }
      loadFollowedAtFromStorage(st);
    } catch (_) {}
  }

  function loadFollowedAtFromStorage(st) {
    try {
      var store = st || getStorage();
      if (!store) return;
      var raw = store.getItem(FOLLOWED_AT_KEY);
      if (!raw) return;
      var parsed = JSON.parse(raw);
      if (!parsed || typeof parsed !== 'object') return;
      var now = Date.now();
      var nextMap = Object.create(null);
      for (var k in parsed) {
        var ts = parsed[k];
        if (typeof ts === 'number' && isFinite(ts) && ts > 0 && now - ts < FOLLOWED_AT_TTL_MS) {
          nextMap[k] = ts;
        }
      }
      followedAtMap = nextMap;
    } catch (_) {}
  }

  function persistFollowedAtNow() {
    try {
      var st = getStorage();
      if (!st) return;
      var keys = Object.keys(followedAtMap);
      if (keys.length > MAX_FOLLOWED_AT_ENTRIES) {
        keys.sort(function(a, b) { return (followedAtMap[b] || 0) - (followedAtMap[a] || 0); });
        var trimmed = Object.create(null);
        for (var i = 0; i < MAX_FOLLOWED_AT_ENTRIES; i++) trimmed[keys[i]] = followedAtMap[keys[i]];
        followedAtMap = trimmed;
      }
      st.setItem(FOLLOWED_AT_KEY, JSON.stringify(followedAtMap));
    } catch (_) {}
  }

  function rememberFollowedAt(handle, ts) {
    if (!handle || handle === selfHandle) return;
    var stamp = typeof ts === 'number' && isFinite(ts) && ts > 0 ? Math.floor(ts) : Date.now();
    followedAtMap[handle] = stamp;
    persistFollowedAtNow();
  }

  function forgetFollowedAt(handle) {
    if (!handle || !followedAtMap[handle]) return;
    delete followedAtMap[handle];
    persistFollowedAtNow();
  }

  function formatOnewayElapsedCompact(followedTs) {
    if (typeof followedTs !== 'number' || !isFinite(followedTs) || followedTs <= 0) return '';
    var diffMs = Date.now() - followedTs;
    if (diffMs < 0) diffMs = 0;
    var totalMins = Math.floor(diffMs / 60000);
    if (totalMins < 60) return totalMins + '分';
    var totalHours = Math.floor(totalMins / 60);
    return totalHours + '時間';
  }

  function formatOnewayElapsedDetail(followedTs) {
    try {
      var d = new Date(followedTs);
      var pad2 = function(n) { return n < 10 ? '0' + n : String(n); };
      var dateStr = (d.getMonth() + 1) + '/' + d.getDate() + ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
      var diffMs = Math.max(0, Date.now() - followedTs);
      var totalMins = Math.floor(diffMs / 60000);
      var hrs = Math.floor(totalMins / 60);
      var mins = totalMins % 60;
      var dur = hrs > 0 ? (hrs + '時間' + mins + '分') : (mins + '分');
      return 'フォロー日時: ' + dateStr + '（経過 ' + dur + '）';
    } catch (_) {
      return '';
    }
  }

  function schedulePersistCache() {
    if (persistTimer) return;
    persistTimer = setTimeout(function() {
      persistTimer = null;
      try {
        var st = getStorage();
        if (!st) return;
        var keys = Object.keys(statsMap);
        if (keys.length > MAX_CACHE_ENTRIES) {
          keys.sort(function(a, b) { return (statsMap[b].ts || 0) - (statsMap[a].ts || 0); });
          var trimmed = Object.create(null);
          for (var i = 0; i < MAX_CACHE_ENTRIES; i++) trimmed[keys[i]] = statsMap[keys[i]];
          statsMap = trimmed;
        }
        st.setItem(CACHE_KEY, JSON.stringify(statsMap));
      } catch (_) {}
    }, 1500);
  }

  function schedulePersistRelSets() {
    if (relSetPersistTimer) return;
    relSetPersistTimer = setTimeout(function() {
      relSetPersistTimer = null;
      try {
        var st = getStorage();
        if (!st) return;
        var followers = Object.keys(selfFollowersSet).slice(-1500);
        var following = Object.keys(selfFollowingSet).slice(-1500);
        st.setItem(REL_SET_KEY, JSON.stringify({ followers: followers, following: following }));
      } catch (_) {}
    }, 2000);
  }

  function rememberSelfFollower(handle) {
    if (!handle || handle === selfHandle) return;
    if (!selfFollowersSet[handle]) {
      selfFollowersSet[handle] = true;
      schedulePersistRelSets();
    }
  }

  function rememberSelfFollowing(handle, isFollowing) {
    if (!handle || handle === selfHandle) return;
    if (isFollowing) {
      if (!selfFollowingSet[handle]) {
        selfFollowingSet[handle] = true;
        schedulePersistRelSets();
      }
    } else if (selfFollowingSet[handle]) {
      delete selfFollowingSet[handle];
      schedulePersistRelSets();
    }
  }

  function detectDynamicPlatformFromDom() {
    if (platform !== 'generic') return;
    try {
      var gen = document.querySelector('meta[name="generator"]');
      var genContent = gen ? (gen.getAttribute('content') || '').toLowerCase() : '';
      var appName = document.querySelector('meta[name="application-name"]');
      var appContent = appName ? (appName.getAttribute('content') || '').toLowerCase() : '';
      if (genContent.indexOf('mastodon') >= 0 || document.getElementById('mastodon') ||
          document.querySelector('script#initial-state[type="application/json"]')) {
        platform = 'mastodon';
        return;
      }
      if (appContent.indexOf('misskey') >= 0 || genContent.indexOf('misskey') >= 0 ||
          document.getElementById('misskey_app') || document.querySelector('meta[name="misskey"]')) {
        platform = 'misskey';
      }
    } catch (_) {}
  }

  function isValidHandle(h) {
    if (!h || typeof h !== 'string') return false;
    var clean = h.replace(/^@+/, '').trim().toLowerCase();
    if (!clean || clean.length > 80) return false;
    if (RESERVED_SEGMENTS[clean]) return false;
    if (platform === 'bluesky') {
      return /^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/.test(clean) || /^did:[a-z0-9:._-]+$/.test(clean);
    }
    if (platform === 'mastodon' || platform === 'misskey') {
      return /^[a-z0-9._-]{1,40}(?:@[a-z0-9.-]+\.[a-z]{2,})?$/.test(clean);
    }
    if (platform === 'pixiv' || platform === 'weibo' || platform === 'mixi') {
      return /^[a-z0-9._-]{1,48}$/.test(clean);
    }
    if (platform === 'instagram' || platform === 'threads' || platform === 'tiktok') {
      return /^[a-z0-9._]{1,35}$/.test(clean);
    }
    return /^[a-z0-9._-]{1,48}$/.test(clean);
  }

  function normalizeHandle(h) {
    if (!h || typeof h !== 'string') return '';
    var clean = h.replace(/^@+/, '').trim().toLowerCase();
    return isValidHandle(clean) ? clean : '';
  }

  function bindUserId(handle, rawId) {
    if (!handle || rawId === undefined || rawId === null) return;
    var idStr = String(rawId).trim();
    if (!idStr) return;
    if (/^\d{3,24}$/.test(idStr) || /^did:[a-z0-9:._-]+$/i.test(idStr) ||
        ((platform === 'mastodon' || platform === 'misskey') && /^[a-z0-9_-]{4,36}$/i.test(idStr))) {
      userIdMap[handle] = idStr;
      idToHandleMap[idStr] = handle;
      idToHandleMap[idStr.toLowerCase()] = handle;
    }
  }

  function formatCompactCount(n) {
    if (typeof n !== 'number' || !isFinite(n) || n < 0) return '';
    if (n >= 100000000) return (n / 100000000).toFixed(1).replace(/\.0$/, '') + '億';
    if (n >= 10000) {
      var man = n / 10000;
      return (man >= 100 ? Math.round(man).toString() : man.toFixed(1).replace(/\.0$/, '')) + '万';
    }
    return n.toLocaleString('ja-JP');
  }

  function parseHumanNumber(raw) {
    if (raw === null || raw === undefined) return null;
    if (typeof raw === 'number') return isFinite(raw) && raw >= 0 ? Math.round(raw) : null;
    var s = String(raw).replace(/,/g, '').trim();
    if (!s) return null;
    var m = /^([0-9]+(?:\.[0-9]+)?)\s*([KMB万千億])?$/i.exec(s);
    if (!m) return null;
    var val = parseFloat(m[1]);
    if (!isFinite(val)) return null;
    var unit = (m[2] || '').toUpperCase();
    if (unit === 'K' || unit === '千') val *= 1000;
    else if (unit === '万') val *= 10000;
    else if (unit === 'M') val *= 1000000;
    else if (unit === '億') val *= 100000000;
    else if (unit === 'B') val *= 1000000000;
    return Math.round(val);
  }

  function postIdentityToHost(handle, following, followers) {
    if (!handle) return;
    var key = handle + '|' + (following === null ? '' : following) + '|' + (followers === null ? '' : followers);
    if (key === lastPostedIdentityKey) return;
    lastPostedIdentityKey = key;
    var flwng = typeof following === 'number' ? Math.round(following) : -1;
    var flwrs = typeof followers === 'number' ? Math.round(followers) : -1;
    try {
      var ch = __omniFollowChannel || window.OmniFollowChannel;
      if (ch && typeof ch.postMessage === 'function') {
        ch.postMessage(JSON.stringify({
          token: __omniFollowToken,
          type: 'identity',
          service: platform,
          handle: handle,
          following: flwng,
          followers: flwrs
        }));
      } else {
        var br = __omniFollowBridge || window.OmniFollowBridge;
        if (br && typeof br.onAccountIdentity === 'function') {
          br.onAccountIdentity(__omniFollowToken, platform, handle, flwng, flwrs);
        }
      }
    } catch (_) {}
  }

  function fetchBlueskySelfDid(handle) {
    if (platform !== 'bluesky' || selfDid || selfDidFetchStarted || !handle) return;
    if (/^did:/i.test(handle)) {
      selfDid = handle;
      return;
    }
    selfDidFetchStarted = true;
    internalFetch('https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile?actor=' + encodeURIComponent(handle), {
      method: 'GET'
    }).then(function(res) {
      if (!res || !res.ok) return;
      return res.json().then(function(p) {
        if (p && typeof p.did === 'string' && p.did) {
          selfDid = p.did;
          bindUserId(handle, p.did);
        }
        if (p && p.handle) {
          recordStats(p.handle, p.followersCount, p.followsCount, null, null, null, null);
        }
        scheduleRelBatch();
      }).catch(function() {});
    }).catch(function() {});
  }

  function setSelfHandle(raw) {
    var h = normalizeHandle(raw);
    if (!h) return;
    var changed = h !== selfHandle;
    selfHandle = h;
    var cached = statsMap[h];
    postIdentityToHost(h, cached ? cached.following : null, cached ? cached.followers : null);
    if (platform === 'bluesky' && !selfDid) {
      if (userIdMap[h] && /^did:/i.test(userIdMap[h])) {
        selfDid = userIdMap[h];
      } else {
        fetchBlueskySelfDid(h);
      }
    }
    if (changed && (!cached || (cached.following === null && cached.followers === null))) {
      enqueueFetch(h, true, false);
    }
  }

  function hasUsableStats(entry) {
    return !!(entry && (typeof entry.followers === 'number' || typeof entry.following === 'number'));
  }

  function computeRelation(entry, handle) {
    if (!handle || handle === selfHandle) return '';
    var iFollow = entry && typeof entry.iFollow === 'boolean' ? entry.iFollow : (selfFollowingSet[handle] ? true : null);
    var followsMe = entry && typeof entry.followsMe === 'boolean' ? entry.followsMe : (selfFollowersSet[handle] ? true : null);
    if (iFollow === true && followsMe === true) return 'mutual';
    if (iFollow === true && followsMe === false) return 'oneway';
    if (iFollow === false && followsMe === true) return 'follower';
    if (iFollow === null && followsMe === true) return 'follower';
    return '';
  }

  function hasAnyDisplayData(entry, handle) {
    return hasUsableStats(entry) || !!computeRelation(entry, handle);
  }

  function recordStats(rawHandle, followers, following, posts, isPrivate, iFollow, followsMe) {
    var h = normalizeHandle(rawHandle);
    if (!h) return false;
    var f1 = typeof followers === 'number' && isFinite(followers) && followers >= 0 ? Math.round(followers) : null;
    var f2 = typeof following === 'number' && isFinite(following) && following >= 0 ? Math.round(following) : null;
    var p = typeof posts === 'number' && isFinite(posts) && posts >= 0 ? Math.round(posts) : null;
    var priv = typeof isPrivate === 'boolean' ? isPrivate : (typeof privateMap[h] === 'boolean' ? privateMap[h] : null);
    var relOut = typeof iFollow === 'boolean' ? iFollow : null;
    var relIn = typeof followsMe === 'boolean' ? followsMe : null;
    if (typeof isPrivate === 'boolean') privateMap[h] = isPrivate;
    if (relIn === true) rememberSelfFollower(h);
    if (relOut !== null) rememberSelfFollowing(h, relOut);
    if (f1 === null && f2 === null && relOut === null && relIn === null) return false;

    if (f1 !== null || f2 !== null) delete failedMap[h];
    var prev = statsMap[h];
    var nextFollowers = f1 !== null ? f1 : (prev ? prev.followers : null);
    var nextFollowing = f2 !== null ? f2 : (prev ? prev.following : null);
    var nextPosts = p !== null ? p : (prev ? prev.posts : null);
    var nextPriv = priv !== null ? priv : (prev ? prev.isPrivate : null);
    var nextIFollow = relOut !== null ? relOut : (prev ? prev.iFollow : null);
    var nextFollowsMe = relIn !== null ? relIn : (prev ? prev.followsMe : null);
    if (prev && prev.iFollow === false && nextIFollow === true && !followedAtMap[h]) {
      rememberFollowedAt(h, Date.now());
    } else if (nextIFollow === false && followedAtMap[h]) {
      forgetFollowedAt(h);
    }
    var changed = !prev ||
      prev.followers !== nextFollowers ||
      prev.following !== nextFollowing ||
      prev.posts !== nextPosts ||
      prev.isPrivate !== nextPriv ||
      prev.iFollow !== nextIFollow ||
      prev.followsMe !== nextFollowsMe;
    statsMap[h] = {
      followers: nextFollowers,
      following: nextFollowing,
      posts: nextPosts,
      isPrivate: nextPriv,
      iFollow: nextIFollow,
      followsMe: nextFollowsMe,
      ts: Date.now()
    };
    if (changed) {
      schedulePersistCache();
      scheduleRenderBadges();
    }
    if (h === selfHandle) {
      postIdentityToHost(h, nextFollowing, nextFollowers);
    }
    return true;
  }

  function recordRelation(rawHandle, iFollow, followsMe) {
    return recordStats(rawHandle, null, null, null, null, iFollow, followsMe);
  }

  // フォロー／アンフォロー操作を即座に記憶・バッジへ反映するフック
  window.__omniOnFollowAction = function(action, targetKey, fallbackHandle) {
    try {
      var isFollow = action === 'follow';
      var key = String(targetKey || '').trim().toLowerCase();
      var h = '';
      if (key) {
        if (idToHandleMap[key]) h = idToHandleMap[key];
        else if (!/^\d+$/.test(key)) h = normalizeHandle(key);
      }
      if (!h && fallbackHandle) {
        h = normalizeHandle(fallbackHandle);
        if (h && key && /^\d+$/.test(key)) {
          idToHandleMap[key] = h;
          userIdMap[h] = key;
        }
      }
      if (!h) h = getCurrentProfileHandleFromUrl();
      if (h && h !== selfHandle) {
        if (isFollow) {
          var prevTs = followedAtMap[h];
          if (!prevTs || Date.now() - prevTs > 5000) {
            rememberFollowedAt(h, Date.now());
          }
        } else {
          forgetFollowedAt(h);
        }
        recordRelation(h, isFollow, null);
        if (isFollow) {
          enqueueFetch(h, true, false);
          scheduleRelBatch(120);
        }
        scheduleRenderBadges(60);
      }
    } catch (_) {}
  };

  function extractRelationFromObject(obj) {
    var iFollow = null;
    var followsMe = null;
    if (!obj || typeof obj !== 'object') return { iFollow: null, followsMe: null };

    // Instagram / Threads friendship_status
    var fs = obj.friendship_status || obj.friendshipStatus || obj.relationship;
    if (fs && typeof fs === 'object') {
      if (typeof fs.following === 'boolean') iFollow = fs.following;
      else if (typeof fs.is_following === 'boolean') iFollow = fs.is_following;
      else if (typeof fs.isFollowing === 'boolean') iFollow = fs.isFollowing;

      if (typeof fs.followed_by === 'boolean') followsMe = fs.followed_by;
      else if (typeof fs.followedBy === 'boolean') followsMe = fs.followedBy;
      else if (typeof fs.is_followed_by === 'boolean') followsMe = fs.is_followed_by;
      else if (typeof fs.isFollowedBy === 'boolean') followsMe = fs.isFollowedBy;
      else if (typeof fs.is_followed === 'boolean') followsMe = fs.is_followed;
      else if (typeof fs.isFollowed === 'boolean') followsMe = fs.isFollowed;
    }

    // Bluesky viewer object
    if (obj.viewer && typeof obj.viewer === 'object') {
      if ('following' in obj.viewer) iFollow = !!obj.viewer.following;
      if ('followedBy' in obj.viewer) followsMe = !!obj.viewer.followedBy;
      if (typeof obj.viewer.isFollowing === 'boolean') iFollow = obj.viewer.isFollowing;
      if (typeof obj.viewer.isFollowedBy === 'boolean') followsMe = obj.viewer.isFollowedBy;
    }

    // Direct flags across Instagram / Threads / Misskey / Mastodon / mixi2 / Weibo / pixiv / X / Generic
    if (iFollow === null) {
      if (typeof obj.followed_by_viewer === 'boolean') iFollow = obj.followed_by_viewer;
      else if (typeof obj.followedByViewer === 'boolean') iFollow = obj.followedByViewer;
      else if (typeof obj.is_following === 'boolean') iFollow = obj.is_following;
      else if (typeof obj.isFollowing === 'boolean') iFollow = obj.isFollowing;
      else if (typeof obj.following === 'boolean') iFollow = obj.following;
      else if (typeof obj.viewer_is_following === 'boolean') iFollow = obj.viewer_is_following;
      else if (typeof obj.text_post_app_is_following === 'boolean') iFollow = obj.text_post_app_is_following;
      else if (typeof obj.is_followed_by_viewer === 'boolean') iFollow = obj.is_followed_by_viewer;
    }
    if (followsMe === null) {
      if (typeof obj.follows_viewer === 'boolean') followsMe = obj.follows_viewer;
      else if (typeof obj.followsViewer === 'boolean') followsMe = obj.followsViewer;
      else if (typeof obj.followed_by === 'boolean') followsMe = obj.followed_by;
      else if (typeof obj.followedBy === 'boolean') followsMe = obj.followedBy;
      else if (typeof obj.is_followed === 'boolean') followsMe = obj.is_followed;
      else if (typeof obj.isFollowed === 'boolean') followsMe = obj.isFollowed;
      else if (typeof obj.is_followed_by === 'boolean') followsMe = obj.is_followed_by;
      else if (typeof obj.isFollowedBy === 'boolean') followsMe = obj.isFollowedBy;
      else if (typeof obj.follow_me === 'boolean') followsMe = obj.follow_me;
      else if (typeof obj.follows_me === 'boolean') followsMe = obj.follows_me;
      else if (typeof obj.followsMe === 'boolean') followsMe = obj.followsMe;
      else if (typeof obj.is_following_viewer === 'boolean') followsMe = obj.is_following_viewer;
    }

    // TikTok numeric relation / followStatus / followerStatus
    if (typeof obj.relation === 'number') {
      if (obj.relation === 2) { iFollow = true; followsMe = true; }
      else if (obj.relation === 1) { iFollow = true; followsMe = false; }
      else if (obj.relation === 3) { iFollow = false; followsMe = true; }
      else if (obj.relation === 0) { iFollow = false; followsMe = false; }
    }
    if (typeof obj.followStatus === 'number') {
      if (obj.followStatus === 2) { iFollow = true; followsMe = true; }
      else if (obj.followStatus === 1) { iFollow = true; }
      else if (obj.followStatus === 0 && iFollow === null) { iFollow = false; }
    }
    if (typeof obj.followerStatus === 'number') {
      if (obj.followerStatus === 1) followsMe = true;
      else if (obj.followerStatus === 0 && followsMe === null) followsMe = false;
    }

    // Explicit mutual / friend indicators (Facebook / VK / Generic)
    if (obj.is_mutual === true || obj.isMutual === true || obj.mutual_follow === true ||
        obj.is_viewer_friend === true || obj.are_friends === true ||
        obj.friendship_status === 'ARE_FRIENDS' || obj.friend_status === 3) {
      iFollow = true;
      followsMe = true;
    } else if (obj.friend_status === 1 && iFollow === null) {
      iFollow = true;
      followsMe = false;
    } else if (obj.friend_status === 2 && followsMe === null) {
      iFollow = false;
      followsMe = true;
    }

    return { iFollow: iFollow, followsMe: followsMe };
  }

  function extractFromJsonObject(root) {
    if (!root || typeof root !== 'object') return false;
    var foundStats = false;
    var stack = [{ node: root, depth: 0 }];
    var visited = 0;
    while (stack.length > 0 && visited < 1600) {
      var cur = stack.pop();
      var obj = cur.node;
      var depth = cur.depth;
      if (!obj || typeof obj !== 'object' || depth > 12) continue;
      visited++;
      if (Array.isArray(obj)) {
        for (var i = obj.length - 1; i >= 0; i--) {
          if (obj[i] && typeof obj[i] === 'object') {
            stack.push({ node: obj[i], depth: depth + 1 });
          }
        }
        continue;
      }

      // Instagram friendships/show_many map: { friendship_statuses: { "<pk>": { following, followed_by } } }
      if (obj.friendship_statuses && typeof obj.friendship_statuses === 'object' && !Array.isArray(obj.friendship_statuses)) {
        var fMap = obj.friendship_statuses;
        var fKeys = Object.keys(fMap);
        for (var fi = 0; fi < fKeys.length && fi < 200; fi++) {
          var pk = fKeys[fi];
          var stObj = fMap[pk];
          var mappedHandle = idToHandleMap[pk];
          if (mappedHandle && stObj && typeof stObj === 'object') {
            var rMany = extractRelationFromObject(stObj);
            if (rMany.iFollow !== null || rMany.followsMe !== null) {
              if (recordRelation(mappedHandle, rMany.iFollow, rMany.followsMe)) foundStats = true;
            }
          }
        }
      }

      // Bluesky app.bsky.graph.getRelationships response item: { did, following, followedBy }
      if (typeof obj.did === 'string' && obj.did.indexOf('did:') === 0 &&
          ('following' in obj || 'followedBy' in obj) && !obj.handle) {
        var bskyHandle = idToHandleMap[obj.did] || idToHandleMap[obj.did.toLowerCase()];
        if (bskyHandle) {
          var bOut = typeof obj.following === 'string' ? true : (obj.following === undefined ? false : !!obj.following);
          var bIn = typeof obj.followedBy === 'string' ? true : (obj.followedBy === undefined ? false : !!obj.followedBy);
          if (recordRelation(bskyHandle, bOut, bIn)) foundStats = true;
        }
      }

      // Mastodon /api/v1/accounts/relationships item: { id, following: bool, followed_by: bool }
      if (typeof obj.id === 'string' && typeof obj.following === 'boolean' && typeof obj.followed_by === 'boolean' && !obj.username) {
        var mHandle = idToHandleMap[obj.id] || idToHandleMap[obj.id.toLowerCase()];
        if (mHandle) {
          if (recordRelation(mHandle, obj.following, obj.followed_by)) foundStats = true;
        }
      }

      var candidateHandle =
        (typeof obj.username === 'string' && obj.username) ||
        (typeof obj.handle === 'string' && obj.handle) ||
        (typeof obj.uniqueId === 'string' && obj.uniqueId) ||
        (typeof obj.acct === 'string' && obj.acct) ||
        (typeof obj.screen_name === 'string' && obj.screen_name) ||
        (typeof obj.screenName === 'string' && obj.screenName) ||
        (typeof obj.userName === 'string' && obj.userName) ||
        (platform === 'pixiv' && typeof obj.userId === 'string' && obj.userId) ||
        '';
      if (candidateHandle) {
        var normH = normalizeHandle(candidateHandle);
        if (normH) {
          var rawId = obj.pk || obj.pk_id || obj.did || obj.id || obj.fbid_v2 || obj.userId;
          bindUserId(normH, rawId);
          var privFlag = typeof obj.is_private === 'boolean' ? obj.is_private
            : (typeof obj.locked === 'boolean' ? obj.locked
            : (typeof obj.isLocked === 'boolean' ? obj.isLocked
            : (typeof obj.privateAccount === 'boolean' ? obj.privateAccount : null)));
          if (typeof privFlag === 'boolean') {
            privateMap[normH] = privFlag;
          }

          var statsSrc = (obj.stats && typeof obj.stats === 'object') ? obj.stats
            : ((obj.authorStats && typeof obj.authorStats === 'object') ? obj.authorStats : null);

          var flwrs = null;
          var flwng = null;
          var posts = null;

          if (typeof obj.follower_count === 'number') flwrs = obj.follower_count;
          else if (typeof obj.followers_count === 'number') flwrs = obj.followers_count;
          else if (typeof obj.text_post_app_follower_count === 'number') flwrs = obj.text_post_app_follower_count;
          else if (typeof obj.followersCount === 'number') flwrs = obj.followersCount;
          else if (typeof obj.followerCount === 'number') flwrs = obj.followerCount;
          else if (obj.edge_followed_by && typeof obj.edge_followed_by.count === 'number') flwrs = obj.edge_followed_by.count;
          else if (statsSrc && typeof statsSrc.followerCount === 'number') flwrs = statsSrc.followerCount;

          if (typeof obj.following_count === 'number') flwng = obj.following_count;
          else if (typeof obj.follows_count === 'number') flwng = obj.follows_count;
          else if (typeof obj.followingCount === 'number') flwng = obj.followingCount;
          else if (typeof obj.followsCount === 'number') flwng = obj.followsCount;
          else if (typeof obj.following === 'number') flwng = obj.following;
          else if (obj.edge_follow && typeof obj.edge_follow.count === 'number') flwng = obj.edge_follow.count;
          else if (statsSrc && typeof statsSrc.followingCount === 'number') flwng = statsSrc.followingCount;

          var rel = extractRelationFromObject(obj);
          if (flwrs !== null || flwng !== null || rel.iFollow !== null || rel.followsMe !== null) {
            if (recordStats(normH, flwrs, flwng, null, privFlag, rel.iFollow, rel.followsMe)) {
              foundStats = true;
            }
          }
        }
      }

      if (typeof obj.viewer_username === 'string' && obj.viewer_username) {
        setSelfHandle(obj.viewer_username);
      } else if (obj.viewer && typeof obj.viewer === 'object' && typeof obj.viewer.username === 'string') {
        setSelfHandle(obj.viewer.username);
      }

      var keys = Object.keys(obj);
      for (var k = 0; k < keys.length; k++) {
        var v = obj[keys[k]];
        if (v && typeof v === 'object') {
          stack.push({ node: v, depth: depth + 1 });
        }
      }
    }
    return foundStats;
  }

  function extractFromHtmlForHandle(html, targetHandle) {
    if (!html || typeof html !== 'string') return false;
    var followers = null;
    var following = null;
    var posts = null;
    var isPrivate = null;
    var iFollow = null;
    var followsMe = null;

    var m1 = /"edge_followed_by"\s*:\s*\{\s*"count"\s*:\s*(\d+)/.exec(html) ||
             /"follower_count"\s*:\s*(\d+)/.exec(html) ||
             /"followers_count"\s*:\s*(\d+)/.exec(html) ||
             /"followersCount"\s*:\s*(\d+)/.exec(html) ||
             /"followerCount"\s*:\s*(\d+)/.exec(html) ||
             /"text_post_app_follower_count"\s*:\s*(\d+)/.exec(html);
    if (m1) followers = parseInt(m1[1], 10);

    var m2 = /"edge_follow"\s*:\s*\{\s*"count"\s*:\s*(\d+)/.exec(html) ||
             /"following_count"\s*:\s*(\d+)/.exec(html) ||
             /"followingCount"\s*:\s*(\d+)/.exec(html) ||
             /"followsCount"\s*:\s*(\d+)/.exec(html);
    if (m2) following = parseInt(m2[1], 10);

    var mPriv = /"(?:is_private|privateAccount|locked)"\s*:\s*(true|false)/.exec(html);
    if (mPriv) isPrivate = mPriv[1] === 'true';

    var mOut = /"(?:followed_by_viewer|followedByViewer|is_following|isFollowing)"\s*:\s*(true|false)/.exec(html);
    if (mOut) iFollow = mOut[1] === 'true';
    var mIn = /"(?:follows_viewer|followsViewer|followed_by|followedBy|is_followed_by|isFollowedBy)"\s*:\s*(true|false)/.exec(html);
    if (mIn) followsMe = mIn[1] === 'true';
    if (platform === 'tiktok') {
      var mRel = /"relation"\s*:\s*([0-3])/.exec(html);
      if (mRel) {
        var rv = parseInt(mRel[1], 10);
        if (rv === 2) { iFollow = true; followsMe = true; }
        else if (rv === 1) { iFollow = true; followsMe = false; }
        else if (rv === 3) { iFollow = false; followsMe = true; }
        else if (rv === 0) { iFollow = false; followsMe = false; }
      }
    }

    if (followers === null || following === null) {
      var metaMatch = /<meta[^>]+(?:name|property)=["'](?:og:description|description)["'][^>]+content=["']([^"']+)["']/i.exec(html) ||
                      /<meta[^>]+content=["']([^"']+)["'][^>]+(?:name|property)=["'](?:og:description|description)["']/i.exec(html);
      if (metaMatch && metaMatch[1]) {
        var desc = metaMatch[1];
        if (followers === null) {
          var mf = /([0-9.,]+[KMB]?)\s+Followers/i.exec(desc) || /フォロワー\s*([0-9.,]+[万千億KMB]?)\s*人?/.exec(desc);
          if (mf) followers = parseHumanNumber(mf[1]);
        }
        if (following === null) {
          var mg = /([0-9.,]+[KMB]?)\s+Following/i.exec(desc) || /フォロー中\s*([0-9.,]+[万千億KMB]?)\s*人?/.exec(desc);
          if (mg) following = parseHumanNumber(mg[1]);
        }
      }
    }

    if (followers !== null || following !== null || iFollow !== null || followsMe !== null) {
      return recordStats(targetHandle, followers, following, null, isPrivate, iFollow, followsMe);
    }
    return false;
  }

  function captureHeaderPair(key, val) {
    if (!key || !val) return;
    var k = String(key).toLowerCase().trim();
    if (k === 'x-ig-app-id' || k === 'x-csrftoken' || k === 'x-ig-www-claim' ||
        k === 'x-asbd-id' || k === 'x-fb-lsd' || k === 'x-bloks-version-id' ||
        k === 'authorization') {
      capturedHeaders[k] = String(val).trim();
    }
  }

  function captureRequestHeaders(headers) {
    if (!headers) return;
    try {
      if (typeof Headers !== 'undefined' && headers instanceof Headers) {
        headers.forEach(function(v, k) { captureHeaderPair(k, v); });
      } else if (Array.isArray(headers)) {
        for (var i = 0; i < headers.length; i++) {
          if (headers[i] && headers[i].length >= 2) captureHeaderPair(headers[i][0], headers[i][1]);
        }
      } else if (typeof headers === 'object') {
        var ks = Object.keys(headers);
        for (var j = 0; j < ks.length; j++) captureHeaderPair(ks[j], headers[ks[j]]);
      }
    } catch (_) {}
  }

  function captureRequestMeta(url, body) {
    var u = String(url || '');
    if (platform === 'generic') {
      if (u.indexOf('/api/v1/accounts') >= 0 || u.indexOf('/api/v1/timelines') >= 0) {
        platform = 'mastodon';
      } else if (u.indexOf('/api/notes/') >= 0 || u.indexOf('/api/users/') >= 0) {
        platform = 'misskey';
      }
    }
    if (platform === 'misskey' && body && typeof body === 'string' && body.indexOf('"i"') >= 0 && body.length < 8192) {
      try {
        var parsed = JSON.parse(body);
        if (parsed && typeof parsed.i === 'string' && parsed.i.length >= 8) {
          capturedMisskeyToken = parsed.i;
        }
      } catch (_) {}
    }
    captureProfileGraphqlTemplate(url, body);
  }

  function captureProfileGraphqlTemplate(url, body) {
    if (platform !== 'instagram' && platform !== 'threads') return;
    if (!url || !body) return;
    var u = String(url);
    if (u.indexOf('/graphql') < 0) return;
    try {
      var str = '';
      if (typeof body === 'string') str = body;
      else if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) str = body.toString();
      if (!str || str.indexOf('doc_id=') < 0) return;
      var params = new URLSearchParams(str);
      var fname = params.get('fb_api_req_friendly_name') || '';
      if (!/PolarisProfilePageContentQuery|PolarisProfileHoverCardQuery|BarcelonaProfileRootQuery|BarcelonaProfilePageQuery/i.test(fname)) {
        return;
      }
      var docId = params.get('doc_id') || '';
      var varsStr = params.get('variables') || '';
      if (!docId || !varsStr) return;
      var varsObj = JSON.parse(varsStr);
      if (!varsObj || typeof varsObj !== 'object') return;
      var idKey = '';
      if (typeof varsObj.id === 'string' || typeof varsObj.id === 'number') idKey = 'id';
      else if (typeof varsObj.userID === 'string' || typeof varsObj.userID === 'number') idKey = 'userID';
      else if (typeof varsObj.user_id === 'string' || typeof varsObj.user_id === 'number') idKey = 'user_id';
      if (!idKey) return;
      var baseParams = Object.create(null);
      params.forEach(function(v, k) {
        if (k !== 'variables') baseParams[k] = v;
      });
      capturedProfileGql = {
        url: u,
        fname: fname,
        idKey: idKey,
        templateVars: varsObj,
        baseParams: baseParams
      };
    } catch (_) {}
  }

  function shouldSniffUrl(rawUrl) {
    var u = String(rawUrl || '').toLowerCase();
    if (!u || /\.(?:png|jpe?g|gif|webp|svg|ico|woff2?|ttf|mp4|webm|m3u8|ts|css)(?:\?|$)/i.test(u)) return false;
    if (platform === 'instagram' || platform === 'threads') {
      if (u.indexOf('logging') >= 0 || u.indexOf('/ajax/bz') >= 0 || u.indexOf('/qp/') >= 0 ||
          u.indexOf('telemetry') >= 0 || u.indexOf('metrics') >= 0 || u.indexOf('heartbeat') >= 0 ||
          u.indexOf('presence') >= 0 || u.indexOf('push/') >= 0 || u.indexOf('direct_v2/threads') >= 0) {
        return false;
      }
      return u.indexOf('/graphql') >= 0 || u.indexOf('/api/v1/') >= 0;
    }
    if (platform === 'bluesky') {
      return u.indexOf('/xrpc/app.bsky.') >= 0;
    }
    if (platform === 'mastodon') {
      return u.indexOf('/api/v1/') >= 0 || u.indexOf('/api/v2/') >= 0;
    }
    if (platform === 'misskey') {
      return u.indexOf('/api/') >= 0;
    }
    if (platform === 'pixiv') {
      return u.indexOf('/ajax/') >= 0;
    }
    return u.indexOf('/api') >= 0 || u.indexOf('graphql') >= 0 || u.indexOf('/ajax') >= 0 ||
           u.indexOf('user') >= 0 || u.indexOf('follow') >= 0 || u.indexOf('profile') >= 0 ||
           u.indexOf('friend') >= 0 || u.indexOf('relation') >= 0;
  }

  function sniffJsonText(txt) {
    if (!txt || txt.length > 1800000) return;
    if (txt.indexOf('follower') < 0 && txt.indexOf('edge_followed_by') < 0 &&
        txt.indexOf('followersCount') < 0 && txt.indexOf('followsCount') < 0 &&
        txt.indexOf('followed_by') < 0 && txt.indexOf('followedBy') < 0 &&
        txt.indexOf('friendship_status') < 0 && txt.indexOf('follows_viewer') < 0 &&
        txt.indexOf('isFollowed') < 0 && txt.indexOf('is_followed') < 0 &&
        txt.indexOf('viewer_username') < 0 && txt.indexOf('"username"') < 0 &&
        txt.indexOf('"uniqueId"') < 0 && txt.indexOf('"acct"') < 0) {
      return;
    }
    try {
      var clean = txt.indexOf('for (;;);') === 0 ? txt.slice(9) : txt;
      var parsed = JSON.parse(clean);
      extractFromJsonObject(parsed);
      if (platform === 'instagram' || platform === 'bluesky' || platform === 'mastodon') {
        scheduleRelBatch(140);
      }
    } catch (_) {
      try {
        var lines = txt.split('\n');
        for (var i = 0; i < lines.length && i < 30; i++) {
          var line = lines[i].trim();
          if (line.length > 2 && line[0] === '{') {
            extractFromJsonObject(JSON.parse(line));
          }
        }
      } catch (_) {}
    }
  }

  var origFetchRef = window.fetch;
  try {
    if (typeof origFetchRef === 'function') {
      window.fetch = function(input, init) {
        var isInternal = !!(init && init.__omniStatsInternal);
        if (isInternal) {
          return origFetchRef.apply(this, arguments);
        }
        var reqUrl = typeof input === 'string' ? input : (input && input.url ? input.url : '');
        try {
          if (init && init.headers) captureRequestHeaders(init.headers);
          if (input && typeof input === 'object' && input.headers) captureRequestHeaders(input.headers);
          captureRequestMeta(reqUrl, init && init.body ? init.body : null);
        } catch (_) {}
        var promise = origFetchRef.apply(this, arguments);
        if (shouldSniffUrl(reqUrl) && promise && typeof promise.then === 'function') {
          promise.then(function(res) {
            try {
              if (!res || !res.ok || typeof res.clone !== 'function') return;
              var ct = (res.headers && res.headers.get && res.headers.get('content-type')) || '';
              if (ct.indexOf('json') >= 0 || ct.indexOf('text/plain') >= 0 || ct.indexOf('javascript') >= 0) {
                res.clone().text().then(sniffJsonText, function() {});
              }
            } catch (_) {}
          }, function() {});
        }
        return promise;
      };
    }
  } catch (_) {}

  try {
    var origOpen = XMLHttpRequest.prototype.open;
    var origSetHeader = XMLHttpRequest.prototype.setRequestHeader;
    var origSend = XMLHttpRequest.prototype.send;
    if (typeof origOpen === 'function' && typeof origSend === 'function') {
      XMLHttpRequest.prototype.open = function(method, url) {
        try { this.__omniStatsUrl = url; } catch (_) {}
        return origOpen.apply(this, arguments);
      };
      if (typeof origSetHeader === 'function') {
        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
          try { captureHeaderPair(name, value); } catch (_) {}
          return origSetHeader.apply(this, arguments);
        };
      }
"""

        private val PROFILE_STATS_JS_PART_2: String = """
      XMLHttpRequest.prototype.send = function(body) {
        try {
          captureRequestMeta(this.__omniStatsUrl, body);
          if (shouldSniffUrl(this.__omniStatsUrl)) {
            this.addEventListener('load', function() {
              try {
                if (this.status >= 200 && this.status < 300 &&
                    (!this.responseType || this.responseType === 'text') &&
                    typeof this.responseText === 'string') {
                  sniffJsonText(this.responseText);
                }
              } catch (_) {}
            }, { once: true });
          }
        } catch (_) {}
        return origSend.apply(this, arguments);
      };
    }
  } catch (_) {}

  function internalFetch(url, opts) {
    var o = Object.assign({ __omniStatsInternal: true }, opts || {});
    return origFetchRef ? origFetchRef.call(window, url, o) : window.fetch(url, o);
  }

  function buildIgHeaders(appIdOverride) {
    var h = {
      'x-ig-app-id': appIdOverride || capturedHeaders['x-ig-app-id'] || '936619743392459',
      'x-requested-with': 'XMLHttpRequest',
      'accept': '*/*'
    };
    var csrf = getCookieValue('csrftoken') || capturedHeaders['x-csrftoken'];
    if (csrf) h['x-csrftoken'] = csrf;
    var claim = capturedHeaders['x-ig-www-claim'] || '';
    if (!claim) {
      try { claim = (window.sessionStorage && window.sessionStorage.getItem('www-claim-v2')) || ''; } catch (_) {}
    }
    if (claim) h['x-ig-www-claim'] = claim;
    if (capturedHeaders['x-asbd-id']) h['x-asbd-id'] = capturedHeaders['x-asbd-id'];
    if (capturedHeaders['x-fb-lsd']) h['x-fb-lsd'] = capturedHeaders['x-fb-lsd'];
    if (capturedHeaders['x-bloks-version-id']) h['x-bloks-version-id'] = capturedHeaders['x-bloks-version-id'];
    return h;
  }

  function tryFetchSelfByCookie() {
    if (platform !== 'instagram' || selfHandle || selfIdFetchStarted) return;
    var dsUserId = getCookieValue('ds_user_id');
    if (!dsUserId || !/^\d{5,24}$/.test(dsUserId)) return;
    selfIdFetchStarted = true;
    internalFetch('/api/v1/users/' + encodeURIComponent(dsUserId) + '/info/', {
      method: 'GET',
      credentials: 'include',
      headers: buildIgHeaders()
    }).then(function(res) {
      if (!res || !res.ok) return;
      return res.json().then(function(data) {
        var u = data && data.user;
        if (u && typeof u.username === 'string') {
          setSelfHandle(u.username);
          extractFromJsonObject(data);
        }
      }).catch(function() {});
    }).catch(function() {});
  }

  function scanSsrScripts() {
    try {
      var scripts = document.querySelectorAll('script[type="application/json"]:not([data-omni-ff-ssr]), script#__UNIVERSAL_DATA_FOR_REHYDRATION__:not([data-omni-ff-ssr]), script#SIGI_STATE:not([data-omni-ff-ssr])');
      if (!scripts || scripts.length === 0) return;
      var idx = 0;
      var total = Math.min(scripts.length, 60);
      function processChunk() {
        var processed = 0;
        while (idx < total && processed < 8) {
          var sc = scripts[idx++];
          sc.setAttribute('data-omni-ff-ssr', '1');
          var txt = sc.textContent || '';
          if (txt.length > 20 && txt.length < 650000) {
            sniffJsonText(txt);
            processed++;
          }
        }
        if (idx < total) {
          runWhenIdle(processChunk, 800);
        }
      }
      runWhenIdle(processChunk, 800);
    } catch (_) {}
  }

  function detectSelfAccountFromDom() {
    if (selfHandle) return;
    try {
      if (platform === 'instagram') {
        tryFetchSelfByCookie();
        var navLinks = document.querySelectorAll('nav a[href], [role="navigation"] a[href]');
        for (var i = 0; i < navLinks.length && i < 80; i++) {
          var a = navLinks[i];
          var href = a.getAttribute('href') || '';
          var m = /^\/([a-z0-9._]{1,35})\/?(?:\?.*)?$/i.exec(href);
          if (!m) continue;
          var h = normalizeHandle(m[1]);
          if (!h) continue;
          var label = (a.innerText || a.textContent || '').trim();
          var aria = (a.getAttribute('aria-label') || '').trim();
          var img = a.querySelector('img[alt]');
          var alt = img ? (img.getAttribute('alt') || '') : '';
          if (/^(プロフィール|profile)$/i.test(label) ||
              /^(プロフィール|profile)$/i.test(aria) ||
              (/(プロフィール写真|profile picture)/i.test(alt) && a.closest('nav, [role="navigation"]'))) {
            setSelfHandle(h);
            return;
          }
        }
        tryFetchSelfByCookie();
      } else if (platform === 'threads') {
        var tLinks = document.querySelectorAll('nav a[href^="/@"], [role="navigation"] a[href^="/@"], a[href^="/@"]');
        for (var j = 0; j < tLinks.length && j < 120; j++) {
          var ta = tLinks[j];
          var thref = ta.getAttribute('href') || '';
          var tm = /^\/@([a-z0-9._]{1,35})\/?(?:\?.*)?$/i.exec(thref);
          if (!tm) continue;
          var svg = ta.querySelector('svg[aria-label]');
          var sAria = svg ? (svg.getAttribute('aria-label') || '') : '';
          var tAria = ta.getAttribute('aria-label') || '';
          var tTxt = (ta.innerText || ta.textContent || '').trim();
          if (/^(プロフィール|profile)$/i.test(sAria) || /^(プロフィール|profile)$/i.test(tAria) || /^(プロフィール|profile)$/i.test(tTxt)) {
            setSelfHandle(tm[1]);
            return;
          }
        }
      } else if (platform === 'bluesky') {
        var bLinks = document.querySelectorAll('a[data-testid="profileBtn"][href^="/profile/"], nav a[href^="/profile/"]');
        for (var k = 0; k < bLinks.length && k < 60; k++) {
          var ba = bLinks[k];
          var bhref = ba.getAttribute('href') || '';
          var bm = /^\/profile\/([^\/?#]+)\/?(?:\?.*)?$/i.exec(bhref);
          if (!bm) continue;
          var bAria = ba.getAttribute('aria-label') || '';
          var bTxt = (ba.innerText || ba.textContent || '').trim();
          if (ba.getAttribute('data-testid') === 'profileBtn' || /^(プロフィール|profile)$/i.test(bAria) || /^(プロフィール|profile)$/i.test(bTxt)) {
            setSelfHandle(bm[1]);
            return;
          }
        }
      } else {
        var gLinks = document.querySelectorAll('nav a[href], header a[href], [role="navigation"] a[href]');
        for (var g = 0; g < gLinks.length && g < 100; g++) {
          var ga = gLinks[g];
          var gAria = (ga.getAttribute('aria-label') || '').trim();
          var gTxt = (ga.innerText || ga.textContent || '').trim();
          var gTestId = (ga.getAttribute('data-testid') || ga.getAttribute('data-e2e') || '').toLowerCase();
          if (/^(プロフィール|マイページ|profile|my profile)$/i.test(gAria) ||
              /^(プロフィール|マイページ|profile|my profile)$/i.test(gTxt) ||
              gTestId.indexOf('profile') >= 0) {
            var gh = extractHandleFromLink(ga);
            if (gh) {
              setSelfHandle(gh);
              return;
            }
          }
        }
      }
    } catch (_) {}
  }

  function extractHandleFromPath(path) {
    if (!path) return '';
    if (platform === 'instagram') {
      var m = /^\/([a-z0-9._]{1,35})\/?$/i.exec(path);
      return m ? normalizeHandle(m[1]) : '';
    }
    if (platform === 'threads' || platform === 'tiktok' || platform === 'mixi2') {
      var tm = /^\/@([a-z0-9._]{1,35})\/?$/i.exec(path);
      return tm ? normalizeHandle(tm[1]) : '';
    }
    if (platform === 'bluesky') {
      var bm = /^\/profile\/([^\/?#]+)\/?$/i.exec(path);
      return bm ? normalizeHandle(bm[1]) : '';
    }
    if (platform === 'mastodon' || platform === 'misskey') {
      var mm = /^\/@([a-z0-9._-]+(?:@[a-z0-9.-]+\.[a-z]{2,})?)\/?$/i.exec(path);
      return mm ? normalizeHandle(mm[1]) : '';
    }
    if (platform === 'pixiv') {
      var pm = /^\/(?:en\/)?users\/(\d{1,16})\/?$/i.exec(path);
      return pm ? normalizeHandle(pm[1]) : '';
    }
    if (platform === 'reddit') {
      var rm = /^\/(?:u|user)\/([a-z0-9_-]{2,32})\/?$/i.exec(path);
      return rm ? normalizeHandle(rm[1]) : '';
    }
    if (platform === 'linkedin') {
      var lm = /^\/in\/([a-z0-9._-]{2,64})\/?$/i.exec(path);
      return lm ? normalizeHandle(lm[1]) : '';
    }
    if (platform === 'weibo') {
      var wm = /^\/(?:u|n)\/([a-z0-9._-]{2,32})\/?$/i.exec(path);
      return wm ? normalizeHandle(wm[1]) : '';
    }
    if (platform === 'tumblr') {
      var tbm = /^\/(?:blog\/view\/)?([a-z0-9-]{2,40})\/?$/i.exec(path);
      return tbm ? normalizeHandle(tbm[1]) : '';
    }
    if (platform === 'facebook' || platform === 'vk' || platform === 'pinterest' ||
        platform === 'twitch' || platform === 'behance' || platform === 'dribbble' ||
        platform === 'deviantart' || platform === 'x' || platform === 'ameba') {
      var sm = /^\/@?([a-z0-9._-]{2,40})\/?$/i.exec(path);
      return sm ? normalizeHandle(sm[1]) : '';
    }
    // generic: /@handle, /users/handle, /u/handle, /profile/handle
    var gm = /^\/(?:@|users\/|user\/|u\/|profile\/|profiles\/|in\/)([a-z0-9._-]{2,48})\/?$/i.exec(path);
    return gm ? normalizeHandle(gm[1]) : '';
  }

  function extractHandleFromLink(a) {
    if (!a || !a.getAttribute) return '';
    var href = a.getAttribute('href') || '';
    if (!href || href[0] === '#' || href.indexOf('javascript:') === 0) return '';
    var path = href;
    if (/^https?:\/\//i.test(href)) {
      try {
        var u = new URL(href);
        if (u.hostname.toLowerCase() !== host) return '';
        if (platform === 'facebook' && u.pathname === '/profile.php') {
          var fbId = u.searchParams.get('id');
          return fbId && /^\d{4,24}$/.test(fbId) ? normalizeHandle(fbId) : '';
        }
        path = u.pathname;
      } catch (_) { return ''; }
    } else {
      if (platform === 'facebook' && path.indexOf('/profile.php') === 0) {
        var fbM = /[?&]id=(\d{4,24})/i.exec(path);
        return fbM ? normalizeHandle(fbM[1]) : '';
      }
      var qIdx = path.indexOf('?');
      if (qIdx >= 0) path = path.slice(0, qIdx);
      var hIdx = path.indexOf('#');
      if (hIdx >= 0) path = path.slice(0, hIdx);
    }
    return extractHandleFromPath(path);
  }

  function getCurrentProfileHandleFromUrl() {
    try {
      var p = (window.location && window.location.pathname) || '';
      var h = extractHandleFromPath(p);
      if (h) return h;
      // サブパス付き (/handle/followers, /@handle/following, /profile/handle/followers 等)
      var stripped = p.replace(/\/(?:followers|following|follows|friends|posts|replies|media|likes|reels|tagged|mutuals|about|notes|bookmarks)(?:\/.*)?$/i, '');
      if (stripped && stripped !== p) {
        return extractHandleFromPath(stripped);
      }
    } catch (_) {}
    return '';
  }

  function detectSelfListPageContext() {
    try {
      var p = ((window.location && window.location.pathname) || '').toLowerCase();
      var full = p + ' ' + ((window.location && window.location.search) || '').toLowerCase();
      var owner = getCurrentProfileHandleFromUrl();
      var isSelfPage = !!(selfHandle && owner && owner === selfHandle);
      var isFollowersPath = /\/followers(?:\/|\?|$)|[?&]tab=followers/i.test(full);
      var isFollowingPath = /\/(?:following|follows)(?:\/|\?|$)|[?&]tab=following/i.test(full);
      if (isSelfPage && isFollowersPath) return 'self-followers';
      if (isSelfPage && isFollowingPath) return 'self-following';
      // モーダル（Instagram / Threads のフォロワー一覧ダイアログ等）判定
      var dlg = document.querySelector('[role="dialog"]');
      if (dlg && isSelfPage) {
        var headEl = dlg.querySelector('h1, h2, [role="heading"], header');
        var headTxt = headEl ? (headEl.textContent || '').trim() : '';
        if (/^(?:フォロワー|followers)$/i.test(headTxt)) return 'self-followers';
        if (/^(?:フォロー中|フォロー|following)$/i.test(headTxt)) return 'self-following';
      }
    } catch (_) {}
    return '';
  }

  function canActiveFetchPlatform() {
    return platform === 'instagram' || platform === 'threads' || platform === 'bluesky' ||
           platform === 'mastodon' || platform === 'misskey' || platform === 'tiktok' ||
           platform === 'pixiv';
  }

  function enqueueFetch(rawHandle, priority, forceRetry) {
    if (!canActiveFetchPlatform()) return;
    var h = normalizeHandle(rawHandle);
    if (!h) return;
    if (forceRetry) {
      delete failedMap[h];
      if (Date.now() < backoffUntil) backoffUntil = 0;
    } else {
      if (Date.now() < backoffUntil) return;
      if (failedMap[h] && Date.now() - failedMap[h] < 45000) return;
    }
    var existing = statsMap[h];
    var needRel = h !== selfHandle && (!existing || existing.followsMe === null);
    if (!forceRetry && hasUsableStats(existing) && !needRel && (Date.now() - existing.ts) < CACHE_TTL_MS) {
      return;
    }
    if (!forceRetry && hasUsableStats(existing) && needRel) {
      scheduleRelBatch();
      if (platform !== 'instagram' && platform !== 'bluesky' && platform !== 'mastodon') return;
      if (userIdMap[h]) return;
    }
    if (inFlight[h]) return;
    if (queuedSet[h]) {
      if (priority) {
        var idx = queue.indexOf(h);
        if (idx > 0) {
          queue.splice(idx, 1);
          queue.unshift(h);
        }
      }
      return;
    }
    queuedSet[h] = true;
    if (priority) queue.unshift(h);
    else queue.push(h);
    if (queue.length > 80) {
      var dropped = queue.pop();
      if (dropped) delete queuedSet[dropped];
    }
    var maxW = platform === 'instagram' ? igConcurrency : 1;
    if (activeWorkers < maxW && !queueStartTimer) {
      queueStartTimer = setTimeout(function() {
        queueStartTimer = null;
        processQueue();
      }, platform === 'bluesky' ? 30 : 20);
    }
  }

  // Instagram / Bluesky / Mastodon の相互関係バッチ照会
  function scheduleRelBatch(delayOverride) {
    if (platform !== 'instagram' && platform !== 'bluesky' && platform !== 'mastodon') return;
    if (relBatchTimer || relBatchRunning) return;
    relBatchTimer = setTimeout(function() {
      relBatchTimer = null;
      runRelBatch();
    }, typeof delayOverride === 'number' ? delayOverride : 220);
  }

  function runRelBatch() {
    if (relBatchRunning || Date.now() < backoffUntil) return;
    var now = Date.now();
    var maxBatch = platform === 'instagram' ? 50 : 25;
    var targetHandles = [];
    var scopeRoot = document.querySelector('[role="dialog"]') || document;
    var rows = scopeRoot.querySelectorAll('[data-omni-ff-row], a[data-omni-ff-target="1"]');
    var seen = Object.create(null);
    for (var i = 0; i < rows.length && targetHandles.length < maxBatch; i++) {
      var h = rows[i].getAttribute('data-omni-ff-row') || rows[i].getAttribute('data-omni-ff-handle') || '';
      if (!h || h === selfHandle || seen[h]) continue;
      seen[h] = true;
      var e = statsMap[h];
      if (e && e.followsMe !== null && e.iFollow !== null) continue;
      if (relQueriedMap[h] && now - relQueriedMap[h] < 120000) continue;
      if (!userIdMap[h]) continue;
      targetHandles.push(h);
    }
    var curH = getCurrentProfileHandleFromUrl();
    if (curH && curH !== selfHandle && !seen[curH] && userIdMap[curH]) {
      var ce = statsMap[curH];
      if ((!ce || ce.followsMe === null || ce.iFollow === null) && (!relQueriedMap[curH] || now - relQueriedMap[curH] >= 120000)) {
        targetHandles.unshift(curH);
      }
    }
    if (targetHandles.length === 0) return;

    if (platform === 'bluesky') {
      if (!selfDid) {
        if (selfHandle) fetchBlueskySelfDid(selfHandle);
        return;
      }
      var dids = [];
      for (var bi = 0; bi < targetHandles.length; bi++) {
        var d = userIdMap[targetHandles[bi]];
        if (d && d.indexOf('did:') === 0 && d !== selfDid) {
          dids.push(d);
          relQueriedMap[targetHandles[bi]] = now;
        }
      }
      if (dids.length === 0) return;
      relBatchRunning = true;
      var qs = 'actor=' + encodeURIComponent(selfDid) + '&' + dids.map(function(x) { return 'others=' + encodeURIComponent(x); }).join('&');
      internalFetch('https://public.api.bsky.app/xrpc/app.bsky.graph.getRelationships?' + qs, {
        method: 'GET'
      }).then(function(res) {
        if (!res || !res.ok) return;
        return res.json().then(function(data) {
          if (data && Array.isArray(data.relationships)) {
            for (var r = 0; r < data.relationships.length; r++) {
              var rel = data.relationships[r];
              if (rel && rel.did) {
                var bh = idToHandleMap[rel.did] || idToHandleMap[rel.did.toLowerCase()];
                if (bh) {
                  recordRelation(bh, !!rel.following, !!rel.followedBy);
                }
              }
            }
          }
        }).catch(function() {});
      }).catch(function() {}).then(function() {
        relBatchRunning = false;
      });
      return;
    }

    if (platform === 'instagram') {
      var pks = [];
      for (var ii = 0; ii < targetHandles.length; ii++) {
        var pk = userIdMap[targetHandles[ii]];
        if (pk && /^\d{5,24}$/.test(pk)) {
          pks.push(pk);
          relQueriedMap[targetHandles[ii]] = now;
        }
      }
      if (pks.length === 0) return;
      relBatchRunning = true;
      var headers = buildIgHeaders();
      headers['content-type'] = 'application/x-www-form-urlencoded';
      internalFetch('/api/v1/friendships/show_many/', {
        method: 'POST',
        credentials: 'include',
        headers: headers,
        body: 'user_ids=' + encodeURIComponent(pks.join(','))
      }).then(function(res) {
        if (!res) return;
        if (res.status === 429) { backoffUntil = Date.now() + 45000; return; }
        if (!res.ok) return;
        return res.json().then(function(data) {
          extractFromJsonObject(data);
        }).catch(function() {});
      }).catch(function() {}).then(function() {
        setTimeout(function() { relBatchRunning = false; }, 600);
      });
      return;
    }

    if (platform === 'mastodon') {
      var mids = [];
      for (var mi = 0; mi < targetHandles.length; mi++) {
        var mid = userIdMap[targetHandles[mi]];
        if (mid) {
          mids.push(mid);
          relQueriedMap[targetHandles[mi]] = now;
        }
      }
      if (mids.length === 0) return;
      relBatchRunning = true;
      var mHeaders = { 'accept': 'application/json' };
      if (capturedHeaders['authorization']) mHeaders['authorization'] = capturedHeaders['authorization'];
      var mQs = mids.map(function(id) { return 'id[]=' + encodeURIComponent(id); }).join('&');
      internalFetch('/api/v1/accounts/relationships?' + mQs, {
        method: 'GET',
        credentials: 'include',
        headers: mHeaders
      }).then(function(res) {
        if (!res || !res.ok) return;
        return res.json().then(function(data) {
          extractFromJsonObject(data);
        }).catch(function() {});
      }).catch(function() {}).then(function() {
        setTimeout(function() { relBatchRunning = false; }, 500);
      });
    }
  }

  function fetchIgViaCapturedGql(handle) {
    var pk = userIdMap[handle];
    if (!pk || !capturedProfileGql) return Promise.resolve({ ok: false, rateLimited: false });
    try {
      var bodyParams = new URLSearchParams();
      for (var k in capturedProfileGql.baseParams) {
        bodyParams.set(k, capturedProfileGql.baseParams[k]);
      }
      var vars = Object.assign({}, capturedProfileGql.templateVars);
      vars[capturedProfileGql.idKey] = pk;
      bodyParams.set('variables', JSON.stringify(vars));
      var headers = buildIgHeaders();
      headers['content-type'] = 'application/x-www-form-urlencoded';
      if (capturedProfileGql.fname) headers['x-fb-friendly-name'] = capturedProfileGql.fname;
      return internalFetch(capturedProfileGql.url, {
        method: 'POST',
        credentials: 'include',
        headers: headers,
        body: bodyParams.toString()
      }).then(function(res) {
        if (res.status === 429) return { ok: false, rateLimited: true };
        if (!res.ok) return { ok: false, rateLimited: false };
        return res.text().then(function(txt) {
          sniffJsonText(txt);
          return { ok: hasUsableStats(statsMap[handle]), rateLimited: false };
        });
      }).catch(function() { return { ok: false, rateLimited: false }; });
    } catch (_) {
      return Promise.resolve({ ok: false, rateLimited: false });
    }
  }

  function fetchIgViaUserInfo(handle) {
    var pk = userIdMap[handle];
    if (!pk) return Promise.resolve({ ok: false, rateLimited: false });
    return internalFetch('/api/v1/users/' + encodeURIComponent(pk) + '/info/', {
      method: 'GET',
      credentials: 'include',
      headers: buildIgHeaders()
    }).then(function(res) {
      if (res.status === 429) return { ok: false, rateLimited: true };
      if (!res.ok) return { ok: false, rateLimited: false };
      return res.json().then(function(data) {
        extractFromJsonObject(data);
        return { ok: hasUsableStats(statsMap[handle]), rateLimited: false };
      }).catch(function() { return { ok: false, rateLimited: false }; });
    }).catch(function() { return { ok: false, rateLimited: false }; });
  }

  function fetchIgViaWebProfileInfo(handle, appId) {
    var enc = encodeURIComponent(handle);
    return internalFetch('/api/v1/users/web_profile_info/?username=' + enc, {
      method: 'GET',
      credentials: 'include',
      headers: buildIgHeaders(appId)
    }).then(function(res) {
      if (res.status === 429) return { ok: false, rateLimited: true };
      if (!res.ok || (res.redirected && String(res.url || '').indexOf('/accounts/login') >= 0)) {
        return { ok: false, rateLimited: false };
      }
      return res.json().then(function(data) {
        extractFromJsonObject(data);
        var u = data && data.data && data.data.user;
        if (u) {
          bindUserId(handle, u.id || u.pk);
          var flwrs = u.edge_followed_by && typeof u.edge_followed_by.count === 'number'
            ? u.edge_followed_by.count
            : (typeof u.follower_count === 'number' ? u.follower_count : null);
          var flwng = u.edge_follow && typeof u.edge_follow.count === 'number'
            ? u.edge_follow.count
            : (typeof u.following_count === 'number' ? u.following_count : null);
          var iFlw = typeof u.followed_by_viewer === 'boolean' ? u.followed_by_viewer : null;
          var flwsMe = typeof u.follows_viewer === 'boolean' ? u.follows_viewer : null;
          recordStats(handle, flwrs, flwng, null, typeof u.is_private === 'boolean' ? u.is_private : null, iFlw, flwsMe);
        }
        return { ok: hasUsableStats(statsMap[handle]), rateLimited: false };
      }).catch(function() { return { ok: false, rateLimited: false }; });
    }).catch(function() { return { ok: false, rateLimited: false }; });
  }

  function fetchIgViaHtml(handle, includeCreds) {
    var enc = encodeURIComponent(handle);
    return internalFetch('/' + enc + '/', {
      method: 'GET',
      credentials: includeCreds ? 'include' : 'omit',
      headers: { 'accept': 'text/html,application/xhtml+xml' }
    }).then(function(res) {
      if (res.status === 429) return { ok: false, rateLimited: true };
      if (!res.ok) return { ok: false, rateLimited: false };
      return res.text().then(function(html) {
        var ok = extractFromHtmlForHandle(html, handle);
        return { ok: ok || hasUsableStats(statsMap[handle]), rateLimited: false };
      });
    }).catch(function() { return { ok: false, rateLimited: false }; });
  }

  function fetchInstagramProfile(handle) {
    var primaryAppId = capturedHeaders['x-ig-app-id'] || '936619743392459';
    var altAppId = primaryAppId === '1217981644879628' ? '936619743392459' : '1217981644879628';
    var now = Date.now();
    var allRoutes = [];
    if (userIdMap[handle] && capturedProfileGql) allRoutes.push({ name: 'gql', fn: function() { return fetchIgViaCapturedGql(handle); } });
    if (userIdMap[handle]) allRoutes.push({ name: 'user_info', fn: function() { return fetchIgViaUserInfo(handle); } });
    allRoutes.push({ name: 'web_info_1', fn: function() { return fetchIgViaWebProfileInfo(handle, primaryAppId); } });
    allRoutes.push({ name: 'web_info_2', fn: function() { return fetchIgViaWebProfileInfo(handle, altAppId); } });
    allRoutes.push({ name: 'html_inc', fn: function() { return fetchIgViaHtml(handle, true); } });
    allRoutes.push({ name: 'html_omit', fn: function() { return fetchIgViaHtml(handle, false); } });

    var routes = allRoutes.filter(function(r) {
      return !deadRouteUntil[r.name] || now >= deadRouteUntil[r.name];
    });
    if (routes.length === 0) routes = allRoutes;

    if (preferredIgRoute) {
      routes.sort(function(a, b) {
        if (a.name === preferredIgRoute) return -1;
        if (b.name === preferredIgRoute) return 1;
        return 0;
      });
    }

    var idx = 0;
    function nextRoute() {
      if (idx >= routes.length) {
        consecutiveFailures++;
        failedMap[handle] = Date.now();
        if (consecutiveFailures >= 4) {
          backoffUntil = Date.now() + 25000;
          consecutiveFailures = 0;
        }
        scheduleRenderBadges();
        return Promise.resolve();
      }
      var r = routes[idx++];
      return r.fn().then(function(res) {
        if (res && res.ok) {
          preferredIgRoute = r.name;
          routeFailCount[r.name] = 0;
          delete deadRouteUntil[r.name];
          consecutiveFailures = 0;
          if (handle !== selfHandle && statsMap[handle] && statsMap[handle].followsMe === null && userIdMap[handle]) {
            scheduleRelBatch(120);
          }
          return;
        }
        if (res && res.rateLimited) {
          igConcurrency = 1;
          backoffUntil = Date.now() + 45000;
          failedMap[handle] = Date.now();
          scheduleRenderBadges();
          return;
        }
        routeFailCount[r.name] = (routeFailCount[r.name] || 0) + 1;
        if (routeFailCount[r.name] >= 2) {
          deadRouteUntil[r.name] = Date.now() + 180000;
          routeFailCount[r.name] = 0;
        }
        return nextRoute();
      });
    }
    return nextRoute();
  }

  function fetchThreadsProfile(handle) {
    var enc = encodeURIComponent(handle);
    function tryHtml(includeCreds) {
      return internalFetch('/@' + enc, {
        method: 'GET',
        credentials: includeCreds ? 'include' : 'omit',
        headers: { 'accept': 'text/html,application/xhtml+xml' }
      }).then(function(res) {
        if (res.status === 429) return { ok: false, rateLimited: true };
        if (!res.ok) return { ok: false, rateLimited: false };
        return res.text().then(function(html) {
          var ok = extractFromHtmlForHandle(html, handle);
          return { ok: ok || hasUsableStats(statsMap[handle]), rateLimited: false };
        });
      }).catch(function() { return { ok: false, rateLimited: false }; });
    }
    var chain = (userIdMap[handle] && capturedProfileGql)
      ? fetchIgViaCapturedGql(handle)
      : Promise.resolve({ ok: false, rateLimited: false });
    return chain.then(function(r0) {
      if (r0 && r0.ok) { consecutiveFailures = 0; return; }
      if (r0 && r0.rateLimited) { backoffUntil = Date.now() + 50000; failedMap[handle] = Date.now(); scheduleRenderBadges(); return; }
      return tryHtml(true).then(function(r1) {
        if (r1 && r1.ok) { consecutiveFailures = 0; return; }
        if (r1 && r1.rateLimited) { backoffUntil = Date.now() + 50000; failedMap[handle] = Date.now(); scheduleRenderBadges(); return; }
        return tryHtml(false).then(function(r2) {
          if (r2 && r2.ok) { consecutiveFailures = 0; return; }
          if (r2 && r2.rateLimited) backoffUntil = Date.now() + 50000;
          failedMap[handle] = Date.now();
          scheduleRenderBadges();
        });
      });
    });
  }

  function fetchBlueskyBatch(handles) {
    var qs = handles.map(function(h) { return 'actors=' + encodeURIComponent(h); }).join('&');
    return internalFetch('https://public.api.bsky.app/xrpc/app.bsky.actor.getProfiles?' + qs, {
      method: 'GET'
    }).then(function(res) {
      if (res.status === 429) {
        backoffUntil = Date.now() + 45000;
        return;
      }
      if (!res.ok) return;
      return res.json().then(function(data) {
        var dids = [];
        if (data && Array.isArray(data.profiles)) {
          for (var i = 0; i < data.profiles.length; i++) {
            var p = data.profiles[i];
            if (p && p.handle) {
              var nh = normalizeHandle(p.handle);
              if (nh && p.did) {
                bindUserId(nh, p.did);
                if (nh === selfHandle) selfDid = p.did;
                else dids.push(p.did);
              }
              recordStats(p.handle, p.followersCount, p.followsCount, null, null, null, null);
            }
          }
        }
        if (selfDid && dids.length > 0) {
          var rQs = 'actor=' + encodeURIComponent(selfDid) + '&' + dids.slice(0, 25).map(function(d) { return 'others=' + encodeURIComponent(d); }).join('&');
          return internalFetch('https://public.api.bsky.app/xrpc/app.bsky.graph.getRelationships?' + rQs, {
            method: 'GET'
          }).then(function(rRes) {
            if (!rRes || !rRes.ok) return;
            return rRes.json().then(function(rData) {
              if (rData && Array.isArray(rData.relationships)) {
                for (var r = 0; r < rData.relationships.length; r++) {
                  var rel = rData.relationships[r];
                  if (rel && rel.did) {
                    var bh = idToHandleMap[rel.did] || idToHandleMap[rel.did.toLowerCase()];
                    if (bh) recordRelation(bh, !!rel.following, !!rel.followedBy);
                  }
                }
              }
            }).catch(function() {});
          }).catch(function() {});
        } else if (selfHandle && !selfDid) {
          fetchBlueskySelfDid(selfHandle);
        }
      });
    }).catch(function() {});
  }

  function fetchMastodonProfile(handle) {
    var headers = { 'accept': 'application/json' };
    if (capturedHeaders['authorization']) headers['authorization'] = capturedHeaders['authorization'];
    return internalFetch('/api/v1/accounts/lookup?acct=' + encodeURIComponent(handle), {
      method: 'GET',
      credentials: 'include',
      headers: headers
    }).then(function(res) {
      if (res.status === 429) { backoffUntil = Date.now() + 45000; return; }
      if (!res.ok) { failedMap[handle] = Date.now(); return; }
      return res.json().then(function(acc) {
        if (acc && acc.id) {
          bindUserId(handle, acc.id);
          recordStats(handle, acc.followers_count, acc.following_count, null, typeof acc.locked === 'boolean' ? acc.locked : null, null, null);
          scheduleRelBatch();
        }
      }).catch(function() {});
    }).catch(function() { failedMap[handle] = Date.now(); });
  }

  function fetchMisskeyProfile(handle) {
    var parts = handle.split('@');
    var payload = { username: parts[0], host: parts.length > 1 ? parts[1] : null };
    if (capturedMisskeyToken) payload.i = capturedMisskeyToken;
    return internalFetch('/api/users/show', {
      method: 'POST',
      credentials: 'include',
      headers: { 'content-type': 'application/json', 'accept': 'application/json' },
      body: JSON.stringify(payload)
    }).then(function(res) {
      if (res.status === 429) { backoffUntil = Date.now() + 45000; return; }
      if (!res.ok) { failedMap[handle] = Date.now(); return; }
      return res.json().then(function(u) {
        if (u && u.id) {
          bindUserId(handle, u.id);
          recordStats(
            handle,
            u.followersCount,
            u.followingCount,
            u.notesCount,
            typeof u.isLocked === 'boolean' ? u.isLocked : null,
            typeof u.isFollowing === 'boolean' ? u.isFollowing : null,
            typeof u.isFollowed === 'boolean' ? u.isFollowed : null
          );
        }
      }).catch(function() {});
    }).catch(function() { failedMap[handle] = Date.now(); });
  }

  function fetchTikTokProfile(handle) {
    return internalFetch('/@' + encodeURIComponent(handle), {
      method: 'GET',
      credentials: 'include',
      headers: { 'accept': 'text/html,application/xhtml+xml' }
    }).then(function(res) {
      if (res.status === 429) { backoffUntil = Date.now() + 45000; return; }
      if (!res.ok) { failedMap[handle] = Date.now(); return; }
      return res.text().then(function(html) {
        if (!extractFromHtmlForHandle(html, handle)) {
          failedMap[handle] = Date.now();
        }
      });
    }).catch(function() { failedMap[handle] = Date.now(); });
  }

  function fetchPixivProfile(handle) {
    if (!/^\d{1,16}$/.test(handle)) return Promise.resolve();
    return internalFetch('/ajax/user/' + encodeURIComponent(handle) + '?full=1', {
      method: 'GET',
      credentials: 'include',
      headers: { 'accept': 'application/json' }
    }).then(function(res) {
      if (res.status === 429) { backoffUntil = Date.now() + 45000; return; }
      if (!res.ok) { failedMap[handle] = Date.now(); return; }
      return res.json().then(function(data) {
        var b = data && data.body;
        if (b && typeof b === 'object') {
          var flwng = typeof b.following === 'number' ? b.following : null;
          var iFlw = typeof b.isFollowed === 'boolean' ? b.isFollowed : null;
          var flwsMe = typeof b.isMypixiv === 'boolean' && b.isMypixiv ? true : null;
          recordStats(handle, null, flwng, null, null, iFlw, flwsMe);
        }
      }).catch(function() {});
    }).catch(function() { failedMap[handle] = Date.now(); });
  }

  function processQueue() {
    if (queue.length === 0 || Date.now() < backoffUntil) return;

    if (platform === 'bluesky') {
      if (activeWorkers > 0) return;
      activeWorkers++;
      var batch = queue.splice(0, 20);
      for (var i = 0; i < batch.length; i++) {
        delete queuedSet[batch[i]];
        inFlight[batch[i]] = true;
      }
      var doneBsky = function() {
        for (var j = 0; j < batch.length; j++) delete inFlight[batch[j]];
        setTimeout(function() {
          activeWorkers = Math.max(0, activeWorkers - 1);
          processQueue();
        }, 220);
      };
      try {
        Promise.resolve(fetchBlueskyBatch(batch)).then(doneBsky, doneBsky);
      } catch (_) {
        doneBsky();
      }
      return;
    }

    var maxW = platform === 'instagram' ? igConcurrency : 1;
    while (activeWorkers < maxW && queue.length > 0 && Date.now() >= backoffUntil) {
      (function() {
        var handle = queue.shift();
        delete queuedSet[handle];
        inFlight[handle] = true;
        activeWorkers++;
        scheduleRenderBadges();
        var delayMs = 420;
        var doneOne = function() {
          delete inFlight[handle];
          setTimeout(function() {
            activeWorkers = Math.max(0, activeWorkers - 1);
            processQueue();
          }, delayMs);
        };
        try {
          var req;
          if (platform === 'instagram') { req = fetchInstagramProfile(handle); delayMs = 240; }
          else if (platform === 'threads') { req = fetchThreadsProfile(handle); delayMs = 520; }
          else if (platform === 'mastodon') { req = fetchMastodonProfile(handle); delayMs = 240; }
          else if (platform === 'misskey') { req = fetchMisskeyProfile(handle); delayMs = 260; }
          else if (platform === 'tiktok') { req = fetchTikTokProfile(handle); delayMs = 680; }
          else if (platform === 'pixiv') { req = fetchPixivProfile(handle); delayMs = 320; }
          else { req = Promise.resolve(); delayMs = 300; }
          Promise.resolve(req).then(doneOne, doneOne);
        } catch (_) {
          doneOne();
        }
      })();
    }
  }

  function detectPageTheme() {
    try {
      var bg = window.getComputedStyle(document.body || document.documentElement).backgroundColor || '';
      var m = /rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/.exec(bg);
      var mode = 'dark';
      if (m) {
        var r = parseInt(m[1], 10);
        var g = parseInt(m[2], 10);
        var b = parseInt(m[3], 10);
        var aMatch = /rgba\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*([0-9.]+)/.exec(bg);
        var alpha = aMatch ? parseFloat(aMatch[1]) : 1;
        if (alpha > 0.1) {
          var lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
          mode = lum >= 0.5 ? 'light' : 'dark';
        }
      } else if (window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches) {
        mode = 'light';
      }
      if (mode !== appliedThemeMode) {
        appliedThemeMode = mode;
        document.documentElement.setAttribute('data-omni-ff-theme', mode);
      }
    } catch (_) {}
  }

  function ensureStyles() {
    detectPageTheme();
    if (document.getElementById('omni-ff-style')) return;
    var style = document.createElement('style');
    style.id = 'omni-ff-style';
    style.textContent =
      '.omni-ff-wrap{' +
      'display:inline-flex;align-items:center;flex-wrap:wrap;gap:3px;margin-left:4px;' +
      'vertical-align:middle;line-height:1.25;user-select:none;letter-spacing:0;' +
      '}' +
      '.omni-ff-wrap.is-row{' +
      'display:flex;margin:2px 0 0 0;max-width:100%;width:fit-content;' +
      '}' +
      '.omni-ff-wrap.is-row.is-below{' +
      'width:auto;max-width:100%;box-sizing:border-box;margin:3px 0 2px 0;' +
      'align-self:stretch;justify-self:stretch;grid-column:1/-1;order:9999;' +
      '}' +
      '.omni-ff-wrap.is-row.is-overlay{' +
      'position:absolute;left:0;right:0;bottom:2px;margin:0;width:auto;max-width:none;' +
      'box-sizing:border-box;z-index:2;' +
      '}' +
      '[data-omni-ff-padrow="1"]{padding-bottom:var(--omni-ff-pad,20px) !important;}' +
      '[data-omni-ff-posrel="1"]{position:relative !important;}' +
      '.omni-ff-wrap.is-row.is-push{max-width:none;}' +
      '.omni-ff-wrap.is-row.is-raised{' +
      'position:relative;z-index:5;padding:1px;border-radius:9px;background:rgba(15,23,42,0.88);' +
      '}' +
      'html[data-omni-ff-theme="light"] .omni-ff-wrap.is-row.is-raised{background:rgba(255,255,255,0.92);}' +
      '.omni-ff-wrap.is-profile-banner{' +
      'display:inline-flex;margin:4px 0 4px 8px;' +
      '}' +
      '.omni-ff-badge{' +
      'display:inline-flex;align-items:center;gap:2px;padding:1px 5px;' +
      'border-radius:999px;font-size:9px;font-weight:600;line-height:1.25;' +
      'background:rgba(21,156,171,0.16);border:1px solid rgba(21,156,171,0.46);' +
      'color:inherit;white-space:nowrap;opacity:0.95;pointer-events:none;' +
      '}' +
      '.omni-ff-wrap.is-row .omni-ff-badge{pointer-events:auto;cursor:pointer;}' +
      '.omni-ff-badge.is-link{' +
      'pointer-events:auto;cursor:pointer;position:relative;' +
      '-webkit-tap-highlight-color:transparent;touch-action:manipulation;' +
      'transition:transform 90ms ease-out,filter 90ms ease-out;' +
      '}' +
      '.omni-ff-badge.is-link::after{' +
      'content:"";position:absolute;left:-3px;right:-3px;top:-6px;bottom:-6px;' +
      '}' +
      '.omni-ff-badge.is-link:active{transform:scale(0.93);filter:brightness(1.25);}' +
      '@keyframes omni-ff-open-pop{' +
      '0%{transform:scale(0.9);box-shadow:0 0 0 0 rgba(56,189,248,0.75);}' +
      '100%{transform:scale(1);box-shadow:0 0 0 7px rgba(56,189,248,0);}' +
      '}' +
      '.omni-ff-badge.is-opening{animation:omni-ff-open-pop 360ms ease-out;}' +
      '.omni-ff-badge.is-heavy-icon{padding:1px 6px;font-size:11px;line-height:1.2;}' +
      '.omni-ff-badge.is-pending{' +
      'background:rgba(148,163,184,0.12);border-color:rgba(148,163,184,0.32);opacity:0.72;' +
      '}' +
      '.omni-ff-badge.is-retry{' +
      'background:rgba(148,163,184,0.16);border:1px dashed rgba(148,163,184,0.55);opacity:0.86;' +
      '}' +
      '.omni-ff-badge.is-following-heavy{' +
      'background:rgba(245,158,11,0.24);border:1.5px solid rgba(245,158,11,0.9);' +
      'color:#fcd34d;font-weight:700;opacity:1;' +
      '}' +
      'html[data-omni-ff-theme="light"] .omni-ff-badge.is-following-heavy{' +
      'background:rgba(245,158,11,0.20);border-color:#d97706;color:#92400e;' +
      '}' +
      '.omni-ff-rel{' +
      'display:inline-flex;align-items:center;gap:2px;padding:1px 5px;' +
      'border-radius:999px;font-size:9px;font-weight:700;line-height:1.25;' +
      'white-space:nowrap;pointer-events:none;' +
      '}' +
      '.omni-ff-rel.is-mutual{' +
      'background:rgba(16,185,129,0.22);border:1px solid rgba(16,185,129,0.82);color:#34d399;' +
      '}' +
      'html[data-omni-ff-theme="light"] .omni-ff-rel.is-mutual{' +
      'background:rgba(16,185,129,0.16);border-color:#059669;color:#047857;' +
      '}' +
      '.omni-ff-rel.is-oneway{' +
      'background:rgba(244,63,94,0.22);border:1px solid rgba(244,63,94,0.8);color:#fda4af;' +
      '}' +
      'html[data-omni-ff-theme="light"] .omni-ff-rel.is-oneway{' +
      'background:rgba(244,63,94,0.14);border-color:#e11d48;color:#be123c;' +
      '}' +
      '.omni-ff-rel.is-follower{' +
      'background:rgba(99,102,241,0.22);border:1px solid rgba(129,140,248,0.8);color:#a5b4fc;' +
      '}' +
      'html[data-omni-ff-theme="light"] .omni-ff-rel.is-follower{' +
      'background:rgba(99,102,241,0.14);border-color:#4f46e5;color:#3730a3;' +
      '}' +
      '[data-omni-ff-heavy="1"]{' +
      'box-shadow:inset 3px 0 0 rgba(245,158,11,0.9) !important;' +
      'background-color:rgba(245,158,11,0.06) !important;' +
      '}';
    (document.head || document.documentElement).appendChild(style);
  }

  function formatBadgeDisplay(entry, handle, includePosts) {
    var relKind = computeRelation(entry, handle);
    var relText = '';
    var relTitle = '';
    if (relKind === 'mutual') {
      relText = '⇄ 相互';
      relTitle = '相互フォロー中（お互いにフォローしています）';
    } else if (relKind === 'oneway') {
      var fTs = followedAtMap[handle];
      var elapsed = fTs ? formatOnewayElapsedCompact(fTs) : '';
      relText = elapsed ? ('→ 片思い ' + elapsed) : '→ 片思い';
      var detail = fTs ? formatOnewayElapsedDetail(fTs) : '';
      relTitle = detail
        ? ('片思い中（相手からフォローバックされていません）\n' + detail)
        : '片思い中（相手からフォローバックされていません）';
    } else if (relKind === 'follower') {
      relText = '← フォロワー';
      relTitle = '相手があなたをフォローしています（未フォローバック）';
    }

    var statsText = '';
    var statsTitle = '';
    var isFollowingHeavy = false;

    if (hasUsableStats(entry)) {
      var hasFollowing = typeof entry.following === 'number';
      var hasFollowers = typeof entry.followers === 'number';
      isFollowingHeavy = hasFollowing && hasFollowers && entry.following > entry.followers;

      var titleParts = [];
      if (entry.isPrivate === true) {
        titleParts.push('非公開アカウント');
      }
      if (hasFollowing) {
        titleParts.push('フォロー中: ' + entry.following.toLocaleString('ja-JP') + '人');
      }
      if (hasFollowers) {
        titleParts.push('フォロワー: ' + entry.followers.toLocaleString('ja-JP') + '人');
      }
      if (isFollowingHeavy) {
        titleParts.push('★ フォロー中の方がフォロワーより多いユーザー');
      }
      var compactBody = '';
      if (hasFollowing && hasFollowers) {
        compactBody = 'F' + formatCompactCount(entry.following) + '/FW' + formatCompactCount(entry.followers);
      } else if (hasFollowing) {
        compactBody = 'F' + formatCompactCount(entry.following);
      } else if (hasFollowers) {
        compactBody = 'FW' + formatCompactCount(entry.followers);
      }
      if (compactBody) {
        var lockPrefix = entry.isPrivate === true ? '🔒' : '';
        var heavyPrefix = isFollowingHeavy ? '▲' : '';
        statsText = heavyPrefix + lockPrefix + compactBody;
        statsTitle = titleParts.join(' / ');
      }
    }

"""

        private val PROFILE_STATS_JS_PART_3: String = """
    if (!relText && !statsText) return null;
    return {
      relKind: relKind,
      relText: relText,
      relTitle: relTitle,
      statsText: statsText,
      statsTitle: statsTitle,
      isFollowingHeavy: isFollowingHeavy
    };
  }

  function findChildWrapByUser(container, handle) {
    var wraps = container.querySelectorAll('.omni-ff-wrap');
    for (var i = 0; i < wraps.length; i++) {
      if (wraps[i].getAttribute('data-omni-ff-user') === handle) return wraps[i];
    }
    return null;
  }

  function toBadgeHttpUrl(raw) {
    if (!raw || typeof raw !== 'string') return null;
    var trimmed = raw.trim();
    if (!trimmed || trimmed === '#' || /^(?:javascript|mailto|tel|data|blob):/i.test(trimmed)) return null;
    try {
      var parsed = new URL(trimmed, location.href);
      if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
      return parsed.href;
    } catch (_) {
      return null;
    }
  }

  function buildProfileUrlForHandle(handle) {
    if (!handle || !isValidHandle(handle)) return null;
    var path = '';
    if (platform === 'instagram') path = '/' + handle + '/';
    else if (platform === 'threads' || platform === 'tiktok' || platform === 'mixi2' ||
             platform === 'mastodon' || platform === 'misskey') path = '/@' + handle;
    else if (platform === 'bluesky') path = '/profile/' + handle;
    else if (platform === 'pixiv') path = /^\d+$/.test(handle) ? '/users/' + handle : '';
    else if (platform === 'reddit') path = '/user/' + handle + '/';
    else if (platform === 'linkedin') path = '/in/' + handle + '/';
    else if (platform === 'facebook') path = /^\d+$/.test(handle) ? '/profile.php?id=' + handle : '/' + handle;
    else if (platform === 'x') path = '/' + handle;
    if (!path) return null;
    return toBadgeHttpUrl(path);
  }

  // バッジ近傍のリンクから対象ユーザーのプロフィール URL を解決する（見つからない場合はプラットフォーム規則で組み立て）
  function resolveBadgeProfileUrl(wrap, handle) {
    try {
      var prev = wrap.previousElementSibling;
      if (prev && prev.tagName === 'A' && extractHandleFromLink(prev) === handle) {
        var pu = toBadgeHttpUrl(prev.getAttribute('href'));
        if (pu) return pu;
      }
      var scope = wrap.closest('[data-omni-ff-row]') || wrap.parentElement;
      for (var hop = 0; scope && hop < 3; hop++) {
        var links = scope.querySelectorAll('a[href]');
        for (var i = 0; i < links.length && i < 40; i++) {
          if (extractHandleFromLink(links[i]) !== handle) continue;
          var u = toBadgeHttpUrl(links[i].getAttribute('href'));
          if (u) return u;
        }
        scope = scope.parentElement;
      }
    } catch (_) {}
    return buildProfileUrlForHandle(handle);
  }

  function postOpenNewTabActivate(url) {
    try {
      var ch = __omniFollowChannel || window.OmniFollowChannel;
      if (ch && typeof ch.postMessage === 'function') {
        ch.postMessage(JSON.stringify({ token: __omniFollowToken, type: 'open-new-tab', url: url, activate: true }));
        return true;
      }
      var br = __omniFollowBridge || window.OmniFollowBridge;
      if (br && typeof br.onOpenNewTabActivate === 'function') {
        br.onOpenNewTabActivate(__omniFollowToken, url);
        return true;
      }
      if (br && typeof br.onOpenNewTab === 'function') {
        br.onOpenNewTab(__omniFollowToken, url);
        return true;
      }
    } catch (_) {}
    return false;
  }

  var lastBadgeOpenAt = 0;

  // 人数ピルのタップ: 人数表示中は新規タブで開いて即切り替え、取得中/再取得表示中は優先再取得
  function bindStatBadgeClick(statEl, wrap, handle) {
    statEl.addEventListener('click', function(ev) {
      var state = statEl.getAttribute('data-omni-ff-state') || '';
      if (state === 'banner') return;
      ev.preventDefault();
      ev.stopPropagation();
      if (typeof ev.stopImmediatePropagation === 'function') ev.stopImmediatePropagation();
      if (ev.isTrusted === false) return;
      if (state === 'stats') {
        var now = Date.now();
        if (now - lastBadgeOpenAt < 700) return;
        var url = resolveBadgeProfileUrl(wrap, handle);
        if (url && postOpenNewTabActivate(url)) {
          lastBadgeOpenAt = now;
          statEl.classList.remove('is-opening');
          void statEl.offsetWidth;
          statEl.classList.add('is-opening');
          setTimeout(function() { statEl.classList.remove('is-opening'); }, 420);
          return;
        }
      }
      enqueueFetch(handle, true, true);
      scheduleRenderBadges();
    });
  }

  function renderWrapContents(wrap, display, handle, isRow) {
    // 関係ピル更新
    var relEl = wrap.querySelector('.omni-ff-rel');
    if (display && display.relText) {
      if (!relEl) {
        relEl = document.createElement('span');
        wrap.insertBefore(relEl, wrap.firstChild);
      }
      var relCls = 'omni-ff-rel is-' + display.relKind;
      if (relEl.className !== relCls) relEl.className = relCls;
      if (relEl.textContent !== display.relText) relEl.textContent = display.relText;
      if (relEl.title !== display.relTitle) relEl.title = display.relTitle;
    } else if (relEl) {
      relEl.remove();
    }

    // 人数ピル更新
    var statEl = wrap.querySelector('.omni-ff-badge');
    var isBanner = wrap.classList.contains('is-profile-banner');
    if (display && display.statsText) {
      if (!statEl) {
        statEl = document.createElement('span');
        bindStatBadgeClick(statEl, wrap, handle);
        wrap.appendChild(statEl);
      }
      var statCls = 'omni-ff-badge' + (display.isFollowingHeavy ? ' is-following-heavy' : '') +
        (isBanner ? ' is-heavy-icon' : ' is-link');
      if (statEl.className !== statCls && statEl.className !== statCls + ' is-opening') statEl.className = statCls;
      var nextState = isBanner ? 'banner' : 'stats';
      if (statEl.getAttribute('data-omni-ff-state') !== nextState) statEl.setAttribute('data-omni-ff-state', nextState);
      if (statEl.textContent !== display.statsText) statEl.textContent = display.statsText;
      var tip = isBanner ? display.statsTitle : display.statsTitle + '（タップで新規タブに開く）';
      if (statEl.title !== tip) statEl.title = tip;
      var aria = isBanner && display.isFollowingHeavy ? 'フォロー多め' : tip;
      if (statEl.getAttribute('aria-label') !== aria) statEl.setAttribute('aria-label', aria);
      if (!isBanner && statEl.getAttribute('role') !== 'link') statEl.setAttribute('role', 'link');
    } else if (isRow && canActiveFetchPlatform()) {
      if (!statEl) {
        statEl = document.createElement('span');
        bindStatBadgeClick(statEl, wrap, handle);
        wrap.appendChild(statEl);
      }
      if (statEl.getAttribute('data-omni-ff-state') !== 'pending') statEl.setAttribute('data-omni-ff-state', 'pending');
      if (statEl.hasAttribute('role')) statEl.removeAttribute('role');
      if (inFlight[handle] || queuedSet[handle]) {
        statEl.className = 'omni-ff-badge is-pending';
        if (statEl.textContent !== '取得中…') statEl.textContent = '取得中…';
        statEl.title = 'フォロー数・フォロワー数を取得中';
      } else if (failedMap[handle] || Date.now() < backoffUntil) {
        statEl.className = 'omni-ff-badge is-retry';
        if (statEl.textContent !== '再取得↻') statEl.textContent = '再取得↻';
        statEl.title = 'クリックしてフォロー数・フォロワー数を取得';
      } else {
        statEl.className = 'omni-ff-badge is-pending';
        if (statEl.textContent !== '取得中…') statEl.textContent = '取得中…';
        statEl.title = 'クリックして優先取得';
      }
    } else if (statEl) {
      statEl.remove();
    }
  }

  var NON_USER_TEXT_RE = /^(?:フォロー|フォロー中|フォローする|フォローバック|フォロワー|相互フォロー|友達|投稿|返信|いいね|もっと見る|すべて見る|メッセージ|削除|リクエスト済|リクエスト中|承認待ち|follow|follow\s+back|following|followers|friends|mutual|posts|replies|likes|more|message|remove|requested|\d+(?:秒|分|時間|日|週間|[smhdw])?)$/i;
  var FOLLOW_LIST_BTN_RE = /^(?:[+＋]\s*)?(?:フォロー|フォローする|フォローバック|フォローバックする|フォローを返す|フォロー中|フォロー済|フォロー済み|相互フォロー|友達|リクエスト済|リクエスト中|承認待ち|follow|follow\s+back|following|friends|mutual|requested|connected|connect|つながり申請)$/i;
  var BTN_IS_MUTUAL_RE = /^(?:相互フォロー|相互|友達|friends|mutual|mutual\s+follow|connected|つながり済み)$/i;
  var BTN_IS_FOLLOW_BACK_RE = /^(?:[+＋]\s*)?(?:フォローバック|フォローバックする|フォローを返す|follow\s+back)$/i;
  var BTN_IS_FOLLOWING_RE = /^(?:フォロー中|フォロー済|フォロー済み|following)$/i;
  var BTN_IS_UNFOLLOWED_RE = /^(?:[+＋]\s*)?(?:フォロー|フォローする|follow)$/i;
  var FOLLOWS_YOU_BADGE_RE = /^(?:フォローされています|あなたをフォローしています|follows\s+you|相互フォロー(?:中)?|友達|friends)$/i;
  var FOLLOWS_YOU_TEXT_RE = /(?:フォローされています|あなたをフォローしています|follows\s+you)/i;

  function isInViewport(el) {
    try {
      var r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return false;
      var vh = window.innerHeight || 900;
      return r.bottom >= -180 && r.top <= vh + 260;
    } catch (_) {
      return false;
    }
  }

  function isBadgeTargetLink(a, handle) {
    try {
      if (a.closest('nav, [role="navigation"]')) return false;
      var txt = (a.innerText || a.textContent || '').replace(/\s+/g, ' ').trim();
      if (!txt || txt.length > 48) return false;
      if (NON_USER_TEXT_RE.test(txt)) return false;
      var curH = getCurrentProfileHandleFromUrl();
      if (curH === handle && a.closest('header')) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  function extractHandleFromRow(row) {
    try {
      var links = row.querySelectorAll('a[href]');
      for (var i = 0; i < links.length; i++) {
        var h = extractHandleFromLink(links[i]);
        if (h) return h;
      }
      var imgs = row.querySelectorAll('img[alt]');
      for (var j = 0; j < imgs.length; j++) {
        var alt = (imgs[j].getAttribute('alt') || '').trim();
        var am = /^@?([a-z0-9._-]{1,40})(?:のプロフィール写真|'s profile picture)/i.exec(alt);
        if (am) {
          var ah = normalizeHandle(am[1]);
          if (ah) return ah;
        }
      }
      var spans = row.querySelectorAll('span, div');
      for (var k = 0; k < spans.length && k < 40; k++) {
        var s = spans[k];
        if (s.children && s.children.length > 0) continue;
        if (s.closest('button, [role="button"], .omni-ff-wrap')) continue;
        var t = (s.textContent || '').trim();
        if (!t || t.length > 40 || /\s/.test(t) || NON_USER_TEXT_RE.test(t)) continue;
        var nh = normalizeHandle(t);
        if (nh && (userIdMap[nh] || t[0] === '@' || /[._0-9]/.test(nh) || /^[a-z][a-z0-9._]{2,30}$/.test(nh))) {
          return nh;
        }
      }
    } catch (_) {}
    return '';
  }

  function findRowTextColumn(row, btn, handle) {
    try {
      var anchor = null;
      var links = row.querySelectorAll('a[href]');
      for (var i = 0; i < links.length; i++) {
        if (extractHandleFromLink(links[i]) === handle && !links[i].querySelector('img, video, canvas')) {
          anchor = links[i];
          break;
        }
      }
      if (!anchor) {
        var leaves = row.querySelectorAll('span, div');
        for (var j = 0; j < leaves.length && j < 40; j++) {
          var el = leaves[j];
          if (el.children && el.children.length > 0) continue;
          if (el.closest('button, [role="button"], .omni-ff-wrap')) continue;
          var txt = (el.textContent || '').trim().replace(/^@+/, '').toLowerCase();
          if (txt === handle) {
            anchor = el;
            break;
          }
        }
      }
      if (!anchor) return null;
      var cur = anchor;
      var best = anchor.parentElement || anchor;
      for (var step = 0; step < 5 && cur && cur !== row; step++) {
        var p = cur.parentElement;
        if (!p || p === row) break;
        if (p.contains(btn)) break;
        if (p.querySelector('img[width], canvas')) break;
        var r = p.getBoundingClientRect();
        if (r.width >= 90 && r.height >= 24 && r.height <= 130) {
          best = p;
        }
        cur = p;
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  function inferRelationFromRowDom(row, btnText, handle, listContext) {
    if (!handle || handle === selfHandle) return;
    var iFollow = null;
    var followsMe = null;

    if (BTN_IS_MUTUAL_RE.test(btnText)) {
      iFollow = true;
      followsMe = true;
    } else if (BTN_IS_FOLLOW_BACK_RE.test(btnText)) {
      iFollow = false;
      followsMe = true;
    } else if (BTN_IS_FOLLOWING_RE.test(btnText)) {
      iFollow = true;
    } else if (BTN_IS_UNFOLLOWED_RE.test(btnText)) {
      iFollow = false;
    }

    if (listContext === 'self-followers') {
      followsMe = true;
    } else if (listContext === 'self-following' && iFollow === null) {
      iFollow = true;
    }

    // 行内の「フォローされています / Follows you」表示を検出（自前バッジ除外）
    if (followsMe === null) {
      var nodes = row.querySelectorAll('span, div');
      for (var i = 0; i < nodes.length && i < 30; i++) {
        var n = nodes[i];
        if (n.children && n.children.length > 0) continue;
        if (n.closest('.omni-ff-wrap, button, [role="button"]')) continue;
        var t = (n.textContent || '').trim();
        if (t && t.length <= 28 && FOLLOWS_YOU_BADGE_RE.test(t)) {
          followsMe = true;
          break;
        }
      }
    }

    if (iFollow !== null || followsMe !== null) {
      recordRelation(handle, iFollow, followsMe);
    }
  }

  // 行要素ごとのテキスト列・バッジのキャッシュ（毎スキャンの祖先 getBoundingClientRect 走査と重複バッジ生成を防ぐ）
  var rowColCache = typeof WeakMap === 'function' ? new WeakMap() : null;
  var rowWrapCache = typeof WeakMap === 'function' ? new WeakMap() : null;

  function getRowTextColumn(row, btn, handle) {
    var cached = rowColCache ? rowColCache.get(row) : null;
    if (cached && cached.h === handle && cached.col.isConnected && row.contains(cached.col)) return cached.col;
    var col = findRowTextColumn(row, btn, handle);
    if (col && rowColCache) {
      try {
        var rr = row.getBoundingClientRect();
        if (rr.width >= 1 && rr.height >= 1) rowColCache.set(row, { h: handle, col: col });
      } catch (_) {}
    }
    return col;
  }

  function upsertRowBadge(row, container, handle, btn, placements) {
    ensureStyles();
    var entry = statsMap[handle];
    var display = formatBadgeDisplay(entry, handle, true);

    if (display && display.isFollowingHeavy) {
      if (row.getAttribute('data-omni-ff-heavy') !== '1') row.setAttribute('data-omni-ff-heavy', '1');
    } else if (row.hasAttribute('data-omni-ff-heavy')) {
      row.removeAttribute('data-omni-ff-heavy');
    }

    if (!display && !canActiveFetchPlatform()) return;

    // 下段へ退避済みのバッジも見つけられるよう、テキスト列ではなく行全体から探す
    var wrap = rowWrapCache ? rowWrapCache.get(row) : null;
    if (!wrap || !wrap.isConnected || wrap.getAttribute('data-omni-ff-user') !== handle || !row.contains(wrap)) {
      wrap = findChildWrapByUser(row, handle);
    }
    if (!wrap) {
      wrap = document.createElement('div');
      wrap.className = 'omni-ff-wrap is-row';
      wrap.setAttribute('data-omni-ff-user', handle);
      try {
        container.appendChild(wrap);
      } catch (_) {
        return;
      }
    }
    if (rowWrapCache) rowWrapCache.set(row, wrap);
    renderWrapContents(wrap, display, handle, true);
    if (placements && btn) {
      var de = document.documentElement;
      var fitKey = (wrap.textContent || '') + '|' + ((de && de.clientWidth) || window.innerWidth || 0);
      if (wrap.getAttribute('data-omni-ff-fit') !== fitKey) {
        placements.push({ row: row, col: container, btn: btn, wrap: wrap, key: fitKey });
      }
    }
  }

  function ffRectsOverlap(a, b) {
    return a.right > b.left + 1 && a.left < b.right - 1 && a.bottom > b.top + 1 && a.top < b.bottom - 1;
  }

  // バッジ（各ピル）がフォローボタンに重なる / テキスト列・行からはみ出しているか
  function ffPillsClash(wrap, colRect, btnRect, rowRect) {
    var kids = wrap.children;
    for (var k = 0; k < kids.length; k++) {
      var kr = kids[k].getBoundingClientRect();
      if (kr.width < 1 || kr.height < 1) continue;
      if (btnRect && ffRectsOverlap(kr, btnRect)) return true;
      if (colRect && kr.right > colRect.right + 2) return true;
      if (rowRect && (kr.right > rowRect.right + 1 || kr.left < rowRect.left - 1)) return true;
    }
    return false;
  }

  // 子要素を末尾に追加した時に新しい行（下段）になる親要素か
  function ffLineBreakMode(el) {
    try {
      var cs = window.getComputedStyle(el);
      var d = cs.display || '';
      if (d.indexOf('grid') >= 0) return 'grid';
      if (d.indexOf('flex') >= 0) return (cs.flexDirection || 'row') === 'column' ? 'column' : '';
      if (d === 'block' || d === 'flow-root' || d === 'list-item' || d === 'inline-block' || d === 'table-cell') return 'block';
    } catch (_) {}
    return '';
  }

  function ffClearRowPad(row) {
    if (row.hasAttribute('data-omni-ff-padrow')) row.removeAttribute('data-omni-ff-padrow');
    if (row.hasAttribute('data-omni-ff-padbase')) row.removeAttribute('data-omni-ff-padbase');
    if (row.hasAttribute('data-omni-ff-posrel')) row.removeAttribute('data-omni-ff-posrel');
    if (row.style && row.style.getPropertyValue('--omni-ff-pad')) row.style.removeProperty('--omni-ff-pad');
  }

  function ffSetWrapPlace(it, pl) {
    var w = it.wrap;
    var row = it.row;
    var mode = pl.mode;
    var below = mode === 'below' || mode === 'overlay';
    var host = mode === 'below' ? pl.target : (mode === 'overlay' ? row : (mode === 'push' ? pl.host : it.col));
    if (host && w.parentElement !== host) host.appendChild(w);
    w.classList.toggle('is-below', below);
    w.classList.toggle('is-overlay', mode === 'overlay');
    w.classList.toggle('is-raised', mode === 'raised');
    w.classList.toggle('is-push', mode === 'push');
    var padL = below && pl.indent > 0 ? pl.indent + 'px' : '';
    if (w.style.paddingLeft !== padL) w.style.paddingLeft = padL;
    var mt = mode === 'push' ? Math.round(pl.push) + 'px' : '';
    if (w.style.marginTop !== mt) w.style.marginTop = mt;
    var wd = mode === 'push' ? Math.round(pl.width) + 'px' : '';
    if (w.style.width !== wd) w.style.width = wd;
    if (mode === 'push') {
      if (w.getAttribute('data-omni-ff-push') !== String(Math.round(pl.push))) w.setAttribute('data-omni-ff-push', String(Math.round(pl.push)));
    } else if (w.hasAttribute('data-omni-ff-push')) {
      w.removeAttribute('data-omni-ff-push');
    }
    if (mode === 'overlay') {
      var base = String(pl.basePad);
      if (row.getAttribute('data-omni-ff-padbase') !== base) row.setAttribute('data-omni-ff-padbase', base);
      // 元の下余白はバッジの下に残し、バッジ分の高さだけ余白を足す
      var bottomPx = Math.max(2, pl.basePad) + 'px';
      if (w.style.bottom !== bottomPx) w.style.bottom = bottomPx;
      if (!row.style.getPropertyValue('--omni-ff-pad')) row.style.setProperty('--omni-ff-pad', (Math.max(2, pl.basePad) + 20) + 'px');
      if (row.getAttribute('data-omni-ff-padrow') !== '1') row.setAttribute('data-omni-ff-padrow', '1');
      if (pl.posRel && row.getAttribute('data-omni-ff-posrel') !== '1') row.setAttribute('data-omni-ff-posrel', '1');
    } else {
      if (w.style.bottom) w.style.bottom = '';
      ffClearRowPad(row);
    }
    if (w.getAttribute('data-omni-ff-place') !== mode) w.setAttribute('data-omni-ff-place', mode);
  }

  function ffPillMetrics(wrap) {
    var m = { total: 0, maxW: 0, maxH: 0, top: Infinity };
    var kids = wrap.children;
    for (var k = 0; k < kids.length; k++) {
      var kr = kids[k].getBoundingClientRect();
      if (kr.width < 1 || kr.height < 1) continue;
      m.total += kr.width + 3;
      if (kr.width > m.maxW) m.maxW = kr.width;
      if (kr.height > m.maxH) m.maxH = kr.height;
      if (kr.top < m.top) m.top = kr.top;
    }
    return m;
  }

  // テキスト列が細くボタンと重なる行（PC版レイアウトを狭い画面で表示した時など）:
  // バッジをテキストブロックの末尾に置いて行の右端まで横幅を広げ、ボタンの下端より下へずらす。
  // 縦中央揃えのボタンは列が伸びた分だけ下がるため、ユーザー名 → ボタン → バッジ の順に重ならず並ぶ。
  // ずらし量は書き込み後の実測で決める（applyRowBadgePlacements の検証段階）。
  function ffPushHost(it) {
    var best = it.col;
    var el = it.col.parentElement;
    for (var d = 0; el && el !== it.row && d < 6 && !el.contains(it.btn); d++) {
      var lm = ffLineBreakMode(el);
      if (lm === 'block' || lm === 'column') best = el;
      el = el.parentElement;
    }
    return best;
  }

  function ffPushPlan(it, cr, br, rr, curPush) {
    if (!br || br.left <= cr.left + 1) return null;
    var host = ffPushHost(it);
    var hr = host === it.col ? cr : host.getBoundingClientRect();
    var width = Math.floor(rr.right - hr.left - 2);
    var pm = ffPillMetrics(it.wrap);
    if (!pm.maxW || pm.maxW + 2 > width) return null;
    // テキストブロック〜行の間に、はみ出したバッジを切り取る要素があれば使えない
    var el = host;
    for (var d = 0; el && el !== it.row && d < 8; d++) {
      var cs = window.getComputedStyle(el);
      if (cs.overflowX !== 'visible' || cs.overflowY !== 'visible') return null;
      el = el.parentElement;
    }
    return { it: it, mode: 'push', host: host, push: Math.max(0, curPush), width: width };
  }

  // 行全体が横並びの場合: 行の下側に余白を確保してそこへバッジを表示する（サイト側要素の配置は変えない）
  function ffOverlayPlan(it, cr, rr) {
    var rcs = window.getComputedStyle(it.row);
    var bl = parseFloat(rcs.borderLeftWidth) || 0;
    var indent = Math.round(cr.left - (rr.left + bl));
    if (indent < 0 || indent > rr.width * 0.5) indent = 0;
    var padAttr = it.row.getAttribute('data-omni-ff-padbase');
    var basePad = padAttr !== null ? (parseFloat(padAttr) || 0) : (parseFloat(rcs.paddingBottom) || 0);
    return {
      it: it,
      mode: 'overlay',
      indent: indent,
      basePad: Math.max(0, Math.round(basePad)),
      posRel: it.row.getAttribute('data-omni-ff-posrel') === '1' || rcs.position === 'static'
    };
  }

  // 下段に新しい行を作れる要素（ブロック / 縦並び flex / grid）をテキスト列とボタンの共通祖先から行要素まで探す
  function ffBelowOrOverlayPlan(it, cr, rr) {
    var target = null;
    var anc = it.col.parentElement;
    while (anc && anc !== it.row && !anc.contains(it.btn)) anc = anc.parentElement;
    for (var depth = 0; anc && depth < 6; depth++) {
      if (ffLineBreakMode(anc)) { target = anc; break; }
      if (anc === it.row) break;
      anc = anc.parentElement;
    }
    if (!target) return ffOverlayPlan(it, cr, rr);
    var tr = target.getBoundingClientRect();
    var tcs = window.getComputedStyle(target);
    var innerLeft = tr.left + (parseFloat(tcs.borderLeftWidth) || 0) + (parseFloat(tcs.paddingLeft) || 0);
    var indent = Math.round(cr.left - innerLeft);
    if (indent < 0 || indent > tr.width * 0.5) indent = 0;
    return { it: it, mode: 'below', target: target, indent: indent };
  }

  // 行バッジがフォローボタンに隠れないよう配置を決める。
  // 優先順: そのまま → ボタンの下へずらす → 行内の下段 → 行下の余白 → ボタンより前面（最終手段）
  // 読み取り → 書き込み → 検証 の順にまとめて処理し、強制レイアウトを最小限にする。
  function applyRowBadgePlacements(items) {
    if (!items || !items.length) return;
    var vh = window.innerHeight || 900;
    var plans = [];
    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      try {
        if (!it.wrap.isConnected || !it.col.isConnected || !it.row.contains(it.wrap)) continue;
        var rr = it.row.getBoundingClientRect();
        // 画面外の行は表示されてから判定する（判定済みキーを付けずに次回スキャンへ回す）
        if (rr.width < 1 || rr.height < 1 || rr.bottom < -180 || rr.top > vh + 260) continue;
        var place = it.wrap.getAttribute('data-omni-ff-place') || 'inline';
        var cr = it.col.getBoundingClientRect();
        var br = it.btn.isConnected ? it.btn.getBoundingClientRect() : null;
        if (br && (br.width < 1 || br.height < 1)) br = null;
        var fits;
        if (place === 'inline') {
          fits = !ffPillsClash(it.wrap, cr, br, rr);
        } else {
          // 退避中: テキスト列にボタンと重ならず収まる幅が戻った時だけ通常表示へ戻す（ちらつき防止の余白付き）
          var maxPill = ffPillMetrics(it.wrap).maxW;
          var avail = cr.width;
          if (br && br.left > cr.left && br.top < cr.bottom && br.bottom > cr.top) avail = Math.min(avail, br.left - cr.left);
          fits = maxPill > 0 && maxPill + 12 <= avail;
        }
        var plan = null;
        if (fits) {
          plan = { it: it, mode: place === 'inline' ? 'keep' : 'inline' };
        } else {
          var inCol = place === 'inline' || place === 'push' || place === 'raised';
          if (inCol && it.row.getAttribute('data-omni-ff-nopush') !== '1') {
            plan = ffPushPlan(it, cr, br, rr, place === 'push' ? (parseFloat(it.wrap.getAttribute('data-omni-ff-push')) || 0) : 0);
          }
          if (!plan) {
            if (it.row.getAttribute('data-omni-ff-nooverlay') === '1') plan = { it: it, mode: 'raised' };
            else if (it.row.getAttribute('data-omni-ff-nobelow') === '1') plan = ffOverlayPlan(it, cr, rr);
            else plan = ffBelowOrOverlayPlan(it, cr, rr);
          }
        }
        plan.colLeft = cr.left;
        plan.btnLeft = br ? br.left : null;
        plans.push(plan);
      } catch (_) {}
    }

    var verify = [];
    var done = [];
    for (var p = 0; p < plans.length; p++) {
      var pl = plans[p];
      try {
        if (pl.mode !== 'keep') ffSetWrapPlace(pl.it, pl);
        if (pl.mode === 'below' || pl.mode === 'overlay' || pl.mode === 'push') verify.push(pl);
        else done.push(pl.it);
      } catch (_) {}
    }
    if (!verify.length && !done.length) return;

    // 検証: 配置後もボタンと重なる / 既存要素が横にずれた場合は次の手段へ
    var failedPush = [];
    var failedBelow = [];
    var failedOverlay = [];
    var padFix = [];
    var pushPending = [];
    for (var v = 0; v < verify.length; v++) {
      var vp = verify[v];
      try {
        var rr2 = vp.it.row.getBoundingClientRect();
        var br2 = vp.it.btn.isConnected ? vp.it.btn.getBoundingClientRect() : null;
        if (br2 && (br2.width < 1 || br2.height < 1)) br2 = null;
        if (vp.mode === 'push') {
          pushPending.push(vp);
          continue;
        }
        var cr2 = vp.it.col.getBoundingClientRect();
        var shifted = Math.abs(cr2.left - vp.colLeft) > 3 ||
          (!!br2 && vp.btnLeft !== null && Math.abs(br2.left - vp.btnLeft) > 3);
        if (vp.mode === 'below') {
          if (shifted || ffPillsClash(vp.it.wrap, null, br2, rr2)) failedBelow.push(vp.it);
          else done.push(vp.it);
        } else if (shifted) {
          failedOverlay.push(vp.it);
        } else {
          // 余白の高さをバッジの実際の高さ（折り返し含む）に合わせる
          var wh = vp.it.wrap.getBoundingClientRect().height;
          padFix.push({ row: vp.it.row, pad: Math.max(2, vp.basePad) + Math.ceil(wh) + 3 });
          done.push(vp.it);
        }
      } catch (_) {}
    }
    for (var q = 0; q < padFix.length; q++) {
      try {
        var padVal = padFix[q].pad + 'px';
        if (padFix[q].row.style.getPropertyValue('--omni-ff-pad') !== padVal) padFix[q].row.style.setProperty('--omni-ff-pad', padVal);
      } catch (_) {}
    }
    // ボタン下へのずらし量: 1 回目は重なり量を実測して決め（縦中央揃えなら 2 倍ずらす必要がある）、2 回目で確認する。
    // ずらし過ぎ（ボタンが縦中央揃えでない場合など）は余白を詰める。
    for (var round = 0; round < 2 && pushPending.length; round++) {
      var nextPending = [];
      var pushWrites = [];
      for (var x = 0; x < pushPending.length; x++) {
        var pp = pushPending[x];
        try {
          var brP = pp.it.btn.isConnected ? pp.it.btn.getBoundingClientRect() : null;
          if (brP && (brP.width < 1 || brP.height < 1)) brP = null;
          if (ffPillsClash(pp.it.wrap, null, null, pp.it.row.getBoundingClientRect())) {
            failedPush.push(pp.it);
            continue;
          }
          var pmP = ffPillMetrics(pp.it.wrap);
          if (brP && ffPillsClash(pp.it.wrap, null, brP, null)) {
            var nextPush = pp.push + 2 * Math.ceil(brP.bottom - pmP.top + 4);
            if (round > 0 || nextPush > 160) {
              failedPush.push(pp.it);
            } else {
              pp.push = nextPush;
              pushWrites.push(pp);
              nextPending.push(pp);
            }
            continue;
          }
          var gapP = brP ? pmP.top - brP.bottom : 0;
          if (brP && gapP > 12 && pp.push > 0) {
            pp.push = Math.max(0, Math.round(pp.push - (gapP - 6)));
            pushWrites.push(pp);
          }
          done.push(pp.it);
        } catch (_) {}
      }
      for (var y = 0; y < pushWrites.length; y++) {
        try {
          var pw = pushWrites[y].it.wrap;
          var pv = Math.round(pushWrites[y].push);
          pw.style.marginTop = pv + 'px';
          pw.setAttribute('data-omni-ff-push', String(pv));
        } catch (_) {}
      }
      pushPending = nextPending;
    }
    // 置けなかった行は前面表示で暫定表示し、次回スキャンで次の手段を試す（判定済みキーは付けない）
    for (var a = 0; a < failedPush.length; a++) {
      try {
        failedPush[a].row.setAttribute('data-omni-ff-nopush', '1');
        ffSetWrapPlace(failedPush[a], { mode: 'raised' });
      } catch (_) {}
    }
    for (var b = 0; b < failedBelow.length; b++) {
      try {
        failedBelow[b].row.setAttribute('data-omni-ff-nobelow', '1');
        ffSetWrapPlace(failedBelow[b], { mode: 'raised' });
      } catch (_) {}
    }
    for (var f = 0; f < failedOverlay.length; f++) {
      try {
        failedOverlay[f].row.setAttribute('data-omni-ff-nooverlay', '1');
        ffSetWrapPlace(failedOverlay[f], { mode: 'raised' });
        done.push(failedOverlay[f]);
      } catch (_) {}
    }
    for (var s = 0; s < done.length; s++) {
      try {
        if (done[s].wrap.getAttribute('data-omni-ff-fit') !== done[s].key) done[s].wrap.setAttribute('data-omni-ff-fit', done[s].key);
      } catch (_) {}
    }
  }

  function scanFollowListRows(rootScope) {
    var listContext = detectSelfListPageContext();
    var scope = rootScope || document;
    var placements = [];
    try {
      var btns = scope.querySelectorAll('button, [role="button"]');
      var maxBtns = rootScope ? 320 : 280;
      for (var i = 0; i < btns.length && i < maxBtns; i++) {
        var btn = btns[i];
        if (btn.closest('nav, [role="navigation"], .omni-ff-wrap')) continue;
        var bTxt = (btn.innerText || btn.textContent || '').replace(/\s+/g, ' ').trim();
        if (!bTxt || bTxt.length > 22 || !FOLLOW_LIST_BTN_RE.test(bTxt)) continue;

        // すでに特定済みの行はレイアウト計算(getBoundingClientRect)をスキップして高速更新
        var row = btn.closest('[data-omni-ff-row]');
        var handle = row ? (row.getAttribute('data-omni-ff-row') || '') : '';
        if (!row || !handle) {
          row = null;
          var cur = btn.parentElement;
          for (var depth = 0; depth < 7 && cur && cur !== document.body; depth++) {
            var rect = cur.getBoundingClientRect();
            if (rect.height >= 40 && rect.height <= 200 && rect.width >= 200) {
              var followBtnCount = 0;
              var subBtns = cur.querySelectorAll('button, [role="button"]');
              for (var sb = 0; sb < subBtns.length; sb++) {
                var st = (subBtns[sb].innerText || subBtns[sb].textContent || '').replace(/\s+/g, ' ').trim();
                if (st && st.length <= 22 && FOLLOW_LIST_BTN_RE.test(st)) followBtnCount++;
              }
              if (followBtnCount === 1) {
                var hCand = extractHandleFromRow(cur);
                if (hCand) {
                  row = cur;
                  handle = hCand;
                  break;
                }
              }
            }
            cur = cur.parentElement;
          }
          if (!row || !handle) continue;
          row.setAttribute('data-omni-ff-row', handle);
        }

        var col = getRowTextColumn(row, btn, handle);
        if (!col) continue;

        inferRelationFromRowDom(row, bTxt, handle, listContext);

        var ent = statsMap[handle];
        var needStats = !hasUsableStats(ent);
        var needRel = handle !== selfHandle && (!ent || ent.followsMe === null) && !!userIdMap[handle];
        if ((needStats || needRel) && isInViewport(row)) {
          if (needStats) {
            enqueueFetch(handle, false, false);
          } else if (needRel) {
            scheduleRelBatch(160);
          }
        }
        upsertRowBadge(row, col, handle, btn, placements);
      }
    } catch (_) {}
    try {
      applyRowBadgePlacements(placements);
    } catch (_) {}
  }

  // 現在開いているプロフィールページのDOMから人数＆相互状態を読み取り、ヘッダーにインライン表示する（全SNS対応）
  function scanCurrentProfilePage() {
    try {
      var curHandle = getCurrentProfileHandleFromUrl();
      if (!curHandle) return;
      var root = document.querySelector('main, header, [role="main"]') || document.body;
      if (!root) return;

      var headerScope = root.querySelector('header') || root;
      var textSample = (headerScope.innerText || '').slice(0, 2500);
      var followers = null;
      var following = null;
      var iFollow = null;
      var followsMe = null;

      // 日本語・英語・中国語・韓国語の人数パターン抽出
      var mFlwng = /([0-9.,]+\s*[KMB万千億]?)\s*(?:フォロー中|フォロー(?!ワー)|Following|Follows|关注|팔로잉)/i.exec(textSample) ||
                   /(?:フォロー中|Following|关注|팔로잉)\s*[:：]?\s*([0-9.,]+\s*[KMB万千億]?)/i.exec(textSample);
      if (mFlwng) following = parseHumanNumber(mFlwng[1]);

      var mFlwrs = /([0-9.,]+\s*[KMB万千億]?)\s*(?:フォロワー|Followers|粉丝|팔로워)/i.exec(textSample) ||
                   /(?:フォロワー|Followers|粉丝|팔로워)\s*[:：]?\s*([0-9.,]+\s*[KMB万千億]?)/i.exec(textSample);
      if (mFlwrs) followers = parseHumanNumber(mFlwrs[1]);

      if (curHandle !== selfHandle) {
        if (FOLLOWS_YOU_TEXT_RE.test(textSample)) {
          followsMe = true;
        }
        var headerBtns = headerScope.querySelectorAll('button, [role="button"]');
        for (var i = 0; i < headerBtns.length && i < 30; i++) {
          var bt = (headerBtns[i].innerText || headerBtns[i].textContent || '').replace(/\s+/g, ' ').trim();
          if (!bt || bt.length > 22) continue;
          if (BTN_IS_MUTUAL_RE.test(bt)) { iFollow = true; followsMe = true; break; }
          if (BTN_IS_FOLLOW_BACK_RE.test(bt)) { iFollow = false; followsMe = true; break; }
          if (BTN_IS_FOLLOWING_RE.test(bt)) { iFollow = true; break; }
          if (BTN_IS_UNFOLLOWED_RE.test(bt)) { iFollow = false; break; }
        }
      }

      if (followers !== null || following !== null || iFollow !== null || followsMe !== null) {
        recordStats(curHandle, followers, following, null, null, iFollow, followsMe);
      }

      if (curHandle === selfHandle) return;

      var entry = statsMap[curHandle];
      if (!hasUsableStats(entry) || (entry && entry.followsMe === null)) {
        enqueueFetch(curHandle, true, false);
        scheduleRelBatch();
      }

      var display = formatBadgeDisplay(entry, curHandle, false);
      if (!display || (!display.relText && !display.isFollowingHeavy)) return;

      var heading = headerScope.querySelector('h1, h2');
      if (!heading || !heading.parentElement) return;
      ensureStyles();
      var existing = findChildWrapByUser(heading.parentElement, curHandle);
      if (!existing) {
        existing = document.createElement('span');
        existing.className = 'omni-ff-wrap is-profile-banner';
        existing.setAttribute('data-omni-ff-user', curHandle);
        try {
          heading.insertAdjacentElement('afterend', existing);
        } catch (_) {
          return;
        }
      }
      // プロフィール画面では相互ピルとフォロー多め強調（文字なしの ▲ アイコンのみ）を簡潔に表示（元の人数表示と重複しすぎないよう）
      var bannerDisplay = {
        relKind: display.relKind,
        relText: display.relText,
        relTitle: display.relTitle,
        statsText: display.isFollowingHeavy ? '▲' : '',
        statsTitle: display.statsTitle,
        isFollowingHeavy: display.isFollowingHeavy
      };
      renderWrapContents(existing, bannerDisplay, curHandle, false);
    } catch (_) {}
  }

  var io = null;
  try {
    if (typeof IntersectionObserver === 'function') {
      io = new IntersectionObserver(function(entries) {
        for (var i = 0; i < entries.length; i++) {
          if (entries[i].isIntersecting) {
            var el = entries[i].target;
            var h = el.getAttribute('data-omni-ff-handle');
            if (h) enqueueFetch(h, false, false);
          }
        }
      }, { rootMargin: '160px' });
    }
  } catch (_) {}

  function applyBadgeToLink(a, handle) {
    var entry = statsMap[handle];
    var display = formatBadgeDisplay(entry, handle, false);
    if (!display) return;

    var next = a.nextElementSibling;
    if (next && next.classList && next.classList.contains('omni-ff-wrap') &&
        next.getAttribute('data-omni-ff-user') === handle) {
      renderWrapContents(next, display, handle, false);
      return;
    }

    var scope = a.closest('[data-omni-ff-row], header, [role="listitem"], li') || a.parentElement;
    if (scope) {
      var existing = findChildWrapByUser(scope, handle);
      if (existing) {
        if (!existing.classList.contains('is-row') && !existing.classList.contains('is-profile-banner')) {
          renderWrapContents(existing, display, handle, false);
        }
        return;
      }
    }

    ensureStyles();
    var wrap = document.createElement('span');
    wrap.className = 'omni-ff-wrap';
    wrap.setAttribute('data-omni-ff-user', handle);
    renderWrapContents(wrap, display, handle, false);
    try {
      a.insertAdjacentElement('afterend', wrap);
    } catch (_) {}
  }

  function scanAndRender() {
    detectDynamicPlatformFromDom();
    detectPageTheme();
    if (isChatOnlyPlatform) return;
    detectSelfAccountFromDom();

    // フォロワー/フォロー一覧モーダルが開いている場合はダイアログ内のみ優先スキャン（背景ページの過剰走査を防止）
    var activeDialog = document.querySelector('[role="dialog"]');
    if (activeDialog && activeDialog.querySelector('a[href], button, [role="button"]')) {
      scanFollowListRows(activeDialog);
      scheduleRelBatch(160);
      return;
    }

    scanCurrentProfilePage();
    scanFollowListRows(null);

    var links = document.querySelectorAll('a[href]');
    var maxLinks = platform === 'instagram' ? 600 : 1200;
    for (var i = 0; i < links.length && i < maxLinks; i++) {
      var a = links[i];
      if (a.closest('[data-omni-ff-row], .omni-ff-wrap')) continue;
      var handle = a.getAttribute('data-omni-ff-handle');
      if (handle === '') continue;
      if (handle === null) {
        handle = extractHandleFromLink(a);
        a.setAttribute('data-omni-ff-handle', handle || '');
        if (handle) {
          (function(linkEl, h) {
            linkEl.addEventListener('pointerenter', function() {
              enqueueFetch(h, true, false);
              scheduleRelBatch(120);
            }, { passive: true });
          })(a, handle);
        }
      }
      if (handle) {
        var targetState = a.getAttribute('data-omni-ff-target');
        if (targetState === null) {
          if (isBadgeTargetLink(a, handle)) {
            a.setAttribute('data-omni-ff-target', '1');
            targetState = '1';
            if (io) io.observe(a);
          } else {
            a.setAttribute('data-omni-ff-target', '0');
            targetState = '0';
          }
        }
        if (targetState === '1') {
          var ent = statsMap[handle];
          if (hasAnyDisplayData(ent, handle)) {
            applyBadgeToLink(a, handle);
          }
          var needStats = !hasUsableStats(ent);
          var needRel = handle !== selfHandle && (!ent || ent.followsMe === null) && !!userIdMap[handle];
          if ((needStats || needRel) && isInViewport(a)) {
            if (needStats) {
              enqueueFetch(handle, false, false);
            } else if (needRel) {
              scheduleRelBatch(160);
            }
          }
        }
      }
    }
    scheduleRelBatch();
  }

  var deferredWhileHidden = false;

  function scheduleRenderBadges(delayMs) {
    if (!pageBooted) return;
    // 非表示（バックグラウンドタブ）中は DOM 全走査を行わず、表示復帰時に 1 回だけまとめて走査する
    if (document.visibilityState === 'hidden') {
      deferredWhileHidden = true;
      return;
    }
    if (renderTimer) return;
    var wait = typeof delayMs === 'number' ? delayMs : (platform === 'instagram' ? 300 : 200);
    renderTimer = setTimeout(function() {
      renderTimer = null;
      runWhenIdle(scanAndRender, 500);
    }, wait);
  }

  loadCache();

  function hookHistory() {
    try {
      var origPush = history.pushState;
      var origReplace = history.replaceState;
      if (typeof origPush === 'function') {
        history.pushState = function() {
          var r = origPush.apply(this, arguments);
          scheduleRenderBadges(320);
          return r;
        };
      }
      if (typeof origReplace === 'function') {
        history.replaceState = function() {
          var r = origReplace.apply(this, arguments);
          scheduleRenderBadges(320);
          return r;
        };
      }
      window.addEventListener('popstate', function() { scheduleRenderBadges(320); }, { passive: true });
    } catch (_) {}
  }

  function isOwnMutationNode(node) {
    if (!node || node.nodeType !== 1) return false;
    var cl = node.classList;
    return !!(cl && (cl.contains('omni-ff-wrap') || cl.contains('omni-ff-badge') || cl.contains('omni-ff-rel')));
  }

  function startAfterInitialPaint() {
    if (pageBooted) return;
    pageBooted = true;
    runWhenIdle(function() {
      scanSsrScripts();
      scanAndRender();
    }, 900);
    try {
      window.addEventListener('scroll', function() {
        var now = Date.now();
        if (now - lastScrollScanAt < 260) return;
        lastScrollScanAt = now;
        scheduleRenderBadges(260);
      }, { capture: true, passive: true });
    } catch (_) {}
    try {
      document.addEventListener('visibilitychange', function() {
        if (document.visibilityState === 'visible' && deferredWhileHidden) {
          deferredWhileHidden = false;
          scheduleRenderBadges(60);
        }
      });
    } catch (_) {}
    try {
      if (typeof MutationObserver === 'function' && document.body) {
        var mo = new MutationObserver(function(mutations) {
          if (document.visibilityState === 'hidden') {
            deferredWhileHidden = true;
            return;
          }
          for (var i = 0; i < mutations.length; i++) {
            var added = mutations[i].addedNodes;
            if (added && added.length > 0) {
              for (var j = 0; j < added.length; j++) {
                if (!isOwnMutationNode(added[j])) {
                  scheduleRenderBadges();
                  return;
                }
              }
            }
          }
        });
        mo.observe(document.body, { childList: true, subtree: true });
      }
    } catch (_) {}
    setTimeout(function() { scanSsrScripts(); scheduleRenderBadges(100); }, 2200);
    setInterval(function() {
      if (document.visibilityState === 'visible') {
        runWhenIdle(scanAndRender, 800);
        var maxW = platform === 'instagram' ? igConcurrency : 1;
        if (activeWorkers < maxW && queue.length > 0 && Date.now() >= backoffUntil) {
          processQueue();
        }
      }
    }, 5000);
  }

  function boot() {
    window.__omniResolveProfileHandle = getCurrentProfileHandleFromUrl;
    window.__omniExtractHandleFromRow = extractHandleFromRow;
    try {
      window.addEventListener('storage', function(ev) {
        if (ev && ev.key === FOLLOWED_AT_KEY) {
          loadFollowedAtFromStorage();
          scheduleRenderBadges(80);
        }
      });
    } catch (_) {}
    injectInstagramPreconnects();
    detectDynamicPlatformFromDom();
    hookHistory();
    // 初回ページ読み込み・ハイドレーションをブロックしないよう load 完了後または最大 1200ms 後にスキャン開始
    if (document.readyState === 'complete') {
      setTimeout(startAfterInitialPaint, platform === 'instagram' ? 350 : 120);
    } else {
      window.addEventListener('load', function() {
        setTimeout(startAfterInitialPaint, platform === 'instagram' ? 280 : 80);
      }, { once: true });
      setTimeout(startAfterInitialPaint, platform === 'instagram' ? 1200 : 700);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }
})();
"""

        val PROFILE_STATS_JS: String = listOf(
            PROFILE_STATS_JS_PART_1,
            PROFILE_STATS_JS_PART_2,
            PROFILE_STATS_JS_PART_3,
        ).joinToString("\n")

        val LONG_PRESS_NEW_TAB_JS: String = """
(function() {
  if (window !== window.top) return;
  if (window.__omniLongPressNewTabInstalled) return;
  window.__omniLongPressNewTabInstalled = true;
  var __omniFollowToken = "__OMNISNS_FOLLOW_TOKEN__";
  var __omniFollowChannel = window.OmniFollowChannel;
  var __omniFollowBridge = window.OmniFollowBridge;

  var HOLD_MS = 460;
  var MOVE_TOLERANCE_PX = 10;
  var activeTimer = null;
  var activePointerId = null;
  var startX = 0;
  var startY = 0;
  var suppressUntil = 0;
  var styleInjected = false;

  function ensureStyle() {
    if (styleInjected) return;
    var target = document.head || document.documentElement;
    if (!target) return;
    styleInjected = true;
    var st = document.createElement('style');
    st.id = 'omni-lp-style';
    st.textContent =
      '@keyframes omni-lp-ring {' +
      '  0% { transform: translate(-50%, -50%) scale(0.35); opacity: 0.92; }' +
      '  100% { transform: translate(-50%, -50%) scale(1.7); opacity: 0; }' +
      '}\n' +
      '.omni-lp-ripple {' +
      '  position: fixed; z-index: 2147483647; width: 42px; height: 42px;' +
      '  border-radius: 999px; border: 2.5px solid #38bdf8;' +
      '  background: rgba(56, 189, 248, 0.16); pointer-events: none;' +
      '  animation: omni-lp-ring 380ms cubic-bezier(0.2, 0.8, 0.2, 1) forwards;' +
      '}\n' +
      'a[href], a[href] * { -webkit-touch-callout: none !important; }';
    target.appendChild(st);
  }

  function showRipple(x, y) {
    ensureStyle();
    if (!document.body) return;
    try {
      var dot = document.createElement('div');
      dot.className = 'omni-lp-ripple';
      dot.style.left = Math.round(x) + 'px';
      dot.style.top = Math.round(y) + 'px';
      document.body.appendChild(dot);
      setTimeout(function() {
        if (dot.parentNode) dot.parentNode.removeChild(dot);
      }, 420);
    } catch (_) {}
  }

  function toHttpUrl(raw) {
    if (!raw || typeof raw !== 'string') return null;
    var trimmed = raw.trim();
    if (!trimmed || trimmed === '#' || /^javascript:/i.test(trimmed) || /^mailto:/i.test(trimmed) || /^tel:/i.test(trimmed)) {
      return null;
    }
    try {
      var parsed = new URL(trimmed, location.href);
      if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
      return parsed.href;
    } catch (_) {
      return null;
    }
  }

  function isEditableElement(el) {
    if (!el || typeof el.closest !== 'function') return false;
    return !!el.closest('input, textarea, select, [contenteditable="true"], [contenteditable=""], [contenteditable="plaintext-only"], [role="textbox"]');
  }

  function resolveTargetUrl(el) {
    if (!el || el.nodeType !== 1 || typeof el.closest !== 'function') return null;
    if (isEditableElement(el)) return null;

    var anchor = el.closest('a[href], area[href]');
    if (anchor) {
      var u1 = toHttpUrl(anchor.getAttribute('href'));
      if (u1) return u1;
    }

    var dataHolder = el.closest('[data-href], [data-url]');
    if (dataHolder) {
      var u2 = toHttpUrl(dataHolder.getAttribute('data-href') || dataHolder.getAttribute('data-url'));
      if (u2) return u2;
    }

    // フォロー・いいね等の操作ボタン自身を長押しした場合は誤爆させない
    if (el.closest('button, [role="button"]')) return null;

    // フォロー中・フォロワー行（data-omni-ff-row）の余白・表示名長押しでもプロフィール URL を解決する
    var ffRow = el.closest('[data-omni-ff-row]');
    if (ffRow) {
      var rowHandle = (ffRow.getAttribute('data-omni-ff-row') || '').trim().toLowerCase();
      var rowLinks = ffRow.querySelectorAll('a[href]');
      var firstValid = null;
      for (var i = 0; i < rowLinks.length; i++) {
        var candidate = toHttpUrl(rowLinks[i].getAttribute('href'));
        if (!candidate) continue;
        if (!firstValid) firstValid = candidate;
        if (rowHandle && candidate.toLowerCase().indexOf(rowHandle) >= 0) {
          return candidate;
        }
      }
      if (firstValid) return firstValid;
    }

    // 小型リンクカード（単一リンクのみ含む）の長押しフォールバック
    var card = el.closest('[role="link"], [role="listitem"], li');
    if (card) {
      try {
        var r = card.getBoundingClientRect();
        if (r.height > 0 && r.height <= 160) {
          var links = card.querySelectorAll('a[href]');
          var distinct = null;
          var multi = false;
          for (var j = 0; j < links.length; j++) {
            var u = toHttpUrl(links[j].getAttribute('href'));
            if (!u) continue;
            if (!distinct) distinct = u;
            else if (distinct !== u) { multi = true; break; }
          }
          if (distinct && !multi) return distinct;
        }
      } catch (_) {}
    }

    return null;
  }

  function postOpenNewTab(url) {
    try {
      if (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function') {
        window.chrome.webview.postMessage(JSON.stringify({ type: 'omnisns:open-new-tab', url: url }));
        return true;
      }
      var ch = __omniFollowChannel || window.OmniFollowChannel;
      if (ch && typeof ch.postMessage === 'function') {
        ch.postMessage(JSON.stringify({ token: __omniFollowToken, type: 'open-new-tab', url: url }));
        return true;
      }
      var br = __omniFollowBridge || window.OmniFollowBridge;
      if (br && typeof br.onOpenNewTab === 'function') {
        br.onOpenNewTab(__omniFollowToken, url);
        return true;
      }
    } catch (_) {}
    return false;
  }

  function cancelPress() {
    if (activeTimer) {
      clearTimeout(activeTimer);
      activeTimer = null;
    }
    activePointerId = null;
  }

  document.addEventListener('pointerdown', function(e) {
    if (!e || e.isTrusted === false) return;
    if (e.ctrlKey || e.altKey || e.metaKey || e.shiftKey) return;
    var isTouchLike = e.pointerType === 'touch' || e.pointerType === 'pen';
    if (!isTouchLike && e.button !== 0) return;

    // 複数本指タッチ（ピンチ等）は即キャンセル
    if (activePointerId !== null) {
      cancelPress();
      return;
    }

    var target = e.target;
    if (target && target.nodeType !== 1) target = target.parentElement;
    var url = resolveTargetUrl(target);
    if (!url) return;

    ensureStyle();
    activePointerId = e.pointerId;
    startX = e.clientX;
    startY = e.clientY;
    var capturedUrl = url;

    activeTimer = setTimeout(function() {
      activeTimer = null;
      activePointerId = null;
      suppressUntil = Date.now() + 750;
      try {
        var sel = window.getSelection && window.getSelection();
        if (sel && sel.removeAllRanges) sel.removeAllRanges();
      } catch (_) {}
      showRipple(startX, startY);
      postOpenNewTab(capturedUrl);
    }, HOLD_MS);
  }, true);

  document.addEventListener('pointermove', function(e) {
    if (activePointerId === null || !e || e.pointerId !== activePointerId) return;
    var dx = e.clientX - startX;
    var dy = e.clientY - startY;
    if ((dx * dx + dy * dy) > (MOVE_TOLERANCE_PX * MOVE_TOLERANCE_PX)) {
      cancelPress();
    }
  }, true);

  document.addEventListener('pointerup', function(e) {
    if (activePointerId !== null && (!e || e.pointerId === activePointerId)) {
      cancelPress();
    }
  }, true);

  document.addEventListener('pointercancel', cancelPress, true);
  window.addEventListener('scroll', cancelPress, { capture: true, passive: true });
  window.addEventListener('wheel', cancelPress, { capture: true, passive: true });
  window.addEventListener('blur', cancelPress);
  document.addEventListener('visibilitychange', cancelPress);

  function maybeSuppressEvent(e) {
    if (Date.now() <= suppressUntil) {
      e.preventDefault();
      e.stopPropagation();
      if (typeof e.stopImmediatePropagation === 'function') {
        e.stopImmediatePropagation();
      }
      return false;
    }
  }

  document.addEventListener('click', maybeSuppressEvent, true);
  document.addEventListener('contextmenu', maybeSuppressEvent, true);
})();
"""

        private val JEV_FILTER_JS_PART_1: String = """
(function() {
  if (window !== window.top) return;
  if (window.__omniJevInstalled) return;
  window.__omniJevInstalled = true;
  var __omniFollowToken = "__OMNISNS_FOLLOW_TOKEN__";
  var __omniFollowChannel = window.OmniFollowChannel;
  var __omniFollowBridge = window.OmniFollowBridge;

  var host = (location.hostname || '').toLowerCase();
  var IS_INSTAGRAM = host === 'instagram.com' || host.endsWith('.instagram.com');
  var IS_TIKTOK = host === 'tiktok.com' || host.endsWith('.tiktok.com');
  var IS_THREADS = host === 'threads.net' || host.endsWith('.threads.net') || host === 'threads.com' || host.endsWith('.threads.com');
  var IS_BLUESKY = host === 'bsky.app' || host.endsWith('.bsky.app');
  var IS_X = host === 'x.com' || host.endsWith('.x.com') || host === 'twitter.com' || host.endsWith('.twitter.com');

  function detectPlatform() {
    if (IS_INSTAGRAM) return 'instagram';
    if (IS_TIKTOK) return 'tiktok';
    if (IS_THREADS) return 'threads';
    if (IS_BLUESKY) return 'bluesky';
    if (IS_X) return 'x';
    if (host.indexOf('facebook.com') >= 0) return 'facebook';
    if (host.indexOf('youtube.com') >= 0) return 'youtube';
    if (host.indexOf('mixi.social') >= 0 || host.indexOf('mixi2') >= 0) return 'mixi2';
    if (host.indexOf('misskey') >= 0) return 'misskey';
    if (host.indexOf('mastodon') >= 0 || host.indexOf('mstdn') >= 0) return 'mastodon';
    if (host.indexOf('reddit.com') >= 0) return 'reddit';
    if (host.indexOf('note.com') >= 0) return 'note';
    return 'sns';
  }

  var PLATFORM = detectPlatform();
  var RESERVED = new Set([
    'explore', 'direct', 'reels', 'stories', 'accounts', 'p', 'reel', 'tv',
    'about', 'legal', 'privacy', 'terms', 'session', 'challenge', 'oauth',
    'graphql', 'api', 'nametag', 'directory', 'topics', 'web', 'threads',
    'foryou', 'following', 'followers', 'friends', 'live', 'upload', 'messages',
    'search', 'tag', 'music', 'tiktok', 'home', 'notifications', 'settings',
    'compose', 'i', 'intent', 'hashtag', 'lists', 'bookmarks', 'communities',
    'login', 'signup', 'register', 'help', 'support', 'profile', 'post', 'status'
  ]);
  var USERNAME_RE = /^[A-Za-z0-9._-]{1,64}$/;
  var API_URL_RE = IS_TIKTOK
    ? /(\/api\/user\/list|\/user\/(follower|following)|\/aweme\/v\d+\/user\/(follower|following)|\/relations\/)/i
    : (IS_INSTAGRAM
        ? /(\/api\/v1\/friendships\/|\/api\/v1\/accounts\/|\/graphql|followers|following)/i
        : /(followers|following|follows|friendships|getFollowers|getFollows|searchActors|UserBy|Following|Followers)/i);
  var FRIENDSHIPS_LIST_RE = IS_TIKTOK
    ? /(\/api\/user\/list|\/user\/(follower|following)\/list|\/aweme\/v\d+\/user\/(follower|following)\/list)/i
    : (IS_INSTAGRAM
        ? /\/api\/v1\/friendships\/[^/?#]+\/(followers|following|mutual)/i
        : /(getFollowers|getFollows|followers|following)/i);
  var FOLLOW_GRAPH_KEY_RE = /^(edge_followed_by|edge_follow|xdt_api__v1__friendships|mutual_followers|userList|followers|follows)/i;
  var IGNORE_TEXT = /^(フォロー|フォロー中|フォローバック|フォローする|友達|削除|メッセージ|リクエスト済み|ブロック|制限する|親しい友達|共通|認証済み|新しいフォロワー|すべて見る|おすすめ|購読|相互|片思い|フォロワー|Follow|Following|Follow Back|Friends|Remove|Message|Requested|Verified|New|See All|Suggested|Subscriptions|•|・|\s*)$/i;
  var IGNORE_SUB = /(がフォロー中|Followed by|フォロワー\s*[\d,.万億kKmM]+|フォロー中\s*[\d,.万億kKmM]+|F[\d,.万億kKmM]+\/FW[\d,.万億kKmM]+|件の投稿|Followers\s*[\d,.kKmM]+|⇄\s*相互|→\s*片思い(?:\s*\d+(?:分|時間))?|←\s*フォロワー)/i;
  var FOLLOW_HEADER = /^(?:[\d,.万億kKmM]+\s*(?:人|人の)?\s*)?(フォロワー|フォロー中|共通のフォロワー|友達|Followers|Following|Follows|Mutual|Mutual followers|Friends|アカウント|ユーザー|People|Accounts)(?:\s*[\d,.万億kKmM人件]+)?$/i;
  var NON_FOLLOW_TAB = /^(おすすめ|Suggested|投稿|Posts|メディア|Media|いいね|Likes)$/i;
  var AVATAR_SIZE = 320;
  var MIN_VISIBLE_MATCHES = 12;
  var PULSE_COOLDOWN_MS = 850;
  var MAX_EMPTY_PULSES = 5;

  var judged = new Map();
  var apiUsers = new Map();
  var pendingQueue = new Map();
  var inflight = new Set();
  var failCounts = new Map();
  var hookedImages = new WeakSet();
  var pendingRequests = new Map();
  var reqSeq = 0;

  var avatarCanvas = null;
  var avatarCtx = null;
  var enabled = false;
  var currentCategory = '女の子';
  var timer = null;
  var cooldownTimer = null;
  var pumping = false;
  var observer = null;
  var lastReportedKey = '';

  var activeContextKey = '';
  var seenInContext = new Set();
  var apiBatchSeq = 0;
  var apiHasMore = null;
  var reachedEnd = false;
  var emptyPulseCount = 0;
  var pulseInProgress = false;
  var autoFetching = false;
  var lastPulseAt = 0;
  var lastUserScrollAt = 0;

  function sendToHost(type, payload) {
    try {
      if (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function') {
        var msg = Object.assign({ type: type }, payload || {});
        window.chrome.webview.postMessage(JSON.stringify(msg));
        return true;
      }
      var ch = __omniFollowChannel || window.OmniFollowChannel;
      if (ch && typeof ch.postMessage === 'function') {
        if (type === 'omnisns:jev-get-config') {
          ch.postMessage(JSON.stringify({ token: __omniFollowToken, type: 'jev-get-config' }));
          return true;
        }
        if (type === 'omnisns:jev-check') {
          ch.postMessage(JSON.stringify({
            token: __omniFollowToken,
            type: 'jev-check',
            reqId: String(payload.reqId || ''),
            payload: JSON.stringify(payload.candidates || [])
          }));
          return true;
        }
        if (type === 'omnisns:jev-state') {
          ch.postMessage(JSON.stringify({
            token: __omniFollowToken,
            type: 'jev-state',
            active: !!payload.active,
            matched: payload.matched | 0,
            hidden: payload.hidden | 0,
            autoFetching: !!payload.autoFetching
          }));
          return true;
        }
      }
      var br = __omniFollowBridge || window.OmniFollowBridge;
      if (br) {
        if (type === 'omnisns:jev-get-config' && typeof br.onJevGetConfig === 'function') {
          br.onJevGetConfig(__omniFollowToken);
          return true;
        }
        if (type === 'omnisns:jev-check' && typeof br.onJevCheckAccounts === 'function') {
          br.onJevCheckAccounts(__omniFollowToken, String(payload.reqId || ''), JSON.stringify(payload.candidates || []));
          return true;
        }
        if (type === 'omnisns:jev-state' && typeof br.onJevState === 'function') {
          br.onJevState(__omniFollowToken, !!payload.active, payload.matched | 0, payload.hidden | 0, !!payload.autoFetching);
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  function hasHostBridge() {
    var ch = __omniFollowChannel || window.OmniFollowChannel;
    var br = __omniFollowBridge || window.OmniFollowBridge;
    return !!(
      (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function') ||
      (ch && typeof ch.postMessage === 'function') ||
      (br && typeof br.onJevCheckAccounts === 'function')
    );
  }

  function resetPaginationState(nextKey) {
    activeContextKey = nextKey || '';
    seenInContext.clear();
    apiHasMore = null;
    reachedEnd = false;
    emptyPulseCount = 0;
    pulseInProgress = false;
    autoFetching = false;
    if (cooldownTimer) {
      clearTimeout(cooldownTimer);
      cooldownTimer = null;
    }
  }

  function ensureStyle() {
    var target = document.head || document.documentElement;
    if (!target || document.getElementById('omni-jev-style')) return;
    var style = document.createElement('style');
    style.id = 'omni-jev-style';
    style.textContent =
      'html.omni-jev-active [data-omni-jev-match="0"],\n' +
      'html.omni-jev-active [data-omni-jev-pending="1"] {\n' +
      '  display: none !important;\n' +
      '}\n' +
      'html.omni-jev-active [data-omni-jev-match="0"][data-omni-jev-tail-probe="1"] {\n' +
      '  display: block !important;\n' +
      '  height: 1px !important;\n' +
      '  min-height: 1px !important;\n' +
      '  max-height: 1px !important;\n' +
      '  overflow: hidden !important;\n' +
      '  opacity: 0 !important;\n' +
      '  pointer-events: none !important;\n' +
      '  margin: 0 !important;\n' +
      '  padding: 0 !important;\n' +
      '  border: 0 !important;\n' +
      '}';
    target.appendChild(style);
  }

  function applyRootClass() {
    if (enabled) ensureStyle();
    if (document.documentElement) {
      document.documentElement.classList.toggle('omni-jev-active', !!enabled);
    }
  }

  function userLinkSelector() {
    if (IS_TIKTOK || IS_THREADS) return 'a[href*="/@"]';
    if (IS_BLUESKY) return 'a[href*="/profile/"]';
    if (IS_INSTAGRAM || IS_X) return 'a[href^="/"]';
    return 'a[href]';
  }

  function parseUsernameHref(href) {
    if (!href) return null;
    var p = href.trim();
    if (/^https?:\/\//i.test(p)) {
      try {
        var uo = new URL(p);
        if (uo.hostname.toLowerCase() !== host && !uo.hostname.toLowerCase().endsWith('.' + host.replace(/^www\./, ''))) {
          return null;
        }
        p = uo.pathname + uo.search;
      } catch (_) {
        return null;
      }
    }
    var m;
    if (IS_TIKTOK || IS_THREADS) {
      m = /^\/@([A-Za-z0-9._-]{1,40})\/?(?:\?.*)?$/.exec(p);
      if (!m) return null;
      if (RESERVED.has(m[1].toLowerCase())) return null;
      return m[1];
    }
    if (IS_BLUESKY) {
      m = /^\/profile\/([A-Za-z0-9._:-]{2,64})\/?(?:\?.*)?$/.exec(p);
      if (!m) return null;
      if (RESERVED.has(m[1].toLowerCase())) return null;
      return m[1];
    }
    if (IS_INSTAGRAM || IS_X) {
      m = /^\/([A-Za-z0-9._]{1,32})\/?(?:\?.*)?$/.exec(p);
      if (!m) return null;
      if (RESERVED.has(m[1].toLowerCase())) return null;
      return m[1];
    }
    // 汎用 SNS（/@user, /@user@host, /users/user, /u/user, /user）
    m = /^\/(?:@|users\/|u\/|profile\/)?([A-Za-z0-9._@:-]{2,64})\/?(?:\?.*)?$/.exec(p);
    if (!m) return null;
    var clean = m[1].replace(/^@+/, '');
    if (!clean || RESERVED.has(clean.toLowerCase()) || !USERNAME_RE.test(clean.replace(/@/g, '_'))) return null;
    return clean;
  }

  function enqueueCandidate(u, key, n, bio, img, b64, fmt) {
    if (!u || !key) return;
    var apiEntry = apiUsers.get(key);
    var mergedName = n || (apiEntry ? apiEntry.n : '') || '';
    var mergedBio = bio || (apiEntry ? apiEntry.bio : '') || '';
    var mergedImg = img || (apiEntry ? apiEntry.img : '') || '';
    var hasImg = !!(mergedImg || b64);
    var cached = judged.get(key);
    if (cached !== undefined && (cached.hasImg || !hasImg)) return;
    if (inflight.has(key)) return;
    if ((failCounts.get(key) || 0) >= 3) return;

    var existing = pendingQueue.get(key);
    if (existing) {
      if (!existing.n && mergedName) existing.n = mergedName;
      if (!existing.bio && mergedBio) existing.bio = mergedBio;
      if (!existing.img && mergedImg) existing.img = mergedImg;
      if (!existing.b64 && b64) {
        existing.b64 = b64;
        existing.fmt = fmt;
      }
      return;
    }
    pendingQueue.set(key, {
      u: u,
      key: key,
      n: mergedName,
      bio: mergedBio,
      img: mergedImg,
      b64: b64 || '',
      fmt: fmt || ''
    });
  }

  function pickTikTokAvatarUrl(v) {
    if (typeof v === 'string') return v;
    if (v && typeof v === 'object') {
      if (Array.isArray(v.url_list) && typeof v.url_list[0] === 'string') return v.url_list[0];
      if (Array.isArray(v.urlList) && typeof v.urlList[0] === 'string') return v.urlList[0];
    }
    return '';
  }

  function rememberApiUser(u, fullName, bio, picUrl, foundByKey) {
    var uLower = u.toLowerCase();
    var prev = apiUsers.get(uLower);
    var entry = {
      u: u,
      key: uLower,
      n: fullName || (prev ? prev.n : ''),
      bio: bio || (prev ? prev.bio : ''),
      img: picUrl || (prev ? prev.img : '')
    };
    apiUsers.set(uLower, entry);
    if (apiUsers.size > 4000) {
      var oldest = apiUsers.keys().next().value;
      apiUsers.delete(oldest);
    }
    foundByKey.set(uLower, entry);
  }

  function inspectApiObject(rootObj, reqUrl) {
    if (!enabled || !rootObj || typeof rootObj !== 'object') return;
    var foundByKey = new Map();
    var hasFollowGraphKey = false;
    var detectedMore = null;
    var visited = 0;

    function walk(node, depth) {
      if (!node || typeof node !== 'object' || depth > 12 || visited > 3500) return;
      visited++;
      if (Array.isArray(node)) {
        for (var i = 0; i < node.length; i++) walk(node[i], depth + 1);
        return;
      }

      if (IS_INSTAGRAM) {
        if (Array.isArray(node.users) && ('next_max_id' in node || 'has_more' in node || 'big_list' in node)) {
          detectedMore = Boolean(node.next_max_id) || node.has_more === true;
        }
        if (node.page_info && typeof node.page_info === 'object' &&
            typeof node.page_info.has_next_page === 'boolean' && Array.isArray(node.edges)) {
          detectedMore = node.page_info.has_next_page;
        }
        if (typeof node.username === 'string') {
          var u = node.username.trim();
          var uLower = u.toLowerCase();
          if (USERNAME_RE.test(u) && !RESERVED.has(uLower) &&
              ('profile_pic_url' in node || 'full_name' in node || 'pk' in node || 'hd_profile_pic_url_info' in node)) {
            var fullName = typeof node.full_name === 'string' ? node.full_name.trim() : '';
            var bio = typeof node.biography === 'string' ? node.biography.trim() : '';
            var picUrl = (typeof node.profile_pic_url === 'string' && node.profile_pic_url) ||
              (node.hd_profile_pic_url_info && typeof node.hd_profile_pic_url_info.url === 'string' && node.hd_profile_pic_url_info.url) || '';
            rememberApiUser(u, fullName, bio, picUrl, foundByKey);
          }
        }
      } else if (IS_TIKTOK) {
        if (Array.isArray(node.userList) || Array.isArray(node.followers) || Array.isArray(node.followings)) {
          if (typeof node.hasMore === 'boolean') detectedMore = node.hasMore;
          else if (typeof node.has_more === 'boolean') detectedMore = node.has_more;
          else if (typeof node.minCursor === 'number') detectedMore = node.minCursor > 0;
        }
        var ttRawId = typeof node.uniqueId === 'string'
          ? node.uniqueId
          : (typeof node.unique_id === 'string' ? node.unique_id : '');
        if (ttRawId) {
          var tu = ttRawId.trim().replace(/^@/, '');
          var tuLower = tu.toLowerCase();
          if (USERNAME_RE.test(tu) && !RESERVED.has(tuLower) &&
              ('nickname' in node || 'avatarThumb' in node || 'avatarMedium' in node || 'avatarLarger' in node || 'avatar_thumb' in node)) {
            var nick = typeof node.nickname === 'string' ? node.nickname.trim() : '';
            var sig = typeof node.signature === 'string' ? node.signature.trim() : '';
            var tPic = pickTikTokAvatarUrl(node.avatarMedium) ||
              pickTikTokAvatarUrl(node.avatarThumb) ||
              pickTikTokAvatarUrl(node.avatarLarger) ||
              pickTikTokAvatarUrl(node.avatar_medium) ||
              pickTikTokAvatarUrl(node.avatar_thumb);
            rememberApiUser(tu, nick, sig, tPic, foundByKey);
          }
        }
      } else if (IS_BLUESKY) {
        if (typeof node.handle === 'string' && ('displayName' in node || 'avatar' in node || 'description' in node)) {
          var bh = node.handle.trim();
          if (bh && !RESERVED.has(bh.toLowerCase())) {
            var bn = typeof node.displayName === 'string' ? node.displayName.trim() : '';
            var bd = typeof node.description === 'string' ? node.description.trim() : '';
            var bp = typeof node.avatar === 'string' ? node.avatar.trim() : '';
            rememberApiUser(bh, bn, bd, bp, foundByKey);
          }
        }
      }

      var keys = Object.keys(node);
      for (var kIdx = 0; kIdx < keys.length; kIdx++) {
        var k = keys[kIdx];
        if (FOLLOW_GRAPH_KEY_RE.test(k)) hasFollowGraphKey = true;
        if (k === 'extensions') continue;
        walk(node[k], depth + 1);
      }
    }

    walk(rootObj, 0);
    var ctxNow = findFollowListContext();
    var isFollowApi = (FRIENDSHIPS_LIST_RE.test(reqUrl) && (!IS_TIKTOK || !!ctxNow || /scene=(21|67)\b/.test(reqUrl))) ||
      (hasFollowGraphKey && !!ctxNow);
    if (isFollowApi) {
      apiBatchSeq++;
      if (detectedMore !== null) {
        apiHasMore = detectedMore;
        if (!detectedMore) {
          reachedEnd = true;
          autoFetching = false;
        } else {
          reachedEnd = false;
          emptyPulseCount = 0;
        }
      } else if (foundByKey.size > 0) {
        reachedEnd = false;
        emptyPulseCount = 0;
      }

      if (enabled && foundByKey.size > 0 && ctxNow) {
        foundByKey.forEach(function(usr) {
          if (ctxNow.owner && usr.key === ctxNow.owner) return;
          seenInContext.add(usr.key);
          enqueueCandidate(usr.u, usr.key, usr.n, usr.bio, usr.img, '', '');
        });
        pumpQueue();
      }
    }
    if (foundByKey.size > 0 || isFollowApi) {
      scheduleScan(16);
    }
  }

  function inspectRawJson(raw, reqUrl) {
    if (!enabled || !raw || typeof raw !== 'string') return;
    var cleaned = raw.replace(/^\s*for\s*\(\s*;\s*;\s*\)\s*;?\s*/, '');
    if (!cleaned || (cleaned[0] !== '{' && cleaned[0] !== '[')) return;
    try {
      inspectApiObject(JSON.parse(cleaned), reqUrl);
    } catch (_) {}
  }

  function hookNetwork() {
    try {
      if (typeof window.fetch === 'function' && !window.fetch.__omniJevHooked) {
        var origFetch = window.fetch;
        var wrappedFetch = function(input) {
          var p = origFetch.apply(this, arguments);
          if (!enabled) return p;
          var reqUrl = '';
          try {
            reqUrl = typeof input === 'string' ? input : ((input && input.url) || String(input || ''));
          } catch (_) {}
          if (API_URL_RE.test(reqUrl) && p && typeof p.then === 'function') {
            p.then(function(res) {
              try {
                if (!enabled || !res || typeof res.clone !== 'function') return;
                var ct = (res.headers && res.headers.get && res.headers.get('content-type')) || '';
                if (ct && !/json|javascript|text/i.test(ct)) return;
                res.clone().text().then(function(txt) { inspectRawJson(txt, reqUrl); }).catch(function() {});
              } catch (_) {}
            }).catch(function() {});
          }
          return p;
        };
        wrappedFetch.__omniJevHooked = true;
        window.fetch = wrappedFetch;
      }
    } catch (_) {}

    try {
      if (typeof XMLHttpRequest !== 'undefined' && XMLHttpRequest.prototype && !XMLHttpRequest.prototype.__omniJevHooked) {
        var origOpen = XMLHttpRequest.prototype.open;
        var origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url) {
          try { this.__omniJevReqUrl = typeof url === 'string' ? url : String(url || ''); } catch (_) {}
          return origOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function() {
          try {
            if (enabled) {
              var reqUrl = this.__omniJevReqUrl || '';
              if (API_URL_RE.test(reqUrl)) {
                this.addEventListener('load', function() {
                  try {
                    if (!enabled) return;
                    var rt = this.responseType;
                    if (!rt || rt === 'text') {
                      inspectRawJson(this.responseText, reqUrl);
                    } else if (rt === 'json' && this.response) {
                      inspectApiObject(this.response, reqUrl);
                    }
                  } catch (_) {}
                });
              }
            }
          } catch (_) {}
          return origSend.apply(this, arguments);
        };
        XMLHttpRequest.prototype.__omniJevHooked = true;
      }
    } catch (_) {}
  }

  function findFollowListContext() {
    if (!document.body) return null;
    var pathname = location.pathname || '';

    if (IS_TIKTOK) {
      var ttListPath = /^\/@([^/?#]+)\/(followers|following)(\/|$)/i.exec(pathname);
      var ttProfilePath = /^\/@([A-Za-z0-9._]{1,32})\/?$/i.exec(pathname);
      var profileOwner = ttListPath
        ? ttListPath[1].toLowerCase()
        : (ttProfilePath ? ttProfilePath[1].toLowerCase() : null);

      var modalCandidates = Array.prototype.slice.call(document.querySelectorAll(
        '[data-e2e="follow-info-popup"], [role="dialog"], [aria-modal="true"], #tux-portal-container > div'
      )).filter(function(d) {
        if (d.closest('nav, header')) return false;
        var r = d.getBoundingClientRect();
        return r.width > 160 && r.height > 160;
      });

      for (var i = modalCandidates.length - 1; i >= 0; i--) {
        var d = modalCandidates[i];
        var dRect = d.getBoundingClientRect();
        var tabs = Array.prototype.slice.call(d.querySelectorAll('[role="tab"]'));
        var activeTab = tabs.find(function(t) { return t.getAttribute('aria-selected') === 'true'; });
        if (activeTab && NON_FOLLOW_TAB.test((activeTab.textContent || '').trim())) continue;
        var headers = d.querySelectorAll('[role="tab"], h1, h2, h3, [role="heading"], header, div, span');
        var matchedHeader = '';
        for (var hi = 0; hi < headers.length; hi++) {
          var h = headers[hi];
          if (h.children.length > 2) continue;
          var hr = h.getBoundingClientRect();
          if (hr.top - dRect.top > 150) continue;
          var t = (h.textContent || '').replace(/\s+/g, ' ').trim();
          if (t && t.length <= 36 && FOLLOW_HEADER.test(t)) {
            matchedHeader = t;
            if (h.getAttribute('aria-selected') === 'true' || h.tagName === 'H1' || h.tagName === 'H2') break;
          }
        }
        var isExplicitPopup = d.getAttribute('data-e2e') === 'follow-info-popup' ||
          !!d.querySelector('[data-e2e="follow-info-popup"], [data-e2e*="follow-info-item"]');
        if (matchedHeader || isExplicitPopup) {
          return { root: d, owner: profileOwner, isDialog: true, key: 'ttdlg:' + pathname + ':' + (matchedHeader || 'popup') };
        }
      }
      if (ttListPath) {
        return { root: document.querySelector('main') || document.body, owner: profileOwner, isDialog: false, key: 'ttpage:' + pathname };
      }
      return null;
    }

    if (IS_INSTAGRAM) {
      var pathMatch = /^\/([^/]+)\/(followers|following|mutual_followers)(\/|$)/i.exec(pathname);
      var pathOwner = pathMatch && !RESERVED.has(pathMatch[1].toLowerCase()) ? pathMatch[1].toLowerCase() : null;

      var dialogs = Array.prototype.slice.call(document.querySelectorAll('[role="dialog"]')).filter(function(el) {
        var r = el.getBoundingClientRect();
        return r.width > 140 && r.height > 140;
      });
      for (var di = dialogs.length - 1; di >= 0; di--) {
        var dlg = dialogs[di];
        var dlgRect = dlg.getBoundingClientRect();
        var dlgHeaders = dlg.querySelectorAll('h1, h2, [role="heading"], [role="tab"], header, div, span');
        var dlgMatched = '';
        for (var j = 0; j < dlgHeaders.length; j++) {
          var dh = dlgHeaders[j];
          if (dh.children.length > 2) continue;
          var dhr = dh.getBoundingClientRect();
          if (dhr.top - dlgRect.top > 130) continue;
          var dt = (dh.textContent || '').trim();
          if (dt && dt.length <= 30 && FOLLOW_HEADER.test(dt)) {
            dlgMatched = dt;
            if (dh.getAttribute('aria-selected') === 'true' || dh.tagName === 'H1' || dh.tagName === 'H2' || dh.getAttribute('role') === 'heading') break;
          }
        }
        if (dlgMatched || pathOwner) {
          return { root: dlg, owner: pathOwner, isDialog: true, key: 'igdlg:' + pathname + ':' + dlgMatched };
        }
      }
      if (pathOwner) {
        return { root: document.querySelector('main') || document.body, owner: pathOwner, isDialog: false, key: 'igpage:' + pathname };
      }
      return null;
    }

    if (IS_THREADS) {
      var thMatch = /^\/@?([^/]+)\/(followers|following)(\/|$)/i.exec(pathname);
      var thOwner = thMatch ? thMatch[1].toLowerCase() : null;
      var thDialogs = Array.prototype.slice.call(document.querySelectorAll('[role="dialog"]')).filter(function(el) {
        var r = el.getBoundingClientRect();
        return r.width > 160 && r.height > 160;
      });
      for (var ti = thDialogs.length - 1; ti >= 0; ti--) {
        var td = thDialogs[ti];
        if (td.querySelectorAll('a[href*="/@"]').length >= 2) {
          return { root: td, owner: thOwner, isDialog: true, key: 'thdlg:' + pathname };
        }
      }
      if (thOwner) {
        return { root: document.querySelector('main') || document.body, owner: thOwner, isDialog: false, key: 'thpage:' + pathname };
      }
      return null;
    }

    if (IS_BLUESKY) {
      var bsMatch = /^\/profile\/([^/]+)\/(followers|follows|known-followers)(\/|$)/i.exec(pathname);
      if (bsMatch || /^\/search/i.test(pathname)) {
        var bsOwner = bsMatch ? bsMatch[1].toLowerCase() : null;
        return { root: document.querySelector('main') || document.body, owner: bsOwner, isDialog: false, key: 'bspage:' + pathname + location.search };
      }
      return null;
    }

    if (IS_X) {
      var xMatch = /^\/([^/]+)\/(followers|following|verified_followers|followers_you_follow)(\/|$)/i.exec(pathname);
      if (xMatch || (/^\/search/i.test(pathname) && /f=user/i.test(location.search || ''))) {
        var xOwner = xMatch && !RESERVED.has(xMatch[1].toLowerCase()) ? xMatch[1].toLowerCase() : null;
        return { root: document.querySelector('main') || document.body, owner: xOwner, isDialog: false, key: 'xpage:' + pathname + location.search };
      }
      return null;
    }

    // 汎用 SNS（Facebook / Mastodon / Misskey / mixi2 / Reddit / note 等）
    var genDialogs = Array.prototype.slice.call(document.querySelectorAll('[role="dialog"]')).filter(function(el) {
      var r = el.getBoundingClientRect();
      return r.width > 160 && r.height > 160 && el.querySelectorAll('[data-omni-ff-row]').length >= 2;
    });
    if (genDialogs.length > 0) {
      return { root: genDialogs[genDialogs.length - 1], owner: null, isDialog: true, key: 'gendlg:' + pathname };
    }
    if (/(followers|following|follows|friends|members|people|users|search)/i.test(pathname + location.search)) {
      var mainEl = document.querySelector('main') || document.body;
      if (mainEl && mainEl.querySelectorAll('[data-omni-ff-row], ' + userLinkSelector()).length >= 2) {
        return { root: mainEl, owner: null, isDialog: false, key: 'genpage:' + pathname + location.search };
      }
    }
    return null;
  }

  function isSubtitleLink(a) {
    if (a.querySelector('img, canvas, svg')) return false;
    var span = a.closest('span');
    if (!span || span.querySelector('div')) return false;
    var sr = span.getBoundingClientRect();
    if (sr.height > 32) return false;
    var txt = (span.textContent || '').replace(/\s+/g, ' ').trim();
    return txt.length <= 90 && /^(Followed by\s+|.+がフォロー中)/i.test(txt);
  }

  function isPrimaryUserLink(a, otherLower) {
    if (isSubtitleLink(a)) return false;
    if (IS_TIKTOK || IS_THREADS || IS_BLUESKY) return true;
    if (a.querySelector('img, canvas, svg')) return true;
    var t = (a.textContent || '').trim().toLowerCase().replace(/^@/, '');
    return t === otherLower || t.indexOf(otherLower + '\n') === 0 || t.indexOf(otherLower + ' ') === 0;
  }

  function isScrollableBox(el) {
    if (!el || el === document.body || el === document.documentElement) return true;
    try {
      var oy = getComputedStyle(el).overflowY;
      return oy === 'auto' || oy === 'scroll' || oy === 'overlay';
    } catch (_) {
      return false;
    }
  }

  function clearRowAttrs(el) {
    el.removeAttribute('data-omni-jev-row');
    el.removeAttribute('data-omni-jev-match');
    el.removeAttribute('data-omni-jev-pending');
    el.removeAttribute('data-omni-jev-tail-probe');
  }

  function reconcileMarkedRows(ctx) {
    var sel = userLinkSelector();
    var markedList = ctx.root.querySelectorAll('[data-omni-jev-row]');
    for (var i = 0; i < markedList.length; i++) {
      var el = markedList[i];
      var prevUser = el.getAttribute('data-omni-jev-row') || '';
      var ffAttr = (el.getAttribute('data-omni-ff-row') || '').toLowerCase();
      if (ffAttr && ffAttr === prevUser) continue;
      var rowLinks = el.querySelectorAll(sel);
      var usersInRow = new Set();
      for (var j = 0; j < rowLinks.length; j++) {
        var a = rowLinks[j];
        if (isSubtitleLink(a)) continue;
        var u = parseUsernameHref(a.getAttribute('href'));
        if (!u) continue;
        var ul = u.toLowerCase();
        if (ctx.owner && ul === ctx.owner) continue;
        if (isPrimaryUserLink(a, ul)) usersInRow.add(ul);
      }
      if (usersInRow.size !== 1 || !usersInRow.has(prevUser)) {
        clearRowAttrs(el);
      }
    }
  }

  function findRowElement(links, uLower, ctx) {
    for (var i = 0; i < links.length; i++) {
      var marked = links[i].closest('[data-omni-jev-row]');
      if (marked && ctx.root.contains(marked) && marked.getAttribute('data-omni-jev-row') === uLower) {
        return marked;
      }
    }
    if (IS_X) {
      for (var xi = 0; xi < links.length; xi++) {
        var cell = links[xi].closest('[data-testid="UserCell"]');
        if (cell && ctx.root.contains(cell)) {
          cell.setAttribute('data-omni-jev-row', uLower);
          return cell;
        }
      }
    }
    // すでに OmniSNS PROFILE_STATS_JS が識別済みの行があれば最優先で使う
    for (var fi = 0; fi < links.length; fi++) {
      var ffRow = links[fi].closest('[data-omni-ff-row]');
      if (ffRow && ctx.root.contains(ffRow) && (ffRow.getAttribute('data-omni-ff-row') || '').toLowerCase() === uLower) {
        ffRow.setAttribute('data-omni-jev-row', uLower);
        return ffRow;
      }
    }

    var anchor = links.find(function(a) { return !a.querySelector('img') && (a.textContent || '').toLowerCase().indexOf(uLower) >= 0; }) ||
      links.find(function(a) { return (a.textContent || '').toLowerCase().indexOf(uLower) >= 0; }) ||
      links[0];
    if (!anchor) return null;
    if (!ctx.isDialog && anchor.closest('header, nav')) return null;

    var anchorRect = anchor.getBoundingClientRect();
    var anchorCenterY = anchorRect.top + anchorRect.height / 2;
    var sel = userLinkSelector();

    var cur = anchor;
    var depth = 0;
    while (cur.parentElement && cur.parentElement !== ctx.root && depth < 10) {
      var parent = cur.parentElement;
      if (!ctx.isDialog && (parent.tagName === 'HEADER' || parent.tagName === 'NAV' || parent.tagName === 'MAIN')) break;
      if (parent.tagName === 'UL' || parent.tagName === 'OL') break;
      if (isScrollableBox(parent)) break;
      if (parent.querySelector('input, h1, h2, [role="heading"], [role="tablist"]')) break;

      var curH = cur.getBoundingClientRect().height;
      var parH = parent.getBoundingClientRect().height;
      if (curH >= 40 && parH > Math.max(260, curH * 1.85)) break;

      var hasOtherUser = false;
      if (parent.querySelector('[data-omni-jev-row]:not([data-omni-jev-row="' + uLower.replace(/"/g, '') + '"])')) {
        hasOtherUser = true;
      } else {
        var pLinks = parent.querySelectorAll(sel);
        for (var pi = 0; pi < pLinks.length; pi++) {
          var pa = pLinks[pi];
          if (isSubtitleLink(pa)) continue;
          var ou = parseUsernameHref(pa.getAttribute('href'));
          if (!ou) continue;
          var oLower = ou.toLowerCase();
          if (ctx.owner && oLower === ctx.owner) continue;
          if (oLower === uLower) continue;
          if (isPrimaryUserLink(pa, oLower)) {
            var pr = pa.getBoundingClientRect();
            if (pr.height === 0 || anchorRect.height === 0 || Math.abs((pr.top + pr.height / 2) - anchorCenterY) >= 30) {
              hasOtherUser = true;
              break;
            }
          }
        }
      }
      if (hasOtherUser) break;
      cur = parent;
      depth++;
    }

    var r = cur.getBoundingClientRect();
    if (r.height > 0 && (r.height < 26 || r.height > 360)) return null;
    cur.setAttribute('data-omni-jev-row', uLower);
    return cur;
  }

  function extractDisplayNameAndBio(row, uLower) {
    var apiEntry = apiUsers.get(uLower);
    var name = (IS_TIKTOK && apiEntry && apiEntry.n) ? apiEntry.n : '';
    var bio = (apiEntry && apiEntry.bio) ? apiEntry.bio : '';
    var texts = [];
    var nodes = row.querySelectorAll('span, p, div');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.closest('button, [role="button"], .omni-ff-wrap, .omni-ff-badge')) continue;
      if (el.querySelector('span, p, div, button, a, ul')) continue;
      var t = (el.textContent || '').replace(/\s+/g, ' ').trim();
      if (!t || t.length > 160) continue;
      var tl = t.toLowerCase();
      if (tl === uLower || tl === '@' + uLower) continue;
      if (IGNORE_TEXT.test(t) || IGNORE_SUB.test(t)) continue;
      if (texts.indexOf(t) < 0) texts.push(t);
    }
    if (!name && texts.length > 0 && texts[0].length <= 60) {
      name = texts[0];
    }
    if (!bio && texts.length >= 2) {
      var extra = texts.slice(1).join(' ').trim();
      if (extra.length > 140) extra = extra.slice(0, 140);
      bio = extra;
    }
    if (!name && apiEntry && apiEntry.n) name = apiEntry.n;
    return { n: name, bio: bio };
  }

  function findAvatarImg(row, uLower) {
    var imgs = row.querySelectorAll('img');
    var fallback = null;
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      var src = img.currentSrc || img.getAttribute('src') || '';
      if (!src || src.indexOf('data:image/svg') === 0) continue;
      var w = img.naturalWidth || img.width || img.clientWidth || 0;
      var h = img.naturalHeight || img.height || img.clientHeight || 0;
      if (w > 0 && w < 22 && h > 0 && h < 22) continue;
      var alt = (img.getAttribute('alt') || '').toLowerCase();
      if (alt.indexOf('プロフィール') >= 0 || alt.indexOf('profile') >= 0 || alt.indexOf('avatar') >= 0 || alt.indexOf(uLower) >= 0) {
        return img;
      }
      if (!fallback) fallback = img;
    }
    return fallback;
  }

  function extractAvatar(row, uLower) {
    var apiEntry = apiUsers.get(uLower);
    var apiImgUrl = apiEntry ? apiEntry.img : '';
    var img = findAvatarImg(row, uLower);
    if (!img) return { url: apiImgUrl, b64: '', fmt: '' };
    var url = img.currentSrc || img.getAttribute('src') || apiImgUrl || '';
    if (!img.complete && !hookedImages.has(img)) {
      hookedImages.add(img);
      img.addEventListener('load', function() { scheduleScan(60); }, { once: true });
    }
    if (img.complete && img.naturalWidth >= 22 && img.naturalHeight >= 22) {
      try {
        if (!avatarCanvas) {
          avatarCanvas = document.createElement('canvas');
          avatarCanvas.width = AVATAR_SIZE;
          avatarCanvas.height = AVATAR_SIZE;
          avatarCtx = avatarCanvas.getContext('2d', { willReadFrequently: false });
        }
        if (avatarCtx) {
          avatarCtx.fillStyle = '#ffffff';
          avatarCtx.fillRect(0, 0, AVATAR_SIZE, AVATAR_SIZE);
          var sw = img.naturalWidth;
          var sh = img.naturalHeight;
          var scale = Math.max(AVATAR_SIZE / sw, AVATAR_SIZE / sh);
          var dw = sw * scale;
          var dh = sh * scale;
          var dx = (AVATAR_SIZE - dw) / 2;
          var dy = (AVATAR_SIZE - dh) / 2;
          avatarCtx.drawImage(img, dx, dy, dw, dh);
          var dataUrl = avatarCanvas.toDataURL('image/jpeg', 0.82);
          var comma = dataUrl.indexOf(',');
          if (comma > 0) {
            return { url: url, b64: dataUrl.slice(comma + 1), fmt: 'jpg' };
          }
        }
      } catch (_) {
        // CORS 制約時は url をホスト側へ渡して直接ダウンロード・320x320 化する
      }
    }
    return { url: url, b64: '', fmt: '' };
  }

  function applyRowJudgment(row, matched) {
    row.removeAttribute('data-omni-jev-pending');
    if (matched) {
      row.setAttribute('data-omni-jev-match', '1');
      row.removeAttribute('data-omni-jev-tail-probe');
    } else {
      row.setAttribute('data-omni-jev-match', '0');
    }
  }

  function findScrollContainer(ctx) {
    var sel = userLinkSelector();
    var candidates = [ctx.root].concat(Array.prototype.slice.call(ctx.root.querySelectorAll('div, ul')));
    var best = null;
    var bestScore = 0;
    for (var i = 0; i < candidates.length; i++) {
      var el = candidates[i];
      if (el === document.body || el === document.documentElement) continue;
      if (!isScrollableBox(el)) continue;
      var ch = el.clientHeight || 0;
      if (ch < 100) continue;
      var hasRow = !!el.querySelector('[data-omni-jev-row], ' + sel);
      var score = ch + (hasRow ? 10000 : 0);
      if (score > bestScore) {
        bestScore = score;
        best = el;
      }
    }
    if (best) return best;
    return ctx.isDialog ? ctx.root : (document.scrollingElement || document.documentElement);
  }

  function computeCounts(ctx) {
    if (!enabled || !ctx || !ctx.root) return { matched: 0, hidden: 0, domMatched: 0 };
    var domMatched = ctx.root.querySelectorAll('[data-omni-jev-match="1"]').length;
    var domHidden = ctx.root.querySelectorAll('[data-omni-jev-match="0"]').length;
    var seenMatched = 0;
    var seenHidden = 0;
    seenInContext.forEach(function(key) {
      var j = judged.get(key);
      if (!j) return;
      if (j.matched) seenMatched++;
      else seenHidden++;
    });
    return {
      matched: Math.max(domMatched, seenMatched),
      hidden: Math.max(domHidden, seenHidden),
      domMatched: domMatched
    };
  }

  function reportState(active, matched, hidden, fetching) {
    var key = active + ':' + matched + ':' + hidden + ':' + (fetching ? 1 : 0);
    if (key === lastReportedKey) return;
    lastReportedKey = key;
    sendToHost('omnisns:jev-state', {
      active: !!active,
      matched: matched | 0,
      hidden: hidden | 0,
      autoFetching: !!fetching
    });
  }

  function triggerPaginationPulse(ctx, scrollEl, matchedRows, allRows) {
    pulseInProgress = true;
    autoFetching = true;
    lastPulseAt = Date.now();
    var beforeSeen = seenInContext.size;
    var beforeSeq = apiBatchSeq;
    var counts = computeCounts(ctx);
    reportState(true, counts.matched, counts.hidden, true);

    var anchorRow = matchedRows.length > 0 ? matchedRows[matchedRows.length - 1] : allRows[0];
    var spacer = document.getElementById('omni-jev-spacer');
    if (!spacer) {
      spacer = document.createElement('div');
      spacer.id = 'omni-jev-spacer';
      spacer.setAttribute('aria-hidden', 'true');
    }
    var pushPx = Math.max(1600, (window.innerHeight || 800) * 2);
    spacer.style.cssText = 'display:block;width:1px;height:' + pushPx + 'px;flex-shrink:0;pointer-events:none;opacity:0;';

    try {
      if (anchorRow && anchorRow.parentNode) {
        anchorRow.after(spacer);
      } else {
        ctx.root.appendChild(spacer);
      }
    } catch (_) {}

    var raf = window.requestAnimationFrame || function(fn) { setTimeout(fn, 16); };
    raf(function() {
      raf(function() {
        try {
          spacer.style.height = '0px';
          var tailRows = allRows.slice(-3);
          for (var ti = 0; ti < tailRows.length; ti++) {
            if (tailRows[ti].getAttribute('data-omni-jev-match') === '0') {
              tailRows[ti].setAttribute('data-omni-jev-tail-probe', '1');
            }
          }

          var isDocScroll = scrollEl === document.scrollingElement || scrollEl === document.documentElement || scrollEl === document.body;
          if (!isDocScroll && scrollEl && matchedRows.length < MIN_VISIBLE_MATCHES) {
            var maxTop = Math.max(0, scrollEl.scrollHeight - scrollEl.clientHeight);
            if (maxTop > 0 && maxTop <= 240) {
              scrollEl.scrollTop = maxTop;
            }
          }

          if (scrollEl && scrollEl !== window) {
            scrollEl.dispatchEvent(new Event('scroll', { bubbles: true }));
          }
          ctx.root.dispatchEvent(new Event('scroll', { bubbles: true }));
          window.dispatchEvent(new Event('scroll'));

          setTimeout(function() {
            try {
              if (spacer.parentNode) spacer.parentNode.removeChild(spacer);
              for (var k = 0; k < tailRows.length; k++) tailRows[k].removeAttribute('data-omni-jev-tail-probe');
            } catch (_) {}
          }, 150);
        } catch (_) {}

        setTimeout(function() {
          pulseInProgress = false;
          var gotNewData = seenInContext.size > beforeSeen || apiBatchSeq > beforeSeq;
          if (gotNewData) {
            emptyPulseCount = 0;
          } else {
            emptyPulseCount++;
            if (emptyPulseCount >= MAX_EMPTY_PULSES) {
              reachedEnd = true;
              autoFetching = false;
            }
          }
          scheduleScan(20);
        }, 760);
      });
    });
  }

  function maybeAutoFetchNextPage(ctx) {
    if (!enabled || !ctx || !ctx.root) {
      autoFetching = false;
      return;
    }
    if (pulseInProgress) return;
    if (pendingQueue.size > 0 || inflight.size > 0) return;
    if (reachedEnd || apiHasMore === false) {
      autoFetching = false;
      return;
    }

    var allRows = Array.prototype.slice.call(ctx.root.querySelectorAll('[data-omni-jev-row]'));
    if (allRows.length === 0 && seenInContext.size === 0) return;

    var matchedRows = allRows.filter(function(r) { return r.getAttribute('data-omni-jev-match') === '1'; });
    var scrollEl = findScrollContainer(ctx);
    var isDocScroll = scrollEl === document.scrollingElement || scrollEl === document.documentElement || scrollEl === document.body;
    var viewportBottom = isDocScroll
      ? (window.innerHeight || document.documentElement.clientHeight || 700)
      : scrollEl.getBoundingClientRect().bottom;

    var needsMore = false;
    if (matchedRows.length === 0) {
      needsMore = true;
    } else {
      var lastRect = matchedRows[matchedRows.length - 1].getBoundingClientRect();
      if (viewportBottom - lastRect.bottom > -180) {
        needsMore = true;
      } else if (matchedRows.length < MIN_VISIBLE_MATCHES) {
        var viewH = isDocScroll ? viewportBottom : (scrollEl.clientHeight || 0);
        var scrollH = isDocScroll
          ? Math.max(scrollEl.scrollHeight || 0, document.body ? document.body.scrollHeight : 0)
          : (scrollEl.scrollHeight || 0);
        if (scrollH <= viewH + 100) needsMore = true;
      }
    }
"""

        private val JEV_FILTER_JS_PART_2: String = """

    if (!needsMore) {
      autoFetching = false;
      return;
    }

    var elapsed = Date.now() - lastPulseAt;
    if (elapsed < PULSE_COOLDOWN_MS) {
      autoFetching = true;
      if (!cooldownTimer) {
        cooldownTimer = setTimeout(function() {
          cooldownTimer = null;
          scheduleScan(0);
        }, PULSE_COOLDOWN_MS - elapsed + 20);
      }
      return;
    }

    triggerPaginationPulse(ctx, scrollEl, matchedRows, allRows);
  }

  function requestCheckBatch(candidates) {
    return new Promise(function(resolve) {
      var id = 'jev_' + (++reqSeq) + '_' + Date.now();
      var done = false;
      var tmo = setTimeout(function() {
        if (done) return;
        done = true;
        pendingRequests.delete(id);
        resolve(null);
      }, 35000);
      pendingRequests.set(id, function(res) {
        if (done) return;
        done = true;
        clearTimeout(tmo);
        pendingRequests.delete(id);
        resolve(res);
      });
      if (!sendToHost('omnisns:jev-check', { reqId: id, candidates: candidates })) {
        done = true;
        clearTimeout(tmo);
        pendingRequests.delete(id);
        resolve(null);
      }
    });
  }

  window.__omniJevResolve = function(reqId, resultMap) {
    var fn = pendingRequests.get(reqId);
    if (fn) {
      fn(resultMap && typeof resultMap === 'object' ? resultMap : null);
    }
  };

  async function pumpQueue() {
    if (pumping || !enabled || pendingQueue.size === 0 || !hasHostBridge()) return;
    pumping = true;
    try {
      while (enabled && pendingQueue.size > 0) {
        var batch = [];
        pendingQueue.forEach(function(item) {
          if (batch.length < 16) batch.push(item);
        });
        for (var i = 0; i < batch.length; i++) {
          pendingQueue.delete(batch[i].key);
          inflight.add(batch[i].key);
        }

        var payload = batch.map(function(x) {
          return { u: x.u, n: x.n, bio: x.bio, img: x.img, b64: x.b64, fmt: x.fmt, p: PLATFORM };
        });
        var res = await requestCheckBatch(payload);

        var retryItems = [];
        for (var j = 0; j < batch.length; j++) {
          var it = batch[j];
          inflight.delete(it.key);
          if (res && typeof res === 'object' && Object.prototype.hasOwnProperty.call(res, it.u)) {
            judged.set(it.key, { matched: !!res[it.u], hasImg: !!(it.img || it.b64) });
            failCounts.delete(it.key);
          } else if (enabled) {
            var fails = (failCounts.get(it.key) || 0) + 1;
            failCounts.set(it.key, fails);
            if (fails < 3) retryItems.push(it);
          }
        }

        syncDom();

        if (retryItems.length > 0 && enabled) {
          await new Promise(function(r) { setTimeout(r, 500); });
          for (var rIdx = 0; rIdx < retryItems.length; rIdx++) {
            var ri = retryItems[rIdx];
            if (!judged.has(ri.key) && !pendingQueue.has(ri.key)) {
              pendingQueue.set(ri.key, ri);
            }
          }
        }
      }
    } finally {
      pumping = false;
      syncDom();
    }
  }

  function syncDom() {
    applyRootClass();
    if (!enabled) {
      reportState(false, 0, 0, false);
      return;
    }
    var ctx = findFollowListContext();
    if (!ctx || !ctx.root) {
      if (activeContextKey !== '') resetPaginationState('');
      reportState(false, 0, 0, false);
      return;
    }
    if (ctx.key !== activeContextKey) {
      resetPaginationState(ctx.key);
    }

    reconcileMarkedRows(ctx);

    var byUser = new Map();
    var anchors = ctx.root.querySelectorAll(userLinkSelector());
    for (var i = 0; i < anchors.length; i++) {
      var a = anchors[i];
      if (isSubtitleLink(a)) continue;
      var u = parseUsernameHref(a.getAttribute('href'));
      if (!u) continue;
      var uLower = u.toLowerCase();
      if (ctx.owner && uLower === ctx.owner) continue;
      var entry = byUser.get(uLower);
      if (!entry) {
        entry = { username: u, links: [] };
        byUser.set(uLower, entry);
      }
      entry.links.push(a);
    }

    // 汎用 SNS ですでに data-omni-ff-row が付いている行も補完
    var ffRows = ctx.root.querySelectorAll('[data-omni-ff-row]');
    for (var f = 0; f < ffRows.length; f++) {
      var fr = ffRows[f];
      var fh = (fr.getAttribute('data-omni-ff-row') || '').trim();
      if (!fh) continue;
      var fhLower = fh.toLowerCase();
      if (ctx.owner && fhLower === ctx.owner) continue;
      if (!byUser.has(fhLower)) {
        var rowLink = fr.querySelector('a[href]');
        if (rowLink) {
          byUser.set(fhLower, { username: fh, links: [rowLink] });
        }
      }
    }

    byUser.forEach(function(ent, uLowerKey) {
      var row = findRowElement(ent.links, uLowerKey, ctx);
      if (!row) return;
      seenInContext.add(uLowerKey);
      var cached = judged.get(uLowerKey);
      if (cached !== undefined) {
        applyRowJudgment(row, cached.matched);
        if (!cached.hasImg) {
          var av2 = extractAvatar(row, uLowerKey);
          if (av2.url || av2.b64) {
            var meta2 = extractDisplayNameAndBio(row, uLowerKey);
            enqueueCandidate(ent.username, uLowerKey, meta2.n, meta2.bio, av2.url, av2.b64, av2.fmt);
          }
        }
      } else {
        var meta = extractDisplayNameAndBio(row, uLowerKey);
        var av = extractAvatar(row, uLowerKey);
        row.setAttribute('data-omni-jev-pending', '1');
        enqueueCandidate(ent.username, uLowerKey, meta.n, meta.bio, av.url, av.b64, av.fmt);
      }
    });

    if (pendingQueue.size > 0) {
      pumpQueue();
    } else {
      maybeAutoFetchNextPage(ctx);
    }

    var counts = computeCounts(ctx);
    reportState(true, counts.matched, counts.hidden, autoFetching);
  }

  function scheduleScan(delay) {
    if (!enabled) return;
    if (timer) clearTimeout(timer);
    timer = setTimeout(function() {
      timer = null;
      syncDom();
    }, delay);
  }

  function startObserver() {
    if (observer || !document.documentElement) return;
    observer = new MutationObserver(function() {
      if (enabled) scheduleScan(24);
    });
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['href', 'src', 'aria-selected']
    });
  }

  function stopObserver() {
    if (observer) {
      observer.disconnect();
      observer = null;
    }
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
  }

  window.__omniJevApplyConfig = function(cfg) {
    if (!cfg || typeof cfg !== 'object') return;
    var prevEnabled = enabled;
    var nextEnabled = !!cfg.enabled;
    var nextCat = typeof cfg.category === 'string' && cfg.category.trim() ? cfg.category.trim() : currentCategory;
    var resetJudged = !!cfg.resetJudged || (nextCat !== currentCategory);

    enabled = nextEnabled;
    currentCategory = nextCat;
    failCounts.clear();

    if (resetJudged) {
      judged.clear();
      pendingQueue.clear();
      resetPaginationState('');
      document.querySelectorAll('[data-omni-jev-match],[data-omni-jev-pending],[data-omni-jev-tail-probe]')
        .forEach(function(el) {
          el.removeAttribute('data-omni-jev-match');
          el.removeAttribute('data-omni-jev-pending');
          el.removeAttribute('data-omni-jev-tail-probe');
        });
    } else if (!enabled) {
      pendingQueue.clear();
      autoFetching = false;
      document.querySelectorAll('[data-omni-jev-pending],[data-omni-jev-tail-probe]')
        .forEach(function(el) {
          el.removeAttribute('data-omni-jev-pending');
          el.removeAttribute('data-omni-jev-tail-probe');
        });
    } else if (!prevEnabled && enabled) {
      reachedEnd = false;
      emptyPulseCount = 0;
    }

    applyRootClass();
    if (enabled) {
      startObserver();
      scheduleScan(0);
    } else {
      stopObserver();
      reportState(false, 0, 0, false);
    }
  };

  hookNetwork();
  window.addEventListener('popstate', function() { if (enabled) scheduleScan(30); });
  window.addEventListener('scroll', function(ev) {
    if (!enabled) return;
    var now = Date.now();
    if (ev && ev.isTrusted && reachedEnd && apiHasMore !== false &&
        now - lastPulseAt > 1500 && now - lastUserScrollAt > 800) {
      reachedEnd = false;
      emptyPulseCount = Math.max(0, MAX_EMPTY_PULSES - 2);
    }
    if (!ev || ev.isTrusted) lastUserScrollAt = now;
    scheduleScan(24);
  }, { capture: true, passive: true });

  function requestInitialConfig() {
    sendToHost('omnisns:jev-get-config', {});
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', requestInitialConfig, { once: true });
  } else {
    requestInitialConfig();
  }
})();
"""

        val JEV_FILTER_JS: String = listOf(
            JEV_FILTER_JS_PART_1,
            JEV_FILTER_JS_PART_2,
        ).joinToString("\n")
    }

    private val channel = MethodChannel(messenger, MANAGER_CHANNEL)
    private val activeViews = ConcurrentHashMap<Int, OmniWebViewPlatformView>()
    private val pendingDeleteProfiles = ConcurrentHashMap.newKeySet<String>()
    private var filePathCallback: ValueCallback<Array<Uri>>? = null
    private var pendingPermissionCallback: ((Map<String, Boolean>) -> Unit)? = null
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

    internal fun requestRuntimePermissions(
        permissions: Array<String>,
        callback: (Map<String, Boolean>) -> Unit,
    ) {
        if (permissions.isEmpty()) {
            callback(emptyMap())
            return
        }
        val already = mutableMapOf<String, Boolean>()
        val missing = mutableListOf<String>()
        for (perm in permissions.distinct()) {
            val granted = ContextCompat.checkSelfPermission(activity, perm) ==
                PackageManager.PERMISSION_GRANTED
            already[perm] = granted
            if (!granted) {
                missing.add(perm)
            }
        }
        if (missing.isEmpty() || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            callback(already)
            return
        }
        if (activity.isFinishing || activity.isDestroyed) {
            callback(already)
            return
        }
        pendingPermissionCallback?.invoke(emptyMap())
        pendingPermissionCallback = { grantedMap ->
            val merged = LinkedHashMap<String, Boolean>(already)
            merged.putAll(grantedMap)
            callback(merged)
        }
        try {
            activity.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST_CODE)
        } catch (_: Throwable) {
            pendingPermissionCallback = null
            callback(already)
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val cb = pendingPermissionCallback
        pendingPermissionCallback = null
        if (cb == null) return true
        val results = LinkedHashMap<String, Boolean>()
        for (i in permissions.indices) {
            val granted = i < grantResults.size &&
                grantResults[i] == PackageManager.PERMISSION_GRANTED
            results[permissions[i]] = granted
        }
        cb(results)
        return true
    }

    private fun getOrCreateSecretKey(): SecretKey? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        return try {
            val ks = KeyStore.getInstance("AndroidKeyStore")
            ks.load(null)
            val existing = ks.getKey(KEYSTORE_ALIAS, null) as? SecretKey
            if (existing != null) {
                return existing
            }
            val keyGenerator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES,
                "AndroidKeyStore",
            )
            val spec = KeyGenParameterSpec.Builder(
                KEYSTORE_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
            keyGenerator.init(spec)
            keyGenerator.generateKey()
        } catch (e: Throwable) {
            Log.w(TAG, "AndroidKeyStore key init failed: ${e.message}")
            null
        }
    }

    private fun secureSetSecret(key: String, value: String): Boolean {
        if (key.isBlank()) return false
        val prefs = activity.getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
        if (value.isEmpty()) {
            return prefs.edit().remove(key).commit()
        }
        val secretKey = getOrCreateSecretKey() ?: return false
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secretKey)
            val iv = cipher.iv
            val cipherText = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            val combined = ByteArray(1 + iv.size + cipherText.size)
            combined[0] = iv.size.toByte()
            System.arraycopy(iv, 0, combined, 1, iv.size)
            System.arraycopy(cipherText, 0, combined, 1 + iv.size, cipherText.size)
            val encoded = Base64.encodeToString(combined, Base64.NO_WRAP)
            prefs.edit().putString(key, encoded).commit()
        } catch (e: Throwable) {
            Log.w(TAG, "secureSetSecret failed: ${e.message}")
            false
        }
    }

    private fun secureGetSecret(key: String): String? {
        if (key.isBlank()) return null
        val prefs = activity.getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
        val encoded = prefs.getString(key, null) ?: return null
        val secretKey = getOrCreateSecretKey() ?: return null
        return try {
            val combined = Base64.decode(encoded, Base64.NO_WRAP)
            if (combined.size < 14) return null
            val ivLen = combined[0].toInt() and 0xFF
            if (ivLen < 12 || ivLen > 16 || combined.size <= 1 + ivLen + 16) return null
            val iv = combined.copyOfRange(1, 1 + ivLen)
            val cipherText = combined.copyOfRange(1 + ivLen, combined.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(128, iv))
            String(cipher.doFinal(cipherText), Charsets.UTF_8)
        } catch (e: Throwable) {
            Log.w(TAG, "secureGetSecret failed: ${e.message}")
            null
        }
    }

    private fun secureDeleteSecret(key: String): Boolean {
        if (key.isBlank()) return false
        val prefs = activity.getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.edit().remove(key).commit()
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
        pendingPermissionCallback?.invoke(emptyMap())
        pendingPermissionCallback = null
        activeViews.values.toList().forEach { it.dispose() }
        activeViews.clear()
    }

    internal fun cancelPendingDeleteProfile(profileName: String) {
        if (profileName.isNotEmpty()) {
            pendingDeleteProfiles.remove(profileName)
        }
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
            if (isProfileInUse(profileName) || !pendingDeleteProfiles.contains(profileName)) {
                return@post
            }
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
        val completed = AtomicBoolean(false)
        fun finishOnce() {
            if (completed.compareAndSet(false, true)) {
                onDone()
            }
        }
        try {
            if (multi && profileName.isNotEmpty() && profileName != Profile.DEFAULT_PROFILE_NAME) {
                val profile = ProfileStore.getInstance().getProfile(profileName)
                if (profile != null) {
                    try {
                        profile.webStorage.deleteAllData()
                    } catch (_: Throwable) {
                    }
                    profile.cookieManager.removeAllCookies {
                        try {
                            profile.cookieManager.flush()
                        } catch (_: Throwable) {
                        }
                        finishOnce()
                    }
                } else {
                    // 未作成／削除済みプロファイルに対して Default プロファイルを誤消去しない
                    finishOnce()
                }
                return
            }
            try {
                WebStorage.getInstance().deleteAllData()
            } catch (_: Throwable) {
            }
            val cm = CookieManager.getInstance()
            cm.removeAllCookies {
                try {
                    cm.flush()
                } catch (_: Throwable) {
                }
                finishOnce()
            }
        } catch (_: Throwable) {
            finishOnce()
        }
    }

    private fun clearAllCookiesInternal(onDone: () -> Unit) {
        val completed = AtomicBoolean(false)
        fun finishOnce() {
            if (completed.compareAndSet(false, true)) {
                onDone()
            }
        }
        val cmDefault = CookieManager.getInstance()
        try {
            WebStorage.getInstance().deleteAllData()
        } catch (_: Throwable) {
        }

        if (!isMultiProfileSupported()) {
            try {
                cmDefault.removeAllCookies {
                    try {
                        cmDefault.flush()
                    } catch (_: Throwable) {
                    }
                    finishOnce()
                }
            } catch (_: Throwable) {
                finishOnce()
            }
            return
        }

        val profileNames = try {
            ProfileStore.getInstance().getAllProfileNames()
        } catch (_: Throwable) {
            emptyList()
        }

        if (profileNames.isEmpty()) {
            try {
                cmDefault.removeAllCookies {
                    try {
                        cmDefault.flush()
                    } catch (_: Throwable) {
                    }
                    finishOnce()
                }
            } catch (_: Throwable) {
                finishOnce()
            }
            return
        }

        val targets = (profileNames + Profile.DEFAULT_PROFILE_NAME).distinct()
        val remaining = AtomicInteger(targets.size)

        fun tick() {
            if (remaining.decrementAndGet() <= 0) {
                finishOnce()
            }
        }

        for (name in targets) {
            try {
                val profile = ProfileStore.getInstance().getProfile(name)
                if (profile != null) {
                    try {
                        profile.webStorage.deleteAllData()
                    } catch (_: Throwable) {
                    }
                    profile.cookieManager.removeAllCookies {
                        try {
                            profile.cookieManager.flush()
                        } catch (_: Throwable) {
                        }
                        tick()
                    }
                } else if (name == Profile.DEFAULT_PROFILE_NAME) {
                    cmDefault.removeAllCookies {
                        try {
                            cmDefault.flush()
                        } catch (_: Throwable) {
                        }
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
            "secureSetSecret" -> {
                val key = call.argument<String>("key") ?: ""
                val value = call.argument<String>("value") ?: ""
                result.success(secureSetSecret(key, value))
            }
            "secureGetSecret" -> {
                val key = call.argument<String>("key") ?: ""
                result.success(secureGetSecret(key))
            }
            "secureDeleteSecret" -> {
                val key = call.argument<String>("key") ?: ""
                result.success(secureDeleteSecret(key))
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
        private const val RELOAD_WATCHDOG_MS = 1400L
        private const val CACHE_BYPASS_RESET_MS = 10_000L
        private const val CRASH_RECOVERY_COOLDOWN_MS = 5000L
        private const val ORPHAN_POPUP_TIMEOUT_MS = 15_000L
        private const val ACTIVATION_REDRAW_KICK_MS = 120L
        private const val ACTIVATION_REDRAW_KICK_LATE_MS = 420L

        private val LINK_SHIM_HOSTS = setOf(
            "l.threads.net",
            "l.threads.com",
            "l.instagram.com",
            "l.facebook.com",
            "lm.facebook.com",
            "t.co",
            "out.reddit.com",
        )

        private val AUTH_EXACT_OR_SUBDOMAIN_HOSTS = setOf(
            "accounts.google.com",
            "appleid.apple.com",
            "access.line.me",
            "login.microsoftonline.com",
            "login.live.com",
            "auth.login.yahoo.co.jp",
            "login.yahoo.co.jp",
            "id.mixi.social",
        )

        private val AUTH_HOST_LABELS = setOf(
            "auth",
            "sso",
            "oauth",
            "login",
            "signin",
        )

        private val AUTH_PATH_SEGMENTS = setOf(
            "oauth",
            "oauth2",
            "authorize",
            "signin",
            "sign-in",
            "login",
            "log-in",
            "sso",
            "auth",
            "webauthn",
        )

        private val PLAY_STORE_HOSTS = setOf(
            "play.google.com",
            "market.android.com",
        )

        private fun isHttpOrHttpsUrl(url: String?): Boolean {
            if (url.isNullOrBlank()) return false
            val trimmed = url.trim()
            val lower = trimmed.lowercase()
            if (!lower.startsWith("http://") && !lower.startsWith("https://")) {
                return false
            }
            return try {
                val host = Uri.parse(trimmed).host
                !host.isNullOrEmpty()
            } catch (_: Throwable) {
                false
            }
        }

        private fun isAuthPopupUrl(url: String): Boolean {
            if (!isHttpOrHttpsUrl(url)) return false
            val uri = try {
                Uri.parse(url.trim())
            } catch (_: Throwable) {
                return false
            }
            val host = uri.host?.lowercase() ?: return false
            if (LINK_SHIM_HOSTS.contains(host)) {
                return false
            }
            for (authHost in AUTH_EXACT_OR_SUBDOMAIN_HOSTS) {
                if (host == authHost || host.endsWith(".$authHost")) {
                    return true
                }
            }
            val hostLabels = host.split('.')
            if (hostLabels.any { AUTH_HOST_LABELS.contains(it) }) {
                return true
            }
            val path = uri.path?.lowercase().orEmpty()
            if (host == "facebook.com" || host.endsWith(".facebook.com")) {
                if (path.startsWith("/dialog") ||
                    path.startsWith("/login") ||
                    Regex("^/v[0-9.]+/dialog(/|$)").containsMatchIn(path)
                ) {
                    return true
                }
            }
            if (path.contains("/dialog/oauth") || path.contains("/accounts/login")) {
                return true
            }
            val segments = path.split('/').filter { it.isNotEmpty() }
            return segments.any { AUTH_PATH_SEGMENTS.contains(it) }
        }

        private fun extractIntentFallbackHttpUrl(intentUrl: String): String? {
            return try {
                val intent = Intent.parseUri(intentUrl, Intent.URI_INTENT_SCHEME)
                val fallback = intent.getStringExtra("browser_fallback_url")?.trim()
                if (!isHttpOrHttpsUrl(fallback)) {
                    return null
                }
                val host = Uri.parse(fallback!!).host?.lowercase().orEmpty()
                if (PLAY_STORE_HOSTS.contains(host)) {
                    return null
                }
                fallback
            } catch (_: Throwable) {
                null
            }
        }
    }

    private val channel = MethodChannel(messenger, "com.pgdarksan.omnisns/webview_$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())
    private val container = FrameLayout(activity)
    private lateinit var webView: OmniWebView
    val appliedProfileName: String
    private val requestedProfileName: String
    private val initialUrl: String
    private var userAgent: String
    private val configuredServiceId: String
    private val customFollowHost: String?
    private val effectiveFollowOrigins: Set<String>

    private var disposed = false
    private var profileAttachFailed = false
    private var isTabActive: Boolean = false
    private var pendingCrashReload: Boolean = false
    private var pendingCrashUrl: String = ""
    private var popupDialog: Dialog? = null
    private var popupWebView: OmniWebView? = null
    private var activePopupDismiss: (() -> Unit)? = null
    private var activePermissionDialog: AlertDialog? = null
    private var activePermissionRequest: PermissionRequest? = null
    private var activeGeoDialog: AlertDialog? = null
    private var activeGeoCallback: GeolocationPermissions.Callback? = null
    private var activeGeoOrigin: String? = null
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null

    private var lastTargetUrl: String = ""
    private var lastFailedUrl: String? = null
    private var currentLoadHadMainFrameError: Boolean = false
    private var isMainFrameLoading: Boolean = false
    private var awaitingReloadStart: Boolean = false
    private var reloadSequence: Int = 0
    private var reloadObservedProgress: Boolean = false
    private var cacheBypassToken: Int = 0
    private var renderProcessCrashed: Boolean = false
    private var mainWebViewDestroyed: Boolean = false
    private var crashRecoveryGen: Int = 0
    private var lastCrashRecoveryAtMs: Long = 0L
    private var webViewPaused: Boolean = false
    private var activationKickGen: Int = 0

    private var mainAutofillToken: String = OmniWebViewManager.generateBridgeToken()
    private var mainFollowToken: String = OmniWebViewManager.generateBridgeToken()
    private var hasDocumentStartAutofill: Boolean = false
    private var hasDocumentStartFollow: Boolean = false
    private val bridgeEventTimestamps = ArrayDeque<Long>()

    init {
        val requestedProfile = (creationParams["profileName"] as? String)?.trim().orEmpty()
        requestedProfileName = requestedProfile
        initialUrl = (creationParams["initialUrl"] as? String)?.trim().orEmpty()
        if (isHttpOrHttpsUrl(initialUrl)) {
            lastTargetUrl = initialUrl
        }
        configuredServiceId = (creationParams["serviceId"] as? String)?.trim()?.lowercase().orEmpty()
        isTabActive = creationParams["isActive"] as? Boolean ?: false

        // カスタム Mastodon / Misskey インスタンスの場合は自タブの https オリジンのみ追加許可する
        var customHost: String? = null
        val followOrigins = LinkedHashSet<String>(OmniWebViewManager.FOLLOW_ALLOWED_ORIGINS)
        if ((configuredServiceId == "mastodon" || configuredServiceId == "misskey") &&
            initialUrl.isNotEmpty()
        ) {
            try {
                val parsed = Uri.parse(initialUrl)
                val host = parsed.host?.lowercase()?.trim().orEmpty()
                if (parsed.scheme.equals("https", ignoreCase = true) && host.isNotEmpty()) {
                    customHost = host
                    val portSuffix = if (parsed.port != -1 && parsed.port != 443) ":${parsed.port}" else ""
                    followOrigins.add("https://$host$portSuffix")
                }
            } catch (_: Throwable) {
            }
        }
        customFollowHost = customHost
        effectiveFollowOrigins = followOrigins

        userAgent = (creationParams["userAgent"] as? String)?.trim().orEmpty().ifEmpty {
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36"
        }

        val (createdWebView, resolvedProfile, attachFailed) = createMainWebView(requestedProfile)
        appliedProfileName = resolvedProfile
        profileAttachFailed = attachFailed
        webView = createdWebView
        container.addView(
            webView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

        channel.setMethodCallHandler(this)
        manager.registerView(viewId, this)

        if (profileAttachFailed) {
            emitProfileIsolationError()
        } else {
            // Dart 側の attach → loadUrl の往復を待たず、生成直後に読み込みを開始して初回表示を高速化する
            val autoLoad = creationParams["autoLoad"] as? Boolean ?: false
            val autoLoadUrl = (creationParams["autoLoadUrl"] as? String)?.trim().orEmpty()
            if (autoLoad) {
                val target = if (isHttpOrHttpsUrl(autoLoadUrl)) autoLoadUrl else initialUrl
                if (target.isNotEmpty()) {
                    loadUrlInternal(target)
                }
            }
        }
    }

    private fun detectEffectivePlatformServiceFromHost(rawHost: String?): String? {
        val known = OmniWebViewManager.detectPlatformServiceFromHost(rawHost)
        if (known != null) return known
        val h = rawHost?.trim()?.lowercase().orEmpty()
        if (customFollowHost != null && h == customFollowHost && configuredServiceId.isNotEmpty()) {
            return configuredServiceId
        }
        return null
    }

    private fun detectEffectivePlatformServiceFromHttpsUrl(rawUrl: String?): String? {
        if (rawUrl.isNullOrBlank()) return null
        return try {
            val uri = Uri.parse(rawUrl.trim())
            if (!uri.scheme.equals("https", ignoreCase = true)) return null
            detectEffectivePlatformServiceFromHost(uri.host)
        } catch (_: Throwable) {
            null
        }
    }

    private fun dismissPendingPermissionDialogs() {
        val permDlg = activePermissionDialog
        val permReq = activePermissionRequest
        activePermissionDialog = null
        activePermissionRequest = null
        if (permDlg != null) {
            try {
                if (permDlg.isShowing) permDlg.dismiss()
            } catch (_: Throwable) {
            }
        }
        if (permReq != null) {
            try {
                permReq.deny()
            } catch (_: Throwable) {
            }
        }
        val geoDlg = activeGeoDialog
        val geoCb = activeGeoCallback
        val geoOrigin = activeGeoOrigin
        activeGeoDialog = null
        activeGeoCallback = null
        activeGeoOrigin = null
        if (geoDlg != null) {
            try {
                if (geoDlg.isShowing) geoDlg.dismiss()
            } catch (_: Throwable) {
            }
        }
        if (geoCb != null && geoOrigin != null) {
            try {
                geoCb.invoke(geoOrigin, false, false)
            } catch (_: Throwable) {
            }
        }
    }

    private fun setTabActive(active: Boolean) {
        if (disposed) return
        isTabActive = active
        if (!active) {
            dismissPendingPermissionDialogs()
            activationKickGen += 1
            applyBackgroundThrottle()
            return
        }
        // バックグラウンド中にレンダラープロセスが終了していた場合、アクティブ復帰時に自動再構築＆再読み込みする
        if (pendingCrashReload && !profileAttachFailed && !activity.isFinishing && !activity.isDestroyed) {
            pendingCrashReload = false
            val targetUrl = pendingCrashUrl.ifEmpty { resolveReloadTargetUrl(null) }
            pendingCrashUrl = ""
            if (renderProcessCrashed) {
                replaceMainWebView()
            }
            if (!profileAttachFailed && targetUrl.isNotEmpty()) {
                loadUrlInternal(targetUrl, bypassCache = false)
            }
        }
        applyBackgroundThrottle()
        ensureLoadedOnActivation()
        scheduleActivationRedrawKicks()
    }

    /**
     * 非アクティブタブは初回読み込み完了後に WebView.onPause() でページを hidden 扱いにし、
     * rAF・動画再生・タイマー頻度を抑えてアクティブタブの描画/操作を軽くする。
     * 読み込み中のタブは一時停止せず裏で読み込みを完了させ、切替時に即表示できるようにする。
     */
    private fun applyBackgroundThrottle() {
        if (disposed || mainWebViewDestroyed || renderProcessCrashed) return
        val shouldPause = !isTabActive && !isMainFrameLoading && customView == null
        if (shouldPause == webViewPaused) return
        webViewPaused = shouldPause
        try {
            if (shouldPause) webView.onPause() else webView.onResume()
        } catch (_: Throwable) {
        }
    }

    /**
     * タブ切替時、まだ一度もページがコミットされていない（読み込み未開始・取りこぼし）場合は自動で読み込む。
     * これにより新規タブへ切り替えた際に手動で再読み込みボタンを押す必要がなくなる。
     */
    private fun ensureLoadedOnActivation() {
        if (disposed || profileAttachFailed || renderProcessCrashed || mainWebViewDestroyed) return
        if (isMainFrameLoading || currentLoadHadMainFrameError) return
        val current = try {
            webView.url?.trim().orEmpty()
        } catch (_: Throwable) {
            ""
        }
        if (isHttpOrHttpsUrl(current)) return
        val target = resolveReloadTargetUrl(null)
        if (target.isNotEmpty()) {
            loadUrlInternal(target)
        }
    }

    /**
     * Flutter TLHC では非表示中に描画されたタブのテクスチャが切替直後に更新されず白紙のままになることがあるため、
     * 切替直後〜合成完了後にかけて数回再描画を要求する。
     */
    private fun scheduleActivationRedrawKicks() {
        val gen = ++activationKickGen
        val kick = Runnable {
            if (disposed || !isTabActive || gen != activationKickGen || mainWebViewDestroyed) return@Runnable
            try {
                webView.invalidate()
                container.invalidate()
            } catch (_: Throwable) {
            }
        }
        mainHandler.post(kick)
        mainHandler.postDelayed(kick, ACTIVATION_REDRAW_KICK_MS)
        mainHandler.postDelayed(kick, ACTIVATION_REDRAW_KICK_LATE_MS)
    }

    private fun emitProfileIsolationError() {
        currentLoadHadMainFrameError = true
        isMainFrameLoading = false
        invokeDart(
            "onWebResourceError",
            mapOf(
                "description" to "アカウント分離プロファイルの初期化に失敗したため読み込みを中止しました。アプリを再起動してください。",
                "errorCode" to -1001,
            ),
        )
    }

    private fun allowBridgeEvent(): Boolean {
        val now = System.currentTimeMillis()
        synchronized(bridgeEventTimestamps) {
            while (bridgeEventTimestamps.isNotEmpty() && now - bridgeEventTimestamps.first() > 1000L) {
                bridgeEventTimestamps.removeFirst()
            }
            if (bridgeEventTimestamps.size >= 25) return false
            bridgeEventTimestamps.addLast(now)
            return true
        }
    }

    private fun createMainWebView(requestedProfile: String): Triple<OmniWebView, String, Boolean> {
        // 1. WebView を生成（Activity コンテキストを使用）
        val target = OmniWebView(activity)

        // 2. 【最重要】getSettings() / loadUrl() より前に独立プロファイルを割り当てる
        var resolvedProfile = Profile.DEFAULT_PROFILE_NAME
        var attachFailed = false
        val needsIsolatedProfile = manager.isMultiProfileSupported() &&
            requestedProfile.isNotEmpty() &&
            requestedProfile != Profile.DEFAULT_PROFILE_NAME
        if (needsIsolatedProfile) {
            manager.cancelPendingDeleteProfile(requestedProfile)
            try {
                ProfileStore.getInstance().getOrCreateProfile(requestedProfile)
                WebViewCompat.setProfile(target, requestedProfile)
                resolvedProfile = requestedProfile
            } catch (e: Throwable) {
                // 独立プロファイル要求に失敗した場合は Default への無断フォールバックを禁止（フェイルクローズ）
                Log.e(TAG, "WebViewCompat.setProfile failed for $requestedProfile; failing closed: ${e.message}")
                resolvedProfile = requestedProfile
                attachFailed = true
            }
        }

        // 3. プロファイル専用の CookieManager を有効化（分離失敗時は Default を触らない）
        if (!attachFailed) {
            configureCookies(target, resolvedProfile)
        }

        // 4. WebSettings / Autofill ガード / フォロー計測 / Client 設定
        configureWebViewSettings(target, userAgent, supportMultipleWindows = true)
        mainAutofillToken = OmniWebViewManager.generateBridgeToken()
        mainFollowToken = OmniWebViewManager.generateBridgeToken()
        hasDocumentStartAutofill = attachAutofillGuard(target, mainAutofillToken)
        hasDocumentStartFollow = attachFollowTracker(target, mainFollowToken)
        target.applyAutofillAllowed(false)

        target.webViewClient = createMainWebViewClient()
        target.webChromeClient = createMainWebChromeClient()

        return Triple(target, resolvedProfile, attachFailed)
    }

    private fun replaceMainWebView() {
        crashRecoveryGen += 1
        exitFullscreenIfActive()
        closePopupAsync()

        val oldView = webView
        val shouldDestroyOld = !mainWebViewDestroyed
        mainWebViewDestroyed = false
        if (shouldDestroyOld) {
            try {
                container.removeView(oldView)
            } catch (_: Throwable) {
            }
            mainHandler.post { safeDestroyWebView(oldView, removeJsBridge = true) }
        }

        val targetProfile = requestedProfileName.ifEmpty { appliedProfileName }
        val (replacement, _, attachFailed) = createMainWebView(targetProfile)
        profileAttachFailed = attachFailed
        webView = replacement
        webViewPaused = false
        renderProcessCrashed = false
        pendingCrashReload = false
        pendingCrashUrl = ""
        container.addView(
            replacement,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        if (profileAttachFailed) {
            emitProfileIsolationError()
        }
    }

    private fun detachAndDestroyDeadMainWebView(dead: WebView) {
        if (dead === webView) {
            if (mainWebViewDestroyed) return
            mainWebViewDestroyed = true
        }
        dismissPendingPermissionDialogs()
        exitFullscreenIfActive()
        closePopupAsync()
        try {
            container.removeView(dead)
        } catch (_: Throwable) {
        }
        safeDestroyWebView(dead, removeJsBridge = true)
    }

    private fun configureCookies(target: WebView, profileName: String) {
        val cm = try {
            if (manager.isMultiProfileSupported() &&
                profileName.isNotEmpty() &&
                profileName != Profile.DEFAULT_PROFILE_NAME
            ) {
                ProfileStore.getInstance().getProfile(profileName)?.cookieManager ?: return
            } else {
                CookieManager.getInstance()
            }
        } catch (_: Throwable) {
            return
        }
        try {
            cm.setAcceptCookie(true)
            cm.setAcceptThirdPartyCookies(target, true)
        } catch (_: Throwable) {
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebViewSettings(
        target: WebView,
        ua: String,
        supportMultipleWindows: Boolean,
    ) {
        target.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mediaPlaybackRequiresUserGesture = false
            // ユーザー操作を伴わないゼロクリック window.open を禁止
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(supportMultipleWindows)
            loadWithOverviewMode = true
            useWideViewPort = true
            builtInZoomControls = true
            displayZoomControls = false
            cacheMode = WebSettings.LOAD_DEFAULT
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            @Suppress("DEPRECATION")
            saveFormData = false
            userAgentString = ua
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                offscreenPreRaster = true
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                target.setRendererPriorityPolicy(
                    WebView.RENDERER_PRIORITY_IMPORTANT,
                    false,
                )
            } catch (_: Throwable) {
            }
        }
    }

    private fun restoreDefaultCacheMode(target: WebView?) {
        if (target == null) return
        try {
            if (target.settings.cacheMode != WebSettings.LOAD_DEFAULT) {
                target.settings.cacheMode = WebSettings.LOAD_DEFAULT
            }
        } catch (_: Throwable) {
        }
    }

    private fun enableTemporaryCacheBypass(target: WebView) {
        val token = ++cacheBypassToken
        try {
            target.settings.cacheMode = WebSettings.LOAD_NO_CACHE
        } catch (_: Throwable) {
        }
        mainHandler.postDelayed({
            if (!disposed && token == cacheBypassToken && target === webView) {
                restoreDefaultCacheMode(target)
            }
        }, CACHE_BYPASS_RESET_MS)
    }

    private fun resolveReloadTargetUrl(fallbackUrl: String?): String {
        val currentWebViewUrl = try {
            if (!renderProcessCrashed) webView.url else null
        } catch (_: Throwable) {
            null
        }
        val candidates = listOf(
            lastFailedUrl,
            currentWebViewUrl,
            lastTargetUrl,
            fallbackUrl,
            initialUrl,
        )
        for (candidate in candidates) {
            val trimmed = candidate?.trim()
            if (isHttpOrHttpsUrl(trimmed)) {
                return trimmed!!
            }
        }
        return ""
    }

    private fun loadUrlInternal(url: String, bypassCache: Boolean = false) {
        if (disposed) return
        if (profileAttachFailed) {
            emitProfileIsolationError()
            return
        }
        val trimmed = url.trim()
        if (!isHttpOrHttpsUrl(trimmed)) return

        if (renderProcessCrashed) {
            replaceMainWebView()
            if (profileAttachFailed) return
        }

        currentLoadHadMainFrameError = false
        lastFailedUrl = null
        awaitingReloadStart = false
        reloadSequence += 1
        lastTargetUrl = trimmed
        if (bypassCache) {
            enableTemporaryCacheBypass(webView)
        } else {
            restoreDefaultCacheMode(webView)
        }
        isMainFrameLoading = true
        // 一時停止中の裏タブでも読み込みは表示状態で進め、切替時に即表示できるようにする
        applyBackgroundThrottle()
        try {
            webView.loadUrl(trimmed)
        } catch (e: Throwable) {
            isMainFrameLoading = false
            Log.w(TAG, "loadUrl failed for $trimmed: ${e.message}")
        }
    }

    private fun reloadInternal(fallbackUrl: String?) {
        if (disposed) return
        if (profileAttachFailed) {
            emitProfileIsolationError()
            return
        }
        val targetUrl = resolveReloadTargetUrl(fallbackUrl)

        if (renderProcessCrashed) {
            replaceMainWebView()
            if (!profileAttachFailed && targetUrl.isNotEmpty()) {
                loadUrlInternal(targetUrl, bypassCache = true)
            }
            return
        }

        val rawUrl = try {
            webView.url?.trim().orEmpty()
        } catch (_: Throwable) {
            ""
        }
        val hasValidCurrentUrl = isHttpOrHttpsUrl(rawUrl)
        val historySize = try {
            webView.copyBackForwardList().size
        } catch (_: Throwable) {
            0
        }

        // エラー後・未コミット・読み込み停滞中・blank/error URL では webView.reload() が無反応になりやすいため
        // 明示的に targetUrl を loadUrl し直して確実に再取得する。
        val shouldForceLoadUrl = currentLoadHadMainFrameError ||
            !hasValidCurrentUrl ||
            historySize == 0 ||
            isMainFrameLoading

        val hadErrorBeforeReload = currentLoadHadMainFrameError
        currentLoadHadMainFrameError = false
        lastFailedUrl = null
        awaitingReloadStart = false
        try {
            webView.stopLoading()
        } catch (_: Throwable) {
        }

        // 通常リロード時はキャッシュ(LOAD_DEFAULT)を活用して Instagram 等の再読み込みを高速化し、
        // エラー復旧時のみキャッシュをバイパスする。
        if (hadErrorBeforeReload) {
            enableTemporaryCacheBypass(webView)
        } else {
            restoreDefaultCacheMode(webView)
        }
        val seq = ++reloadSequence
        reloadObservedProgress = false
        awaitingReloadStart = true
        isMainFrameLoading = true
        applyBackgroundThrottle()

        if (shouldForceLoadUrl && targetUrl.isNotEmpty()) {
            if (hasValidCurrentUrl && targetUrl.contains('#') && targetUrl == rawUrl) {
                try {
                    webView.reload()
                } catch (_: Throwable) {
                }
                scheduleReloadWatchdog(seq, targetUrl)
            } else {
                lastTargetUrl = targetUrl
                try {
                    webView.loadUrl(targetUrl)
                } catch (e: Throwable) {
                    isMainFrameLoading = false
                    Log.w(TAG, "force loadUrl on reload failed: ${e.message}")
                }
            }
        } else {
            try {
                webView.reload()
            } catch (_: Throwable) {
            }
            if (targetUrl.isNotEmpty()) {
                scheduleReloadWatchdog(seq, targetUrl)
            }
        }
    }

    private fun scheduleReloadWatchdog(seq: Int, targetUrl: String) {
        mainHandler.postDelayed({
            if (!disposed && !renderProcessCrashed && !profileAttachFailed && seq == reloadSequence && !reloadObservedProgress) {
                Log.w(TAG, "webView.reload() did not start in time; falling back to loadUrl($targetUrl)")
                try {
                    webView.stopLoading()
                    val currentNow = webView.url?.trim().orEmpty()
                    if (targetUrl.contains('#') && targetUrl == currentNow) {
                        webView.evaluateJavascript("window.location.reload();", null)
                    } else {
                        lastTargetUrl = targetUrl
                        webView.loadUrl(targetUrl)
                    }
                } catch (e: Throwable) {
                    Log.w(TAG, "reload watchdog fallback failed: ${e.message}")
                }
            }
        }, RELOAD_WATCHDOG_MS)
    }

    @SuppressLint("AddJavascriptInterface")
    private fun attachAutofillGuard(target: OmniWebView, token: String): Boolean {
        try {
            target.addJavascriptInterface(OmniAutofillBridge(target, token), "OmniAutofillBridge")
        } catch (e: Throwable) {
            Log.w(TAG, "addJavascriptInterface failed: ${e.message}")
        }
        return try {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                WebViewCompat.addDocumentStartJavaScript(
                    target,
                    OmniWebViewManager.buildAutofillGuardJs(token),
                    setOf("*"),
                )
                true
            } else {
                false
            }
        } catch (e: Throwable) {
            Log.w(TAG, "addDocumentStartJavaScript failed: ${e.message}")
            false
        }
    }

    private fun injectAutofillGuardFallback(target: WebView, token: String, skipIfDocumentStart: Boolean) {
        if (skipIfDocumentStart) return
        try {
            target.evaluateJavascript(OmniWebViewManager.buildAutofillGuardJs(token), null)
        } catch (_: Throwable) {
        }
    }

    private fun dispatchVerifiedFollowEvent(
        kind: String,
        verifiedService: String,
        source: String,
        handle: String = "",
        following: Int = -1,
        followers: Int = -1,
    ) {
        if (disposed || !allowBridgeEvent()) return
        when (kind) {
            "follow" -> invokeDart(
                "onFollowDetected",
                mapOf("source" to source.ifEmpty { "auto" }, "service" to verifiedService),
            )
            "unfollow" -> invokeDart(
                "onUnfollowDetected",
                mapOf("source" to source.ifEmpty { "auto" }, "service" to verifiedService),
            )
            "identity" -> {
                val cleanHandle = handle.trim()
                if (cleanHandle.isEmpty()) return
                val payload = mutableMapOf<String, Any>(
                    "service" to verifiedService,
                    "handle" to cleanHandle,
                )
                if (following >= 0) payload["following"] = following
                if (followers >= 0) payload["followers"] = followers
                invokeDart("onAccountIdentity", payload)
            }
        }
    }

    @SuppressLint("AddJavascriptInterface")
    private fun attachFollowTracker(target: OmniWebView, token: String): Boolean {
        var attachedListener = false
        try {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
                WebViewCompat.addWebMessageListener(
                    target,
                    "OmniFollowChannel",
                    setOf("*"),
                ) { view, message: WebMessageCompat, sourceOrigin, isMainFrame, _ ->
                    if (disposed || view !== webView || !isMainFrame) return@addWebMessageListener
                    val isHttps = sourceOrigin.scheme.equals("https", ignoreCase = true)
                    val isHttp = sourceOrigin.scheme.equals("http", ignoreCase = true)
                    if (!isHttps && !isHttp) return@addWebMessageListener
                    val rawData = message.data ?: return@addWebMessageListener
                    if (rawData.length > 4 * 1024 * 1024) return@addWebMessageListener
                    try {
                        val obj = JSONObject(rawData)
                        if (obj.optString("token") != token) return@addWebMessageListener
                        val type = obj.optString("type")
                        if (type != "jev-check" && rawData.length > 4096) return@addWebMessageListener
                        when (type) {
                            "follow", "unfollow" -> {
                                if (!isHttps) return@addWebMessageListener
                                val verifiedService = detectEffectivePlatformServiceFromHost(sourceOrigin.host)
                                    ?: return@addWebMessageListener
                                dispatchVerifiedFollowEvent(
                                    kind = type,
                                    verifiedService = verifiedService,
                                    source = obj.optString("source", "auto"),
                                )
                            }
                            "identity" -> {
                                if (!isHttps) return@addWebMessageListener
                                val verifiedService = detectEffectivePlatformServiceFromHost(sourceOrigin.host)
                                    ?: return@addWebMessageListener
                                if (verifiedService == "instagram" ||
                                    verifiedService == "threads" ||
                                    verifiedService == "bluesky"
                                ) {
                                    dispatchVerifiedFollowEvent(
                                        kind = "identity",
                                        verifiedService = verifiedService,
                                        source = "auto",
                                        handle = obj.optString("handle", ""),
                                        following = obj.optInt("following", -1),
                                        followers = obj.optInt("followers", -1),
                                    )
                                }
                            }
                            "open-new-tab" -> {
                                if (!allowBridgeEvent()) return@addWebMessageListener
                                val cleanUrl = obj.optString("url", "").trim()
                                if (cleanUrl.startsWith("http://", ignoreCase = true) ||
                                    cleanUrl.startsWith("https://", ignoreCase = true)
                                ) {
                                    invokeDart(
                                        "onOpenNewTab",
                                        mapOf(
                                            "url" to cleanUrl,
                                            "activate" to obj.optBoolean("activate", false),
                                        ),
                                    )
                                }
                            }
                            "jev-get-config" -> {
                                if (!allowBridgeEvent()) return@addWebMessageListener
                                invokeDart("onJevGetConfig", null)
                            }
                            "jev-check" -> {
                                if (!allowBridgeEvent()) return@addWebMessageListener
                                val reqId = obj.optString("reqId", "").trim()
                                val payloadJson = obj.optString("payload", "").trim()
                                if (reqId.isNotEmpty()) {
                                    invokeDart(
                                        "onJevCheckAccounts",
                                        mapOf("reqId" to reqId, "payload" to payloadJson),
                                    )
                                }
                            }
                            "jev-state" -> {
                                if (!allowBridgeEvent()) return@addWebMessageListener
                                invokeDart(
                                    "onJevState",
                                    mapOf(
                                        "active" to obj.optBoolean("active", false),
                                        "matched" to obj.optInt("matched", 0),
                                        "hidden" to obj.optInt("hidden", 0),
                                        "autoFetching" to obj.optBoolean("autoFetching", false),
                                    ),
                                )
                            }
                        }
                    } catch (_: Throwable) {
                    }
                }
                attachedListener = true
            }
        } catch (e: Throwable) {
            Log.w(TAG, "addWebMessageListener(OmniFollowChannel) failed: ${e.message}")
        }

        if (!attachedListener) {
            // 古い WebView 向けフォールバック（トークン検証＋メインスレッドで実URL由来のHTTPSオリジン検証）
            try {
                target.addJavascriptInterface(
                    OmniFollowBridge(
                        expectedToken = token,
                        onFollow = { source, _ ->
                            mainHandler.post {
                                if (disposed || target !== webView) return@post
                                val svc = detectEffectivePlatformServiceFromHttpsUrl(target.url)
                                    ?: return@post
                                dispatchVerifiedFollowEvent("follow", svc, source)
                            }
                        },
                        onUnfollow = { source, _ ->
                            mainHandler.post {
                                if (disposed || target !== webView) return@post
                                val svc = detectEffectivePlatformServiceFromHttpsUrl(target.url)
                                    ?: return@post
                                dispatchVerifiedFollowEvent("unfollow", svc, source)
                            }
                        },
                        onIdentity = { _, handle, following, followers ->
                            mainHandler.post {
                                if (disposed || target !== webView) return@post
                                val svc = detectEffectivePlatformServiceFromHttpsUrl(target.url)
                                    ?: return@post
                                if (svc != "instagram" && svc != "threads" && svc != "bluesky") {
                                    return@post
                                }
                                dispatchVerifiedFollowEvent(
                                    kind = "identity",
                                    verifiedService = svc,
                                    source = "auto",
                                    handle = handle,
                                    following = following,
                                    followers = followers,
                                )
                            }
                        },
                        onOpenNewTabCb = { url, activate ->
                            mainHandler.post {
                                if (disposed || target !== webView || !allowBridgeEvent()) return@post
                                invokeDart("onOpenNewTab", mapOf("url" to url, "activate" to activate))
                            }
                        },
                        onJevGetConfigCb = {
                            mainHandler.post {
                                if (disposed || target !== webView || !allowBridgeEvent()) return@post
                                invokeDart("onJevGetConfig", null)
                            }
                        },
                        onJevCheckAccountsCb = { reqId, payloadJson ->
                            mainHandler.post {
                                if (disposed || target !== webView || !allowBridgeEvent()) return@post
                                invokeDart(
                                    "onJevCheckAccounts",
                                    mapOf("reqId" to reqId, "payload" to payloadJson),
                                )
                            }
                        },
                        onJevStateCb = { active, matched, hidden, autoFetching ->
                            mainHandler.post {
                                if (disposed || target !== webView || !allowBridgeEvent()) return@post
                                invokeDart(
                                    "onJevState",
                                    mapOf(
                                        "active" to active,
                                        "matched" to matched,
                                        "hidden" to hidden,
                                        "autoFetching" to autoFetching,
                                    ),
                                )
                            }
                        },
                    ),
                    "OmniFollowBridge",
                )
            } catch (e: Throwable) {
                Log.w(TAG, "addJavascriptInterface(OmniFollowBridge) failed: ${e.message}")
            }
        }

        return try {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                WebViewCompat.addDocumentStartJavaScript(
                    target,
                    OmniWebViewManager.buildFollowTrackerJs(token),
                    effectiveFollowOrigins,
                )
                WebViewCompat.addDocumentStartJavaScript(
                    target,
                    OmniWebViewManager.buildProfileStatsJs(token),
                    setOf("*"),
                )
                WebViewCompat.addDocumentStartJavaScript(
                    target,
                    OmniWebViewManager.buildLongPressNewTabJs(token),
                    setOf("*"),
                )
                WebViewCompat.addDocumentStartJavaScript(
                    target,
                    OmniWebViewManager.buildJevFilterJs(token),
                    setOf("*"),
                )
                true
            } else {
                false
            }
        } catch (e: Throwable) {
            Log.w(TAG, "addDocumentStartJavaScript(FOLLOW/PROFILE_STATS/LP/JEV) failed: ${e.message}")
            false
        }
    }

    private fun injectFollowTrackerFallback(target: WebView, url: String?) {
        if (hasDocumentStartFollow) return
        val svc = detectEffectivePlatformServiceFromHttpsUrl(url ?: target.url)
        try {
            if (svc != null) {
                target.evaluateJavascript(OmniWebViewManager.buildFollowTrackerJs(mainFollowToken), null)
            }
            target.evaluateJavascript(OmniWebViewManager.buildProfileStatsJs(mainFollowToken), null)
            target.evaluateJavascript(OmniWebViewManager.buildLongPressNewTabJs(mainFollowToken), null)
            target.evaluateJavascript(OmniWebViewManager.buildJevFilterJs(mainFollowToken), null)
        } catch (_: Throwable) {
        }
    }

    private fun safeDestroyWebView(target: WebView, removeJsBridge: Boolean) {
        try {
            (target.parent as? ViewGroup)?.removeView(target)
        } catch (_: Throwable) {
        }
        try {
            target.webChromeClient = null
            target.webViewClient = WebViewClient()
        } catch (_: Throwable) {
        }
        try {
            target.stopLoading()
        } catch (_: Throwable) {
        }
        try {
            target.onPause()
        } catch (_: Throwable) {
        }
        if (removeJsBridge) {
            try {
                target.removeJavascriptInterface("OmniAutofillBridge")
            } catch (_: Throwable) {
            }
            try {
                target.removeJavascriptInterface("OmniFollowBridge")
            } catch (_: Throwable) {
            }
            try {
                if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
                    WebViewCompat.removeWebMessageListener(target, "OmniFollowChannel")
                }
            } catch (_: Throwable) {
            }
        }
        try {
            target.destroy()
        } catch (_: Throwable) {
        }
    }

    private fun safeDestroyPopup(child: OmniWebView?, dialog: Dialog?, removeJsBridge: Boolean) {
        if (dialog != null) {
            try {
                if (dialog.isShowing) {
                    dialog.dismiss()
                }
            } catch (_: Throwable) {
            }
        }
        if (child != null) {
            safeDestroyWebView(child, removeJsBridge)
        }
    }

    private fun formatOriginLabel(rawUrl: String?): String {
        if (rawUrl.isNullOrBlank()) return ""
        return try {
            val uri = Uri.parse(rawUrl.trim())
            val scheme = uri.scheme?.lowercase().orEmpty()
            val host = uri.host?.lowercase().orEmpty()
            if ((scheme == "https" || scheme == "http") && host.isNotEmpty()) {
                val port = if (uri.port != -1) ":${uri.port}" else ""
                val prefix = if (scheme == "https") "🔒 " else "⚠ http://"
                if (scheme == "https") "$prefix$host$port" else "$prefix$host$port"
            } else {
                ""
            }
        } catch (_: Throwable) {
            ""
        }
    }

    private fun handleWebPermissionRequest(request: PermissionRequest?) {
        if (request == null) return
        mainHandler.post {
            // 非アクティブタブ・バックグラウンド・ダイアログ多重表示時は即拒否（背景タブ偽装・スパム防止）
            if (disposed || !isTabActive || !container.isShown ||
                activity.isFinishing || activity.isDestroyed ||
                activePermissionDialog != null || activeGeoDialog != null
            ) {
                try {
                    request.deny()
                } catch (_: Throwable) {
                }
                return@post
            }
            val origin = request.origin
            val scheme = origin?.scheme?.lowercase().orEmpty()
            val host = origin?.host?.lowercase().orEmpty()
            if (scheme != "https" || host.isEmpty()) {
                try {
                    request.deny()
                } catch (_: Throwable) {
                }
                return@post
            }
            val resources = request.resources ?: emptyArray()
            if (resources.isEmpty()) {
                try {
                    request.deny()
                } catch (_: Throwable) {
                }
                return@post
            }
            val grantableResources = ArrayList<String>()
            val labels = ArrayList<String>()
            val neededOsPermissions = LinkedHashSet<String>()
            for (res in resources) {
                when (res) {
                    PermissionRequest.RESOURCE_VIDEO_CAPTURE -> {
                        grantableResources.add(res)
                        labels.add("カメラ")
                        neededOsPermissions.add(Manifest.permission.CAMERA)
                    }
                    PermissionRequest.RESOURCE_AUDIO_CAPTURE -> {
                        grantableResources.add(res)
                        labels.add("マイク")
                        neededOsPermissions.add(Manifest.permission.RECORD_AUDIO)
                    }
                    PermissionRequest.RESOURCE_PROTECTED_MEDIA_ID -> {
                        grantableResources.add(res)
                        labels.add("保護されたメディア再生")
                    }
                    PermissionRequest.RESOURCE_MIDI_SYSEX -> {
                        grantableResources.add(res)
                        labels.add("MIDIデバイス")
                    }
                }
            }
            val distinctLabels = labels.distinct()
            if (grantableResources.isEmpty() || distinctLabels.isEmpty()) {
                try {
                    request.deny()
                } catch (_: Throwable) {
                }
                return@post
            }
            val handled = AtomicBoolean(false)
            fun clearTracked() {
                if (activePermissionRequest === request) {
                    activePermissionRequest = null
                    activePermissionDialog = null
                }
            }
            try {
                val dlg = AlertDialog.Builder(activity)
                    .setTitle("権限のリクエスト")
                    .setMessage("https://$host が以下の権限を要求しています:\n・${distinctLabels.joinToString("\n・")}\n\n許可しますか？")
                    .setPositiveButton("許可") { _, _ ->
                        clearTracked()
                        if (!handled.compareAndSet(false, true)) return@setPositiveButton
                        if (disposed || !isTabActive) {
                            try {
                                request.deny()
                            } catch (_: Throwable) {
                            }
                            return@setPositiveButton
                        }
                        if (neededOsPermissions.isEmpty()) {
                            try {
                                request.grant(grantableResources.toTypedArray())
                            } catch (_: Throwable) {
                            }
                        } else {
                            val reqPerms = neededOsPermissions.toTypedArray()
                            manager.requestRuntimePermissions(reqPerms) { results ->
                                val allGranted = reqPerms.all { results[it] == true }
                                try {
                                    if (allGranted && !disposed && isTabActive) {
                                        request.grant(grantableResources.toTypedArray())
                                    } else {
                                        request.deny()
                                    }
                                } catch (_: Throwable) {
                                }
                            }
                        }
                    }
                    .setNegativeButton("拒否") { _, _ ->
                        clearTracked()
                        if (handled.compareAndSet(false, true)) {
                            try {
                                request.deny()
                            } catch (_: Throwable) {
                            }
                        }
                    }
                    .setOnCancelListener {
                        clearTracked()
                        if (handled.compareAndSet(false, true)) {
                            try {
                                request.deny()
                            } catch (_: Throwable) {
                            }
                        }
                    }
                    .create()
                activePermissionRequest = request
                activePermissionDialog = dlg
                dlg.show()
            } catch (_: Throwable) {
                clearTracked()
                if (handled.compareAndSet(false, true)) {
                    try {
                        request.deny()
                    } catch (_: Throwable) {
                    }
                }
            }
        }
    }

    private fun handleGeolocationPrompt(
        origin: String?,
        callback: GeolocationPermissions.Callback?,
    ) {
        if (origin == null || callback == null) return
        mainHandler.post {
            if (disposed || !isTabActive || !container.isShown ||
                activity.isFinishing || activity.isDestroyed ||
                activePermissionDialog != null || activeGeoDialog != null
            ) {
                try {
                    callback.invoke(origin, false, false)
                } catch (_: Throwable) {
                }
                return@post
            }
            val uri = try {
                Uri.parse(origin.trim())
            } catch (_: Throwable) {
                null
            }
            val scheme = uri?.scheme?.lowercase().orEmpty()
            val host = uri?.host?.lowercase().orEmpty()
            if (scheme != "https" || host.isEmpty()) {
                try {
                    callback.invoke(origin, false, false)
                } catch (_: Throwable) {
                }
                return@post
            }
            val handled = AtomicBoolean(false)
            fun clearTracked() {
                if (activeGeoCallback === callback) {
                    activeGeoDialog = null
                    activeGeoCallback = null
                    activeGeoOrigin = null
                }
            }
            try {
                val dlg = AlertDialog.Builder(activity)
                    .setTitle("位置情報のリクエスト")
                    .setMessage("https://$host が端末の位置情報へのアクセスを要求しています。許可しますか？")
                    .setPositiveButton("今回のみ許可") { _, _ ->
                        clearTracked()
                        if (!handled.compareAndSet(false, true)) return@setPositiveButton
                        if (disposed || !isTabActive) {
                            try {
                                callback.invoke(origin, false, false)
                            } catch (_: Throwable) {
                            }
                            return@setPositiveButton
                        }
                        val locPerms = arrayOf(
                            Manifest.permission.ACCESS_FINE_LOCATION,
                            Manifest.permission.ACCESS_COARSE_LOCATION,
                        )
                        manager.requestRuntimePermissions(locPerms) { results ->
                            val locGranted =
                                results[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
                                    results[Manifest.permission.ACCESS_COARSE_LOCATION] == true
                            try {
                                callback.invoke(origin, locGranted && !disposed && isTabActive, false)
                            } catch (_: Throwable) {
                            }
                        }
                    }
                    .setNegativeButton("拒否") { _, _ ->
                        clearTracked()
                        if (handled.compareAndSet(false, true)) {
                            try {
                                callback.invoke(origin, false, false)
                            } catch (_: Throwable) {
                            }
                        }
                    }
                    .setOnCancelListener {
                        clearTracked()
                        if (handled.compareAndSet(false, true)) {
                            try {
                                callback.invoke(origin, false, false)
                            } catch (_: Throwable) {
                            }
                        }
                    }
                    .create()
                activeGeoCallback = callback
                activeGeoOrigin = origin
                activeGeoDialog = dlg
                dlg.show()
            } catch (_: Throwable) {
                clearTracked()
                if (handled.compareAndSet(false, true)) {
                    try {
                        callback.invoke(origin, false, false)
                    } catch (_: Throwable) {
                    }
                }
            }
        }
    }

    private fun createMainWebViewClient(): WebViewClient {
        return object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?,
            ): Boolean {
                if (disposed || view == null || view !== webView) return true
                val req = request ?: return true
                val url = req.url?.toString() ?: return true
                val scheme = req.url?.scheme?.lowercase() ?: return true
                if (scheme == "http" || scheme == "https") {
                    return false
                }
                // サブフレームやユーザー操作なしの外部スキーム・intent リダイレクトを遮断
                if (!req.isForMainFrame) {
                    return true
                }
                if (scheme == "intent") {
                    if (req.hasGesture()) {
                        val fallback = extractIntentFallbackHttpUrl(url)
                        if (fallback != null) {
                            mainHandler.post {
                                if (!disposed) {
                                    loadUrlInternal(fallback)
                                }
                            }
                        }
                    }
                    return true
                }
                if ((scheme == "mailto" || scheme == "tel") && req.hasGesture()) {
                    invokeDart("onExternalScheme", mapOf("url" to url))
                }
                return true
            }

            override fun onPageStarted(
                view: WebView?,
                url: String?,
                favicon: android.graphics.Bitmap?,
            ) {
                super.onPageStarted(view, url, favicon)
                if (disposed || view == null || view !== webView) return
                awaitingReloadStart = false
                reloadObservedProgress = true
                isMainFrameLoading = true
                // ページ側リダイレクト等で始まった読み込みも、一時停止中の裏タブなら再開して読み込ませる
                applyBackgroundThrottle()
                val cleanUrl = if (isHttpOrHttpsUrl(url)) url!!.trim() else ""
                if (cleanUrl.isNotEmpty()) {
                    currentLoadHadMainFrameError = false
                    lastFailedUrl = null
                    lastTargetUrl = cleanUrl
                }
                webView.applyAutofillAllowed(false)
                invokeDart("onPageStarted", mapOf("url" to cleanUrl))
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                if (disposed || view == null || view !== webView) return
                awaitingReloadStart = false
                isMainFrameLoading = false
                restoreDefaultCacheMode(view)
                injectAutofillGuardFallback(view, mainAutofillToken, hasDocumentStartAutofill)
                injectFollowTrackerFallback(view, url)
                val resolvedUrl = listOf(url, view.url)
                    .firstOrNull { isHttpOrHttpsUrl(it) }
                    ?.trim()
                    .orEmpty()
                if (resolvedUrl.isNotEmpty() && !currentLoadHadMainFrameError) {
                    lastTargetUrl = resolvedUrl
                }
                invokeDart(
                    "onPageFinished",
                    mapOf(
                        "url" to resolvedUrl,
                        "title" to (view.title ?: ""),
                        "canGoBack" to view.canGoBack(),
                        "canGoForward" to view.canGoForward(),
                        "hadError" to currentLoadHadMainFrameError,
                    ),
                )
                // 裏で読み込み完了した非アクティブタブはここで一時停止して前面タブの負荷を下げる
                applyBackgroundThrottle()
            }

            override fun doUpdateVisitedHistory(view: WebView?, url: String?, isReload: Boolean) {
                super.doUpdateVisitedHistory(view, url, isReload)
                if (disposed || view == null || view !== webView) return
                val resolvedUrl = listOf(url, view.url)
                    .firstOrNull { isHttpOrHttpsUrl(it) }
                    ?.trim()
                    .orEmpty()
                if (resolvedUrl.isNotEmpty()) {
                    lastTargetUrl = resolvedUrl
                }
                invokeDart(
                    "onHistoryChanged",
                    mapOf(
                        "url" to resolvedUrl,
                        "canGoBack" to view.canGoBack(),
                        "canGoForward" to view.canGoForward(),
                    ),
                )
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?,
            ) {
                super.onReceivedError(view, request, error)
                if (disposed || view == null || view !== webView) return
                if (request?.isForMainFrame != true) return

                val desc = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    error?.description?.toString() ?: "Unknown error"
                } else {
                    "Page load error"
                }
                val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    error?.errorCode ?: -1
                } else {
                    -1
                }
                val errorUrl = request.url?.toString()

                // リダイレクト切替・SPA遷移・stopLoading・アプリスキーム抑止等に伴う ERR_ABORTED は無視する
                if (desc.contains("ERR_ABORTED", ignoreCase = true)) {
                    return
                }
                if (!errorUrl.isNullOrEmpty() && !isHttpOrHttpsUrl(errorUrl)) {
                    return
                }

                currentLoadHadMainFrameError = true
                isMainFrameLoading = false
                awaitingReloadStart = false
                reloadObservedProgress = true
                restoreDefaultCacheMode(view)
                if (isHttpOrHttpsUrl(errorUrl)) {
                    lastFailedUrl = errorUrl!!.trim()
                }
                invokeDart(
                    "onWebResourceError",
                    mapOf("description" to desc, "errorCode" to code),
                )
                applyBackgroundThrottle()
            }

            override fun onRenderProcessGone(
                view: WebView?,
                detail: RenderProcessGoneDetail?,
            ): Boolean {
                if (disposed || view == null || view !== webView) {
                    if (view != null) {
                        mainHandler.post { safeDestroyWebView(view, removeJsBridge = true) }
                    }
                    return true
                }
                Log.w(TAG, "Main WebView render process gone; recovering safely")
                renderProcessCrashed = true
                isMainFrameLoading = false
                awaitingReloadStart = false
                val targetUrl = resolveReloadTargetUrl(null)
                val now = System.currentTimeMillis()
                val withinCooldown = (now - lastCrashRecoveryAtMs) < CRASH_RECOVERY_COOLDOWN_MS
                lastCrashRecoveryAtMs = now
                val myGen = crashRecoveryGen
                val deadView = view

                mainHandler.post {
                    // Android WebViewClient 契約に従い、true を返したクラッシュ済み WebView は
                    // バックグラウンド・非アクティブ時であっても必ず即座にデタッチ＆破棄する
                    if (deadView === webView) {
                        detachAndDestroyDeadMainWebView(deadView)
                    } else {
                        safeDestroyWebView(deadView, removeJsBridge = true)
                    }
                    // すでに再生成済み・破棄済み・Activity終了中の場合は二重置換しない
                    if (disposed || !renderProcessCrashed || myGen != crashRecoveryGen ||
                        activity.isFinishing || activity.isDestroyed
                    ) {
                        return@post
                    }
                    // 非アクティブタブまたはアプリ非表示（バックグラウンド LMK）時は一斉自動再生成を控え、
                    // 次回タブ選択またはアプリ復帰（setTabActive(true)）時に自動再構築・再読み込みする
                    if (!isTabActive || !container.isShown) {
                        pendingCrashReload = true
                        pendingCrashUrl = targetUrl
                        if (targetUrl.isNotEmpty()) {
                            lastFailedUrl = targetUrl
                        }
                        return@post
                    }
                    replaceMainWebView()
                    if (!profileAttachFailed && !withinCooldown && targetUrl.isNotEmpty()) {
                        loadUrlInternal(targetUrl, bypassCache = false)
                    } else if (!profileAttachFailed) {
                        currentLoadHadMainFrameError = true
                        if (targetUrl.isNotEmpty()) {
                            lastFailedUrl = targetUrl
                        }
                        invokeDart(
                            "onWebResourceError",
                            mapOf(
                                "description" to "ページの表示プロセスが終了しました。再読み込みしてください。",
                                "errorCode" to -999,
                            ),
                        )
                    }
                }
                return true
            }
        }
    }

    private fun createMainWebChromeClient(): WebChromeClient {
        return object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                super.onProgressChanged(view, newProgress)
                if (disposed || view == null || view !== webView) return
                // stopLoading() 直後に届く古い進捗 100 を無視して読み込み表示を早閉じさせない
                if (awaitingReloadStart && newProgress >= 100) {
                    return
                }
                if (newProgress in 1..95) {
                    awaitingReloadStart = false
                    reloadObservedProgress = true
                }
                invokeDart("onProgress", mapOf("progress" to newProgress))
            }

            override fun onReceivedTitle(view: WebView?, title: String?) {
                super.onReceivedTitle(view, title)
                if (disposed || view == null || view !== webView) return
                if (!title.isNullOrEmpty()) {
                    invokeDart("onTitleChanged", mapOf("title" to title))
                }
            }

            override fun onPermissionRequest(request: PermissionRequest?) {
                handleWebPermissionRequest(request)
            }

            override fun onPermissionRequestCanceled(request: PermissionRequest?) {
                mainHandler.post {
                    if (request == null || activePermissionRequest === request) {
                        val dlg = activePermissionDialog
                        activePermissionDialog = null
                        activePermissionRequest = null
                        if (dlg != null) {
                            try {
                                if (dlg.isShowing) dlg.dismiss()
                            } catch (_: Throwable) {
                            }
                        }
                    }
                }
            }

            override fun onGeolocationPermissionsShowPrompt(
                origin: String?,
                callback: GeolocationPermissions.Callback?,
            ) {
                handleGeolocationPrompt(origin, callback)
            }

            override fun onGeolocationPermissionsHidePrompt() {
                mainHandler.post {
                    val dlg = activeGeoDialog
                    activeGeoDialog = null
                    activeGeoCallback = null
                    activeGeoOrigin = null
                    if (dlg != null) {
                        try {
                            if (dlg.isShowing) dlg.dismiss()
                        } catch (_: Throwable) {
                        }
                    }
                }
            }

            override fun onShowFileChooser(
                webView: WebView?,
                filePathCallback: ValueCallback<Array<Uri>>?,
                fileChooserParams: FileChooserParams?,
            ): Boolean {
                if (filePathCallback == null || fileChooserParams == null) return false
                return manager.launchFileChooser(filePathCallback, fileChooserParams)
            }

            override fun onShowCustomView(view: View?, callback: CustomViewCallback?) {
                if (view == null || disposed) return
                exitFullscreenIfActive()
                customView = view
                customViewCallback = callback
                val decor = activity.window?.decorView as? FrameLayout ?: return
                try {
                    (view.parent as? ViewGroup)?.removeView(view)
                    decor.addView(
                        view,
                        FrameLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT,
                        ),
                    )
                } catch (_: Throwable) {
                }
            }

            override fun onHideCustomView() {
                exitFullscreenIfActive()
            }

            override fun onCreateWindow(
                view: WebView?,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: Message?,
            ): Boolean {
                if (disposed || profileAttachFailed || activity.isFinishing || activity.isDestroyed) {
                    return false
                }
                // ユーザー操作なし、または非アクティブ／非表示バックグラウンドタブからのポップアップを拒否（フィッシング対策）
                if (!isUserGesture || !isTabActive || view == null || view !== webView || !container.isShown) {
                    return false
                }
                val transport = resultMsg?.obj as? WebView.WebViewTransport ?: return false

                return try {
                    closePopupAsync()

                    val child = OmniWebView(activity)
                    // 親と同じプロファイルを即座に継承し、失敗時は Default に落とさず拒否（フェイルクローズ）
                    if (manager.isMultiProfileSupported() &&
                        appliedProfileName.isNotEmpty() &&
                        appliedProfileName != Profile.DEFAULT_PROFILE_NAME
                    ) {
                        try {
                            ProfileStore.getInstance().getOrCreateProfile(appliedProfileName)
                            WebViewCompat.setProfile(child, appliedProfileName)
                        } catch (e: Throwable) {
                            Log.e(TAG, "Popup setProfile failed for $appliedProfileName; rejecting popup: ${e.message}")
                            safeDestroyWebView(child, removeJsBridge = false)
                            return false
                        }
                    }
                    configureCookies(child, appliedProfileName)
                    configureWebViewSettings(child, userAgent, supportMultipleWindows = false)
                    // ページ読み込み開始前に Autofill ガードを装着して OAuth 入力欄を正しく保護する
                    val popupAutofillToken = OmniWebViewManager.generateBridgeToken()
                    val popupHasDocStart = attachAutofillGuard(child, popupAutofillToken)
                    child.applyAutofillAllowed(false)

                    var childClosed = false
                    var dialogShown = false
                    var localDialog: Dialog? = null

                    val titleView = TextView(activity).apply {
                        text = "認証ウィンドウ"
                        setTextColor(Color.WHITE)
                        textSize = 13.5f
                        maxLines = 1
                        ellipsize = TextUtils.TruncateAt.END
                    }
                    // ページタイトルでは上書きできない常時表示オリジンバー（URL偽装フィッシング対策）
                    val originView = TextView(activity).apply {
                        text = ""
                        setTextColor(Color.parseColor("#93C5FD"))
                        textSize = 11.5f
                        maxLines = 1
                        ellipsize = TextUtils.TruncateAt.END
                    }

                    fun updateOriginHeader(url: String?) {
                        val originLabel = formatOriginLabel(url)
                        if (originLabel.isNotEmpty()) {
                            originView.text = originLabel
                        }
                    }

                    // 【重要】WebViewClient/WebChromeClient コールバック内で child.destroy() を
                    // 同期実行すると Chromium ネイティブ層でクラッシュするため、必ず mainHandler.post で遅延破棄する。
                    fun dismissThisPopupAsync() {
                        if (childClosed) return
                        childClosed = true
                        val dlgToClose = localDialog
                        localDialog = null
                        if (popupWebView === child) {
                            popupWebView = null
                            activePopupDismiss = null
                        }
                        if (dlgToClose != null && popupDialog === dlgToClose) {
                            popupDialog = null
                        }
                        mainHandler.post {
                            safeDestroyPopup(child, dlgToClose, removeJsBridge = true)
                        }
                    }

                    fun ensurePopupDialogShown(): Boolean {
                        if (childClosed || disposed || popupWebView !== child ||
                            activity.isFinishing || activity.isDestroyed
                        ) {
                            return false
                        }
                        if (dialogShown) return true
                        dialogShown = true
                        return try {
                            val dialog = Dialog(activity).apply {
                                requestWindowFeature(Window.FEATURE_NO_TITLE)
                                setCancelable(true)
                                setOnCancelListener { dismissThisPopupAsync() }
                            }
                            val root = LinearLayout(activity).apply {
                                orientation = LinearLayout.VERTICAL
                                setBackgroundColor(Color.parseColor("#0F1219"))
                            }
                            val header = LinearLayout(activity).apply {
                                orientation = LinearLayout.HORIZONTAL
                                gravity = Gravity.CENTER_VERTICAL
                                setBackgroundColor(Color.parseColor("#181C26"))
                                setPadding(16, 10, 8, 10)
                            }
                            val titleColumn = LinearLayout(activity).apply {
                                orientation = LinearLayout.VERTICAL
                            }
                            titleColumn.addView(
                                titleView,
                                LinearLayout.LayoutParams(
                                    ViewGroup.LayoutParams.MATCH_PARENT,
                                    ViewGroup.LayoutParams.WRAP_CONTENT,
                                ),
                            )
                            titleColumn.addView(
                                originView,
                                LinearLayout.LayoutParams(
                                    ViewGroup.LayoutParams.MATCH_PARENT,
                                    ViewGroup.LayoutParams.WRAP_CONTENT,
                                ),
                            )
                            val closeBtn = ImageButton(activity).apply {
                                setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
                                setBackgroundColor(Color.TRANSPARENT)
                                setColorFilter(Color.WHITE)
                                setOnClickListener { dismissThisPopupAsync() }
                            }
                            header.addView(
                                titleColumn,
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
                            (child.parent as? ViewGroup)?.removeView(child)
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
                            localDialog = dialog
                            popupDialog = dialog
                            dialog.show()
                            true
                        } catch (e: Throwable) {
                            Log.w(TAG, "Failed to show popup dialog: ${e.message}")
                            dialogShown = false
                            dismissThisPopupAsync()
                            false
                        }
                    }

                    fun forwardToParentAndClose(url: String) {
                        dismissThisPopupAsync()
                        mainHandler.post {
                            if (!disposed) {
                                loadUrlInternal(url)
                            }
                        }
                    }

                    child.webViewClient = object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(
                            popupView: WebView?,
                            request: WebResourceRequest?,
                        ): Boolean {
                            if (childClosed || disposed || popupWebView !== child) return true
                            val req = request ?: return true
                            val url = req.url?.toString() ?: return true
                            val scheme = req.url?.scheme?.lowercase() ?: return true
                            if (!req.isForMainFrame) {
                                return scheme != "http" && scheme != "https"
                            }
                            if (scheme != "http" && scheme != "https") {
                                if (scheme == "intent" && req.hasGesture()) {
                                    val fallback = extractIntentFallbackHttpUrl(url)
                                    if (fallback != null) {
                                        forwardToParentAndClose(fallback)
                                        return true
                                    }
                                } else if ((scheme == "mailto" || scheme == "tel") && req.hasGesture()) {
                                    invokeDart("onExternalScheme", mapOf("url" to url))
                                }
                                dismissThisPopupAsync()
                                return true
                            }
                            if (!dialogShown && !isDialog && !isAuthPopupUrl(url)) {
                                // OAuth 以外の通常 _blank リンク（Threads等の外部URL）は親タブで安全に開く
                                forwardToParentAndClose(url)
                                return true
                            }
                            if (!ensurePopupDialogShown()) {
                                forwardToParentAndClose(url)
                                return true
                            }
                            updateOriginHeader(url)
                            return false
                        }

                        override fun onPageStarted(
                            popupView: WebView?,
                            url: String?,
                            favicon: android.graphics.Bitmap?,
                        ) {
                            super.onPageStarted(popupView, url, favicon)
                            if (childClosed || disposed || popupWebView !== child) return
                            child.applyAutofillAllowed(false)
                            if (!url.isNullOrEmpty() && url != "about:blank") {
                                if (!isHttpOrHttpsUrl(url)) {
                                    dismissThisPopupAsync()
                                    return
                                }
                                if (!dialogShown && !isDialog && !isAuthPopupUrl(url)) {
                                    forwardToParentAndClose(url)
                                    return
                                }
                                if (!ensurePopupDialogShown()) {
                                    forwardToParentAndClose(url)
                                    return
                                }
                                updateOriginHeader(url)
                            }
                        }

                        override fun onPageFinished(popupView: WebView?, url: String?) {
                            super.onPageFinished(popupView, url)
                            if (childClosed || disposed || popupWebView !== child) return
                            if (popupView != null) {
                                injectAutofillGuardFallback(popupView, popupAutofillToken, popupHasDocStart)
                                updateOriginHeader(url ?: popupView.url)
                                if (!popupView.title.isNullOrEmpty()) {
                                    titleView.text = popupView.title
                                }
                            }
                        }

                        override fun doUpdateVisitedHistory(popupView: WebView?, url: String?, isReload: Boolean) {
                            super.doUpdateVisitedHistory(popupView, url, isReload)
                            if (childClosed || disposed || popupWebView !== child) return
                            updateOriginHeader(url ?: popupView?.url)
                        }

                        override fun onRenderProcessGone(
                            popupView: WebView?,
                            detail: RenderProcessGoneDetail?,
                        ): Boolean {
                            Log.w(TAG, "Popup WebView render process gone; dismissing safely")
                            dismissThisPopupAsync()
                            return true
                        }
                    }

                    child.webChromeClient = object : WebChromeClient() {
                        override fun onReceivedTitle(popupView: WebView?, title: String?) {
                            if (childClosed || disposed || popupWebView !== child) return
                            if (!title.isNullOrEmpty()) {
                                titleView.text = title
                            }
                        }

                        override fun onPermissionRequest(request: PermissionRequest?) {
                            handleWebPermissionRequest(request)
                        }

                        override fun onPermissionRequestCanceled(request: PermissionRequest?) {
                            mainHandler.post {
                                if (request == null || activePermissionRequest === request) {
                                    val dlg = activePermissionDialog
                                    activePermissionDialog = null
                                    activePermissionRequest = null
                                    if (dlg != null) {
                                        try {
                                            if (dlg.isShowing) dlg.dismiss()
                                        } catch (_: Throwable) {
                                        }
                                    }
                                }
                            }
                        }

                        override fun onGeolocationPermissionsShowPrompt(
                            origin: String?,
                            callback: GeolocationPermissions.Callback?,
                        ) {
                            handleGeolocationPrompt(origin, callback)
                        }

                        override fun onGeolocationPermissionsHidePrompt() {
                            mainHandler.post {
                                val dlg = activeGeoDialog
                                activeGeoDialog = null
                                activeGeoCallback = null
                                activeGeoOrigin = null
                                if (dlg != null) {
                                    try {
                                        if (dlg.isShowing) dlg.dismiss()
                                    } catch (_: Throwable) {
                                    }
                                }
                            }
                        }

                        override fun onCloseWindow(window: WebView?) {
                            dismissThisPopupAsync()
                        }
                    }

                    popupWebView = child
                    activePopupDismiss = { dismissThisPopupAsync() }
                    if (isDialog) {
                        if (!ensurePopupDialogShown()) {
                            return false
                        }
                    } else {
                        // 遷移せず不可視のまま残った about:blank ポップアップを自動回収する
                        mainHandler.postDelayed({
                            if (!childClosed && !dialogShown && popupWebView === child) {
                                dismissThisPopupAsync()
                            }
                        }, ORPHAN_POPUP_TIMEOUT_MS)
                    }
                    transport.webView = child
                    resultMsg.sendToTarget()
                    true
                } catch (e: Throwable) {
                    Log.w(TAG, "onCreateWindow failed safely: ${e.message}")
                    false
                }
            }
        }
    }

    fun exitFullscreenIfActive(): Boolean {
        val view = customView ?: return false
        val decor = activity.window?.decorView as? FrameLayout
        try {
            decor?.removeView(view)
        } catch (_: Throwable) {
        }
        customView = null
        try {
            customViewCallback?.onCustomViewHidden()
        } catch (_: Throwable) {
        }
        customViewCallback = null
        // 全画面動画を閉じた非アクティブタブは再び一時停止対象にする
        applyBackgroundThrottle()
        return true
    }

    private fun closePopupAsync() {
        val dismissFn = activePopupDismiss
        if (dismissFn != null) {
            dismissFn()
            return
        }
        val dialog = popupDialog
        popupDialog = null
        val child = popupWebView
        popupWebView = null
        if (dialog != null || child != null) {
            mainHandler.post {
                safeDestroyPopup(child, dialog, removeJsBridge = true)
            }
        }
    }

    private fun closePopupNow() {
        activePopupDismiss = null
        val dialog = popupDialog
        popupDialog = null
        val child = popupWebView
        popupWebView = null
        safeDestroyPopup(child, dialog, removeJsBridge = true)
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

    override fun getView(): View = container

    override fun dispose() {
        if (disposed) return
        disposed = true
        crashRecoveryGen += 1
        channel.setMethodCallHandler(null)
        dismissPendingPermissionDialogs()
        exitFullscreenIfActive()
        closePopupNow()
        try {
            container.removeAllViews()
        } catch (_: Throwable) {
        }
        if (::webView.isInitialized && !mainWebViewDestroyed) {
            mainWebViewDestroyed = true
            safeDestroyWebView(webView, removeJsBridge = true)
        }
        manager.unregisterView(viewId, appliedProfileName)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.success(null)
            return
        }
        when (call.method) {
            "setActive" -> {
                val active = call.argument<Boolean>("active") ?: false
                setTabActive(active)
                result.success(null)
            }
            "loadUrl" -> {
                val url = call.argument<String>("url")
                if (!url.isNullOrEmpty()) {
                    loadUrlInternal(url)
                }
                result.success(null)
            }
            "reload" -> {
                val fallbackUrl = call.argument<String>("fallbackUrl")
                reloadInternal(fallbackUrl)
                result.success(null)
            }
            "goBack" -> {
                if (!exitFullscreenIfActive() && !renderProcessCrashed) {
                    try {
                        if (webView.canGoBack()) {
                            webView.goBack()
                        }
                    } catch (_: Throwable) {
                    }
                }
                result.success(null)
            }
            "goForward" -> {
                if (!renderProcessCrashed) {
                    try {
                        if (webView.canGoForward()) {
                            webView.goForward()
                        }
                    } catch (_: Throwable) {
                    }
                }
                result.success(null)
            }
            "canGoBack" -> {
                val can = customView != null || (!renderProcessCrashed && try {
                    webView.canGoBack()
                } catch (_: Throwable) {
                    false
                })
                result.success(can)
            }
            "canGoForward" -> {
                val can = !renderProcessCrashed && try {
                    webView.canGoForward()
                } catch (_: Throwable) {
                    false
                }
                result.success(can)
            }
            "getTitle" -> {
                val title = if (renderProcessCrashed) null else try {
                    webView.title
                } catch (_: Throwable) {
                    null
                }
                result.success(title)
            }
            "getUrl" -> {
                val url = if (renderProcessCrashed) null else try {
                    webView.url
                } catch (_: Throwable) {
                    null
                }
                result.success(url)
            }
            "getAppliedProfileName" -> {
                result.success(appliedProfileName)
            }
            "setUserAgent" -> {
                val nextUa = call.argument<String>("userAgent")?.trim().orEmpty()
                val shouldReload = call.argument<Boolean>("reload") ?: true
                if (nextUa.isNotEmpty() && !renderProcessCrashed) {
                    userAgent = nextUa
                    try {
                        webView.settings.userAgentString = nextUa
                        webView.settings.useWideViewPort = true
                        webView.settings.loadWithOverviewMode = true
                        if (shouldReload) {
                            val current = webView.url
                            if (!current.isNullOrEmpty() && isHttpOrHttpsUrl(current)) {
                                loadUrlInternal(current)
                            } else {
                                reloadInternal(initialUrl)
                            }
                        }
                    } catch (_: Throwable) {
                    }
                }
                result.success(null)
            }
            "evaluateJavascript" -> {
                val script = call.argument<String>("script").orEmpty()
                if (script.isNotEmpty() && !renderProcessCrashed) {
                    try {
                        webView.evaluateJavascript(script, null)
                    } catch (_: Throwable) {
                    }
                }
                result.success(null)
            }
            "scrollBy" -> {
                val dx = (call.argument<Number>("dx"))?.toDouble() ?: 0.0
                val dy = (call.argument<Number>("dy"))?.toDouble() ?: 0.0
                if (!renderProcessCrashed) {
                    val js = """
                        (function() {
                          var dx = $dx, dy = $dy;
                          function canScroll(el) {
                            if (!el || el === document.body || el === document.documentElement) return false;
                            var st = window.getComputedStyle(el);
                            var oy = st && st.overflowY;
                            return (oy === 'auto' || oy === 'scroll') && el.scrollHeight > el.clientHeight + 8;
                          }
                          var cx = Math.round(window.innerWidth * 0.5);
                          var cy = Math.round(window.innerHeight * 0.5);
                          var cur = document.elementFromPoint(cx, cy);
                          while (cur && cur !== document.body && cur !== document.documentElement) {
                            if (canScroll(cur)) {
                              var before = cur.scrollTop;
                              cur.scrollTop += dy;
                              cur.scrollLeft += dx;
                              if (cur.scrollTop !== before || Math.abs(dy) < 1) return;
                            }
                            cur = cur.parentElement;
                          }
                          window.scrollBy(dx, dy);
                        })();
                    """.trimIndent()
                    try {
                        webView.evaluateJavascript(js, null)
                    } catch (_: Throwable) {
                    }
                }
                result.success(null)
            }
            "scrollToEdge" -> {
                val toTop = call.argument<Boolean>("toTop") ?: true
                if (!renderProcessCrashed) {
                    val js = if (toTop) {
                        """
                        (function() {
                          function canScroll(el) {
                            if (!el || el === document.body || el === document.documentElement) return false;
                            var st = window.getComputedStyle(el);
                            var oy = st && st.overflowY;
                            return (oy === 'auto' || oy === 'scroll') && el.scrollHeight > el.clientHeight + 8;
                          }
                          var cur = document.elementFromPoint(Math.round(window.innerWidth * 0.5), Math.round(window.innerHeight * 0.5));
                          while (cur && cur !== document.body && cur !== document.documentElement) {
                            if (canScroll(cur) && cur.scrollTop > 0) {
                              cur.scrollTo({ top: 0, behavior: 'smooth' });
                              return;
                            }
                            cur = cur.parentElement;
                          }
                          window.scrollTo({ top: 0, behavior: 'smooth' });
                        })();
                        """.trimIndent()
                    } else {
                        """
                        (function() {
                          function canScroll(el) {
                            if (!el || el === document.body || el === document.documentElement) return false;
                            var st = window.getComputedStyle(el);
                            var oy = st && st.overflowY;
                            return (oy === 'auto' || oy === 'scroll') && el.scrollHeight > el.clientHeight + 8;
                          }
                          var cur = document.elementFromPoint(Math.round(window.innerWidth * 0.5), Math.round(window.innerHeight * 0.5));
                          while (cur && cur !== document.body && cur !== document.documentElement) {
                            if (canScroll(cur)) {
                              cur.scrollTo({ top: cur.scrollHeight, behavior: 'smooth' });
                              return;
                            }
                            cur = cur.parentElement;
                          }
                          var h = Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement ? document.documentElement.scrollHeight : 0);
                          window.scrollTo({ top: h, behavior: 'smooth' });
                        })();
                        """.trimIndent()
                    }
                    try {
                        webView.evaluateJavascript(js, null)
                    } catch (_: Throwable) {
                    }
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
