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
    take_pwstr, AcceleratorKeyPressedEventHandler, CallDevToolsProtocolMethodCompletedHandler,
    ClearBrowsingDataCompletedHandler, ExecuteScriptCompletedHandler, FaviconChangedEventHandler,
    HistoryChangedEventHandler, NavigationCompletedEventHandler, NavigationStartingEventHandler,
    SourceChangedEventHandler, WebMessageReceivedEventHandler, ZoomFactorChangedEventHandler,
};
use windows::Win32::Foundation::{GlobalFree, LocalFree, FALSE, HANDLE, HGLOBAL, HLOCAL, HWND};
use windows::Win32::Networking::WinHttp::{
    WinHttpCloseHandle, WinHttpConnect, WinHttpOpen, WinHttpOpenRequest, WinHttpQueryDataAvailable,
    WinHttpQueryHeaders, WinHttpReadData, WinHttpReceiveResponse, WinHttpSendRequest,
    WinHttpSetOption, WinHttpSetTimeouts, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_FLAG_SECURE,
    WINHTTP_OPTION_REDIRECT_POLICY, WINHTTP_OPTION_REDIRECT_POLICY_NEVER,
    WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_QUERY_STATUS_CODE,
};
use windows::Win32::Security::Cryptography::{
    CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
};
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

use crate::url_utils::{
    canonical_external_http_url, detect_platform_service_from_url, is_safe_favicon_url,
    is_same_site_url,
};

fn encode_hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

fn decode_hex(s: &str) -> Option<Vec<u8>> {
    let bytes = s.as_bytes();
    if bytes.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 2);
    let mut i = 0;
    while i < bytes.len() {
        let hi = match bytes[i] {
            b'0'..=b'9' => bytes[i] - b'0',
            b'a'..=b'f' => bytes[i] - b'a' + 10,
            b'A'..=b'F' => bytes[i] - b'A' + 10,
            _ => return None,
        };
        let lo = match bytes[i + 1] {
            b'0'..=b'9' => bytes[i + 1] - b'0',
            b'a'..=b'f' => bytes[i + 1] - b'a' + 10,
            b'A'..=b'F' => bytes[i + 1] - b'A' + 10,
            _ => return None,
        };
        out.push((hi << 4) | lo);
        i += 2;
    }
    Some(out)
}

/// Windows DPAPI（現在ログイン中の Windows ユーザー専用鍵）で機密トークンを暗号化する。
pub fn dpapi_protect_secret(plaintext: &str) -> Option<String> {
    if plaintext.is_empty() {
        return Some(String::new());
    }
    let mut input = plaintext.as_bytes().to_vec();
    let in_blob = CRYPT_INTEGER_BLOB {
        cbData: u32::try_from(input.len()).ok()?,
        pbData: input.as_mut_ptr(),
    };
    let mut out_blob = CRYPT_INTEGER_BLOB::default();
    let ok = unsafe {
        CryptProtectData(
            &in_blob,
            PCWSTR::null(),
            None,
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out_blob,
        )
    };
    if ok.is_err() || out_blob.pbData.is_null() || out_blob.cbData == 0 {
        return None;
    }
    let encrypted = unsafe {
        let slice = std::slice::from_raw_parts(out_blob.pbData, out_blob.cbData as usize);
        let hex = encode_hex_lower(slice);
        let _ = LocalFree(Some(HLOCAL(out_blob.pbData as *mut std::ffi::c_void)));
        hex
    };
    Some(format!("dpapi:v1:{encrypted}"))
}

/// Windows DPAPI で暗号化されたトークンを復号する。
pub fn dpapi_unprotect_secret(encoded: &str) -> Option<String> {
    let hex = encoded.trim().strip_prefix("dpapi:v1:")?;
    let mut raw = decode_hex(hex)?;
    if raw.is_empty() {
        return None;
    }
    let in_blob = CRYPT_INTEGER_BLOB {
        cbData: u32::try_from(raw.len()).ok()?,
        pbData: raw.as_mut_ptr(),
    };
    let mut out_blob = CRYPT_INTEGER_BLOB::default();
    let ok = unsafe {
        CryptUnprotectData(
            &in_blob,
            None,
            None,
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out_blob,
        )
    };
    if ok.is_err() || out_blob.pbData.is_null() {
        return None;
    }
    let decrypted = unsafe {
        let slice = std::slice::from_raw_parts(out_blob.pbData, out_blob.cbData as usize);
        let s = String::from_utf8(slice.to_vec()).ok();
        let _ = LocalFree(Some(HLOCAL(out_blob.pbData as *mut std::ffi::c_void)));
        s
    };
    decrypted
}

fn has_crlf_or_nul(s: &str) -> bool {
    s.bytes().any(|b| b == b'\r' || b == b'\n' || b == 0)
}

/// WinHTTP を使って HTTPS JSON リクエスト（GET / POST / PATCH）を実行する。
pub fn winhttp_json_request(
    method: &str,
    host: &str,
    path: &str,
    headers: &[(&str, &str)],
    body: Option<&str>,
) -> Result<(u16, String), String> {
    if method.is_empty()
        || host.is_empty()
        || path.is_empty()
        || has_crlf_or_nul(method)
        || has_crlf_or_nul(host)
        || has_crlf_or_nul(path)
        || method.bytes().any(|b| !b.is_ascii_alphabetic())
        || host.bytes().any(|b| b.is_ascii_whitespace())
        || path.bytes().any(|b| b.is_ascii_control() || b.is_ascii_whitespace())
    {
        return Err("不正な HTTPS リクエストパラメータです".to_string());
    }

    let ua = HSTRING::from("OmniSNS/1.6");
    let host_h = HSTRING::from(host);
    let method_h = HSTRING::from(method);
    let path_h = HSTRING::from(path);

    let mut header_str = String::new();
    for (k, v) in headers {
        if k.is_empty()
            || has_crlf_or_nul(k)
            || has_crlf_or_nul(v)
            || k.bytes().any(|b| b <= 0x20 || b >= 0x7F || b == b':')
            || v.bytes().any(|b| b < 0x20 || b == 0x7F)
        {
            return Err("不正な HTTP ヘッダーが含まれています".to_string());
        }
        header_str.push_str(k);
        header_str.push_str(": ");
        header_str.push_str(v);
        header_str.push_str("\r\n");
    }
    let header_wide: Vec<u16> = header_str.encode_utf16().collect();
    let body_bytes = body.map(|b| b.as_bytes()).unwrap_or(&[]);
    let body_len = u32::try_from(body_bytes.len())
        .map_err(|_| "送信データサイズが大きすぎます".to_string())?;

    unsafe {
        let session = WinHttpOpen(
            &ua,
            WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
            PCWSTR::null(),
            PCWSTR::null(),
            0,
        );
        if session.is_null() {
            return Err("WinHttpOpen に失敗しました".to_string());
        }
        let _ = WinHttpSetTimeouts(session, 8000, 8000, 10000, 15000);

        let connect = WinHttpConnect(session, &host_h, 443, 0);
        if connect.is_null() {
            let _ = WinHttpCloseHandle(session);
            return Err("WinHttpConnect に失敗しました".to_string());
        }

        let req = WinHttpOpenRequest(
            connect,
            &method_h,
            &path_h,
            PCWSTR::null(),
            PCWSTR::null(),
            std::ptr::null(),
            WINHTTP_FLAG_SECURE,
        );
        if req.is_null() {
            let _ = WinHttpCloseHandle(connect);
            let _ = WinHttpCloseHandle(session);
            return Err("WinHttpOpenRequest に失敗しました".to_string());
        }

        let redirect_policy: u32 = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
        if WinHttpSetOption(
            Some(req),
            WINHTTP_OPTION_REDIRECT_POLICY,
            Some(&redirect_policy.to_ne_bytes()),
        )
        .is_err()
        {
            let _ = WinHttpCloseHandle(req);
            let _ = WinHttpCloseHandle(connect);
            let _ = WinHttpCloseHandle(session);
            return Err("WinHttpSetOption に失敗しました".to_string());
        }

        let headers_opt = if header_wide.is_empty() {
            None
        } else {
            Some(header_wide.as_slice())
        };
        let opt_ptr = if body_bytes.is_empty() {
            None
        } else {
            Some(body_bytes.as_ptr() as *const std::ffi::c_void)
        };

        let send_res = WinHttpSendRequest(req, headers_opt, opt_ptr, body_len, body_len, 0);
        if send_res.is_err() {
            let _ = WinHttpCloseHandle(req);
            let _ = WinHttpCloseHandle(connect);
            let _ = WinHttpCloseHandle(session);
            return Err("HTTPS 送信に失敗しました（ネットワーク接続を確認してください）".to_string());
        }

        if WinHttpReceiveResponse(req, std::ptr::null_mut()).is_err() {
            let _ = WinHttpCloseHandle(req);
            let _ = WinHttpCloseHandle(connect);
            let _ = WinHttpCloseHandle(session);
            return Err("HTTPS 応答の受信に失敗しました".to_string());
        }

        let mut status_code: u32 = 0;
        let mut status_len = std::mem::size_of::<u32>() as u32;
        let mut header_idx: u32 = 0;
        let _ = WinHttpQueryHeaders(
            req,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            PCWSTR::null(),
            Some(&mut status_code as *mut u32 as *mut std::ffi::c_void),
            &mut status_len,
            &mut header_idx,
        );

        const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
        let mut response_bytes: Vec<u8> = Vec::new();
        let mut read_err: Option<String> = None;
        loop {
            let mut avail: u32 = 0;
            if WinHttpQueryDataAvailable(req, &mut avail).is_err() {
                read_err = Some("HTTPS 応答の読み取り中に接続が中断されました".to_string());
                break;
            }
            if avail == 0 {
                break;
            }
            let chunk_size = avail.min(65536) as usize;
            let mut buf = vec![0u8; chunk_size];
            let mut read: u32 = 0;
            if WinHttpReadData(
                req,
                buf.as_mut_ptr() as *mut std::ffi::c_void,
                chunk_size as u32,
                &mut read,
            )
            .is_err()
            {
                read_err = Some("HTTPS 応答の受信中にエラーが発生しました".to_string());
                break;
            }
            if read == 0 {
                break;
            }
            if response_bytes.len().saturating_add(read as usize) > MAX_RESPONSE_BYTES {
                read_err = Some("HTTPS 応答サイズが上限を超えました".to_string());
                break;
            }
            response_bytes.extend_from_slice(&buf[..read as usize]);
        }

        let _ = WinHttpCloseHandle(req);
        let _ = WinHttpCloseHandle(connect);
        let _ = WinHttpCloseHandle(session);

        if let Some(err) = read_err {
            return Err(err);
        }

        let text = String::from_utf8_lossy(&response_bytes).to_string();
        Ok((status_code as u16, text))
    }
}

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
                // SetClipboardData 成功時のみ OS が所有権を引き取る。失敗時は自分で解放する。
                if SetClipboardData(CF_UNICODETEXT.0 as u32, Some(HANDLE(hmem.0))).is_err() {
                    let _ = GlobalFree(Some(hmem));
                }
            } else {
                let h: HGLOBAL = hmem;
                let _ = GlobalFree(Some(h));
            }
        }

        let _ = CloseClipboard();
    }
}

/// 安全な http/https URL のみを Windows 既定ブラウザで開く。
pub fn open_external_url(url: &str) {
    let Some(canonical) = canonical_external_http_url(url) else {
        return;
    };
    let verb = HSTRING::from("open");
    let target = HSTRING::from(canonical);
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
    pub on_follow_detected: Arc<dyn Fn(Option<String>) + Send + Sync>,
    pub on_unfollow_detected: Arc<dyn Fn(Option<String>) + Send + Sync>,
    pub on_account_identity: Arc<dyn Fn(Option<String>, String, Option<u32>, Option<u32>) + Send + Sync>,
}

/// WebView 単位で予測不能な認証トークン（128bit 相当）を生成する。
/// 注入スクリプトのクロージャ内にのみ保持し、任意ページからの WebMessage 偽装を防ぐ。
pub fn generate_bridge_token() -> String {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static SEQ: AtomicU64 = AtomicU64::new(1);
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);

    let mut h1 = RandomState::new().build_hasher();
    h1.write_u64(nanos);
    h1.write_u64(seq);
    let a = h1.finish();

    let mut h2 = RandomState::new().build_hasher();
    h2.write_u64(a.rotate_left(17));
    h2.write_u64(seq ^ 0x9E37_79B9_7F4A_7C15);
    let b = h2.finish();

    format!("{a:016x}{b:016x}")
}

pub fn build_follow_tracker_js(bridge_token: &str) -> String {
    FOLLOW_TRACKER_JS.replace("__OMNI_BRIDGE_TOKEN__", bridge_token)
}

pub fn build_profile_stats_js(bridge_token: &str) -> String {
    PROFILE_STATS_JS.replace("__OMNI_BRIDGE_TOKEN__", bridge_token)
}

/// Threads / Instagram / Bluesky / mixi2 等のフォロー・アンフォロー操作を自動検知してホストへ通知するスクリプト。
pub const FOLLOW_TRACKER_JS: &str = r#"(function() {
  if (window !== window.top) return;
  if (window.__omniFollowTrackerInstalled) return;
  window.__omniFollowTrackerInstalled = true;

  var __OMNI_TOKEN__ = "__OMNI_BRIDGE_TOKEN__";
  var __omniPostMessage = (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function')
    ? window.chrome.webview.postMessage.bind(window.chrome.webview)
    : null;

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
      if (h === 'instagram.com' || h.slice(-14) === '.instagram.com') return 'instagram';
      if (h === 'threads.net' || h.slice(-12) === '.threads.net' || h === 'threads.com' || h.slice(-12) === '.threads.com') return 'threads';
      if (h === 'bsky.app' || h.slice(-9) === '.bsky.app') return 'bluesky';
      if (h === 'mixi.social' || h.slice(-12) === '.mixi.social') return 'mixi2';
      if (h === 'x.com' || h.slice(-6) === '.x.com' || h === 'twitter.com' || h.slice(-12) === '.twitter.com') return 'x';
      if (h === 'tiktok.com' || h.slice(-11) === '.tiktok.com') return 'tiktok';
      if (h === 'facebook.com' || h.slice(-13) === '.facebook.com') return 'facebook';
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
      var poster = __omniPostMessage || (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function' ? window.chrome.webview.postMessage.bind(window.chrome.webview) : null);
      if (poster) {
        poster(JSON.stringify({
          token: __OMNI_TOKEN__,
          type: action === 'unfollow' ? 'omnisns:unfollow' : 'omnisns:follow',
          source: source || 'auto',
          service: detectCurrentService()
        }));
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
})();"#;

/// Instagram / Threads / Bluesky 等で表示されたアカウント（フォロワー一覧・フィード等）に、
/// ページ遷移なしでフォロー数・フォロワー数・投稿数・非公開状態をインライン可視化するスクリプト。
/// またログイン中アカウント自身のハンドルと実フォロー数・フォロワー数もホストへ通知する。
pub const PROFILE_STATS_JS: &str = r#"(function() {
  if (window !== window.top) return;
  if (window.__omniProfileStatsInstalled) return;
  window.__omniProfileStatsInstalled = true;

  var __OMNI_TOKEN__ = "__OMNI_BRIDGE_TOKEN__";
  var __omniPostMessage = (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function')
    ? window.chrome.webview.postMessage.bind(window.chrome.webview)
    : null;

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
  var MAX_CACHE_ENTRIES = 600;
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
    try {
      var poster = __omniPostMessage || (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function' ? window.chrome.webview.postMessage.bind(window.chrome.webview) : null);
      if (poster) {
        poster(JSON.stringify({
          token: __OMNI_TOKEN__,
          type: 'omnisns:account-identity',
          service: platform,
          handle: handle,
          following: typeof following === 'number' ? following : null,
          followers: typeof followers === 'number' ? followers : null
        }));
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
      enqueueFetch(h, true);
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
      var parsed = JSON.parse(clean);
      extractFromJsonObject(parsed);
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
    var primaryAppId = capturedHeaders['x-ig-app-id'] || '936619743392459';
    var altAppId = primaryAppId === '1217981644879628' ? '936619743392459' : '1217981644879628';
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
      var doneBatch = function() {
        for (var j = 0; j < batch.length; j++) delete inFlight[batch[j]];
        setTimeout(function() {
          queueRunning = false;
          processQueue();
        }, 280);
      };
      Promise.resolve(fetchBlueskyBatch(batch)).then(doneBatch, doneBatch);
      return;
    }

    var handle = queue.shift();
    delete queuedSet[handle];
    inFlight[handle] = true;
    scheduleRenderBadges();
    var req = platform === 'instagram' ? fetchInstagramProfile(handle) : fetchThreadsProfile(handle);
    var delayMs = platform === 'instagram' ? 620 : 820;
    var doneSingle = function() {
      delete inFlight[handle];
      setTimeout(function() {
        queueRunning = false;
        processQueue();
      }, delayMs);
    };
    Promise.resolve(req).then(doneSingle, doneSingle);
  }

  function ensureStyles() {
    if (document.getElementById('omni-ff-style')) return;
    var style = document.createElement('style');
    style.id = 'omni-ff-style';
    style.textContent =
      '.omni-ff-badge{' +
      'display:inline-flex;align-items:center;gap:3px;margin-left:5px;padding:1px 6px;' +
      'border-radius:999px;font-size:10.5px;font-weight:600;line-height:1.35;' +
      'background:rgba(21,156,171,0.16);border:1px solid rgba(21,156,171,0.42);' +
      'color:inherit;white-space:nowrap;user-select:none;vertical-align:middle;' +
      'opacity:0.94;letter-spacing:0;pointer-events:none;' +
      '}' +
      '.omni-ff-badge-row{' +
      'display:inline-flex;align-items:center;flex-wrap:wrap;gap:3px;margin:3px 0 0 0;padding:1.5px 7px;' +
      'border-radius:999px;font-size:10.5px;font-weight:600;line-height:1.35;' +
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
    var titleParts = [];
    if (entry.isPrivate === true) {
      parts.push('🔒');
      titleParts.push('非公開アカウント');
    }
    if (hasFollowing) {
      parts.push('フォロー ' + formatCompactCount(entry.following));
      titleParts.push('フォロー中: ' + entry.following.toLocaleString('ja-JP') + '人');
    }
    if (hasFollowers) {
      parts.push('フォロワー ' + formatCompactCount(entry.followers));
      titleParts.push('フォロワー: ' + entry.followers.toLocaleString('ja-JP') + '人');
    }
    if (hasPosts) {
      parts.push('投稿 ' + formatCompactCount(entry.posts));
      titleParts.push('投稿: ' + entry.posts.toLocaleString('ja-JP') + '件');
    }
    if (parts.length === 0) return null;
    var prefix = parts[0] === '🔒' ? '🔒 ' : '';
    var body = (prefix ? parts.slice(1) : parts).join(' · ');
    return { text: prefix + body, title: titleParts.join(' / ') };
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
      if (badge.title !== display.title) badge.title = display.title + '（クリックで再取得）';
    } else if (inFlight[handle] || queuedSet[handle]) {
      badge.className = 'omni-ff-badge-row is-pending';
      if (badge.textContent !== '人数を取得中…') badge.textContent = '人数を取得中…';
      badge.title = 'フォロー数・フォロワー数を取得中';
    } else if (failedMap[handle] || Date.now() < backoffUntil) {
      badge.className = 'omni-ff-badge-row is-retry';
      if (badge.textContent !== '人数を取得 ↻') badge.textContent = '人数を取得 ↻';
      badge.title = 'クリックしてフォロー数・フォロワー数を取得';
    } else {
      badge.className = 'omni-ff-badge-row is-pending';
      if (badge.textContent !== '人数を取得中…') badge.textContent = '人数を取得中…';
      badge.title = 'クリックして優先取得';
    }
  }

  function scanFollowListRows() {
    var handledRows = [];
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
        handledRows.push(row);
        var visible = isInViewport(row);
        if (!hasUsableStats(statsMap[handle]) && visible) {
          enqueueFetch(handle, false, false);
        }
        upsertRowBadge(col, handle);
      }
    } catch (_) {}
    return handledRows;
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
      if (next.title !== display.title) next.title = display.title;
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
    span.title = display.title;
    try {
      a.insertAdjacentElement('afterend', span);
    } catch (_) {}
  }

  function scanAndRender() {
    detectSelfAccountFromDom();
    scanFollowListRows();
    var links = document.querySelectorAll('a[href]');
    for (var i = 0; i < links.length && i < 3000; i++) {
      var a = links[i];
      if (a.closest('[data-omni-ff-row]')) continue;
      var handle = a.getAttribute('data-omni-ff-handle');
      if (!handle) {
        handle = extractHandleFromLink(a);
        if (handle) {
          a.setAttribute('data-omni-ff-handle', handle);
          (function(linkEl, h) {
            linkEl.addEventListener('pointerenter', function() {
              enqueueFetch(h, true, false);
            }, { passive: true });
          })(a, handle);
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

#[derive(serde::Deserialize)]
struct InboundWebMessage {
    token: String,
    #[serde(rename = "type")]
    msg_type: String,
    #[serde(default)]
    handle: Option<String>,
    #[serde(default)]
    following: Option<u64>,
    #[serde(default)]
    followers: Option<u64>,
}

/// SNSタブ子WebView2へネイティブイベントハンドラ（ナビゲーション・ファビコン・ミュート・ショートカット等）を接続する。
pub fn attach_tab_handlers(
    controller: &ICoreWebView2Controller,
    initial_muted: bool,
    initial_zoom: f64,
    initial_ua: &str,
    bridge_token: String,
    instance_home_url: String,
    initial_navigate_url: Option<String>,
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

        // WebMessage でフォロー/アンフォロー検知・ログインアカウントID＆実フォロー数を受信する。
        // Per-WebView 秘密トークン + args.Source()/wv.Source() 同一オリジン検証 + レート制限を強制し、
        // 任意ページ・iframe・広告スクリプトからのメッセージ偽装や DoS を防ぐ。
        {
            let cb_follow = callbacks.on_follow_detected.clone();
            let cb_unfollow = callbacks.on_unfollow_detected.clone();
            let cb_identity = callbacks.on_account_identity.clone();
            let expected_token = bridge_token;
            let home_url_for_msg = instance_home_url;
            let rate_state = std::sync::Mutex::new((std::time::Instant::now(), 0u32));
            let mut token = Default::default();
            let _ = wv.add_WebMessageReceived(
                &WebMessageReceivedEventHandler::create(Box::new(move |sender, args| {
                    let (Some(wv), Some(args)) = (sender, args) else {
                        return Ok(());
                    };
                    if expected_token.is_empty() {
                        return Ok(());
                    }

                    // レート制限（1秒あたり最大25メッセージ）
                    if let Ok(mut rl) = rate_state.lock() {
                        if rl.0.elapsed() >= std::time::Duration::from_secs(1) {
                            rl.0 = std::time::Instant::now();
                            rl.1 = 1;
                        } else {
                            rl.1 = rl.1.saturating_add(1);
                            if rl.1 > 25 {
                                return Ok(());
                            }
                        }
                    }

                    // 送信元 URL とトップレベル URL の一致・http(s) スキームを検証
                    let mut src_pw = PWSTR::null();
                    if args.Source(&mut src_pw).is_err() {
                        return Ok(());
                    }
                    let msg_source = take_pwstr(src_pw);
                    let mut top_pw = PWSTR::null();
                    if wv.Source(&mut top_pw).is_err() {
                        return Ok(());
                    }
                    let top_source = take_pwstr(top_pw);

                    let (Ok(msg_url), Ok(top_url)) =
                        (url::Url::parse(&msg_source), url::Url::parse(&top_source))
                    else {
                        return Ok(());
                    };
                    if !matches!(msg_url.scheme(), "https" | "http")
                        || msg_url.scheme() != top_url.scheme()
                        || msg_url.host_str() != top_url.host_str()
                    {
                        return Ok(());
                    }

                    let mut raw = PWSTR::null();
                    if args.TryGetWebMessageAsString(&mut raw).is_err() {
                        return Ok(());
                    }
                    let msg = take_pwstr(raw);
                    if msg.len() > 8192 {
                        return Ok(());
                    }
                    let Ok(parsed) = serde_json::from_str::<InboundWebMessage>(&msg) else {
                        return Ok(());
                    };
                    if parsed.token != expected_token {
                        return Ok(());
                    }

                    // プラットフォーム名は JS 申告値ではなく WebView2 が検証した送信元 URL から決定する。
                    // 既知の 16 プラットフォームに加え、Mastodon/Misskey・その他カタログ/カスタム SNS は
                    // インスタンス設定のホーム URL と同一サイトであれば自サービスのフォロー計測を許可する。
                    let verified_service =
                        detect_platform_service_from_url(&msg_source).map(|s| s.to_string());
                    let is_own_service_site = !home_url_for_msg.is_empty()
                        && is_same_site_url(&msg_source, &home_url_for_msg);

                    match parsed.msg_type.as_str() {
                        "omnisns:follow" => {
                            if verified_service.is_some() || is_own_service_site {
                                cb_follow(verified_service);
                            }
                        }
                        "omnisns:unfollow" => {
                            if verified_service.is_some() || is_own_service_site {
                                cb_unfollow(verified_service);
                            }
                        }
                        "omnisns:account-identity" => {
                            if verified_service.is_some() {
                                if let Some(handle) = parsed
                                    .handle
                                    .as_deref()
                                    .and_then(crate::follow_sync::normalize_account_handle)
                                {
                                    let following =
                                        parsed.following.map(|n| n.min(u32::MAX as u64) as u32);
                                    let followers =
                                        parsed.followers.map(|n| n.min(u32::MAX as u64) as u32);
                                    cb_identity(verified_service, handle, following, followers);
                                }
                            }
                        }
                        _ => {}
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
                &NavigationStartingEventHandler::create(Box::new(move |_, args| {
                    if let Some(args) = args {
                        let mut uri_pw = PWSTR::null();
                        if args.Uri(&mut uri_pw).is_ok() {
                            let uri = take_pwstr(uri_pw);
                            if uri.eq_ignore_ascii_case("about:blank") {
                                return Ok(());
                            }
                        }
                    }
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
                    if url.eq_ignore_ascii_case("about:blank") {
                        return Ok(());
                    }

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
                        if !url.eq_ignore_ascii_case("about:blank") {
                            cb(url, can_back, can_fwd);
                        }
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
                        if !url.eq_ignore_ascii_case("about:blank") {
                            cb(url, can_back, can_fwd);
                        }
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
                                if is_safe_favicon_url(&favicon) {
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

        // 全ハンドラ・ミュート・ズーム・UA 設定完了後に初期 URL へ遷移させることで
        // 早期 NavigationCompleted / DNS エラー取りこぼしやミュート前の音声再生を防ぐ
        if let Some(target_url) = initial_navigate_url {
            if !target_url.is_empty() {
                let target_h = HSTRING::from(target_url);
                let _ = wv.Navigate(&target_h);
            }
        }
    }
}
