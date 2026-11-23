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

private class OmniFollowBridge(private val onFollow: (String) -> Unit) {
    @JavascriptInterface
    fun onFollowDetected(source: String?) {
        onFollow(source?.ifEmpty { "auto" } ?: "auto")
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

        /**
         * Threads / Instagram / Bluesky / mixi2 等のフォロー操作を検知してネイティブへ通知するスクリプト。
         * fetch / XMLHttpRequest のフォローAPI成功を優先検知し、DOMボタン状態遷移をフォールバックとする。
         */
        val FOLLOW_TRACKER_JS: String = """
            (function() {
              if (window.__omniFollowTrackerInstalled) return;
              window.__omniFollowTrackerInstalled = true;

              var NEGATIVE_RE = /(フォロー中|フォロー済|フォロー解除|フォロワー|リクエスト済|リクエスト中|承認待ち|解除|following|unfollow|followers|requested|pending|remove|cancel|block|mute)/i;
              var EXACT_FOLLOW_TEXT_RE = /^(?:[+＋]\s*)?(?:フォロー|フォローする|フォローバック|フォローバックする|フォローを返す|follow|follow\s+back)$/i;
              var ARIA_FOLLOW_RE = /^(?:(?:[+＋]\s*)?(?:フォロー|フォローする|フォローバック|follow|follow\s+back)|.+?(?:をフォロー|をフォローする|をフォローバック)|follow\s+@?[\w.\-\u3040-\u30ff\u4e00-\u9faf]+.*)$/i;
              var POST_FOLLOW_STATE_RE = /(フォロー中|フォロー済|フォロー解除|リクエスト済|リクエスト中|承認待ち|following|unfollow|requested|pending|チェック|check)/i;

              var lastNetworkFollowAt = 0;
              var lastNetworkEmitAt = 0;
              var lastDomEmitAt = 0;

              function emitFollow(source) {
                var now = Date.now();
                if (source === 'network') {
                  if (now - lastNetworkEmitAt < 120) return;
                  lastNetworkEmitAt = now;
                  lastNetworkFollowAt = now;
                } else {
                  if (now - lastDomEmitAt < 350) return;
                  lastDomEmitAt = now;
                }
                try {
                  if (window.OmniFollowBridge && typeof window.OmniFollowBridge.onFollowDetected === 'function') {
                    window.OmniFollowBridge.onFollowDetected(source || 'auto');
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

              function isFollowApiRequest(rawUrl, method, rawBody) {
                try {
                  var m = (method || 'GET').toUpperCase();
                  if (m !== 'POST') return false;
                  var url = String(rawUrl || '');
                  var lowerUrl = url.toLowerCase();
                  var body = bodyToSearchString(rawBody);
                  var decodedBody = body;
                  try {
                    if (body.indexOf('%') >= 0) decodedBody = decodeURIComponent(body.replace(/\+/g, ' '));
                  } catch (_) {}
                  var lowerBody = decodedBody.toLowerCase();

                  if (/\/friendships\/create(?:\/|\?|$)/i.test(lowerUrl) ||
                      /\/web\/friendships\/[^\/?#]+\/follow(?:\/|\?|$)/i.test(lowerUrl)) {
                    return !/unfollow|destroy/i.test(lowerUrl);
                  }

                  if (/\/(?:api\/)?graphql(?:\/|\?|$)/i.test(lowerUrl)) {
                    var fnameMatch = /(?:fb_api_req_friendly_name|friendlyname)["'=\s:]+([a-z0-9_]+)/i.exec(decodedBody);
                    var fname = fnameMatch ? fnameMatch[1] : '';
                    if (fname) {
                      if (/unfollow|destroy|remove|cancel|block|mute|follower|following|suggestion|recommend|list|count/i.test(fname)) {
                        return false;
                      }
                      if (/follow/i.test(fname) && /mutation|barcelona|polaris|friendship|profile|user|comet|textpost|ig/i.test(fname)) {
                        return true;
                      }
                    }
                    if (/usebarcelonafollowmutation|barcelonafollowmutation|polarisfriendshipsfollow|polarisfollowmutation|usepolarisfollowmutation|textpostappfollowmutation|friendingcometfollowmutation/i.test(lowerBody) &&
                        !/unfollow/i.test(lowerBody)) {
                      return true;
                    }
                    return false;
                  }

                  if (lowerUrl.indexOf('com.atproto.repo.createrecord') >= 0 &&
                      lowerBody.indexOf('app.bsky.graph.follow') >= 0) {
                    return true;
                  }

                  if (/\/api\/v1\/accounts\/[^\/?#]+\/follow(?:\?|$)/i.test(lowerUrl)) return true;
                  if (/\/api\/following\/create(?:\?|$)/i.test(lowerUrl)) return true;
                  if (/\/api\/commit\/follow\/user/i.test(lowerUrl) &&
                      (/[?&]type=1(?:&|$)/i.test(lowerUrl) || /(?:^|&)type=1(?:&|$)|"type"\s*:\s*1/i.test(lowerBody))) {
                    return true;
                  }
                } catch (_) {}
                return false;
              }

              try {
                var origFetch = window.fetch;
                if (typeof origFetch === 'function') {
                  window.fetch = function(input, init) {
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
                    var isFollow = isFollowApiRequest(reqUrl, reqMethod, reqBody);
                    var promise = origFetch.apply(this, arguments);
                    if (isFollow && promise && typeof promise.then === 'function') {
                      promise.then(function(res) {
                        try {
                          if (res && res.ok) emitFollow('network');
                        } catch (_) {}
                      }, function() {});
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
                      if (isFollowApiRequest(this.__omniUrl, this.__omniMethod, body)) {
                        this.addEventListener('load', function() {
                          try {
                            if (this.status >= 200 && this.status < 300) {
                              emitFollow('network');
                            }
                          } catch (_) {}
                        }, { once: true });
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
                  if (labels.text && NEGATIVE_RE.test(labels.text)) return false;
                  if (labels.aria && NEGATIVE_RE.test(labels.aria)) return false;
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
                  var target = e.target;
                  if (!target) return;
                  if (target.nodeType !== 1) target = target.parentElement;
                  if (!target || typeof target.closest !== 'function') return;
                  var btn = target.closest('button, [role="button"], a');
                  if (!btn || !isFollowButtonElement(btn)) return;

                  var clickedAt = Date.now();
                  var hadDialog = !!document.querySelector('[role="dialog"]');
                  var initialLabels = readElementLabels(btn);

                  setTimeout(function() {
                    try {
                      if (lastNetworkFollowAt >= clickedAt - 200) return;
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
                        emitFollow('dom');
                        return;
                      }
                      if (btn.getAttribute('aria-pressed') === 'true') {
                        emitFollow('dom');
                        return;
                      }
                      var after = readElementLabels(btn);
                      if ((after.text && POST_FOLLOW_STATE_RE.test(after.text)) ||
                          (after.aria && POST_FOLLOW_STATE_RE.test(after.aria))) {
                        emitFollow('dom');
                        return;
                      }
                      if ((after.text !== initialLabels.text || after.aria !== initialLabels.aria) &&
                          !isFollowButtonElement(btn)) {
                        emitFollow('dom');
                      }
                    } catch (_) {}
                  }, 650);
                } catch (_) {}
              }, true);
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
    private val initialUrl: String
    private val userAgent: String

    private var disposed = false
    private var popupDialog: Dialog? = null
    private var popupWebView: OmniWebView? = null
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
    private var lastCrashRecoveryAtMs: Long = 0L

    init {
        val requestedProfile = (creationParams["profileName"] as? String)?.trim().orEmpty()
        initialUrl = (creationParams["initialUrl"] as? String)?.trim().orEmpty()
        if (isHttpOrHttpsUrl(initialUrl)) {
            lastTargetUrl = initialUrl
        }
        userAgent = (creationParams["userAgent"] as? String)?.trim().orEmpty().ifEmpty {
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36"
        }

        val (createdWebView, resolvedProfile) = createMainWebView(requestedProfile)
        appliedProfileName = resolvedProfile
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

        val autoLoad = creationParams["autoLoad"] as? Boolean ?: false
        if (autoLoad && initialUrl.isNotEmpty()) {
            loadUrlInternal(initialUrl)
        }
    }

    private fun createMainWebView(requestedProfile: String): Pair<OmniWebView, String> {
        // 1. WebView を生成（Activity コンテキストを使用）
        val target = OmniWebView(activity)

        // 2. 【最重要】getSettings() / loadUrl() より前に独立プロファイルを割り当てる
        var resolvedProfile = Profile.DEFAULT_PROFILE_NAME
        if (manager.isMultiProfileSupported() &&
            requestedProfile.isNotEmpty() &&
            requestedProfile != Profile.DEFAULT_PROFILE_NAME
        ) {
            try {
                ProfileStore.getInstance().getOrCreateProfile(requestedProfile)
                WebViewCompat.setProfile(target, requestedProfile)
                resolvedProfile = requestedProfile
            } catch (e: Throwable) {
                Log.w(TAG, "WebViewCompat.setProfile failed for $requestedProfile: ${e.message}")
            }
        }

        // 3. プロファイル専用の CookieManager を有効化（OAuth 用サードパーティCookie含む）
        configureCookies(target, resolvedProfile)

        // 4. WebSettings / Autofill ガード / フォロー計測 / Client 設定
        configureWebViewSettings(target, userAgent, supportMultipleWindows = true)
        attachAutofillGuard(target)
        attachFollowTracker(target)
        target.applyAutofillAllowed(false)

        target.webViewClient = createMainWebViewClient()
        target.webChromeClient = createMainWebChromeClient()

        return Pair(target, resolvedProfile)
    }

    private fun replaceMainWebView() {
        val oldView = webView
        try {
            container.removeView(oldView)
        } catch (_: Throwable) {
        }
        mainHandler.post { safeDestroyWebView(oldView, removeJsBridge = true) }

        val (replacement, _) = createMainWebView(appliedProfileName)
        webView = replacement
        renderProcessCrashed = false
        container.addView(
            replacement,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    private fun configureCookies(target: WebView, profileName: String) {
        val cm = try {
            if (manager.isMultiProfileSupported() &&
                profileName.isNotEmpty() &&
                profileName != Profile.DEFAULT_PROFILE_NAME
            ) {
                ProfileStore.getInstance().getProfile(profileName)?.cookieManager
                    ?: CookieManager.getInstance()
            } else {
                CookieManager.getInstance()
            }
        } catch (_: Throwable) {
            CookieManager.getInstance()
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
            mediaPlaybackRequiresUserGesture = false
            javaScriptCanOpenWindowsAutomatically = supportMultipleWindows
            setSupportMultipleWindows(supportMultipleWindows)
            loadWithOverviewMode = true
            useWideViewPort = true
            builtInZoomControls = true
            displayZoomControls = false
            cacheMode = WebSettings.LOAD_DEFAULT
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
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
        val trimmed = url.trim()
        if (trimmed.isEmpty()) return

        if (renderProcessCrashed) {
            replaceMainWebView()
        }

        currentLoadHadMainFrameError = false
        lastFailedUrl = null
        awaitingReloadStart = false
        reloadSequence += 1
        if (isHttpOrHttpsUrl(trimmed)) {
            lastTargetUrl = trimmed
        }
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
        val targetUrl = resolveReloadTargetUrl(fallbackUrl)

        if (renderProcessCrashed) {
            replaceMainWebView()
            if (targetUrl.isNotEmpty()) {
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
            if (!disposed && !renderProcessCrashed && seq == reloadSequence && !reloadObservedProgress) {
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
    private fun attachAutofillGuard(target: OmniWebView) {
        try {
            target.addJavascriptInterface(OmniAutofillBridge(target), "OmniAutofillBridge")
        } catch (e: Throwable) {
            Log.w(TAG, "addJavascriptInterface failed: ${e.message}")
        }
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

    @SuppressLint("AddJavascriptInterface")
    private fun attachFollowTracker(target: OmniWebView) {
        try {
            target.addJavascriptInterface(
                OmniFollowBridge { source ->
                    invokeDart("onFollowDetected", mapOf("source" to source))
                },
                "OmniFollowBridge",
            )
        } catch (e: Throwable) {
            Log.w(TAG, "addJavascriptInterface(OmniFollowBridge) failed: ${e.message}")
        }
        try {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                WebViewCompat.addDocumentStartJavaScript(
                    target,
                    OmniWebViewManager.FOLLOW_TRACKER_JS,
                    setOf("*"),
                )
            }
        } catch (e: Throwable) {
            Log.w(TAG, "addDocumentStartJavaScript(FOLLOW_TRACKER_JS) failed: ${e.message}")
        }
    }

    private fun injectFollowTrackerFallback(target: WebView) {
        try {
            target.evaluateJavascript(OmniWebViewManager.FOLLOW_TRACKER_JS, null)
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

    private fun createMainWebViewClient(): WebViewClient {
        return object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?,
            ): Boolean {
                if (disposed || view == null || view !== webView) return true
                val url = request?.url?.toString() ?: return true
                val scheme = request.url?.scheme?.lowercase() ?: return true
                if (scheme == "http" || scheme == "https") {
                    return false
                }
                if (scheme == "intent") {
                    val fallback = extractIntentFallbackHttpUrl(url)
                    if (fallback != null) {
                        mainHandler.post {
                            if (!disposed) {
                                loadUrlInternal(fallback)
                            }
                        }
                    }
                    return true
                }
                if (scheme == "mailto" || scheme == "tel") {
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
                injectAutofillGuardFallback(view)
                injectFollowTrackerFallback(view)
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

                mainHandler.post {
                    if (disposed) return@post
                    replaceMainWebView()
                    if (!withinCooldown && targetUrl.isNotEmpty()) {
                        loadUrlInternal(targetUrl, bypassCache = false)
                    } else {
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
                if (request == null) return
                mainHandler.post {
                    try {
                        request.grant(request.resources)
                    } catch (_: Throwable) {
                    }
                }
            }

            override fun onGeolocationPermissionsShowPrompt(
                origin: String?,
                callback: GeolocationPermissions.Callback?,
            ) {
                if (origin == null || callback == null) return
                try {
                    callback.invoke(origin, true, true)
                } catch (_: Throwable) {
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
                if (disposed || activity.isFinishing || activity.isDestroyed) return false
                val transport = resultMsg?.obj as? WebView.WebViewTransport ?: return false

                return try {
                    closePopupAsync()

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
                    configureCookies(child, appliedProfileName)
                    configureWebViewSettings(child, userAgent, supportMultipleWindows = false)
                    child.applyAutofillAllowed(false)

                    var childClosed = false
                    var dialogShown = false
                    var autofillAttached = false
                    var localDialog: Dialog? = null

                    val titleView = TextView(activity).apply {
                        text = "認証ウィンドウ"
                        setTextColor(Color.WHITE)
                        textSize = 14f
                        maxLines = 1
                        setPadding(24, 0, 12, 0)
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
                        }
                        if (dlgToClose != null && popupDialog === dlgToClose) {
                            popupDialog = null
                        }
                        val hadBridge = autofillAttached
                        mainHandler.post {
                            safeDestroyPopup(child, dlgToClose, removeJsBridge = hadBridge)
                        }
                    }

                    fun ensurePopupDialogShown(): Boolean {
                        if (childClosed || disposed || activity.isFinishing || activity.isDestroyed) {
                            return false
                        }
                        if (dialogShown) return true
                        dialogShown = true
                        if (!autofillAttached) {
                            autofillAttached = true
                            attachAutofillGuard(child)
                        }
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
                                setPadding(8, 12, 8, 12)
                            }
                            val closeBtn = ImageButton(activity).apply {
                                setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
                                setBackgroundColor(Color.TRANSPARENT)
                                setColorFilter(Color.WHITE)
                                setOnClickListener { dismissThisPopupAsync() }
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
                            if (childClosed || disposed) return true
                            val url = request?.url?.toString() ?: return true
                            val scheme = request.url?.scheme?.lowercase() ?: return true
                            if (scheme != "http" && scheme != "https") {
                                if (scheme == "intent") {
                                    val fallback = extractIntentFallbackHttpUrl(url)
                                    if (fallback != null) {
                                        forwardToParentAndClose(fallback)
                                        return true
                                    }
                                } else if (scheme == "mailto" || scheme == "tel") {
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
                            return false
                        }

                        override fun onPageStarted(
                            popupView: WebView?,
                            url: String?,
                            favicon: android.graphics.Bitmap?,
                        ) {
                            super.onPageStarted(popupView, url, favicon)
                            if (childClosed || disposed) return
                            child.applyAutofillAllowed(false)
                            if (!url.isNullOrEmpty() && url != "about:blank") {
                                if (!isHttpOrHttpsUrl(url)) {
                                    val lower = url.trim().lowercase()
                                    if (lower.startsWith("intent://")) {
                                        val fallback = extractIntentFallbackHttpUrl(url)
                                        if (fallback != null) {
                                            forwardToParentAndClose(fallback)
                                            return
                                        }
                                    } else if (lower.startsWith("mailto:") || lower.startsWith("tel:")) {
                                        invokeDart("onExternalScheme", mapOf("url" to url))
                                    }
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
                                titleView.text = url
                            }
                        }

                        override fun onPageFinished(popupView: WebView?, url: String?) {
                            super.onPageFinished(popupView, url)
                            if (childClosed || disposed) return
                            if (popupView != null) {
                                injectAutofillGuardFallback(popupView)
                                if (!popupView.title.isNullOrEmpty()) {
                                    titleView.text = popupView.title
                                }
                            }
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
                            if (childClosed || disposed) return
                            if (!title.isNullOrEmpty()) {
                                titleView.text = title
                            }
                        }

                        override fun onCloseWindow(window: WebView?) {
                            dismissThisPopupAsync()
                        }
                    }

                    popupWebView = child
                    if (isDialog) {
                        ensurePopupDialogShown()
                    } else {
                        // 遷移せず不可視のまま残った about:blank ポップアップを自動回収する
                        mainHandler.postDelayed({
                            if (!childClosed && !dialogShown) {
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
        channel.setMethodCallHandler(null)
        exitFullscreenIfActive()
        closePopupNow()
        try {
            container.removeAllViews()
        } catch (_: Throwable) {
        }
        if (::webView.isInitialized) {
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
            else -> result.notImplemented()
        }
    }
}
