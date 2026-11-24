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
                          emitRelation('follow', 'dom', '', clickInteractionId);
                          return;
                        }
                        if (btn.getAttribute('aria-pressed') === 'true') {
                          emitRelation('follow', 'dom', '', clickInteractionId);
                          return;
                        }
                        var after = readElementLabels(btn);
                        if ((after.text && POST_FOLLOW_STATE_RE.test(after.text)) ||
                            (after.aria && POST_FOLLOW_STATE_RE.test(after.aria))) {
                          emitRelation('follow', 'dom', '', clickInteractionId);
                          return;
                        }
                        if ((after.text !== initialLabels.text || after.aria !== initialLabels.aria) &&
                            !isFollowButtonElement(btn)) {
                          emitRelation('follow', 'dom', '', clickInteractionId);
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
                          emitRelation('unfollow', 'dom', '', clickInteractionId);
                          return;
                        }
                        var afterU = readElementLabels(btn);
                        if ((afterU.text && EXACT_FOLLOW_TEXT_RE.test(afterU.text)) ||
                            (!afterU.text && afterU.aria && ARIA_FOLLOW_RE.test(afterU.aria))) {
                          emitRelation('unfollow', 'dom', '', clickInteractionId);
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
        val PROFILE_STATS_JS: String = """
            (function() {
              if (window !== window.top) return;
              if (window.__omniProfileStatsInstalled) return;
              window.__omniProfileStatsInstalled = true;
              var __omniFollowToken = "__OMNISNS_FOLLOW_TOKEN__";
              var __omniFollowChannel = window.OmniFollowChannel;
              var __omniFollowBridge = window.OmniFollowBridge;

              var host = (window.location && window.location.hostname || '').toLowerCase();
              var platform = '';
              if (host === 'instagram.com' || host.endsWith('.instagram.com')) {
                platform = 'instagram';
              } else if (host === 'threads.com' || host.endsWith('.threads.com') || host === 'threads.net' || host.endsWith('.threads.net')) {
                platform = 'threads';
              } else if (host === 'bsky.app' || host.endsWith('.bsky.app')) {
                platform = 'bluesky';
              } else {
                return;
              }

              var RESERVED_SEGMENTS = {
                explore: 1, direct: 1, reels: 1, reel: 1, p: 1, tv: 1, stories: 1, accounts: 1,
                about: 1, legal: 1, developer: 1, developers: 1, settings: 1, search: 1, activity: 1,
                notifications: 1, messages: 1, home: 1, login: 1, signup: 1, hashtag: 1, tags: 1,
                profile: 1, lists: 1, feeds: 1, moderation: 1, post: 1, intent: 1, challenge: 1,
                privacy: 1, terms: 1, help: 1, support: 1, download: 1, apps: 1, api: 1, graphql: 1,
                web: 1, static: 1, assets: 1, following: 1, followers: 1, saved: 1, tagged: 1,
                channel: 1, audio: 1, locations: 1, directory: 1, nametag: 1, session: 1, oauth: 1
              };

              var CACHE_KEY = 'omnisns_ff_cache_v2_' + platform;
              var CACHE_TTL_MS = 6 * 60 * 60 * 1000;
              var MAX_CACHE_ENTRIES = 500;
              var statsMap = Object.create(null);
              var userIdMap = Object.create(null);
              var privateMap = Object.create(null);
              var failedMap = Object.create(null);
              var inFlight = Object.create(null);
              var queue = [];
              var queuedSet = Object.create(null);
              var queueRunning = false;
              var queueStartTimer = null;
              var backoffUntil = 0;
              var consecutiveFailures = 0;
              var preferredIgRoute = '';
              var selfHandle = '';
              var selfIdFetchStarted = false;
              var lastPostedIdentityKey = '';
              var persistTimer = null;
              var renderTimer = null;

              var capturedHeaders = Object.create(null);
              var capturedProfileGql = null;

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
                  var raw = st && st.getItem(CACHE_KEY);
                  if (!raw) return;
                  var parsed = JSON.parse(raw);
                  if (!parsed || typeof parsed !== 'object') return;
                  var now = Date.now();
                  for (var k in parsed) {
                    var e = parsed[k];
                    if (e && typeof e === 'object' && now - (e.ts || 0) < CACHE_TTL_MS) {
                      statsMap[k] = {
                        followers: typeof e.followers === 'number' ? e.followers : null,
                        following: typeof e.following === 'number' ? e.following : null,
                        posts: typeof e.posts === 'number' ? e.posts : null,
                        isPrivate: typeof e.isPrivate === 'boolean' ? e.isPrivate : null,
                        ts: e.ts || now
                      };
                      if (typeof e.isPrivate === 'boolean') privateMap[k] = e.isPrivate;
                    }
                  }
                } catch (_) {}
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

              function isValidHandle(h) {
                if (!h || typeof h !== 'string') return false;
                var clean = h.replace(/^@+/, '').trim().toLowerCase();
                if (!clean || clean.length > 64) return false;
                if (RESERVED_SEGMENTS[clean]) return false;
                if (platform === 'bluesky') {
                  return /^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/.test(clean) || /^did:[a-z0-9:._-]+$/.test(clean);
                }
                return /^[a-z0-9._]{1,35}$/.test(clean);
              }

              function normalizeHandle(h) {
                if (!h || typeof h !== 'string') return '';
                var clean = h.replace(/^@+/, '').trim().toLowerCase();
                return isValidHandle(clean) ? clean : '';
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

              function setSelfHandle(raw) {
                var h = normalizeHandle(raw);
                if (!h) return;
                var changed = h !== selfHandle;
                selfHandle = h;
                var cached = statsMap[h];
                postIdentityToHost(h, cached ? cached.following : null, cached ? cached.followers : null);
                if (changed && (!cached || (cached.following === null && cached.followers === null))) {
                  enqueueFetch(h, true, false);
                }
              }

              function hasUsableStats(entry) {
                return !!(entry && (typeof entry.followers === 'number' || typeof entry.following === 'number'));
              }

              function recordStats(rawHandle, followers, following, posts, isPrivate) {
                var h = normalizeHandle(rawHandle);
                if (!h) return false;
                var f1 = typeof followers === 'number' && isFinite(followers) && followers >= 0 ? Math.round(followers) : null;
                var f2 = typeof following === 'number' && isFinite(following) && following >= 0 ? Math.round(following) : null;
                var p = typeof posts === 'number' && isFinite(posts) && posts >= 0 ? Math.round(posts) : null;
                var priv = typeof isPrivate === 'boolean' ? isPrivate : (typeof privateMap[h] === 'boolean' ? privateMap[h] : null);
                if (typeof isPrivate === 'boolean') privateMap[h] = isPrivate;
                if (f1 === null && f2 === null) return false;

                delete failedMap[h];
                var prev = statsMap[h];
                var nextFollowers = f1 !== null ? f1 : (prev ? prev.followers : null);
                var nextFollowing = f2 !== null ? f2 : (prev ? prev.following : null);
                var nextPosts = p !== null ? p : (prev ? prev.posts : null);
                var nextPriv = priv !== null ? priv : (prev ? prev.isPrivate : null);
                var changed = !prev ||
                  prev.followers !== nextFollowers ||
                  prev.following !== nextFollowing ||
                  prev.posts !== nextPosts ||
                  prev.isPrivate !== nextPriv;
                statsMap[h] = {
                  followers: nextFollowers,
                  following: nextFollowing,
                  posts: nextPosts,
                  isPrivate: nextPriv,
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

              function extractFromJsonObject(root) {
                if (!root || typeof root !== 'object') return false;
                var foundStats = false;
                var stack = [{ node: root, depth: 0 }];
                var visited = 0;
                while (stack.length > 0 && visited < 2200) {
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

                  var candidateHandle =
                    (typeof obj.username === 'string' && obj.username) ||
                    (typeof obj.handle === 'string' && obj.handle) ||
                    '';
                  if (candidateHandle) {
                    var normH = normalizeHandle(candidateHandle);
                    if (normH) {
                      var rawId = obj.pk || obj.pk_id || obj.id || obj.fbid_v2;
                      if (rawId !== undefined && rawId !== null) {
                        var idStr = String(rawId).trim();
                        if (/^\d{5,24}$/.test(idStr)) {
                          userIdMap[normH] = idStr;
                        }
                      }
                      if (typeof obj.is_private === 'boolean') {
                        privateMap[normH] = obj.is_private;
                      }

                      var flwrs = null;
                      var flwng = null;
                      var posts = null;
                      if (typeof obj.follower_count === 'number') flwrs = obj.follower_count;
                      else if (typeof obj.text_post_app_follower_count === 'number') flwrs = obj.text_post_app_follower_count;
                      else if (typeof obj.followersCount === 'number') flwrs = obj.followersCount;
                      else if (obj.edge_followed_by && typeof obj.edge_followed_by.count === 'number') flwrs = obj.edge_followed_by.count;

                      if (typeof obj.following_count === 'number') flwng = obj.following_count;
                      else if (typeof obj.followsCount === 'number') flwng = obj.followsCount;
                      else if (obj.edge_follow && typeof obj.edge_follow.count === 'number') flwng = obj.edge_follow.count;

                      if (typeof obj.media_count === 'number') posts = obj.media_count;
                      else if (typeof obj.postsCount === 'number') posts = obj.postsCount;
                      else if (obj.edge_owner_to_timeline_media && typeof obj.edge_owner_to_timeline_media.count === 'number') {
                        posts = obj.edge_owner_to_timeline_media.count;
                      }

                      if (flwrs !== null || flwng !== null) {
                        if (recordStats(normH, flwrs, flwng, posts, typeof obj.is_private === 'boolean' ? obj.is_private : null)) {
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

                var m1 = /"edge_followed_by"\s*:\s*\{\s*"count"\s*:\s*(\d+)/.exec(html) ||
                         /"follower_count"\s*:\s*(\d+)/.exec(html) ||
                         /"text_post_app_follower_count"\s*:\s*(\d+)/.exec(html);
                if (m1) followers = parseInt(m1[1], 10);

                var m2 = /"edge_follow"\s*:\s*\{\s*"count"\s*:\s*(\d+)/.exec(html) ||
                         /"following_count"\s*:\s*(\d+)/.exec(html);
                if (m2) following = parseInt(m2[1], 10);

                var m3 = /"edge_owner_to_timeline_media"\s*:\s*\{\s*"count"\s*:\s*(\d+)/.exec(html) ||
                         /"media_count"\s*:\s*(\d+)/.exec(html);
                if (m3) posts = parseInt(m3[1], 10);

                var mPriv = /"is_private"\s*:\s*(true|false)/.exec(html);
                if (mPriv) isPrivate = mPriv[1] === 'true';

                if (followers === null || following === null || posts === null) {
                  var metaMatch = /<meta[^>]+(?:name|property)=["'](?:og:description|description)["'][^>]+content=["']([^"']+)["']/i.exec(html) ||
                                  /<meta[^>]+content=["']([^"']+)["'][^>]+(?:name|property)=["'](?:og:description|description)["']/i.exec(html);
                  if (metaMatch && metaMatch[1]) {
                    var desc = metaMatch[1];
                    if (followers === null) {
                      var mf = /([0-9.,]+[KMB]?)\s+Followers/i.exec(desc) || /フォロワー\s*([0-9.,]+[万千億KMB]?)\s*人/.exec(desc);
                      if (mf) followers = parseHumanNumber(mf[1]);
                    }
                    if (following === null) {
                      var mg = /([0-9.,]+[KMB]?)\s+Following/i.exec(desc) || /フォロー中\s*([0-9.,]+[万千億KMB]?)\s*人/.exec(desc);
                      if (mg) following = parseHumanNumber(mg[1]);
                    }
                    if (posts === null) {
                      var mp = /([0-9.,]+[KMB]?)\s+Posts/i.exec(desc) || /投稿\s*([0-9.,]+[万千億KMB]?)\s*件/.exec(desc);
                      if (mp) posts = parseHumanNumber(mp[1]);
                    }
                  }
                }

                if (followers !== null || following !== null) {
                  return recordStats(targetHandle, followers, following, posts, isPrivate);
                }
                return false;
              }

              function captureHeaderPair(key, val) {
                if (!key || !val) return;
                var k = String(key).toLowerCase().trim();
                if (k === 'x-ig-app-id' || k === 'x-csrftoken' || k === 'x-ig-www-claim' ||
                    k === 'x-asbd-id' || k === 'x-fb-lsd' || k === 'x-bloks-version-id') {
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
                if (!u) return false;
                if (platform === 'instagram' || platform === 'threads') {
                  return u.indexOf('/graphql') >= 0 || u.indexOf('/api/v1/') >= 0;
                }
                if (platform === 'bluesky') {
                  return u.indexOf('/xrpc/app.bsky.') >= 0;
                }
                return false;
              }

              function sniffJsonText(txt) {
                if (!txt || txt.length > 3500000) return;
                if (txt.indexOf('follower') < 0 && txt.indexOf('edge_followed_by') < 0 &&
                    txt.indexOf('followersCount') < 0 && txt.indexOf('followsCount') < 0 &&
                    txt.indexOf('viewer_username') < 0 && txt.indexOf('"username"') < 0) {
                  return;
                }
                try {
                  var clean = txt.indexOf('for (;;);') === 0 ? txt.slice(9) : txt;
                  extractFromJsonObject(JSON.parse(clean));
                } catch (_) {
                  try {
                    var lines = txt.split('\n');
                    for (var i = 0; i < lines.length && i < 40; i++) {
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
                      if (init && init.body) captureProfileGraphqlTemplate(reqUrl, init.body);
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
                  XMLHttpRequest.prototype.send = function(body) {
                    try {
                      if (body) captureProfileGraphqlTemplate(this.__omniStatsUrl, body);
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
                  'x-ig-app-id': appIdOverride || capturedHeaders['x-ig-app-id'] || '1217981644879628',
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
                  var scripts = document.querySelectorAll('script[type="application/json"]');
                  for (var i = 0; i < scripts.length && i < 80; i++) {
                    var txt = scripts[i].textContent || '';
                    if (txt.length > 10 && txt.length < 1800000) {
                      sniffJsonText(txt);
                    }
                  }
                } catch (_) {}
              }

              function detectSelfAccountFromDom() {
                try {
                  if (platform === 'instagram') {
                    var navLinks = document.querySelectorAll('nav a[href], [role="navigation"] a[href], div[class] a[href]');
                    for (var i = 0; i < navLinks.length && i < 240; i++) {
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
                  }
                } catch (_) {}
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
                    path = u.pathname;
                  } catch (_) { return ''; }
                } else {
                  var qIdx = path.indexOf('?');
                  if (qIdx >= 0) path = path.slice(0, qIdx);
                  var hIdx = path.indexOf('#');
                  if (hIdx >= 0) path = path.slice(0, hIdx);
                }

                if (platform === 'instagram') {
                  var m = /^\/([a-z0-9._]{1,35})\/?$/i.exec(path);
                  return m ? normalizeHandle(m[1]) : '';
                }
                if (platform === 'threads') {
                  var tm = /^\/@([a-z0-9._]{1,35})\/?$/i.exec(path);
                  return tm ? normalizeHandle(tm[1]) : '';
                }
                if (platform === 'bluesky') {
                  var bm = /^\/profile\/([^\/?#]+)\/?$/i.exec(path);
                  return bm ? normalizeHandle(bm[1]) : '';
                }
                return '';
              }

              function enqueueFetch(rawHandle, priority, forceRetry) {
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
                if (!forceRetry && hasUsableStats(existing) && (Date.now() - existing.ts) < CACHE_TTL_MS) {
                  return;
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
                if (!queueRunning && !queueStartTimer) {
                  queueStartTimer = setTimeout(function() {
                    queueStartTimer = null;
                    processQueue();
                  }, platform === 'bluesky' ? 30 : 20);
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
                    if (u && !hasUsableStats(statsMap[handle])) {
                      var flwrs = u.edge_followed_by && typeof u.edge_followed_by.count === 'number'
                        ? u.edge_followed_by.count
                        : (typeof u.follower_count === 'number' ? u.follower_count : null);
                      var flwng = u.edge_follow && typeof u.edge_follow.count === 'number'
                        ? u.edge_follow.count
                        : (typeof u.following_count === 'number' ? u.following_count : null);
                      var posts = u.edge_owner_to_timeline_media && typeof u.edge_owner_to_timeline_media.count === 'number'
                        ? u.edge_owner_to_timeline_media.count
                        : (typeof u.media_count === 'number' ? u.media_count : null);
                      recordStats(handle, flwrs, flwng, posts, typeof u.is_private === 'boolean' ? u.is_private : null);
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
                var primaryAppId = capturedHeaders['x-ig-app-id'] || '1217981644879628';
                var altAppId = primaryAppId === '936619743392459' ? '1217981644879628' : '936619743392459';
                var routes = [];
                if (userIdMap[handle] && capturedProfileGql) routes.push({ name: 'gql', fn: function() { return fetchIgViaCapturedGql(handle); } });
                if (userIdMap[handle]) routes.push({ name: 'user_info', fn: function() { return fetchIgViaUserInfo(handle); } });
                routes.push({ name: 'web_info_1', fn: function() { return fetchIgViaWebProfileInfo(handle, primaryAppId); } });
                routes.push({ name: 'web_info_2', fn: function() { return fetchIgViaWebProfileInfo(handle, altAppId); } });
                routes.push({ name: 'html_inc', fn: function() { return fetchIgViaHtml(handle, true); } });
                routes.push({ name: 'html_omit', fn: function() { return fetchIgViaHtml(handle, false); } });

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
                      consecutiveFailures = 0;
                      return;
                    }
                    if (res && res.rateLimited) {
                      backoffUntil = Date.now() + 50000;
                      failedMap[handle] = Date.now();
                      scheduleRenderBadges();
                      return;
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
                    if (data && Array.isArray(data.profiles)) {
                      for (var i = 0; i < data.profiles.length; i++) {
                        var p = data.profiles[i];
                        if (p && p.handle) {
                          recordStats(p.handle, p.followersCount, p.followsCount, p.postsCount, null);
                        }
                      }
                    }
                  });
                }).catch(function() {});
              }

              function processQueue() {
                if (queueRunning || queue.length === 0) return;
                if (Date.now() < backoffUntil) return;
                queueRunning = true;

                if (platform === 'bluesky') {
                  var batch = queue.splice(0, 20);
                  for (var i = 0; i < batch.length; i++) {
                    delete queuedSet[batch[i]];
                    inFlight[batch[i]] = true;
                  }
                  var doneBsky = function() {
                    for (var j = 0; j < batch.length; j++) delete inFlight[batch[j]];
                    setTimeout(function() {
                      queueRunning = false;
                      processQueue();
                    }, 280);
                  };
                  try {
                    Promise.resolve(fetchBlueskyBatch(batch)).then(doneBsky, doneBsky);
                  } catch (_) {
                    doneBsky();
                  }
                  return;
                }

                var handle = queue.shift();
                delete queuedSet[handle];
                inFlight[handle] = true;
                scheduleRenderBadges();
                var delayMs = platform === 'instagram' ? 620 : 820;
                var doneOne = function() {
                  delete inFlight[handle];
                  setTimeout(function() {
                    queueRunning = false;
                    processQueue();
                  }, delayMs);
                };
                try {
                  var req = platform === 'instagram' ? fetchInstagramProfile(handle) : fetchThreadsProfile(handle);
                  Promise.resolve(req).then(doneOne, doneOne);
                } catch (_) {
                  doneOne();
                }
              }

              function ensureStyles() {
                if (document.getElementById('omni-ff-style')) return;
                var style = document.createElement('style');
                style.id = 'omni-ff-style';
                style.textContent =
                  '.omni-ff-badge{' +
                  'display:inline-flex;align-items:center;gap:2px;margin-left:4px;padding:1px 5px;' +
                  'border-radius:999px;font-size:10px;font-weight:600;line-height:1.3;' +
                  'background:rgba(21,156,171,0.16);border:1px solid rgba(21,156,171,0.42);' +
                  'color:inherit;white-space:nowrap;user-select:none;vertical-align:middle;' +
                  'opacity:0.94;letter-spacing:0;pointer-events:none;' +
                  '}' +
                  '.omni-ff-badge-row{' +
                  'display:inline-flex;align-items:center;flex-wrap:wrap;gap:2px;margin:2px 0 0 0;padding:1px 5px;' +
                  'border-radius:999px;font-size:9.5px;font-weight:600;line-height:1.25;' +
                  'background:rgba(21,156,171,0.18);border:1px solid rgba(21,156,171,0.45);' +
                  'color:inherit;max-width:100%;width:fit-content;user-select:none;letter-spacing:0;' +
                  'pointer-events:auto;cursor:pointer;' +
                  '}' +
                  '.omni-ff-badge-row.is-pending{' +
                  'background:rgba(148,163,184,0.12);border-color:rgba(148,163,184,0.3);opacity:0.72;' +
                  '}' +
                  '.omni-ff-badge-row.is-retry{' +
                  'background:rgba(245,158,11,0.14);border-color:rgba(245,158,11,0.42);opacity:0.88;' +
                  '}';
                (document.head || document.documentElement).appendChild(style);
              }

              function formatBadgeDisplay(entry, includePosts) {
                if (!hasUsableStats(entry)) return null;
                var hasFollowing = typeof entry.following === 'number';
                var hasFollowers = typeof entry.followers === 'number';
                var hasPosts = includePosts && typeof entry.posts === 'number';
                var parts = [];
                if (entry.isPrivate === true) parts.push('🔒');
                if (hasFollowing) parts.push('フォロー ' + formatCompactCount(entry.following));
                if (hasFollowers) parts.push('フォロワー ' + formatCompactCount(entry.followers));
                if (hasPosts) parts.push('投稿 ' + formatCompactCount(entry.posts));
                if (parts.length === 0) return null;
                var prefix = parts[0] === '🔒' ? '🔒 ' : '';
                var body = (prefix ? parts.slice(1) : parts).join(' · ');
                return { text: prefix + body };
              }

              var NON_USER_TEXT_RE = /^(?:フォロー|フォロー中|フォローする|フォローバック|フォロワー|投稿|返信|いいね|もっと見る|すべて見る|メッセージ|削除|リクエスト済|リクエスト中|承認待ち|follow|follow\s+back|following|followers|posts|replies|likes|more|message|remove|requested|\d+(?:秒|分|時間|日|週間|[smhdw])?)$/i;
              var FOLLOW_LIST_BTN_RE = /^(?:[+＋]\s*)?(?:フォロー|フォローする|フォローバック|フォローバックする|フォロー中|フォロー済|リクエスト済|リクエスト中|承認待ち|follow|follow\s+back|following|requested)$/i;

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
                  var curPath = (window.location && window.location.pathname || '').toLowerCase().replace(/^\/@?/, '').replace(/\/.*$/, '');
                  if (curPath === handle && a.closest('header')) return false;
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
                    var am = /^@?([a-z0-9._]{1,35})(?:のプロフィール写真|'s profile picture)/i.exec(alt);
                    if (am) {
                      var ah = normalizeHandle(am[1]);
                      if (ah) return ah;
                    }
                  }
                  var spans = row.querySelectorAll('span, div');
                  for (var k = 0; k < spans.length && k < 40; k++) {
                    var s = spans[k];
                    if (s.children && s.children.length > 0) continue;
                    if (s.closest('button, [role="button"]')) continue;
                    var t = (s.textContent || '').trim();
                    if (!t || t.length > 36 || /\s/.test(t) || NON_USER_TEXT_RE.test(t)) continue;
                    var nh = normalizeHandle(t);
                    if (nh && (userIdMap[nh] || /[._0-9]/.test(nh) || /^[a-z][a-z0-9._]{2,30}$/.test(nh))) {
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
                      if (el.closest('button, [role="button"]')) continue;
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
                    if (r.width >= 90 && r.height >= 24 && r.height <= 120) {
                      best = p;
                    }
                    cur = p;
                  }
                  return best;
                } catch (_) {
                  return null;
                }
              }

              function upsertRowBadge(container, handle) {
                ensureStyles();
                var entry = statsMap[handle];
                var display = formatBadgeDisplay(entry, true);
                var badge = container.querySelector('.omni-ff-badge-row[data-omni-ff-user="' + handle + '"]');
                if (!badge) {
                  badge = document.createElement('div');
                  badge.className = 'omni-ff-badge-row';
                  badge.setAttribute('data-omni-ff-user', handle);
                  badge.addEventListener('click', function(ev) {
                    ev.preventDefault();
                    ev.stopPropagation();
                    enqueueFetch(handle, true, true);
                    upsertRowBadge(container, handle);
                  });
                  try {
                    container.appendChild(badge);
                  } catch (_) {
                    return;
                  }
                }

                if (display) {
                  badge.className = 'omni-ff-badge-row';
                  if (badge.textContent !== display.text) badge.textContent = display.text;
                } else if (inFlight[handle] || queuedSet[handle]) {
                  badge.className = 'omni-ff-badge-row is-pending';
                  if (badge.textContent !== '人数を取得中…') badge.textContent = '人数を取得中…';
                } else if (failedMap[handle] || Date.now() < backoffUntil) {
                  badge.className = 'omni-ff-badge-row is-retry';
                  if (badge.textContent !== '人数を取得 ↻') badge.textContent = '人数を取得 ↻';
                } else {
                  badge.className = 'omni-ff-badge-row is-pending';
                  if (badge.textContent !== '人数を取得中…') badge.textContent = '人数を取得中…';
                }
              }

              function scanFollowListRows() {
                try {
                  var btns = document.querySelectorAll('button, [role="button"]');
                  for (var i = 0; i < btns.length && i < 600; i++) {
                    var btn = btns[i];
                    if (btn.closest('nav, [role="navigation"]')) continue;
                    var bTxt = (btn.innerText || btn.textContent || '').replace(/\s+/g, ' ').trim();
                    if (!bTxt || bTxt.length > 20 || !FOLLOW_LIST_BTN_RE.test(bTxt)) continue;

                    var row = null;
                    var cur = btn.parentElement;
                    for (var depth = 0; depth < 7 && cur && cur !== document.body; depth++) {
                      var rect = cur.getBoundingClientRect();
                      if (rect.height >= 42 && rect.height <= 190 && rect.width >= 210) {
                        var followBtnCount = 0;
                        var subBtns = cur.querySelectorAll('button, [role="button"]');
                        for (var sb = 0; sb < subBtns.length; sb++) {
                          var st = (subBtns[sb].innerText || subBtns[sb].textContent || '').replace(/\s+/g, ' ').trim();
                          if (st && st.length <= 20 && FOLLOW_LIST_BTN_RE.test(st)) followBtnCount++;
                        }
                        if (followBtnCount === 1) {
                          var hCand = extractHandleFromRow(cur);
                          if (hCand) {
                            row = cur;
                            break;
                          }
                        }
                      }
                      cur = cur.parentElement;
                    }
                    if (!row) continue;

                    var handle = extractHandleFromRow(row);
                    if (!handle) continue;
                    var col = findRowTextColumn(row, btn, handle);
                    if (!col) continue;

                    row.setAttribute('data-omni-ff-row', handle);
                    var visible = isInViewport(row);
                    if (!hasUsableStats(statsMap[handle]) && visible) {
                      enqueueFetch(handle, false, false);
                    }
                    upsertRowBadge(col, handle);
                  }
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
                var display = formatBadgeDisplay(entry, false);
                if (!display) return;

                var next = a.nextElementSibling;
                if (next && next.classList && next.classList.contains('omni-ff-badge') &&
                    next.getAttribute('data-omni-ff-user') === handle) {
                  if (next.textContent !== display.text) next.textContent = display.text;
                  return;
                }

                var scope = a.closest('[data-omni-ff-row], header, [role="listitem"], li') || a.parentElement;
                if (scope) {
                  var existing = scope.querySelector('.omni-ff-badge[data-omni-ff-user="' + handle + '"], .omni-ff-badge-row[data-omni-ff-user="' + handle + '"]');
                  if (existing) {
                    if (!existing.classList.contains('omni-ff-badge-row') && existing.textContent !== display.text) {
                      existing.textContent = display.text;
                    }
                    return;
                  }
                }

                ensureStyles();
                var span = document.createElement('span');
                span.className = 'omni-ff-badge';
                span.setAttribute('data-omni-ff-user', handle);
                span.textContent = display.text;
                try {
                  a.insertAdjacentElement('afterend', span);
                } catch (_) {}
              }

              function scanAndRender() {
                detectSelfAccountFromDom();
                scanFollowListRows();
                var links = document.querySelectorAll('a[href]');
                for (var i = 0; i < links.length && i < 2500; i++) {
                  var a = links[i];
                  if (a.closest('[data-omni-ff-row]')) continue;
                  var handle = a.getAttribute('data-omni-ff-handle');
                  if (!handle) {
                    handle = extractHandleFromLink(a);
                    if (handle) {
                      a.setAttribute('data-omni-ff-handle', handle);
                    }
                  }
                  if (handle) {
                    if (a.getAttribute('data-omni-ff-target') !== '1' && isBadgeTargetLink(a, handle)) {
                      a.setAttribute('data-omni-ff-target', '1');
                      if (io) io.observe(a);
                    }
                    if (a.getAttribute('data-omni-ff-target') === '1') {
                      if (hasUsableStats(statsMap[handle])) {
                        applyBadgeToLink(a, handle);
                      } else if (isInViewport(a)) {
                        enqueueFetch(handle, false, false);
                      }
                    }
                  }
                }
              }

              function scheduleRenderBadges() {
                if (renderTimer) return;
                renderTimer = setTimeout(function() {
                  renderTimer = null;
                  scanAndRender();
                }, 150);
              }

              loadCache();

              function hookHistory() {
                try {
                  var origPush = history.pushState;
                  var origReplace = history.replaceState;
                  if (typeof origPush === 'function') {
                    history.pushState = function() {
                      var r = origPush.apply(this, arguments);
                      setTimeout(scheduleRenderBadges, 250);
                      return r;
                    };
                  }
                  if (typeof origReplace === 'function') {
                    history.replaceState = function() {
                      var r = origReplace.apply(this, arguments);
                      setTimeout(scheduleRenderBadges, 250);
                      return r;
                    };
                  }
                  window.addEventListener('popstate', function() { setTimeout(scheduleRenderBadges, 250); }, { passive: true });
                } catch (_) {}
              }

              function boot() {
                hookHistory();
                scanSsrScripts();
                scanAndRender();
                try {
                  window.addEventListener('scroll', scheduleRenderBadges, true);
                } catch (_) {}
                try {
                  if (typeof MutationObserver === 'function' && document.body) {
                    var mo = new MutationObserver(function(mutations) {
                      for (var i = 0; i < mutations.length; i++) {
                        if (mutations[i].addedNodes && mutations[i].addedNodes.length > 0) {
                          scheduleRenderBadges();
                          return;
                        }
                      }
                    });
                    mo.observe(document.body, { childList: true, subtree: true });
                  }
                } catch (_) {}
                setTimeout(function() { scanSsrScripts(); scanAndRender(); }, 1000);
                setTimeout(function() { scanAndRender(); }, 3000);
                setInterval(function() {
                  if (document.visibilityState === 'visible') {
                    scanAndRender();
                    if (!queueRunning && queue.length > 0 && Date.now() >= backoffUntil) {
                      processQueue();
                    }
                  }
                }, 2800);
              }

              if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', boot, { once: true });
              } else {
                boot();
              }
            })();
        """.trimIndent()
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
    private val userAgent: String
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
            val autoLoad = creationParams["autoLoad"] as? Boolean ?: false
            if (autoLoad && initialUrl.isNotEmpty()) {
                loadUrlInternal(initialUrl)
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

        currentLoadHadMainFrameError = false
        lastFailedUrl = null
        awaitingReloadStart = false
        try {
            webView.stopLoading()
        } catch (_: Throwable) {
        }

        enableTemporaryCacheBypass(webView)
        val seq = ++reloadSequence
        reloadObservedProgress = false
        awaitingReloadStart = true
        isMainFrameLoading = true

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
                    effectiveFollowOrigins,
                ) { view, message: WebMessageCompat, sourceOrigin, isMainFrame, _ ->
                    if (disposed || view !== webView || !isMainFrame) return@addWebMessageListener
                    if (!sourceOrigin.scheme.equals("https", ignoreCase = true)) return@addWebMessageListener
                    val verifiedService = detectEffectivePlatformServiceFromHost(sourceOrigin.host)
                        ?: return@addWebMessageListener
                    val rawData = message.data ?: return@addWebMessageListener
                    if (rawData.length > 4096) return@addWebMessageListener
                    try {
                        val obj = JSONObject(rawData)
                        if (obj.optString("token") != token) return@addWebMessageListener
                        when (val type = obj.optString("type")) {
                            "follow", "unfollow" -> dispatchVerifiedFollowEvent(
                                kind = type,
                                verifiedService = verifiedService,
                                source = obj.optString("source", "auto"),
                            )
                            "identity" -> {
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
                    OmniWebViewManager.PROFILE_STATS_ALLOWED_ORIGINS,
                )
                true
            } else {
                false
            }
        } catch (e: Throwable) {
            Log.w(TAG, "addDocumentStartJavaScript(FOLLOW/PROFILE_STATS) failed: ${e.message}")
            false
        }
    }

    private fun injectFollowTrackerFallback(target: WebView, url: String?) {
        if (hasDocumentStartFollow) return
        val svc = detectEffectivePlatformServiceFromHttpsUrl(url ?: target.url) ?: return
        try {
            target.evaluateJavascript(OmniWebViewManager.buildFollowTrackerJs(mainFollowToken), null)
            if (svc == "instagram" || svc == "threads" || svc == "bluesky") {
                target.evaluateJavascript(OmniWebViewManager.buildProfileStatsJs(mainFollowToken), null)
            }
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
