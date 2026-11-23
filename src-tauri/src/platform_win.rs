#![cfg(windows)]

use std::ptr::copy_nonoverlapping;
use std::sync::Arc;

use webview2_com::Microsoft::Web::WebView2::Win32::{
    GetAvailableCoreWebView2BrowserVersionString, ICoreWebView2, ICoreWebView2Controller,
    ICoreWebView2Settings2, ICoreWebView2_13, ICoreWebView2_15, ICoreWebView2_8,
    ICoreWebView2Profile2, COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN,
    COREWEBVIEW2_KEY_EVENT_KIND_SYSTEM_KEY_DOWN, COREWEBVIEW2_WEB_ERROR_STATUS,
    COREWEBVIEW2_WEB_ERROR_STATUS_CANNOT_CONNECT,
    COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_COMMON_NAME_IS_INCORRECT,
    COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_EXPIRED,
    COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_IS_INVALID,
    COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_REVOKED,
    COREWEBVIEW2_WEB_ERROR_STATUS_CLIENT_CERTIFICATE_CONTAINS_ERRORS,
    COREWEBVIEW2_WEB_ERROR_STATUS_CONNECTION_ABORTED,
    COREWEBVIEW2_WEB_ERROR_STATUS_CONNECTION_RESET,
    COREWEBVIEW2_WEB_ERROR_STATUS_DISCONNECTED,
    COREWEBVIEW2_WEB_ERROR_STATUS_ERROR_HTTP_INVALID_SERVER_RESPONSE,
    COREWEBVIEW2_WEB_ERROR_STATUS_HOST_NAME_NOT_RESOLVED,
    COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED,
    COREWEBVIEW2_WEB_ERROR_STATUS_REDIRECT_FAILED,
    COREWEBVIEW2_WEB_ERROR_STATUS_SERVER_UNREACHABLE,
    COREWEBVIEW2_WEB_ERROR_STATUS_TIMEOUT,
    COREWEBVIEW2_WEB_ERROR_STATUS_UNEXPECTED_ERROR,
    COREWEBVIEW2_WEB_ERROR_STATUS_VALID_AUTHENTICATION_CREDENTIALS_REQUIRED,
    COREWEBVIEW2_WEB_ERROR_STATUS_VALID_PROXY_AUTHENTICATION_REQUIRED,
};
use webview2_com::{
    take_pwstr, AcceleratorKeyPressedEventHandler,
    AddScriptToExecuteOnDocumentCreatedCompletedHandler,
    CallDevToolsProtocolMethodCompletedHandler, ClearBrowsingDataCompletedHandler,
    ExecuteScriptCompletedHandler, FaviconChangedEventHandler, HistoryChangedEventHandler,
    NavigationCompletedEventHandler, NavigationStartingEventHandler, SourceChangedEventHandler,
    WebMessageReceivedEventHandler, ZoomFactorChangedEventHandler,
};
use windows::Win32::Foundation::{FALSE, HANDLE, HGLOBAL, HWND};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_UNICODETEXT;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetKeyState, VK_CONTROL, VK_MENU, VK_SHIFT};
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::{
    SetWindowPos, HWND_TOP, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOOWNERZORDER, SWP_NOSIZE,
    SW_SHOWNORMAL,
};
use windows_core::{BOOL, Interface, HSTRING, PCWSTR, PWSTR};

use crate::url_utils::is_http_url;

/// インストール済み WebView2 Runtime のバージョン（例: "136.0.3240.76"）を取得する。
pub fn get_webview2_version() -> String {
    let mut version_pwstr = PWSTR::null();
    let res = unsafe {
        GetAvailableCoreWebView2BrowserVersionString(PCWSTR::null(), &mut version_pwstr)
    };
    if res.is_ok() {
        let raw = take_pwstr(version_pwstr);
        // 末尾にチャネル名等が付く場合は先頭トークンだけ取り出す
        let token = raw.split_whitespace().next().unwrap_or("").trim();
        if !token.is_empty() {
            return token.to_string();
        }
    }
    "136.0.0.0".to_string()
}

/// テキストを Windows クリップボード（UTF-16 / CF_UNICODETEXT）へコピーする。
pub fn copy_text_to_clipboard(text: &str) {
    let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    let byte_len = wide.len() * std::mem::size_of::<u16>();

    unsafe {
        if OpenClipboard(None).is_err() {
            return;
        }
        let _ = EmptyClipboard();

        if let Ok(hmem) = GlobalAlloc(GMEM_MOVEABLE, byte_len) {
            let ptr = GlobalLock(hmem);
            if !ptr.is_null() {
                copy_nonoverlapping(wide.as_ptr(), ptr as *mut u16, wide.len());
                let _ = GlobalUnlock(hmem);
                let _ = SetClipboardData(CF_UNICODETEXT.0 as u32, Some(HANDLE(hmem.0)));
            } else {
                let _: HGLOBAL = hmem;
            }
        }

        let _ = CloseClipboard();
    }
}

/// 安全な http/https URL のみを Windows 既定ブラウザで開く。
pub fn open_external_url(url: &str) {
    if !is_http_url(url) {
        return;
    }
    let verb = HSTRING::from("open");
    let target = HSTRING::from(url);
    unsafe {
        ShellExecuteW(
            None,
            &verb,
            &target,
            PCWSTR::null(),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        );
    }
}

/// 子WebViewのWin32コンテナウィンドウをZオーダー最前面に配置する。
pub fn bring_controller_to_top(controller: &ICoreWebView2Controller) {
    unsafe {
        let mut parent = HWND::default();
        if controller.ParentWindow(&mut parent).is_ok() && !parent.0.is_null() {
            let _ = SetWindowPos(
                parent,
                Some(HWND_TOP),
                0,
                0,
                0,
                0,
                SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOOWNERZORDER | SWP_NOSIZE,
            );
        }
    }
}

pub fn set_muted(controller: &ICoreWebView2Controller, muted: bool) {
    unsafe {
        if let Ok(wv) = controller.CoreWebView2() {
            if let Ok(wv8) = wv.cast::<ICoreWebView2_8>() {
                let _ = wv8.SetIsMuted(muted);
            }
        }
    }
}

pub fn set_zoom_factor(controller: &ICoreWebView2Controller, zoom: f64) {
    unsafe {
        let _ = controller.SetZoomFactor(zoom);
    }
}

pub fn go_back(controller: &ICoreWebView2Controller) {
    unsafe {
        if let Ok(wv) = controller.CoreWebView2() {
            let mut can = FALSE;
            if wv.CanGoBack(&mut can).is_ok() && can.as_bool() {
                let _ = wv.GoBack();
            }
        }
    }
}

pub fn go_forward(controller: &ICoreWebView2Controller) {
    unsafe {
        if let Ok(wv) = controller.CoreWebView2() {
            let mut can = FALSE;
            if wv.CanGoForward(&mut can).is_ok() && can.as_bool() {
                let _ = wv.GoForward();
            }
        }
    }
}

pub fn reload(controller: &ICoreWebView2Controller, hard: bool) {
    unsafe {
        if let Ok(wv) = controller.CoreWebView2() {
            if hard {
                let method = HSTRING::from("Page.reload");
                let params = HSTRING::from("{\"ignoreCache\":true}");
                let handler =
                    CallDevToolsProtocolMethodCompletedHandler::create(Box::new(|_, _| Ok(())));
                if wv
                    .CallDevToolsProtocolMethod(&method, &params, &handler)
                    .is_err()
                {
                    let _ = wv.Reload();
                }
            } else {
                let _ = wv.Reload();
            }
        }
    }
}

pub fn navigate(controller: &ICoreWebView2Controller, url: &str) {
    unsafe {
        if let Ok(wv) = controller.CoreWebView2() {
            let target = HSTRING::from(url);
            let _ = wv.Navigate(&target);
        }
    }
}

pub fn set_user_agent_and_reload(controller: &ICoreWebView2Controller, ua: &str) {
    unsafe {
        if let Ok(wv) = controller.CoreWebView2() {
            if let Ok(settings) = wv.Settings() {
                if let Ok(settings2) = settings.cast::<ICoreWebView2Settings2>() {
                    let ua_h = HSTRING::from(ua);
                    let _ = settings2.SetUserAgent(&ua_h);
                }
            }
        }
    }
    reload(controller, true);
}

pub fn open_devtools(controller: &ICoreWebView2Controller) {
    unsafe {
        if let Ok(wv) = controller.CoreWebView2() {
            if let Ok(settings) = wv.Settings() {
                let _ = settings.SetAreDevToolsEnabled(true);
            }
            let _ = wv.OpenDevToolsWindow();
        }
    }
}

pub fn clear_browsing_data_and_navigate(controller: &ICoreWebView2Controller, home_url: String) {
    unsafe {
        if let Ok(wv) = controller.CoreWebView2() {
            let wv_clone = wv.clone();
            if let Ok(wv13) = wv.cast::<ICoreWebView2_13>() {
                if let Ok(profile) = wv13.Profile() {
                    if let Ok(profile2) = profile.cast::<ICoreWebView2Profile2>() {
                        let home_url_cb = home_url.clone();
                        let handler = ClearBrowsingDataCompletedHandler::create(Box::new(
                            move |_err| {
                                let target = HSTRING::from(home_url_cb.as_str());
                                let _ = wv_clone.Navigate(&target);
                                Ok(())
                            },
                        ));
                        if profile2.ClearBrowsingDataAll(&handler).is_ok() {
                            return;
                        }
                    }
                }
            }
            let target = HSTRING::from(home_url.as_str());
            let _ = wv.Navigate(&target);
        }
    }
}

/// CDP `Input.dispatchMouseEvent` で指定 DIP 座標（ZoomFactor 補正済み CSS 座標）に
/// Ctrl+左クリック（modifiers: 2）を送信する。
/// カーソル移動や OS の Ctrl キー状態を汚さずに、ジェスチャー開始位置のリンクを別タブで開ける。
pub fn dispatch_ctrl_click(
    controller: &ICoreWebView2Controller,
    dip_x: f64,
    dip_y: f64,
) {
    if !dip_x.is_finite() || !dip_y.is_finite() {
        return;
    }
    unsafe {
        let mut zoom = 1.0_f64;
        let _ = controller.ZoomFactor(&mut zoom);
        let z = if zoom.is_finite() && zoom > 0.05 {
            zoom
        } else {
            1.0
        };
        let x = (dip_x / z).max(0.0);
        let y = (dip_y / z).max(0.0);
        let Ok(wv) = controller.CoreWebView2() else {
            return;
        };
        let method = HSTRING::from("Input.dispatchMouseEvent");
        let move_params = HSTRING::from(format!(
            "{{\"type\":\"mouseMoved\",\"x\":{x:.1},\"y\":{y:.1},\"modifiers\":2,\"pointerType\":\"mouse\"}}"
        ));
        let down_params = HSTRING::from(format!(
            "{{\"type\":\"mousePressed\",\"x\":{x:.1},\"y\":{y:.1},\"button\":\"left\",\"buttons\":1,\"clickCount\":1,\"modifiers\":2,\"pointerType\":\"mouse\"}}"
        ));
        let up_params = HSTRING::from(format!(
            "{{\"type\":\"mouseReleased\",\"x\":{x:.1},\"y\":{y:.1},\"button\":\"left\",\"buttons\":0,\"clickCount\":1,\"modifiers\":2,\"pointerType\":\"mouse\"}}"
        ));

        let wv_for_down = wv.clone();
        let method_down = method.clone();
        let move_handler = CallDevToolsProtocolMethodCompletedHandler::create(Box::new(
            move |_, _| {
                let wv_for_up = wv_for_down.clone();
                let method_up = method_down.clone();
                let up_params_c = up_params.clone();
                let down_handler = CallDevToolsProtocolMethodCompletedHandler::create(Box::new(
                    move |_, _| {
                        let up_handler = CallDevToolsProtocolMethodCompletedHandler::create(
                            Box::new(|_, _| Ok(())),
                        );
                        let _ = wv_for_up.CallDevToolsProtocolMethod(
                            &method_up,
                            &up_params_c,
                            &up_handler,
                        );
                        Ok(())
                    },
                ));
                let _ = wv_for_down.CallDevToolsProtocolMethod(
                    &method_down,
                    &down_params,
                    &down_handler,
                );
                Ok(())
            },
        ));
        let _ = wv.CallDevToolsProtocolMethod(&method, &move_params, &move_handler);
    }
}

/// CDP `Input.dispatchMouseEvent` (mouseWheel) で指定 DIP 座標（ZoomFactor 補正済み CSS 座標）下の要素を滑らかにスクロールする。
/// メインページだけでなく X / Discord / Instagram 等の内側スクロール領域にも自然に効く。
pub fn dispatch_wheel_scroll(
    controller: &ICoreWebView2Controller,
    dip_x: f64,
    dip_y: f64,
    delta_x: f64,
    delta_y: f64,
) {
    if !delta_x.is_finite() || !delta_y.is_finite() {
        return;
    }
    unsafe {
        let mut zoom = 1.0_f64;
        let _ = controller.ZoomFactor(&mut zoom);
        let z = if zoom.is_finite() && zoom > 0.05 {
            zoom
        } else {
            1.0
        };
        let x = (dip_x / z).max(0.0);
        let y = (dip_y / z).max(0.0);
        let params = format!(
            "{{\"type\":\"mouseWheel\",\"x\":{x:.1},\"y\":{y:.1},\"deltaX\":{delta_x:.2},\"deltaY\":{delta_y:.2}}}"
        );
        if let Ok(wv) = controller.CoreWebView2() {
            let method = HSTRING::from("Input.dispatchMouseEvent");
            let params_h = HSTRING::from(params.as_str());
            let handler =
                CallDevToolsProtocolMethodCompletedHandler::create(Box::new(|_, _| Ok(())));
            let _ = wv.CallDevToolsProtocolMethod(&method, &params_h, &handler);
        }
    }
}

/// ページ最上部または最下部へスクロールする（内側スクロールコンテナ対応 — HisatorNotebook page_scroll_js 準拠）。
pub fn scroll_to_edge(controller: &ICoreWebView2Controller, to_top: bool) {
    let target = if to_top { "0" } else { "el.scrollHeight" };
    let inner_target = if to_top { "0" } else { "b.scrollHeight" };
    let js = format!(
        "(function(){{\
        function inner(){{var best=null,bs=0;\
          var all=document.querySelectorAll('div,main,section,article,ul');\
          for(var i=0;i<all.length&&i<3000;i++){{var e=all[i],st;\
            try{{st=getComputedStyle(e);}}catch(x){{continue;}}\
            if(!st||(st.overflowY!=='auto'&&st.overflowY!=='scroll'))continue;\
            var d=e.scrollHeight-e.clientHeight;\
            if(d>bs&&d>40&&e.clientHeight>120){{bs=d;best=e;}}}}\
          return best;}}\
        function go(el,t){{try{{el.scrollTo({{top:t,behavior:'smooth'}});}}catch(x){{el.scrollTop=t;}}}}\
        var el=document.scrollingElement||document.documentElement||document.body;\
        var before=Math.round(el.scrollTop||window.scrollY||0);\
        go(el,{target});\
        setTimeout(function(){{\
          var after=Math.round(el.scrollTop||window.scrollY||0);\
          if(after===before){{var b=inner();if(b)go(b,{inner_target});}}\
        }},40);\
        }})();"
    );
    unsafe {
        if let Ok(wv) = controller.CoreWebView2() {
            let js_h = HSTRING::from(js.as_str());
            let handler = ExecuteScriptCompletedHandler::create(Box::new(|_, _| Ok(())));
            let _ = wv.ExecuteScript(&js_h, &handler);
        }
    }
}

pub struct TabWebviewCallbacks {
    pub on_navigation_starting: Arc<dyn Fn() + Send + Sync>,
    pub on_navigation_completed: Arc<dyn Fn(bool, Option<String>, String, bool, bool) + Send + Sync>,
    pub on_nav_flags_changed: Arc<dyn Fn(String, bool, bool) + Send + Sync>,
    pub on_favicon_changed: Arc<dyn Fn(String) + Send + Sync>,
    pub on_zoom_factor_changed: Arc<dyn Fn(f64) + Send + Sync>,
    pub on_shortcut: Arc<dyn Fn(&'static str, Option<usize>) + Send + Sync>,
    pub on_follow_detected: Arc<dyn Fn() + Send + Sync>,
}

/// Threads / Instagram / Bluesky / mixi2 等のフォロー操作を自動検知してホストへ通知するスクリプト。
const FOLLOW_TRACKER_JS: &str = r#"(function() {
  if (window !== window.top) return;
  if (window.__omniFollowTrackerInstalled) return;
  window.__omniFollowTrackerInstalled = true;

  var NEGATIVE_RE = /(フォロー中|フォロー済|フォロー解除|フォロワー|リクエスト済|リクエスト中|承認待ち|解除|following|unfollow|followers|requested|pending|remove|cancel|block|mute)/i;
  var EXACT_FOLLOW_TEXT_RE = /^(?:[+＋]\s*)?(?:フォロー|フォローする|フォローバック|フォローバックする|フォローを返す|follow|follow\s+back)$/i;
  var ARIA_FOLLOW_RE = /^(?:(?:[+＋]\s*)?(?:フォロー|フォローする|フォローバック|follow|follow\s+back)|.+?(?:をフォロー|をフォローする|をフォローバック)|follow\s+@?[\w.\-\u3040-\u30ff\u4e00-\u9faf]+.*)$/i;
  var POST_FOLLOW_STATE_RE = /(フォロー中|フォロー済|フォロー解除|リクエスト済|リクエスト中|承認待ち|following|unfollow|requested|pending|チェック|check)/i;

  var lastNetworkFollowStartAt = 0;
  var lastNetworkFollowAt = 0;
  var lastDomEmitAt = 0;
  var lastAnyEmitAt = 0;
  var inFlightFollows = 0;
  var recentTargetKeys = Object.create(null);
  var userInteractionSeq = 0;
  var lastUserInteractionAt = 0;
  var lastPointerDownAt = 0;
  var emittedInteractions = Object.create(null);

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

  function emitFollow(source, targetKey, interactionId) {
    var now = Date.now();
    if (interactionId && interactionId > 0) {
      for (var ik in emittedInteractions) {
        if (now - emittedInteractions[ik] > 15000) delete emittedInteractions[ik];
      }
      if (emittedInteractions[interactionId]) {
        if (source === 'network') {
          lastNetworkFollowAt = now;
          if (targetKey) recentTargetKeys[targetKey] = now;
        }
        return;
      }
    }
    if (targetKey) {
      for (var k in recentTargetKeys) {
        if (now - recentTargetKeys[k] > 15000) delete recentTargetKeys[k];
      }
      if (recentTargetKeys[targetKey] && now - recentTargetKeys[targetKey] < 5000) {
        return;
      }
    }
    if (source === 'network') {
      if (now - lastDomEmitAt < 2500) {
        lastNetworkFollowAt = now;
        if (targetKey) recentTargetKeys[targetKey] = now;
        if (interactionId && interactionId > 0) emittedInteractions[interactionId] = now;
        return;
      }
      if (!targetKey && now - lastAnyEmitAt < 1200) {
        lastNetworkFollowAt = now;
        return;
      }
      lastNetworkFollowAt = now;
      lastAnyEmitAt = now;
      if (targetKey) recentTargetKeys[targetKey] = now;
      if (interactionId && interactionId > 0) emittedInteractions[interactionId] = now;
    } else {
      if (now - lastAnyEmitAt < 2500) return;
      lastDomEmitAt = now;
      lastAnyEmitAt = now;
      if (interactionId && interactionId > 0) emittedInteractions[interactionId] = now;
    }
    try {
      if (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function') {
        window.chrome.webview.postMessage(JSON.stringify({ type: 'omnisns:follow', source: source || 'auto' }));
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
      var m = /\/friendships\/create\/([^\/?#]+)/i.exec(url) ||
              /\/web\/friendships\/([^\/?#]+)\/follow/i.exec(url) ||
              /\/api\/v1\/accounts\/([^\/?#]+)\/follow/i.exec(url);
      if (m && m[1]) return String(m[1]).trim().toLowerCase();

      // 相手IDを示す明示キーを優先（viewerの user_id を誤って先に拾わない）
      m = /"(?:target_user_id|targetUserId|to_user_id|subscribee_id|subject)"\s*:\s*"?([a-z0-9:._-]+)"?/i.exec(decodedBody) ||
          /(?:^|&)(?:target_user_id|to_user_id)=([a-z0-9._-]+)/i.exec(decodedBody);
      if (m && m[1]) return String(m[1]).trim().toLowerCase();

      m = /"(?:user_id|profile_id|userId)"\s*:\s*"?([a-z0-9:._-]+)"?/i.exec(decodedBody) ||
          /(?:^|&)user_id=([a-z0-9._-]+)/i.exec(decodedBody) ||
          /[?&]user_id=([a-z0-9._-]+)/i.exec(url);
      if (m && m[1]) return String(m[1]).trim().toLowerCase();
    } catch (_) {}
    return '';
  }

  function detectFollowApiRequest(rawUrl, method, rawBody) {
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

      if (/\/friendships\/create(?:\/|\?|$)/i.test(lowerUrl) ||
          /\/web\/friendships\/[^\/?#]+\/follow(?:\/|\?|$)/i.test(lowerUrl)) {
        if (!/unfollow|destroy/i.test(lowerUrl)) {
          return { targetKey: extractTargetKey(url, decodedBody) };
        }
        return null;
      }

      if (/\/(?:api\/)?graphql(?:\/|\?|$)/i.test(lowerUrl)) {
        var fnameMatch = /(?:fb_api_req_friendly_name|friendlyname)["'=\s:]+([a-z0-9_]+)/i.exec(decodedBody);
        var fname = fnameMatch ? fnameMatch[1] : '';
        if (fname) {
          if (/unfollow|destroy|remove|cancel|block|mute|follower|following|suggestion|recommend|list|count|query|fetch|load|get|status|info|chaining|similar|show|check|batch|many|bulk|sync|refresh|feed|timeline|modal|dialog|sheet/i.test(fname)) {
            return null;
          }
          if (/follow/i.test(fname) && /(?:mutation|create|add)/i.test(fname)) {
            return { targetKey: extractTargetKey(url, decodedBody) };
          }
          return null;
        }
        if (/usebarcelonafollowmutation|barcelonafollowmutation|polarisfriendshipsfollow|polarisfollowmutation|usepolarisfollowmutation|polarisuserfollowmutation|igwebprofilefollowmutation|textpostappfollowmutation|friendingcometfollowmutation/i.test(lowerBody) &&
            !/unfollow|destroy/i.test(lowerBody)) {
          return { targetKey: extractTargetKey(url, decodedBody) };
        }
        return null;
      }

      if (lowerUrl.indexOf('com.atproto.repo.createrecord') >= 0 &&
          lowerBody.indexOf('app.bsky.graph.follow') >= 0) {
        return { targetKey: extractTargetKey(url, decodedBody) };
      }

      if (/\/api\/v1\/accounts\/[^\/?#]+\/follow(?:\?|$)/i.test(lowerUrl)) {
        return { targetKey: extractTargetKey(url, decodedBody) };
      }
      if (/\/api\/following\/create(?:\?|$)/i.test(lowerUrl)) {
        return { targetKey: extractTargetKey(url, decodedBody) };
      }
      if (/\/api\/commit\/follow\/user/i.test(lowerUrl) &&
          (/[?&]type=1(?:&|$)/i.test(lowerUrl) || /(?:^|&)type=1(?:&|$)|"type"\s*:\s*1/i.test(lowerBody))) {
        return { targetKey: extractTargetKey(url, decodedBody) };
      }
    } catch (_) {}
    return null;
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
        var followReq = detectFollowApiRequest(reqUrl, reqMethod, reqBody);
        var reqInteractionId = 0;
        if (followReq) {
          lastNetworkFollowStartAt = Date.now();
          inFlightFollows++;
          reqInteractionId = currentInteractionId();
        }
        var promise = origFetch.apply(this, arguments);
        if (followReq && promise && typeof promise.then === 'function') {
          promise.then(function(res) {
            inFlightFollows = Math.max(0, inFlightFollows - 1);
            try {
              if (res && res.ok) emitFollow('network', followReq.targetKey, reqInteractionId);
            } catch (_) {}
          }, function() {
            inFlightFollows = Math.max(0, inFlightFollows - 1);
          });
        } else if (followReq) {
          inFlightFollows = Math.max(0, inFlightFollows - 1);
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
          var followReq = detectFollowApiRequest(this.__omniUrl, this.__omniMethod, body);
          if (followReq) {
            lastNetworkFollowStartAt = Date.now();
            inFlightFollows++;
            var reqInteractionId = currentInteractionId();
            var done = false;
            var finish = function() {
              if (!done) {
                done = true;
                inFlightFollows = Math.max(0, inFlightFollows - 1);
              }
            };
            this.addEventListener('load', function() {
              finish();
              try {
                if (this.status >= 200 && this.status < 300) {
                  emitFollow('network', followReq.targetKey, reqInteractionId);
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
      if (e && (e.isTrusted === false || e.button !== 0 || e.ctrlKey || e.metaKey)) return;
      bumpUserInteraction(false);
      var clickInteractionId = currentInteractionId();
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
          if (inFlightFollows > 0 ||
              lastNetworkFollowStartAt >= clickedAt - 300 ||
              lastNetworkFollowAt >= clickedAt - 300 ||
              lastAnyEmitAt >= clickedAt - 300) {
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
            emitFollow('dom', '', clickInteractionId);
            return;
          }
          if (btn.getAttribute('aria-pressed') === 'true') {
            emitFollow('dom', '', clickInteractionId);
            return;
          }
          var after = readElementLabels(btn);
          if ((after.text && POST_FOLLOW_STATE_RE.test(after.text)) ||
              (after.aria && POST_FOLLOW_STATE_RE.test(after.aria))) {
            emitFollow('dom', '', clickInteractionId);
            return;
          }
          if ((after.text !== initialLabels.text || after.aria !== initialLabels.aria) &&
              !isFollowButtonElement(btn)) {
            emitFollow('dom', '', clickInteractionId);
          }
        } catch (_) {}
      }, 1000);
    } catch (_) {}
  }, true);
})();"#;

fn read_nav_snapshot(wv: &ICoreWebView2) -> (String, bool, bool) {
    unsafe {
        let mut src = PWSTR::null();
        let url = if wv.Source(&mut src).is_ok() {
            take_pwstr(src)
        } else {
            String::new()
        };
        let mut back: BOOL = FALSE;
        let mut fwd: BOOL = FALSE;
        let _ = wv.CanGoBack(&mut back);
        let _ = wv.CanGoForward(&mut fwd);
        (url, back.as_bool(), fwd.as_bool())
    }
}

fn format_web_error_status(status: COREWEBVIEW2_WEB_ERROR_STATUS) -> &'static str {
    match status {
        COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_COMMON_NAME_IS_INCORRECT => {
            "ERR_CERT_COMMON_NAME_INVALID"
        }
        COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_EXPIRED => "ERR_CERT_DATE_INVALID",
        COREWEBVIEW2_WEB_ERROR_STATUS_CLIENT_CERTIFICATE_CONTAINS_ERRORS => {
            "ERR_BAD_SSL_CLIENT_AUTH_CERT"
        }
        COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_REVOKED => "ERR_CERT_REVOKED",
        COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_IS_INVALID => "ERR_CERT_INVALID",
        COREWEBVIEW2_WEB_ERROR_STATUS_SERVER_UNREACHABLE => "ERR_ADDRESS_UNREACHABLE",
        COREWEBVIEW2_WEB_ERROR_STATUS_TIMEOUT => "ERR_TIMED_OUT",
        COREWEBVIEW2_WEB_ERROR_STATUS_ERROR_HTTP_INVALID_SERVER_RESPONSE => {
            "ERR_INVALID_HTTP_RESPONSE"
        }
        COREWEBVIEW2_WEB_ERROR_STATUS_CONNECTION_ABORTED => "ERR_CONNECTION_ABORTED",
        COREWEBVIEW2_WEB_ERROR_STATUS_CONNECTION_RESET => "ERR_CONNECTION_RESET",
        COREWEBVIEW2_WEB_ERROR_STATUS_DISCONNECTED => "ERR_INTERNET_DISCONNECTED",
        COREWEBVIEW2_WEB_ERROR_STATUS_CANNOT_CONNECT => "ERR_CONNECTION_REFUSED",
        COREWEBVIEW2_WEB_ERROR_STATUS_HOST_NAME_NOT_RESOLVED => "ERR_NAME_NOT_RESOLVED",
        COREWEBVIEW2_WEB_ERROR_STATUS_REDIRECT_FAILED => "ERR_TOO_MANY_REDIRECTS",
        COREWEBVIEW2_WEB_ERROR_STATUS_UNEXPECTED_ERROR => "ERR_UNEXPECTED",
        COREWEBVIEW2_WEB_ERROR_STATUS_VALID_AUTHENTICATION_CREDENTIALS_REQUIRED => {
            "ERR_AUTH_REQUIRED"
        }
        COREWEBVIEW2_WEB_ERROR_STATUS_VALID_PROXY_AUTHENTICATION_REQUIRED => {
            "ERR_PROXY_AUTH_REQUIRED"
        }
        _ => "ERR_FAILED",
    }
}

/// SNSタブ子WebView2へネイティブイベントハンドラ（ナビゲーション・ファビコン・ミュート・ショートカット等）を接続する。
pub fn attach_tab_handlers(
    controller: &ICoreWebView2Controller,
    initial_muted: bool,
    initial_zoom: f64,
    initial_ua: &str,
    callbacks: TabWebviewCallbacks,
) {
    unsafe {
        let _ = controller.SetZoomFactor(initial_zoom);

        let Ok(wv) = controller.CoreWebView2() else {
            return;
        };

        if let Ok(settings) = wv.Settings() {
            let _ = settings.SetAreDevToolsEnabled(true);
            let _ = settings.SetAreDefaultContextMenusEnabled(true);
            let _ = settings.SetAreDefaultScriptDialogsEnabled(true);
            let _ = settings.SetIsStatusBarEnabled(false);
            let _ = settings.SetIsWebMessageEnabled(true);
            if let Ok(settings2) = settings.cast::<ICoreWebView2Settings2>() {
                let ua_h = HSTRING::from(initial_ua);
                let _ = settings2.SetUserAgent(&ua_h);
            }
        }

        // フォロー検知スクリプトをドキュメント生成前に注入し、WebMessage で受信する
        {
            let script_h = HSTRING::from(FOLLOW_TRACKER_JS);
            let add_handler =
                AddScriptToExecuteOnDocumentCreatedCompletedHandler::create(Box::new(|_, _| Ok(())));
            let _ = wv.AddScriptToExecuteOnDocumentCreated(&script_h, &add_handler);
            let exec_handler = ExecuteScriptCompletedHandler::create(Box::new(|_, _| Ok(())));
            let _ = wv.ExecuteScript(&script_h, &exec_handler);

            let cb = callbacks.on_follow_detected.clone();
            let mut token = Default::default();
            let _ = wv.add_WebMessageReceived(
                &WebMessageReceivedEventHandler::create(Box::new(move |_, args| {
                    if let Some(args) = args {
                        let mut raw = PWSTR::null();
                        if args.TryGetWebMessageAsString(&mut raw).is_ok() {
                            let msg = take_pwstr(raw);
                            if msg.contains("\"omnisns:follow\"") {
                                cb();
                            }
                        }
                    }
                    Ok(())
                })),
                &mut token,
            );
        }

        if let Ok(wv8) = wv.cast::<ICoreWebView2_8>() {
            let _ = wv8.SetIsMuted(initial_muted);
        }

        // 1. NavigationStarting
        {
            let cb = callbacks.on_navigation_starting.clone();
            let mut token = Default::default();
            let _ = wv.add_NavigationStarting(
                &NavigationStartingEventHandler::create(Box::new(move |_, _| {
                    cb();
                    Ok(())
                })),
                &mut token,
            );
        }

        // 2. NavigationCompleted
        {
            let cb = callbacks.on_navigation_completed.clone();
            let mut token = Default::default();
            let _ = wv.add_NavigationCompleted(
                &NavigationCompletedEventHandler::create(Box::new(move |sender, args| {
                    let Some(wv) = sender else {
                        return Ok(());
                    };
                    let (url, can_back, can_fwd) = read_nav_snapshot(&wv);

                    let mut is_success = BOOL(1);
                    let mut error_status = COREWEBVIEW2_WEB_ERROR_STATUS::default();
                    if let Some(args) = args {
                        let _ = args.IsSuccess(&mut is_success);
                        let _ = args.WebErrorStatus(&mut error_status);
                    }

                    if !is_success.as_bool() {
                        // ERR_ABORTED 相当のリダイレクト・SPA遷移キャンセルは無視する
                        if error_status == COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED {
                            cb(true, None, url, can_back, can_fwd);
                        } else {
                            let label = format_web_error_status(error_status);
                            let detail = format!("{label} ({}) — {url}", error_status.0);
                            cb(false, Some(detail), url, can_back, can_fwd);
                        }
                    } else {
                        cb(true, None, url, can_back, can_fwd);
                    }
                    Ok(())
                })),
                &mut token,
            );
        }

        // 3. HistoryChanged (SPA遷移・戻る/進む状態同期)
        {
            let cb = callbacks.on_nav_flags_changed.clone();
            let mut token = Default::default();
            let _ = wv.add_HistoryChanged(
                &HistoryChangedEventHandler::create(Box::new(move |sender, _| {
                    if let Some(wv) = sender {
                        let (url, can_back, can_fwd) = read_nav_snapshot(&wv);
                        cb(url, can_back, can_fwd);
                    }
                    Ok(())
                })),
                &mut token,
            );
        }

        // 4. SourceChanged
        {
            let cb = callbacks.on_nav_flags_changed.clone();
            let mut token = Default::default();
            let _ = wv.add_SourceChanged(
                &SourceChangedEventHandler::create(Box::new(move |sender, _| {
                    if let Some(wv) = sender {
                        let (url, can_back, can_fwd) = read_nav_snapshot(&wv);
                        cb(url, can_back, can_fwd);
                    }
                    Ok(())
                })),
                &mut token,
            );
        }

        // 5. FaviconChanged (ICoreWebView2_15)
        if let Ok(wv15) = wv.cast::<ICoreWebView2_15>() {
            let cb = callbacks.on_favicon_changed.clone();
            let mut token = Default::default();
            let _ = wv15.add_FaviconChanged(
                &FaviconChangedEventHandler::create(Box::new(move |sender, _| {
                    if let Some(wv) = sender {
                        if let Ok(wv15) = wv.cast::<ICoreWebView2_15>() {
                            let mut uri = PWSTR::null();
                            if wv15.FaviconUri(&mut uri).is_ok() {
                                let favicon = take_pwstr(uri);
                                if !favicon.is_empty() {
                                    cb(favicon);
                                }
                            }
                        }
                    }
                    Ok(())
                })),
                &mut token,
            );
        }

        // 5.5 ZoomFactorChanged (Ctrl+ホイール等のネイティブズームをツールバー＆設定と同期)
        {
            let cb = callbacks.on_zoom_factor_changed.clone();
            let mut token = Default::default();
            let _ = controller.add_ZoomFactorChanged(
                &ZoomFactorChangedEventHandler::create(Box::new(move |sender, _| {
                    if let Some(ctrl) = sender {
                        let mut zoom = 1.0_f64;
                        if ctrl.ZoomFactor(&mut zoom).is_ok() && zoom.is_finite() {
                            cb(zoom);
                        }
                    }
                    Ok(())
                })),
                &mut token,
            );
        }

        // 6. AcceleratorKeyPressed (SNSフォーカス中でも Ctrl+K / Ctrl+1..9 / Ctrl+Alt+1..9 等を捕捉)
        {
            let cb = callbacks.on_shortcut.clone();
            let mut token = Default::default();
            let _ = controller.add_AcceleratorKeyPressed(
                &AcceleratorKeyPressedEventHandler::create(Box::new(move |_, args| {
                    let Some(args) = args else {
                        return Ok(());
                    };
                    let mut kind = Default::default();
                    if args.KeyEventKind(&mut kind).is_err() {
                        return Ok(());
                    }
                    if kind != COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN
                        && kind != COREWEBVIEW2_KEY_EVENT_KIND_SYSTEM_KEY_DOWN
                    {
                        return Ok(());
                    }

                    let ctrl = GetKeyState(VK_CONTROL.0 as i32) < 0;
                    if !ctrl {
                        return Ok(());
                    }
                    let shift = GetKeyState(VK_SHIFT.0 as i32) < 0;
                    let alt = GetKeyState(VK_MENU.0 as i32) < 0;

                    let mut vkey: u32 = 0;
                    if args.VirtualKey(&mut vkey).is_err() {
                        return Ok(());
                    }

                    // Ctrl + Alt + 1..9 (0x31..=0x39) -> 同一SNS内のアカウント切替
                    if !shift && alt && (0x31..=0x39).contains(&vkey) {
                        let _ = args.SetHandled(true);
                        cb("switch-account", Some((vkey - 0x31) as usize));
                        return Ok(());
                    }

                    // Ctrl + Alt + Left (0x25) / Right (0x27) -> 同一SNS内の前/次アカウント切替
                    if !shift && alt && vkey == 0x25 {
                        let _ = args.SetHandled(true);
                        cb("previous-account", None);
                        return Ok(());
                    }
                    if !shift && alt && vkey == 0x27 {
                        let _ = args.SetHandled(true);
                        cb("next-account", None);
                        return Ok(());
                    }

                    // Ctrl + Shift + T (0x54) -> 閉じたタブを復元
                    if shift && !alt && vkey == 0x54 {
                        let _ = args.SetHandled(true);
                        cb("restore-closed", None);
                        return Ok(());
                    }

                    // Ctrl + T (0x54) -> 新しいタブ
                    if !shift && !alt && vkey == 0x54 {
                        let _ = args.SetHandled(true);
                        cb("new-tab", None);
                        return Ok(());
                    }

                    // Ctrl + W (0x57) -> タブを閉じる
                    if !shift && !alt && vkey == 0x57 {
                        let _ = args.SetHandled(true);
                        cb("close-tab", None);
                        return Ok(());
                    }

                    // Ctrl + Tab / Ctrl + Shift + Tab (0x09) -> 次/前のタブ
                    if !alt && vkey == 0x09 {
                        let _ = args.SetHandled(true);
                        cb(if shift { "previous-tab" } else { "next-tab" }, None);
                        return Ok(());
                    }

                    // Ctrl + '+' / '=' / ';' (VK_OEM_PLUS=0xBB) / Numpad '+' (0x6B) -> 拡大
                    if !alt && (vkey == 0xBB || vkey == 0x6B) {
                        let _ = args.SetHandled(true);
                        cb("zoom-in", None);
                        return Ok(());
                    }

                    // Ctrl + '-' (VK_OEM_MINUS=0xBD) / Numpad '-' (0x6D) -> 縮小
                    if !alt && (vkey == 0xBD || vkey == 0x6D) {
                        let _ = args.SetHandled(true);
                        cb("zoom-out", None);
                        return Ok(());
                    }

                    // Ctrl + '0' (0x30) / Numpad '0' (0x60) -> ズームリセット (100%)
                    if !shift && !alt && (vkey == 0x30 || vkey == 0x60) {
                        let _ = args.SetHandled(true);
                        cb("zoom-reset", None);
                        return Ok(());
                    }

                    // Ctrl + L (0x4C) -> アドレスバーへフォーカス
                    if !shift && !alt && vkey == 0x4C {
                        let _ = args.SetHandled(true);
                        cb("focus-address-bar", None);
                        return Ok(());
                    }

                    // Ctrl + K (0x4B)
                    if !shift && !alt && vkey == 0x4B {
                        let _ = args.SetHandled(true);
                        cb("open-catalog", None);
                        return Ok(());
                    }

                    // Ctrl + 1..9 (0x31..=0x39) -> サイドバーのSNS切替
                    if !shift && !alt && (0x31..=0x39).contains(&vkey) {
                        let _ = args.SetHandled(true);
                        cb("switch-tab", Some((vkey - 0x31) as usize));
                    }

                    Ok(())
                })),
                &mut token,
            );
        }
    }
}
