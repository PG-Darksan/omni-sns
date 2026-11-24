#![cfg(windows)]

use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetDC, ReleaseDC, SelectObject,
    AC_SRC_ALPHA, AC_SRC_OVER, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, BLENDFUNCTION,
    DIB_RGB_COLORS, HGDIOBJ,
};
use windows::Win32::Graphics::GdiPlus::{
    DashCapFlat, FillModeAlternate, FontStyleBold, FontStyleRegular, GdipAddPathArc,
    GdipClosePathFigure, GdipCreateBitmapFromScan0, GdipCreateFont, GdipCreateFontFamilyFromName,
    GdipCreatePath, GdipCreatePen1, GdipCreateSolidFill, GdipDeleteBrush, GdipDeleteFont,
    GdipDeleteFontFamily, GdipDeleteGraphics, GdipDeletePath, GdipDeletePen, GdipDisposeImage,
    GdipDrawLines, GdipDrawPath, GdipDrawString, GdipFillEllipse, GdipFillPath,
    GdipGetImageGraphicsContext, GdipGraphicsClear, GdipSetPenLineCap197819, GdipSetPenLineJoin,
    GdipSetSmoothingMode, GdipSetStringFormatAlign, GdipSetStringFormatLineAlign,
    GdipSetTextRenderingHint, GdipCreateStringFormat, GdipDeleteStringFormat, GdiplusShutdown,
    GdiplusStartup, GdiplusStartupInput, GpBitmap, GpBrush, GpFont, GpFontFamily, GpGraphics,
    GpImage, GpPath, GpPen, GpSolidFill, GpStringFormat, LineCapRound, LineJoinRound, PointF,
    RectF, SmoothingModeAntiAlias, StringAlignmentCenter, TextRenderingHintAntiAliasGridFit,
    UnitPixel,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_LEFTDOWN,
    MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEINPUT, VK_CONTROL,
    VK_ESCAPE, VK_LBUTTON, VK_MBUTTON, VK_RBUTTON, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetAncestor,
    GetMessageW, GetSystemMetrics, IsIconic, IsWindowVisible, KillTimer, PostMessageW,
    PostThreadMessageW, RegisterClassExW, SetTimer, SetWindowPos, SetWindowsHookExW, ShowWindow,
    TranslateMessage, UnhookWindowsHookEx, UpdateLayeredWindow, WindowFromPoint, CS_HREDRAW,
    CS_VREDRAW, GA_ROOT, HCURSOR, HHOOK, HICON, HWND_TOPMOST, MSG, MSLLHOOKSTRUCT, SM_SWAPBUTTON,
    SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SW_HIDE, SW_SHOWNOACTIVATE, ULW_ALPHA, WH_MOUSE_LL,
    WM_APP, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MOUSEMOVE, WM_QUIT,
    WM_RBUTTONDOWN, WM_RBUTTONUP, WM_TIMER, WNDCLASSEXW, WS_EX_LAYERED, WS_EX_NOACTIVATE,
    WS_EX_TOOLWINDOW, WS_EX_TRANSPARENT, WS_POPUP,
};
use windows_core::{HSTRING, PCWSTR};

use crate::gesture::{
    action_label_ja, live_scroll_of, reveal_delta, scroll_dir_of, shape_arrows, shape_name_ja,
    GesturePath, GestureSettings, Point,
};

const SYNTHETIC_MAGIC: usize = 0x4F4D_4E49_534E; // "OMNISN"
const PIXEL_FORMAT_32BPP_PARGB: i32 = 0x000E_200B;

const WM_GESTURE_EVENT: u32 = WM_APP + 10;
const WM_GESTURE_NOTICE: u32 = WM_APP + 11;
const TIMER_GESTURE_TICK: usize = 1;
const TIMER_NOTICE_HIDE: usize = 2;

#[derive(Debug, Clone, Copy)]
pub struct ViewportRect {
    pub left: i32,
    pub top: i32,
    pub width: i32,
    pub height: i32,
    pub scale_factor: f64,
}

impl Default for ViewportRect {
    fn default() -> Self {
        Self {
            left: 0,
            top: 0,
            width: 0,
            height: 0,
            scale_factor: 1.0,
        }
    }
}

impl ViewportRect {
    fn contains(&self, x: i32, y: i32) -> bool {
        self.width > 0
            && self.height > 0
            && x >= self.left
            && x < self.left + self.width
            && y >= self.top
            && y < self.top + self.height
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct GestureActionContext {
    pub origin_lx: f64,
    pub origin_ly: f64,
}

pub struct GestureHostCallbacks {
    pub on_action: Arc<dyn Fn(String, String, GestureActionContext) + Send + Sync>,
    pub on_live_scroll: Arc<dyn Fn(f64, f64, f64, f64) + Send + Sync>,
}

static LAST_USER_NEW_TAB_CLICK_MS: AtomicU64 = AtomicU64::new(0);
static LAST_USER_NEW_TAB_FOREGROUND: AtomicBool = AtomicBool::new(false);

fn now_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// ジェスチャー経由の Ctrl+クリック 実行直前に呼び出し、直後の NewWindowRequested を
/// 同一アカウントの新しいバックグラウンドタブとして開く意図を記録する。
pub fn mark_gesture_ctrl_click() {
    LAST_USER_NEW_TAB_FOREGROUND.store(false, Ordering::SeqCst);
    LAST_USER_NEW_TAB_CLICK_MS.store(now_epoch_ms(), Ordering::SeqCst);
}

/// NewWindowRequested がユーザーによる Ctrl+クリック / 中クリック / Ctrl+クリックジェスチャー
/// 起因かを判定して消費する。戻り値は `(is_user_new_tab, force_foreground)`。
pub fn consume_new_tab_click_intent() -> (bool, bool) {
    let now = now_epoch_ms();
    let recorded = LAST_USER_NEW_TAB_CLICK_MS.load(Ordering::SeqCst);
    if recorded != 0 && now.saturating_sub(recorded) <= 1500 {
        LAST_USER_NEW_TAB_CLICK_MS.store(0, Ordering::SeqCst);
        let fg = LAST_USER_NEW_TAB_FOREGROUND.load(Ordering::SeqCst);
        return (true, fg);
    }
    let ctrl_down = unsafe { GetAsyncKeyState(VK_CONTROL.0 as i32) } < 0;
    let mid_down = unsafe { GetAsyncKeyState(VK_MBUTTON.0 as i32) } < 0;
    if ctrl_down || mid_down {
        let shift_down = unsafe { GetAsyncKeyState(VK_SHIFT.0 as i32) } < 0;
        return (true, shift_down);
    }
    (false, false)
}

enum HookMsg {
    Down(i32, i32),
    Move(i32, i32),
    Up(i32, i32),
    Abort,
}

struct SharedHookState {
    main_hwnd: AtomicIsize,
    overlay_hwnd: AtomicIsize,
    enabled: AtomicBool,
    suspended: AtomicBool,
    tracking: AtomicBool,
    viewport: Mutex<ViewportRect>,
    settings: Mutex<GestureSettings>,
    queue: Mutex<Vec<HookMsg>>,
    pending_notice: Mutex<Option<(String, bool)>>,
}

static HOOK_STATE: OnceLock<Arc<SharedHookState>> = OnceLock::new();

fn hook_state() -> &'static Arc<SharedHookState> {
    HOOK_STATE.get_or_init(|| {
        Arc::new(SharedHookState {
            main_hwnd: AtomicIsize::new(0),
            overlay_hwnd: AtomicIsize::new(0),
            enabled: AtomicBool::new(true),
            suspended: AtomicBool::new(false),
            tracking: AtomicBool::new(false),
            viewport: Mutex::new(ViewportRect::default()),
            settings: Mutex::new(GestureSettings::default()),
            queue: Mutex::new(Vec::new()),
            pending_notice: Mutex::new(None),
        })
    })
}

fn is_swapped_buttons() -> bool {
    unsafe { GetSystemMetrics(SM_SWAPBUTTON) != 0 }
}

unsafe extern "system" fn low_level_mouse_proc(
    code: i32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if code >= 0 {
        let st = hook_state();
        let info = unsafe { &*(lparam.0 as *const MSLLHOOKSTRUCT) };

        if info.dwExtraInfo != SYNTHETIC_MAGIC {
            let msg = wparam.0 as u32;
            let swapped = is_swapped_buttons();
            let (sec_down, sec_up, primary_down, primary_up) = if swapped {
                (WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN, WM_RBUTTONUP)
            } else {
                (WM_RBUTTONDOWN, WM_RBUTTONUP, WM_LBUTTONDOWN, WM_LBUTTONUP)
            };

            if msg == sec_down {
                if st.enabled.load(Ordering::Relaxed) && !st.suspended.load(Ordering::Relaxed) {
                    let main_raw = st.main_hwnd.load(Ordering::Relaxed);
                    if main_raw != 0 {
                        let main_hwnd = HWND(main_raw as *mut c_void);
                        let pt = info.pt;
                        let in_vp = st
                            .viewport
                            .lock()
                            .map(|vp| vp.contains(pt.x, pt.y))
                            .unwrap_or(false);
                        if in_vp {
                            // 他ボタン（左・中）が押されていないこと & カーソル下が自ウィンドウ配下であること
                            let primary_vk = if swapped { VK_RBUTTON } else { VK_LBUTTON };
                            let is_primary_down = unsafe { GetAsyncKeyState(primary_vk.0 as i32) } < 0;
                            let middle_down = unsafe { GetAsyncKeyState(VK_MBUTTON.0 as i32) } < 0;
                            if !is_primary_down && !middle_down {
                                let under = unsafe { WindowFromPoint(pt) };
                                let root = unsafe { GetAncestor(under, GA_ROOT) };
                                if root == main_hwnd {
                                    st.tracking.store(true, Ordering::SeqCst);
                                    if let Ok(mut q) = st.queue.lock() {
                                        q.push(HookMsg::Down(pt.x, pt.y));
                                    }
                                    let ov = st.overlay_hwnd.load(Ordering::Relaxed);
                                    if ov != 0 {
                                        let _ = unsafe {
                                            PostMessageW(
                                                Some(HWND(ov as *mut c_void)),
                                                WM_GESTURE_EVENT,
                                                WPARAM(0),
                                                LPARAM(0),
                                            )
                                        };
                                    }
                                    return LRESULT(1);
                                }
                            }
                        }
                    }
                }
            } else if st.tracking.load(Ordering::Relaxed) {
                if msg == WM_MOUSEMOVE {
                    let pt = info.pt;
                    if let Ok(mut q) = st.queue.lock() {
                        q.push(HookMsg::Move(pt.x, pt.y));
                    }
                    let ov = st.overlay_hwnd.load(Ordering::Relaxed);
                    if ov != 0 {
                        let _ = unsafe {
                            PostMessageW(
                                Some(HWND(ov as *mut c_void)),
                                WM_GESTURE_EVENT,
                                WPARAM(0),
                                LPARAM(0),
                            )
                        };
                    }
                    // 注意: WH_MOUSE_LL で WM_MOUSEMOVE を飲み込むとカーソルが動かないため必ず通す
                } else if msg == primary_down || msg == WM_MBUTTONDOWN {
                    if let Ok(mut q) = st.queue.lock() {
                        q.push(HookMsg::Abort);
                    }
                    let ov = st.overlay_hwnd.load(Ordering::Relaxed);
                    if ov != 0 {
                        let _ = unsafe {
                            PostMessageW(
                                Some(HWND(ov as *mut c_void)),
                                WM_GESTURE_EVENT,
                                WPARAM(0),
                                LPARAM(0),
                            )
                        };
                    }
                } else if msg == sec_up {
                    st.tracking.store(false, Ordering::SeqCst);
                    let pt = info.pt;
                    if let Ok(mut q) = st.queue.lock() {
                        q.push(HookMsg::Up(pt.x, pt.y));
                    }
                    let ov = st.overlay_hwnd.load(Ordering::Relaxed);
                    if ov != 0 {
                        let _ = unsafe {
                            PostMessageW(
                                Some(HWND(ov as *mut c_void)),
                                WM_GESTURE_EVENT,
                                WPARAM(0),
                                LPARAM(0),
                            )
                        };
                    }
                    return LRESULT(1);
                }
            } else if (msg == primary_down
                || msg == primary_up
                || msg == WM_MBUTTONDOWN
                || msg == WM_MBUTTONUP)
                && !st.suspended.load(Ordering::Relaxed)
            {
                // 物理 Ctrl+クリック / 中クリック を記録し、NewWindowRequested が
                // 非同期ディスパッチされた後でも確実に同一アカウントの新規タブとして開けるようにする
                let is_middle = msg == WM_MBUTTONDOWN || msg == WM_MBUTTONUP;
                let ctrl_down = unsafe { GetAsyncKeyState(VK_CONTROL.0 as i32) } < 0;
                if is_middle || ctrl_down {
                    let main_raw = st.main_hwnd.load(Ordering::Relaxed);
                    if main_raw != 0 {
                        let pt = info.pt;
                        let in_vp = st
                            .viewport
                            .lock()
                            .map(|vp| vp.contains(pt.x, pt.y))
                            .unwrap_or(false);
                        if in_vp {
                            let under = unsafe { WindowFromPoint(pt) };
                            let root = unsafe { GetAncestor(under, GA_ROOT) };
                            if root == HWND(main_raw as *mut c_void) {
                                let shift_down =
                                    unsafe { GetAsyncKeyState(VK_SHIFT.0 as i32) } < 0;
                                LAST_USER_NEW_TAB_FOREGROUND
                                    .store(shift_down, Ordering::SeqCst);
                                LAST_USER_NEW_TAB_CLICK_MS
                                    .store(now_epoch_ms(), Ordering::SeqCst);
                            }
                        }
                    }
                }
            }
        }
    }

    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

fn replay_secondary_click() {
    let swapped = is_swapped_buttons();
    let (down_flag, up_flag) = if swapped {
        (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP)
    } else {
        (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP)
    };
    let inputs = [
        INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx: 0,
                    dy: 0,
                    mouseData: 0,
                    dwFlags: down_flag,
                    time: 0,
                    dwExtraInfo: SYNTHETIC_MAGIC,
                },
            },
        },
        INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx: 0,
                    dy: 0,
                    mouseData: 0,
                    dwFlags: up_flag,
                    time: 0,
                    dwExtraInfo: SYNTHETIC_MAGIC,
                },
            },
        },
    ];
    unsafe {
        SendInput(&inputs, std::mem::size_of::<INPUT>() as i32);
    }
}

struct ActiveStroke {
    path: GesturePath,
    settings: GestureSettings,
    viewport: ViewportRect,
    canceled: bool,
    live_scrolled: bool,
    last_scroll_shape: Option<String>,
    last_tick: Instant,
    started_at: Instant,
}

struct OverlayNotice {
    text: String,
    is_error: bool,
}

struct OverlayRuntime {
    hwnd: HWND,
    callbacks: GestureHostCallbacks,
    stroke: Option<ActiveStroke>,
    notice: Option<OverlayNotice>,
    dirty: bool,
    visible: bool,
}

impl OverlayRuntime {
    fn drain_events(&mut self) {
        let events: Vec<HookMsg> = {
            let st = hook_state();
            if let Ok(mut q) = st.queue.lock() {
                std::mem::take(&mut *q)
            } else {
                Vec::new()
            }
        };

        for ev in events {
            match ev {
                HookMsg::Down(sx, sy) => self.on_down(sx, sy),
                HookMsg::Move(sx, sy) => self.on_move(sx, sy),
                HookMsg::Abort => self.on_abort(),
                HookMsg::Up(sx, sy) => self.on_up(sx, sy),
            }
        }
    }

    fn on_down(&mut self, sx: i32, sy: i32) {
        let st = hook_state();
        let vp = st.viewport.lock().map(|v| *v).unwrap_or_default();
        let settings = st.settings.lock().map(|s| s.clone()).unwrap_or_default();
        let sf = if vp.scale_factor > 0.0 {
            vp.scale_factor
        } else {
            1.0
        };
        let lx = (sx - vp.left) as f64 / sf;
        let ly = (sy - vp.top) as f64 / sf;

        self.notice = None;
        unsafe {
            let _ = KillTimer(Some(self.hwnd), TIMER_NOTICE_HIDE);
            let _ = SetTimer(Some(self.hwnd), TIMER_GESTURE_TICK, 16, None);
        }

        self.stroke = Some(ActiveStroke {
            path: GesturePath::new(Point::new(lx, ly), settings.tremor),
            settings,
            viewport: vp,
            canceled: false,
            live_scrolled: false,
            last_scroll_shape: None,
            last_tick: Instant::now(),
            started_at: Instant::now(),
        });
        self.dirty = true;
    }

    fn on_move(&mut self, sx: i32, sy: i32) {
        let Some(stroke) = self.stroke.as_mut() else {
            return;
        };
        if stroke.canceled {
            return;
        }
        let sf = if stroke.viewport.scale_factor > 0.0 {
            stroke.viewport.scale_factor
        } else {
            1.0
        };
        let lx = (sx - stroke.viewport.left) as f64 / sf;
        let ly = (sy - stroke.viewport.top) as f64 / sf;
        stroke.path.add(Point::new(lx, ly));
        self.dirty = true;
    }

    fn on_abort(&mut self) {
        if let Some(stroke) = self.stroke.as_mut() {
            if !stroke.canceled {
                stroke.canceled = true;
                self.dirty = true;
                self.hide_overlay();
            }
        }
    }

    fn on_up(&mut self, sx: i32, sy: i32) {
        unsafe {
            let _ = KillTimer(Some(self.hwnd), TIMER_GESTURE_TICK);
        }
        let Some(mut stroke) = self.stroke.take() else {
            self.hide_overlay();
            return;
        };

        let sf = if stroke.viewport.scale_factor > 0.0 {
            stroke.viewport.scale_factor
        } else {
            1.0
        };
        let lx = (sx - stroke.viewport.left) as f64 / sf;
        let ly = (sy - stroke.viewport.top) as f64 / sf;

        let shape = if stroke.canceled {
            None
        } else {
            stroke.path.finish(Point::new(lx, ly))
        };

        let used = stroke.canceled
            || stroke.live_scrolled
            || stroke.path.ever_recognized()
            || shape.is_some();

        self.hide_overlay();

        if !used {
            // 動かさずに離した = 通常の右クリックをWebView2へ送り直す
            replay_secondary_click();
            return;
        }

        let Some(shape) = shape else {
            return;
        };

        let action = stroke.settings.action_for(&shape).to_string();
        if action == "none" {
            if stroke.settings.show_feedback {
                self.set_notice(
                    format!(
                        "{} ({}) は未割り当てです",
                        shape_arrows(&shape),
                        shape_name_ja(&shape)
                    ),
                    false,
                );
            }
            return;
        }

        // スクロールはドラッグ中に進行済みのため離した時は追加操作なし
        if scroll_dir_of(&action).is_some() {
            return;
        }

        let origin = stroke.path.origin();
        let ctx = GestureActionContext {
            origin_lx: origin.x,
            origin_ly: origin.y,
        };
        (self.callbacks.on_action)(action, shape, ctx);
    }

    fn on_tick(&mut self) {
        let Some(stroke) = self.stroke.as_mut() else {
            unsafe {
                let _ = KillTimer(Some(self.hwnd), TIMER_GESTURE_TICK);
            }
            return;
        };

        // Esc キー / サスペンド / ウィンドウ非表示・最小化 / 30秒タイムアウトで中止
        // (HisatorNotebook w247AbortsOnLifecycle 準拠: 焦点移動だけでは中止しない)
        let esc_down = unsafe { GetAsyncKeyState(VK_ESCAPE.0 as i32) } < 0;
        let suspended = hook_state().suspended.load(Ordering::Relaxed);
        let main_raw = hook_state().main_hwnd.load(Ordering::Relaxed);
        let main_hidden = if main_raw != 0 {
            let mh = HWND(main_raw as *mut c_void);
            unsafe { !IsWindowVisible(mh).as_bool() || IsIconic(mh).as_bool() }
        } else {
            false
        };
        let timed_out = stroke.started_at.elapsed() > Duration::from_secs(30);

        if esc_down || suspended || main_hidden || timed_out {
            stroke.canceled = true;
            self.hide_overlay();
            return;
        }

        let now = Instant::now();
        let dt = now.duration_since(stroke.last_tick).as_secs_f64().min(0.1);
        stroke.last_tick = now;

        // リアルタイム連続スクロール (HisatorNotebook w367 準拠)
        if !stroke.canceled {
            let cur_shape = stroke.path.shape();
            let verts = stroke.path.vertices();
            let ls = live_scroll_of(
                cur_shape.as_deref(),
                stroke.path.pending(),
                stroke.path.invalid(),
                stroke.canceled,
                &verts,
                &stroke.settings,
                stroke.last_scroll_shape.as_deref(),
            );
            stroke.last_scroll_shape = ls.shape;
            if let Some(dir) = ls.dir {
                if ls.speed > 0.0 && dt > 0.0 {
                    let (dx, dy) = reveal_delta(dir, ls.speed * dt);
                    let origin = stroke.path.origin();
                    (self.callbacks.on_live_scroll)(origin.x, origin.y, dx, dy);
                    stroke.live_scrolled = true;
                }
            }
        }

        if self.dirty {
            self.dirty = false;
            self.render_overlay();
        }
    }

    fn take_pending_notice(&mut self) {
        let next = hook_state()
            .pending_notice
            .lock()
            .ok()
            .and_then(|mut slot| slot.take());
        if let Some((text, is_error)) = next {
            self.set_notice(text, is_error);
        }
    }

    fn set_notice(&mut self, text: String, is_error: bool) {
        let show = hook_state()
            .settings
            .lock()
            .map(|s| s.show_feedback)
            .unwrap_or(true);
        if !show || text.is_empty() {
            return;
        }
        self.notice = Some(OverlayNotice { text, is_error });
        unsafe {
            let _ = SetTimer(Some(self.hwnd), TIMER_NOTICE_HIDE, 2200, None);
        }
        self.render_overlay();
    }

    fn clear_notice(&mut self) {
        self.notice = None;
        unsafe {
            let _ = KillTimer(Some(self.hwnd), TIMER_NOTICE_HIDE);
        }
        if self.stroke.is_none() {
            self.hide_overlay();
        } else {
            self.render_overlay();
        }
    }

    fn hide_overlay(&mut self) {
        if self.visible && self.notice.is_none() {
            unsafe {
                let _ = ShowWindow(self.hwnd, SW_HIDE);
            }
            self.visible = false;
        }
    }

    fn render_overlay(&mut self) {
        let vp = if let Some(ref s) = self.stroke {
            s.viewport
        } else {
            hook_state().viewport.lock().map(|v| *v).unwrap_or_default()
        };
        if vp.width <= 0 || vp.height <= 0 {
            self.hide_overlay();
            return;
        }

        let draw_stroke = self.stroke.as_ref().filter(|s| !s.canceled);
        let has_trail = draw_stroke
            .map(|s| s.settings.show_trail && s.path.ever_recognized())
            .unwrap_or(false);
        let has_guide = draw_stroke
            .map(|s| s.settings.show_feedback && s.path.shape().is_some())
            .unwrap_or(false);
        let has_notice = draw_stroke.is_none() && self.notice.is_some();

        if !has_trail && !has_guide && !has_notice {
            if self.visible {
                unsafe {
                    let _ = ShowWindow(self.hwnd, SW_HIDE);
                }
                self.visible = false;
            }
            return;
        }

        let w = vp.width;
        let h = vp.height;
        let sf = (if vp.scale_factor > 0.0 {
            vp.scale_factor
        } else {
            1.0
        }) as f32;

        unsafe {
            let screen_dc = GetDC(None);
            let mem_dc = CreateCompatibleDC(Some(screen_dc));
            let bmi = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: w,
                    biHeight: -h, // top-down DIB
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let mut bits: *mut c_void = std::ptr::null_mut();
            let Ok(hbmp) = CreateDIBSection(Some(mem_dc), &bmi, DIB_RGB_COLORS, &mut bits, None, 0)
            else {
                let _ = DeleteDC(mem_dc);
                ReleaseDC(None, screen_dc);
                return;
            };
            let old_obj: HGDIOBJ = SelectObject(mem_dc, HGDIOBJ(hbmp.0));

            // ゼロ初期化（完全透明）
            std::ptr::write_bytes(bits as *mut u8, 0, (w as usize) * (h as usize) * 4);

            let mut gp_bmp: *mut GpBitmap = std::ptr::null_mut();
            let mut gfx: *mut GpGraphics = std::ptr::null_mut();
            if GdipCreateBitmapFromScan0(
                w,
                h,
                w * 4,
                PIXEL_FORMAT_32BPP_PARGB,
                Some(bits as *const u8),
                &mut gp_bmp,
            ) == windows::Win32::Graphics::GdiPlus::Ok
                && GdipGetImageGraphicsContext(gp_bmp as *mut GpImage, &mut gfx)
                    == windows::Win32::Graphics::GdiPlus::Ok
            {
                let _ = GdipGraphicsClear(gfx, 0x0000_0000);
                let _ = GdipSetSmoothingMode(gfx, SmoothingModeAntiAlias);
                let _ = GdipSetTextRenderingHint(gfx, TextRenderingHintAntiAliasGridFit);

                if let Some(stroke) = draw_stroke {
                    // 1. 軌跡の描画 (HisatorNotebook _W246TrailPainter 準拠: 白縁 + ティール #159CAB + 始点丸)
                    if has_trail {
                        let verts = stroke.path.vertices();
                        let pts: Vec<PointF> = verts
                            .iter()
                            .map(|p| PointF {
                                X: (p.x as f32) * sf,
                                Y: (p.y as f32) * sf,
                            })
                            .collect();

                        if pts.len() >= 2 {
                            draw_polyline(gfx, &pts, 0xF0FF_FFFF, 7.0 * sf);
                            draw_polyline(gfx, &pts, 0xFF15_9CAB, 4.0 * sf);
                        }
                        if let Some(first) = pts.first() {
                            draw_circle(gfx, first.X, first.Y, 6.0 * sf, 0xFFFF_FFFF);
                            draw_circle(gfx, first.X, first.Y, 4.0 * sf, 0xFF15_9CAB);
                        }
                    }

                    // 2. 操作ガイドカード（画面下部中央）
                    if has_guide {
                        if let Some(shape) = stroke.path.shape() {
                            let action = stroke.settings.action_for(&shape);
                            let arrows = shape_arrows(&shape);
                            let name = shape_name_ja(&shape);
                            let label = action_label_ja(action);
                            let is_scroll = scroll_dir_of(action).is_some();
                            let title = format!("{arrows}   {name}  ·  {label}");
                            let sub = if action == "none" {
                                "ジェスチャー設定から操作を割り当てできます"
                            } else if is_scroll {
                                "ドラッグ中リアルタイムスクロール · 離すと停止"
                            } else if action == "ctrl-click" {
                                "右ボタンを離すと開始位置を Ctrl+クリック · Esc で中止"
                            } else {
                                "右ボタンを離すと実行 · Esc で中止"
                            };
                            let border = if action == "none" {
                                0xAA94_A3B8
                            } else {
                                0xEE15_9CAB
                            };
                            draw_hud_card(gfx, w as f32, h as f32, sf, &title, Some(sub), border);
                        }
                    }
                } else if let Some(ref notice) = self.notice {
                    let border = if notice.is_error {
                        0xEEE5_7373
                    } else {
                        0xCC64_748B
                    };
                    draw_hud_card(gfx, w as f32, h as f32, sf, &notice.text, None, border);
                }

                let _ = GdipDeleteGraphics(gfx);
            }
            if !gp_bmp.is_null() {
                let _ = GdipDisposeImage(gp_bmp as *mut GpImage);
            }

            let dst_pos = POINT {
                x: vp.left,
                y: vp.top,
            };
            let dst_size = SIZE { cx: w, cy: h };
            let src_pos = POINT { x: 0, y: 0 };
            let blend = BLENDFUNCTION {
                BlendOp: AC_SRC_OVER as u8,
                BlendFlags: 0,
                SourceConstantAlpha: 255,
                AlphaFormat: AC_SRC_ALPHA as u8,
            };

            let _ = UpdateLayeredWindow(
                self.hwnd,
                Some(screen_dc),
                Some(&dst_pos),
                Some(&dst_size),
                Some(mem_dc),
                Some(&src_pos),
                windows::Win32::Foundation::COLORREF(0),
                Some(&blend),
                ULW_ALPHA,
            );

            if !self.visible {
                let _ = ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
                let _ = SetWindowPos(
                    self.hwnd,
                    Some(HWND_TOPMOST),
                    0,
                    0,
                    0,
                    0,
                    SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE,
                );
                self.visible = true;
            }

            SelectObject(mem_dc, old_obj);
            let _ = DeleteObject(HGDIOBJ(hbmp.0));
            let _ = DeleteDC(mem_dc);
            ReleaseDC(None, screen_dc);
        }
    }
}

unsafe fn draw_polyline(gfx: *mut GpGraphics, pts: &[PointF], argb: u32, width: f32) {
    let mut pen: *mut GpPen = std::ptr::null_mut();
    if GdipCreatePen1(argb, width, UnitPixel, &mut pen) == windows::Win32::Graphics::GdiPlus::Ok {
        let _ = GdipSetPenLineCap197819(pen, LineCapRound, LineCapRound, DashCapFlat);
        let _ = GdipSetPenLineJoin(pen, LineJoinRound);
        let _ = GdipDrawLines(gfx, pen, pts.as_ptr(), pts.len() as i32);
        let _ = GdipDeletePen(pen);
    }
}

unsafe fn draw_circle(gfx: *mut GpGraphics, cx: f32, cy: f32, r: f32, argb: u32) {
    let mut brush: *mut GpSolidFill = std::ptr::null_mut();
    if GdipCreateSolidFill(argb, &mut brush) == windows::Win32::Graphics::GdiPlus::Ok {
        let _ = GdipFillEllipse(gfx, brush as *mut GpBrush, cx - r, cy - r, r * 2.0, r * 2.0);
        let _ = GdipDeleteBrush(brush as *mut GpBrush);
    }
}

unsafe fn add_rounded_rect_path(x: f32, y: f32, w: f32, h: f32, r: f32) -> *mut GpPath {
    let mut path: *mut GpPath = std::ptr::null_mut();
    if GdipCreatePath(FillModeAlternate, &mut path) != windows::Win32::Graphics::GdiPlus::Ok {
        return std::ptr::null_mut();
    }
    let d = r * 2.0;
    let _ = GdipAddPathArc(path, x, y, d, d, 180.0, 90.0);
    let _ = GdipAddPathArc(path, x + w - d, y, d, d, 270.0, 90.0);
    let _ = GdipAddPathArc(path, x + w - d, y + h - d, d, d, 0.0, 90.0);
    let _ = GdipAddPathArc(path, x, y + h - d, d, d, 90.0, 90.0);
    let _ = GdipClosePathFigure(path);
    path
}

unsafe fn draw_hud_card(
    gfx: *mut GpGraphics,
    vp_w: f32,
    vp_h: f32,
    sf: f32,
    title: &str,
    sub: Option<&str>,
    border_argb: u32,
) {
    let card_w = (440.0 * sf).min((vp_w - 32.0 * sf).max(200.0));
    let card_h = if sub.is_some() { 64.0 * sf } else { 42.0 * sf };
    let x = (vp_w - card_w) * 0.5;
    let y = (vp_h - card_h - 26.0 * sf).max(12.0 * sf);
    let radius = 12.0 * sf;

    let path = add_rounded_rect_path(x, y, card_w, card_h, radius);
    if !path.is_null() {
        let mut bg_brush: *mut GpSolidFill = std::ptr::null_mut();
        if GdipCreateSolidFill(0xEB14_1926, &mut bg_brush) == windows::Win32::Graphics::GdiPlus::Ok {
            let _ = GdipFillPath(gfx, bg_brush as *mut GpBrush, path);
            let _ = GdipDeleteBrush(bg_brush as *mut GpBrush);
        }
        let mut pen: *mut GpPen = std::ptr::null_mut();
        if GdipCreatePen1(border_argb, 1.5 * sf, UnitPixel, &mut pen)
            == windows::Win32::Graphics::GdiPlus::Ok
        {
            let _ = GdipDrawPath(gfx, pen, path);
            let _ = GdipDeletePen(pen);
        }
        let _ = GdipDeletePath(path);
    }

    // 日本語フォント（Yu Gothic UI / Segoe UI フォールバック）
    let mut family: *mut GpFontFamily = std::ptr::null_mut();
    let fam_name = HSTRING::from("Yu Gothic UI");
    if GdipCreateFontFamilyFromName(&fam_name, std::ptr::null_mut(), &mut family)
        != windows::Win32::Graphics::GdiPlus::Ok
    {
        let fallback = HSTRING::from("Segoe UI");
        let _ = GdipCreateFontFamilyFromName(&fallback, std::ptr::null_mut(), &mut family);
    }
    if family.is_null() {
        return;
    }

    let mut fmt: *mut GpStringFormat = std::ptr::null_mut();
    let _ = GdipCreateStringFormat(0, 0, &mut fmt);
    if !fmt.is_null() {
        let _ = GdipSetStringFormatAlign(fmt, StringAlignmentCenter);
        let _ = GdipSetStringFormatLineAlign(fmt, StringAlignmentCenter);
    }

    let mut font_title: *mut GpFont = std::ptr::null_mut();
    if GdipCreateFont(family, 15.0 * sf, FontStyleBold.0, UnitPixel, &mut font_title)
        == windows::Win32::Graphics::GdiPlus::Ok
    {
        let mut brush: *mut GpSolidFill = std::ptr::null_mut();
        if GdipCreateSolidFill(0xFFFF_FFFF, &mut brush) == windows::Win32::Graphics::GdiPlus::Ok {
            let title_h = HSTRING::from(title);
            let rect = RectF {
                X: x + 12.0 * sf,
                Y: if sub.is_some() { y + 7.0 * sf } else { y },
                Width: card_w - 24.0 * sf,
                Height: if sub.is_some() { 30.0 * sf } else { card_h },
            };
            let _ = GdipDrawString(
                gfx,
                &title_h,
                -1,
                font_title,
                &rect,
                fmt,
                brush as *const GpBrush,
            );
            let _ = GdipDeleteBrush(brush as *mut GpBrush);
        }
        let _ = GdipDeleteFont(font_title);
    }

    if let Some(sub_text) = sub {
        let mut font_sub: *mut GpFont = std::ptr::null_mut();
        if GdipCreateFont(family, 11.5 * sf, FontStyleRegular.0, UnitPixel, &mut font_sub)
            == windows::Win32::Graphics::GdiPlus::Ok
        {
            let mut brush: *mut GpSolidFill = std::ptr::null_mut();
            if GdipCreateSolidFill(0xB8CB_D5E1, &mut brush)
                == windows::Win32::Graphics::GdiPlus::Ok
            {
                let sub_h = HSTRING::from(sub_text);
                let rect = RectF {
                    X: x + 12.0 * sf,
                    Y: y + 36.0 * sf,
                    Width: card_w - 24.0 * sf,
                    Height: 22.0 * sf,
                };
                let _ = GdipDrawString(
                    gfx,
                    &sub_h,
                    -1,
                    font_sub,
                    &rect,
                    fmt,
                    brush as *const GpBrush,
                );
                let _ = GdipDeleteBrush(brush as *mut GpBrush);
            }
            let _ = GdipDeleteFont(font_sub);
        }
    }

    if !fmt.is_null() {
        let _ = GdipDeleteStringFormat(fmt);
    }
    let _ = GdipDeleteFontFamily(family);
}

thread_local! {
    static OVERLAY_RT: std::cell::RefCell<Option<OverlayRuntime>> = const { std::cell::RefCell::new(None) };
}

unsafe extern "system" fn overlay_wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_GESTURE_EVENT => {
            OVERLAY_RT.with(|cell| {
                if let Some(rt) = cell.borrow_mut().as_mut() {
                    rt.drain_events();
                }
            });
            LRESULT(0)
        }
        WM_GESTURE_NOTICE => {
            OVERLAY_RT.with(|cell| {
                if let Some(rt) = cell.borrow_mut().as_mut() {
                    rt.take_pending_notice();
                }
            });
            LRESULT(0)
        }
        WM_TIMER => {
            let id = wparam.0;
            OVERLAY_RT.with(|cell| {
                if let Some(rt) = cell.borrow_mut().as_mut() {
                    if id == TIMER_GESTURE_TICK {
                        rt.on_tick();
                    } else if id == TIMER_NOTICE_HIDE {
                        rt.clear_notice();
                    }
                }
            });
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

#[derive(Clone)]
pub struct GestureWinHost {
    thread_id: Arc<AtomicIsize>,
}

impl GestureWinHost {
    pub fn start(
        main_hwnd: isize,
        initial_settings: GestureSettings,
        callbacks: GestureHostCallbacks,
    ) -> Self {
        let st = hook_state();
        st.main_hwnd.store(main_hwnd, Ordering::SeqCst);
        st.enabled.store(initial_settings.enabled, Ordering::SeqCst);
        if let Ok(mut s) = st.settings.lock() {
            *s = initial_settings;
        }

        let thread_id = Arc::new(AtomicIsize::new(0));
        let thread_id_bg = thread_id.clone();

        std::thread::Builder::new()
            .name("omnisns-gesture".to_string())
            .spawn(move || {
                unsafe {
                    let tid = windows::Win32::System::Threading::GetCurrentThreadId();
                    thread_id_bg.store(tid as isize, Ordering::SeqCst);

                    // GDI+ 初期化
                    let mut gdip_token: usize = 0;
                    let gdip_input = GdiplusStartupInput {
                        GdiplusVersion: 1,
                        ..Default::default()
                    };
                    let _ = GdiplusStartup(&mut gdip_token, &gdip_input, std::ptr::null_mut());

                    // 透明レイヤードオーバーレイウィンドウ作成
                    let hmod = GetModuleHandleW(PCWSTR::null()).unwrap_or_default();
                    let hinst = HINSTANCE(hmod.0);
                    let class_name = HSTRING::from("OmniSNSGestureOverlay");
                    let wc = WNDCLASSEXW {
                        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                        style: CS_HREDRAW | CS_VREDRAW,
                        lpfnWndProc: Some(overlay_wnd_proc),
                        hInstance: hinst,
                        hIcon: HICON::default(),
                        hCursor: HCURSOR::default(),
                        lpszClassName: PCWSTR(class_name.as_ptr()),
                        ..Default::default()
                    };
                    let _ = RegisterClassExW(&wc);

                    let owner = if main_hwnd != 0 {
                        Some(HWND(main_hwnd as *mut c_void))
                    } else {
                        None
                    };

                    let overlay_hwnd = CreateWindowExW(
                        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                        &class_name,
                        PCWSTR::null(),
                        WS_POPUP,
                        0,
                        0,
                        1,
                        1,
                        owner,
                        None,
                        Some(hinst),
                        None,
                    )
                    .unwrap_or_default();

                    if !overlay_hwnd.0.is_null() {
                        hook_state()
                            .overlay_hwnd
                            .store(overlay_hwnd.0 as isize, Ordering::SeqCst);
                        OVERLAY_RT.with(|cell| {
                            *cell.borrow_mut() = Some(OverlayRuntime {
                                hwnd: overlay_hwnd,
                                callbacks,
                                stroke: None,
                                notice: None,
                                dirty: false,
                                visible: false,
                            });
                        });
                    }

                    // 低レベルマウスフック登録（このスレッドのメッセージループで高速処理）
                    let hook: Option<HHOOK> = SetWindowsHookExW(
                        WH_MOUSE_LL,
                        Some(low_level_mouse_proc),
                        Some(hinst),
                        0,
                    )
                    .ok();

                    let mut msg = MSG::default();
                    while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                        let _ = TranslateMessage(&msg);
                        DispatchMessageW(&msg);
                    }

                    if let Some(h) = hook {
                        let _ = UnhookWindowsHookEx(h);
                    }
                    hook_state().overlay_hwnd.store(0, Ordering::SeqCst);
                    hook_state().tracking.store(false, Ordering::SeqCst);
                    OVERLAY_RT.with(|cell| {
                        *cell.borrow_mut() = None;
                    });
                    if !overlay_hwnd.0.is_null() {
                        let _ = DestroyWindow(overlay_hwnd);
                    }
                    if gdip_token != 0 {
                        GdiplusShutdown(gdip_token);
                    }
                }
            })
            .ok();

        Self { thread_id }
    }

    pub fn update_viewport(&self, vp: ViewportRect) {
        if let Ok(mut guard) = hook_state().viewport.lock() {
            *guard = vp;
        }
    }

    pub fn update_settings(&self, settings: GestureSettings) {
        let st = hook_state();
        st.enabled.store(settings.enabled, Ordering::SeqCst);
        if let Ok(mut guard) = st.settings.lock() {
            *guard = settings;
        }
    }

    pub fn set_suspended(&self, suspended: bool) {
        hook_state().suspended.store(suspended, Ordering::SeqCst);
    }

    pub fn show_notice(&self, text: impl Into<String>, is_error: bool) {
        let st = hook_state();
        if let Ok(mut slot) = st.pending_notice.lock() {
            *slot = Some((text.into(), is_error));
        }
        let ov = st.overlay_hwnd.load(Ordering::Relaxed);
        if ov != 0 {
            unsafe {
                let _ = PostMessageW(
                    Some(HWND(ov as *mut c_void)),
                    WM_GESTURE_NOTICE,
                    WPARAM(0),
                    LPARAM(0),
                );
            }
        }
    }

    pub fn shutdown(&self) {
        let tid = self.thread_id.load(Ordering::Relaxed) as u32;
        if tid != 0 {
            unsafe {
                let _ = PostThreadMessageW(tid, WM_QUIT, WPARAM(0), LPARAM(0));
            }
        }
    }
}

/// メインウィンドウのクライアント座標から、ビューポート矩形のスクリーン物理座標を計算する。
pub fn compute_viewport_screen_rect(
    main_hwnd: isize,
    sidebar_logical_w: f64,
    header_logical_h: f64,
    bottom_logical_h: f64,
    scale_factor: f64,
) -> Option<ViewportRect> {
    if main_hwnd == 0 {
        return None;
    }
    let hwnd = HWND(main_hwnd as *mut c_void);
    let mut client = RECT::default();
    let mut top_left = POINT { x: 0, y: 0 };
    unsafe {
        if windows::Win32::UI::WindowsAndMessaging::GetClientRect(hwnd, &mut client).is_err() {
            return None;
        }
        if !windows::Win32::Graphics::Gdi::ClientToScreen(hwnd, &mut top_left).as_bool() {
            return None;
        }
    }
    let sf = if scale_factor > 0.0 { scale_factor } else { 1.0 };
    let off_x = (sidebar_logical_w * sf).round() as i32;
    let off_y = (header_logical_h * sf).round() as i32;
    let off_bottom = (bottom_logical_h.max(0.0) * sf).round() as i32;
    let total_w = client.right - client.left;
    let total_h = client.bottom - client.top;
    let vp_w = (total_w - off_x).max(0);
    let vp_h = (total_h - off_y - off_bottom).max(0);
    Some(ViewportRect {
        left: top_left.x + off_x,
        top: top_left.y + off_y,
        width: vp_w,
        height: vp_h,
        scale_factor: sf,
    })
}
