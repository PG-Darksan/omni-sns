use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tauri::webview::{NewWindowResponse, PermissionKind, PermissionResponse, WebviewBuilder};
use tauri::{
    AppHandle, Emitter, EventTarget, LogicalPosition, LogicalSize, Manager, Rect, Webview,
    WebviewUrl, WebviewWindowBuilder,
};

use crate::follow_sync::{FollowSyncSettings, UpdateFollowSyncPatch};
use crate::gesture::{step_tab_index, GestureSettings};
use crate::models::{
    BrowserTabInfo, SavedSubTab, ServiceInstance, TabRuntimeState, UpdateSettingsPatch,
};
use crate::store::ConfigStore;
use crate::url_utils::{
    build_user_agent, detect_platform_service_from_url, is_auth_popup_for_site, is_auth_popup_url,
    is_http_url, is_internal_tauri_url, is_same_site_url, normalize_service_url,
    parse_unread_count_from_title, service_group_key,
};

/// 同一プロファイルを共有する全タブ WebView2 へ統一指定する高速起動フラグ。
/// バックグラウンド・オフスクリーン生成時の Chromium スロットリングとウィンドウ遮蔽判定を抑止し、
/// Instagram / Threads 等の重い SPA が別タブで瞬時にハイドレーション完了するようにする。
#[cfg(windows)]
const WEBVIEW2_FAST_BROWSER_ARGS: &str = "--disable-features=msWebOOUI,msPdfOOUI,CalculateNativeWinOcclusion --disable-background-timer-throttling --disable-backgrounding-occluded-windows --disable-renderer-backgrounding";

const BG_WARM_MAX_SECS: u64 = 8;
const BG_WARM_POST_LOAD_MS: u64 = 2500;
const GMAIL_HOME_URL: &str = "https://mail.google.com/";

pub const ACCOUNTBAR_HEIGHT: f64 = 40.0;
pub const TOOLBAR_HEIGHT: f64 = 44.0;
pub const TABBAR_HEIGHT: f64 = 34.0;
pub const TOP_HEADER_HEIGHT: f64 = ACCOUNTBAR_HEIGHT + TOOLBAR_HEIGHT + TABBAR_HEIGHT;

pub fn top_header_height(header_collapsed: bool, active_tab_count: usize) -> f64 {
    if !header_collapsed {
        TOP_HEADER_HEIGHT
    } else if active_tab_count >= 2 {
        ACCOUNTBAR_HEIGHT + TABBAR_HEIGHT
    } else {
        ACCOUNTBAR_HEIGHT
    }
}
const MAX_SUBTABS_PER_SERVICE: usize = 20;
const MAX_CLOSED_HISTORY: usize = 25;

static WEBVIEW_GEN: AtomicU64 = AtomicU64::new(1);
static TAB_GEN: AtomicU64 = AtomicU64::new(1);
static POPUP_GEN: AtomicU64 = AtomicU64::new(1);

fn next_tab_id() -> String {
    format!("t-{}", TAB_GEN.fetch_add(1, Ordering::Relaxed))
}

#[derive(Debug, Clone, Copy)]
pub struct ContentBounds {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Default for ContentBounds {
    fn default() -> Self {
        Self {
            x: 248.0,
            y: TOP_HEADER_HEIGHT,
            width: 1000.0,
            height: 760.0,
        }
    }
}

#[derive(Debug, Clone)]
pub struct BrowserTabEntry {
    pub tab_id: String,
    pub instance_id: String,
    pub webview_label: Option<String>,
    pub creation_epoch: u64,
    pub warming_until: Option<Instant>,
    pub current_url: String,
    pub title: String,
    pub favicon_url: Option<String>,
    pub unread_count: u32,
    pub is_loading: bool,
    pub is_sleeping: bool,
    pub can_go_back: bool,
    pub can_go_forward: bool,
    pub load_error: Option<String>,
}

impl BrowserTabEntry {
    fn new_for_service(inst: &ServiceInstance, url: String, title: String) -> Self {
        Self {
            tab_id: next_tab_id(),
            instance_id: inst.instance_id.clone(),
            webview_label: None,
            creation_epoch: 0,
            warming_until: None,
            current_url: url,
            title,
            favicon_url: None,
            unread_count: 0,
            is_loading: false,
            is_sleeping: true,
            can_go_back: false,
            can_go_forward: false,
            load_error: None,
        }
    }

    pub fn to_info(&self) -> BrowserTabInfo {
        BrowserTabInfo {
            tab_id: self.tab_id.clone(),
            instance_id: self.instance_id.clone(),
            current_url: self.current_url.clone(),
            title: self.title.clone(),
            favicon_url: self.favicon_url.clone(),
            unread_count: self.unread_count,
            is_loading: self.is_loading,
            is_sleeping: self.is_sleeping,
            can_go_back: self.can_go_back,
            can_go_forward: self.can_go_forward,
            load_error: self.load_error.clone(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ServiceTabs {
    pub tabs: Vec<BrowserTabEntry>,
    pub active_tab_id: String,
}

impl ServiceTabs {
    fn new_initial(inst: &ServiceInstance) -> Self {
        if inst.saved_tabs.len() >= 2 {
            let tabs: Vec<BrowserTabEntry> = inst
                .saved_tabs
                .iter()
                .map(|st| {
                    let title = if st.title.trim().is_empty() {
                        inst.name.clone()
                    } else {
                        st.title.clone()
                    };
                    BrowserTabEntry::new_for_service(inst, st.url.clone(), title)
                })
                .collect();
            let active_idx = inst
                .saved_active_tab_index
                .unwrap_or(0)
                .min(tabs.len() - 1);
            let active_tab_id = tabs[active_idx].tab_id.clone();
            return Self {
                tabs,
                active_tab_id,
            };
        }
        let first = BrowserTabEntry::new_for_service(inst, inst.url.clone(), inst.name.clone());
        let active_tab_id = first.tab_id.clone();
        Self {
            tabs: vec![first],
            active_tab_id,
        }
    }

    fn active_tab(&self) -> Option<&BrowserTabEntry> {
        self.tabs
            .iter()
            .find(|t| t.tab_id == self.active_tab_id)
            .or_else(|| self.tabs.first())
    }

    fn tab_mut(&mut self, tab_id: &str) -> Option<&mut BrowserTabEntry> {
        self.tabs.iter_mut().find(|t| t.tab_id == tab_id)
    }

    fn to_runtime_state(
        &self,
        inst: &ServiceInstance,
        cross_site: Option<&(String, String)>,
    ) -> TabRuntimeState {
        let active = self.active_tab();
        let total_unread: u32 = self
            .tabs
            .iter()
            .fold(0u32, |acc, t| acc.saturating_add(t.unread_count));
        TabRuntimeState {
            instance_id: inst.instance_id.clone(),
            current_url: active
                .map(|t| t.current_url.clone())
                .unwrap_or_else(|| inst.url.clone()),
            title: active
                .map(|t| t.title.clone())
                .unwrap_or_else(|| inst.name.clone()),
            favicon_url: active
                .and_then(|t| t.favicon_url.clone())
                .or_else(|| self.tabs.iter().find_map(|t| t.favicon_url.clone())),
            unread_count: total_unread,
            is_loading: active.map(|t| t.is_loading).unwrap_or(false),
            is_sleeping: active.map(|t| t.is_sleeping).unwrap_or(true),
            can_go_back: active.map(|t| t.can_go_back).unwrap_or(false),
            can_go_forward: active.map(|t| t.can_go_forward).unwrap_or(false),
            muted: inst.muted,
            zoom_factor: inst.zoom_factor,
            ua_mode: inst.ua_mode.clone(),
            load_error: active.and_then(|t| t.load_error.clone()),
            active_tab_id: active
                .map(|t| t.tab_id.clone())
                .unwrap_or_else(|| self.active_tab_id.clone()),
            tabs: self.tabs.iter().map(|t| t.to_info()).collect(),
            cross_site_service: cross_site.map(|(svc, _)| svc.clone()),
            cross_site_handle: cross_site.map(|(_, h)| h.clone()),
        }
    }
}

#[derive(Debug, Clone)]
pub enum ClosedEntry {
    SubTab {
        instance_id: String,
        url: String,
        title: String,
    },
    #[allow(dead_code)]
    Service {
        instance: ServiceInstance,
        url: String,
        title: String,
    },
}

pub struct AppStateInner {
    pub store: ConfigStore,
    pub services: HashMap<String, ServiceTabs>,
    /// `tab_id -> (pending_webview_label, creation_epoch)`（`win.add_child` 実行中の重複生成防止および孤立・旧エポック判定用）
    pub creating_tabs: HashMap<String, (String, u64)>,
    /// `tab_id -> desired_url`（WebView2 生成中に届いた遷移／再生成要求を取りこぼさないための保留キュー）
    pub pending_tab_nav: HashMap<String, String>,
    pub last_active_by_group: HashMap<String, String>,
    pub cross_site_identities: HashMap<String, (String, String)>,
    pub closed_tabs: Vec<ClosedEntry>,
    pub active_instance_id: Option<String>,
    pub gmail_open: bool,
    pub gmail_tab: Option<BrowserTabEntry>,
    pub gmail_creating_label: Option<String>,
    pub overlay_visible: bool,
    pub is_quitting: bool,
    pub bootstrapped: bool,
    pub bounds: ContentBounds,
    pub profiles_root: PathBuf,
    pub chrome_version: String,
    pub main_hwnd: isize,
    pub cloud_sync_gen: Arc<AtomicU64>,
    pub cloud_sync_config_gen: Arc<AtomicU64>,
    pub cloud_sync_worker_running: Arc<AtomicBool>,
    pub bounds_persist_gen: Arc<AtomicU64>,
    pub bounds_persist_worker_running: Arc<AtomicBool>,
    #[cfg(windows)]
    pub gesture_host: Option<crate::gesture_win::GestureWinHost>,
}

#[derive(Clone)]
pub struct SharedState {
    pub inner: Arc<Mutex<AppStateInner>>,
    /// GitHub Gist 同期を直列化するための専用ロック（`inner` ロック外で取得する）
    pub cloud_sync_lock: Arc<Mutex<()>>,
}

impl SharedState {
    pub fn new(store: ConfigStore, profiles_root: PathBuf, chrome_version: String) -> Self {
        let mut services = HashMap::new();
        for inst in store.get_instances() {
            services.insert(inst.instance_id.clone(), ServiceTabs::new_initial(&inst));
        }
        let settings_init = store.get_settings();
        let sidebar_w = settings_init.sidebar_width as f64;
        let init_tab_count = settings_init
            .active_instance_id
            .as_deref()
            .and_then(|id| services.get(id))
            .map(|s| s.tabs.len())
            .unwrap_or(0);
        let top_h = top_header_height(settings_init.header_collapsed, init_tab_count);
        Self {
            inner: Arc::new(Mutex::new(AppStateInner {
                store,
                services,
                creating_tabs: HashMap::new(),
                pending_tab_nav: HashMap::new(),
                last_active_by_group: HashMap::new(),
                cross_site_identities: HashMap::new(),
                closed_tabs: Vec::new(),
                active_instance_id: None,
                gmail_open: false,
                gmail_tab: None,
                gmail_creating_label: None,
                overlay_visible: false,
                is_quitting: false,
                bootstrapped: false,
                bounds: ContentBounds {
                    x: sidebar_w,
                    y: top_h,
                    width: 1000.0,
                    height: 760.0,
                },
                profiles_root,
                chrome_version,
                main_hwnd: 0,
                cloud_sync_gen: Arc::new(AtomicU64::new(0)),
                cloud_sync_config_gen: Arc::new(AtomicU64::new(0)),
                cloud_sync_worker_running: Arc::new(AtomicBool::new(false)),
                bounds_persist_gen: Arc::new(AtomicU64::new(0)),
                bounds_persist_worker_running: Arc::new(AtomicBool::new(false)),
                #[cfg(windows)]
                gesture_host: None,
            })),
            cloud_sync_lock: Arc::new(Mutex::new(())),
        }
    }

    pub fn build_all_runtime_states(guard: &AppStateInner) -> Vec<TabRuntimeState> {
        let mut out = Vec::new();
        for inst in guard.store.get_instances() {
            if let Some(st) = guard.services.get(&inst.instance_id) {
                let cross = guard.cross_site_identities.get(&inst.instance_id);
                out.push(st.to_runtime_state(&inst, cross));
            }
        }
        out
    }

    pub fn open_webview_count(guard: &AppStateInner) -> usize {
        guard
            .services
            .values()
            .flat_map(|s| s.tabs.iter())
            .filter(|t| t.webview_label.is_some())
            .count()
    }
}

fn sanitize_profile_segment(id: &str) -> String {
    let s: String = id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    if s.is_empty() {
        "default".to_string()
    } else {
        s
    }
}

fn profile_dir_for(profiles_root: &PathBuf, instance_id: &str) -> PathBuf {
    profiles_root.join(format!("omnisns-{}", sanitize_profile_segment(instance_id)))
}

fn active_tab_count(guard: &AppStateInner) -> usize {
    guard
        .active_instance_id
        .as_deref()
        .and_then(|id| guard.services.get(id))
        .map(|s| s.tabs.len())
        .unwrap_or(0)
}

fn persist_service_tabs(guard: &mut AppStateInner, instance_id: &str) {
    let snapshot = guard.services.get(instance_id).map(|svc| {
        let mut saved: Vec<SavedSubTab> = Vec::with_capacity(svc.tabs.len());
        let mut active_idx: usize = 0;
        for t in &svc.tabs {
            if let Some(url) = normalize_service_url(&t.current_url) {
                if t.tab_id == svc.active_tab_id {
                    active_idx = saved.len();
                }
                saved.push(SavedSubTab {
                    url,
                    title: t.title.clone(),
                });
            }
        }
        (saved, active_idx)
    });
    if let Some((saved, active_idx)) = snapshot {
        guard
            .store
            .update_saved_tabs(instance_id, saved, active_idx);
    }
}

fn push_closed_entry(guard: &mut AppStateInner, entry: ClosedEntry) {
    guard.closed_tabs.push(entry);
    if guard.closed_tabs.len() > MAX_CLOSED_HISTORY {
        let drop_n = guard.closed_tabs.len() - MAX_CLOSED_HISTORY;
        guard.closed_tabs.drain(0..drop_n);
    }
}

pub fn show_overlay_notice(shared: &SharedState, text: impl Into<String>, is_error: bool) {
    #[cfg(windows)]
    {
        let host = {
            let guard = shared.inner.lock().unwrap();
            guard.gesture_host.clone()
        };
        if let Some(h) = host {
            h.show_notice(text, is_error);
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (shared, text, is_error);
    }
}

pub fn sync_gesture_host_state(app: &AppHandle, shared: &SharedState) {
    #[cfg(windows)]
    {
        let (host, main_hwnd, sidebar_w, top_h, suspended, settings) = {
            let guard = shared.inner.lock().unwrap();
            let active_sleeping_or_err = if guard.gmail_open {
                guard
                    .gmail_tab
                    .as_ref()
                    .map(|t| t.is_sleeping || t.load_error.is_some() || t.webview_label.is_none())
                    .unwrap_or(true)
            } else {
                guard
                    .active_instance_id
                    .as_deref()
                    .and_then(|id| guard.services.get(id))
                    .and_then(|s| s.active_tab())
                    .map(|t| t.is_sleeping || t.load_error.is_some() || t.webview_label.is_none())
                    .unwrap_or(true)
            };
            let suspended = guard.overlay_visible
                || (!guard.gmail_open && guard.active_instance_id.is_none())
                || active_sleeping_or_err;
            let st = guard.store.get_settings();
            let tab_count = active_tab_count(&guard);
            (
                guard.gesture_host.clone(),
                guard.main_hwnd,
                st.sidebar_width as f64,
                top_header_height(st.header_collapsed, tab_count),
                suspended,
                st.gesture,
            )
        };

        if let Some(host) = host {
            host.set_suspended(suspended);
            host.update_settings(settings);
            let sf = app
                .get_window("main")
                .and_then(|w| w.scale_factor().ok())
                .unwrap_or(1.0);
            if let Some(vp) = crate::gesture_win::compute_viewport_screen_rect(
                main_hwnd,
                sidebar_w,
                top_h,
                sf,
            ) {
                host.update_viewport(vp);
            }
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (app, shared);
    }
}

pub fn update_window_title(app: &AppHandle, shared: &SharedState) {
    let title = {
        let guard = shared.inner.lock().unwrap();
        let mut total: u32 = 0;
        for inst in guard.store.get_instances() {
            if !inst.notifications_enabled {
                continue;
            }
            if let Some(svc) = guard.services.get(&inst.instance_id) {
                for tab in &svc.tabs {
                    total = total.saturating_add(tab.unread_count);
                }
            }
        }
        if total > 0 {
            format!("({total}) OmniSNS")
        } else {
            "OmniSNS".to_string()
        }
    };

    if let Some(win) = app.get_window("main") {
        let _ = win.set_title(&title);
    }
}

pub fn emit_state_updated(app: &AppHandle, shared: &SharedState) {
    let payload = {
        let guard = shared.inner.lock().unwrap();
        crate::models::StateUpdatedPayload {
            config: guard.store.get_config(),
            runtime_states: SharedState::build_all_runtime_states(&guard),
            closed_tabs_count: guard.closed_tabs.len(),
            gmail_open: guard.gmail_open,
            gmail_runtime: guard.gmail_tab.as_ref().map(|t| t.to_info()),
        }
    };

    let _ = app.emit_to(EventTarget::webview("shell"), "app:state-updated", payload);
    update_window_title(app, shared);
}

pub fn emit_runtime_updated(app: &AppHandle, shared: &SharedState, instance_id: &str) {
    let state_opt = {
        let guard = shared.inner.lock().unwrap();
        let cross = guard.cross_site_identities.get(instance_id);
        guard.store.get_instance(instance_id).and_then(|inst| {
            guard
                .services
                .get(instance_id)
                .map(|s| s.to_runtime_state(&inst, cross))
        })
    };

    if let Some(state) = state_opt {
        let _ = app.emit_to(EventTarget::webview("shell"), "tab:runtime-updated", state);
    }
    update_window_title(app, shared);
}

pub fn ensure_safe_active_instance(shared: &SharedState) -> Option<String> {
    let mut guard = shared.inner.lock().unwrap();
    let settings = guard.store.get_settings();
    let instances = guard.store.get_instances();

    if let Some(ref cur) = settings.active_instance_id {
        if instances.iter().any(|i| &i.instance_id == cur) {
            return Some(cur.clone());
        }
    }
    let fallback = instances.first().map(|i| i.instance_id.clone());
    guard.store.update_settings(UpdateSettingsPatch {
        active_instance_id: Some(fallback.clone()),
        ..Default::default()
    });
    fallback
}

fn close_webview_cleanly(wv: &Webview) {
    let _ = wv.hide();
    let _ = wv.close();
}

/// 休止中インスタンスのホームURL・表示名が編集された場合、休止タブ側の表示状態も同期する。
pub fn sync_sleeping_instance_metadata(shared: &SharedState, inst: &ServiceInstance) {
    let mut guard = shared.inner.lock().unwrap();
    if let Some(svc) = guard.services.get_mut(&inst.instance_id) {
        if svc.tabs.len() == 1 && svc.tabs[0].is_sleeping && svc.tabs[0].webview_label.is_none() {
            svc.tabs[0].current_url = inst.url.clone();
            svc.tabs[0].title = inst.name.clone();
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProfileActivityState {
    /// 稼働中 WebView または現行エポックの生成タスクが存在（プロファイル削除を中止すべき）
    Active,
    /// 無効化（旧エポック）済みの生成タスクが終了処理中（削除中止せずリトライ待機すべき）
    ObsoleteCreating,
    /// 完全に非アクティブ（即座にリネーム・削除可能）
    Idle,
}

fn instance_profile_activity(guard: &AppStateInner, instance_id: &str) -> ProfileActivityState {
    let mut has_obsolete = false;
    if let Some(svc) = guard.services.get(instance_id) {
        for tab in &svc.tabs {
            if tab.webview_label.is_some() {
                return ProfileActivityState::Active;
            }
            if let Some((_, creating_epoch)) = guard.creating_tabs.get(&tab.tab_id) {
                if *creating_epoch == tab.creation_epoch {
                    return ProfileActivityState::Active;
                }
                has_obsolete = true;
            }
        }
    }
    if has_obsolete {
        ProfileActivityState::ObsoleteCreating
    } else {
        ProfileActivityState::Idle
    }
}

fn spawn_profile_dir_cleanup(
    shared: &SharedState,
    entries: Vec<(Option<String>, PathBuf, bool)>,
) {
    if entries.is_empty() {
        return;
    }

    // ロックされていないディレクトリは SharedState ロック下で非アクティブを確認した上で
    // 同期的に一意な退避名へリネームして切り離す。
    // これにより、直後にユーザーが同一アカウントを再アクティブ化して新しいプロファイルを作成しても
    // バックグラウンド削除スレッドが稼働中のプロファイルを消す競合を根本防止できる。
    static CLEANUP_SEQ: AtomicU64 = AtomicU64::new(1);
    let mut deferred: Vec<(Option<String>, PathBuf, bool, bool)> = Vec::new();
    for (instance_id_opt, dir, had_live_webview) in entries {
        if !dir.exists() {
            continue;
        }
        let mut renamed_to_trash = false;
        let mut target_dir = dir.clone();
        if !had_live_webview {
            let guard = shared.inner.lock().unwrap();
            let activity = match instance_id_opt.as_deref() {
                Some(inst_id) => instance_profile_activity(&guard, inst_id),
                None => ProfileActivityState::Idle,
            };
            match activity {
                ProfileActivityState::Active => continue,
                ProfileActivityState::ObsoleteCreating => {}
                ProfileActivityState::Idle => {
                    if let (Some(parent), Some(name)) = (dir.parent(), dir.file_name()) {
                        let seq = CLEANUP_SEQ.fetch_add(1, Ordering::Relaxed);
                        let trash = parent.join(format!(
                            "{}.deleting-{}-{seq}",
                            name.to_string_lossy(),
                            crate::follow_sync::now_unix_secs()
                        ));
                        if fs::rename(&dir, &trash).is_ok() {
                            target_dir = trash;
                            renamed_to_trash = true;
                        }
                    }
                }
            }
        }
        deferred.push((instance_id_opt, target_dir, had_live_webview, renamed_to_trash));
    }

    if deferred.is_empty() {
        return;
    }

    let shared_bg = shared.clone();
    std::thread::Builder::new()
        .name("omnisns-profile-cleanup".to_string())
        .spawn(move || {
            for (instance_id_opt, mut dir, had_live_webview, mut renamed_to_trash) in deferred {
                if had_live_webview {
                    std::thread::sleep(Duration::from_millis(700));
                }
                for attempt in 0..6u64 {
                    if !dir.exists() {
                        break;
                    }
                    // 元のパスを直接消す場合は、リトライ直前にロック下で再アクティブ化を確認し、
                    // O(1) リネームで切り離してからロック外で remove_dir_all を実行する。
                    // 旧エポックの生成タスクがまだ終了待ちの場合は削除を中止せず待機リトライする。
                    if !renamed_to_trash {
                        if let Some(ref inst_id) = instance_id_opt {
                            let step = {
                                let guard = shared_bg.inner.lock().unwrap();
                                match instance_profile_activity(&guard, inst_id) {
                                    ProfileActivityState::Active => None, // 再アクティブ化済みのため中止
                                    ProfileActivityState::ObsoleteCreating => Some(None), // 待機リトライ
                                    ProfileActivityState::Idle => {
                                        if let (Some(parent), Some(name)) =
                                            (dir.parent(), dir.file_name())
                                        {
                                            let seq = CLEANUP_SEQ.fetch_add(1, Ordering::Relaxed);
                                            let trash = parent.join(format!(
                                                "{}.deleting-{}-{seq}",
                                                name.to_string_lossy(),
                                                crate::follow_sync::now_unix_secs()
                                            ));
                                            if fs::rename(&dir, &trash).is_ok() {
                                                Some(Some(trash))
                                            } else {
                                                Some(None)
                                            }
                                        } else {
                                            Some(None)
                                        }
                                    }
                                }
                            };
                            match step {
                                None => break,
                                Some(Some(trash)) => {
                                    dir = trash;
                                    renamed_to_trash = true;
                                }
                                Some(None) => {
                                    std::thread::sleep(Duration::from_millis(500 * (attempt + 1)));
                                    continue;
                                }
                            }
                        }
                    }
                    if fs::remove_dir_all(&dir).is_ok() {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(500 * (attempt + 1)));
                }
            }
        })
        .ok();
}

/// ConfigStore のインスタンス一覧に合わせて ServiceTabs / 削除済みWebview を同期する。
/// `purge_profile` が false の場合は閉じたタブ復元のためディスク上のプロファイルを保持する。
pub fn sync_instances_ex(app: &AppHandle, shared: &SharedState, purge_profiles: bool) {
    let (to_close_labels, dirs_to_purge): (Vec<String>, Vec<(Option<String>, PathBuf, bool)>) = {
        let mut guard = shared.inner.lock().unwrap();
        let instances = guard.store.get_instances();
        let valid_ids: HashSet<String> = instances.iter().map(|i| i.instance_id.clone()).collect();

        let removed_ids: Vec<String> = guard
            .services
            .keys()
            .filter(|id| !valid_ids.contains(*id))
            .cloned()
            .collect();

        let mut close_labels = Vec::new();
        let mut seen_dirs: HashSet<PathBuf> = HashSet::new();
        let mut purge_list: Vec<(Option<String>, PathBuf, bool)> = Vec::new();
        for id in &removed_ids {
            guard.cross_site_identities.remove(id);
            let prof = if purge_profiles {
                Some(profile_dir_for(&guard.profiles_root, id))
            } else {
                None
            };
            let mut had_live = false;
            if let Some(svc) = guard.services.remove(id) {
                for tab in svc.tabs {
                    guard.pending_tab_nav.remove(&tab.tab_id);
                    if guard.creating_tabs.contains_key(&tab.tab_id) {
                        had_live = true;
                    }
                    if let Some(label) = tab.webview_label {
                        had_live = true;
                        close_labels.push(label);
                    }
                }
            }
            if let Some(dir) = prof {
                if seen_dirs.insert(dir.clone()) {
                    purge_list.push((Some(id.clone()), dir, had_live));
                }
            }
            if guard.active_instance_id.as_deref() == Some(id.as_str()) {
                guard.active_instance_id = None;
            }
        }

        for inst in &instances {
            guard
                .services
                .entry(inst.instance_id.clone())
                .or_insert_with(|| ServiceTabs::new_initial(inst));
        }

        (close_labels, purge_list)
    };

    for label in to_close_labels {
        if let Some(wv) = app.get_webview(&label) {
            close_webview_cleanly(&wv);
        }
    }
    // ディスク I/O（Chromium プロファイル削除）はロック外・別スレッドで重複排除＆リトライ実行
    spawn_profile_dir_cleanup(shared, dirs_to_purge);
}

pub fn sync_instances(app: &AppHandle, shared: &SharedState) {
    sync_instances_ex(app, shared, true);
}

pub fn update_bounds_from_window(app: &AppHandle, shared: &SharedState) {
    let Some(win) = app.get_window("main") else {
        return;
    };
    let Ok(phys_size) = win.inner_size() else {
        return;
    };
    if phys_size.width == 0 || phys_size.height == 0 {
        return;
    }
    let scale = win.scale_factor().unwrap_or(1.0);
    let logical = phys_size.to_logical::<f64>(scale);

    // シェルUIをウィンドウ全体に追従
    if let Some(shell) = app.get_webview("shell") {
        let _ = shell.set_bounds(Rect {
            position: LogicalPosition::new(0.0, 0.0).into(),
            size: LogicalSize::new(logical.width, logical.height).into(),
        });
    }

    {
        let mut guard = shared.inner.lock().unwrap();
        let st = guard.store.get_settings();
        let sidebar_w = st.sidebar_width as f64;
        let top_h = top_header_height(st.header_collapsed, active_tab_count(&guard));
        guard.bounds = ContentBounds {
            x: sidebar_w,
            y: top_h,
            width: (logical.width - sidebar_w).max(0.0),
            height: (logical.height - top_h).max(0.0),
        };
    }

    refresh_attached_view(app, shared);
    sync_gesture_host_state(app, shared);
}

pub fn refresh_attached_view(app: &AppHandle, shared: &SharedState) {
    let (target_label, bounds, tracked_labels, creating_labels, warming_labels, should_focus_shell) = {
        let mut guard = shared.inner.lock().unwrap();
        let now = Instant::now();
        let target = if guard.gmail_open {
            let gmail_has_error = guard
                .gmail_tab
                .as_ref()
                .map(|t| t.load_error.is_some())
                .unwrap_or(false);
            if guard.overlay_visible || gmail_has_error {
                None
            } else {
                guard
                    .gmail_tab
                    .as_ref()
                    .and_then(|t| t.webview_label.clone())
            }
        } else {
            let active_tab = guard
                .active_instance_id
                .as_deref()
                .and_then(|id| guard.services.get(id))
                .and_then(|s| s.active_tab());

            let active_has_error = active_tab
                .map(|t| t.load_error.is_some())
                .unwrap_or(false);
            let active_is_sleeping = active_tab
                .map(|t| t.is_sleeping)
                .unwrap_or(true);

            let should_hide = guard.overlay_visible
                || guard.active_instance_id.is_none()
                || active_has_error
                || active_is_sleeping;

            if should_hide {
                None
            } else {
                active_tab.and_then(|t| t.webview_label.clone())
            }
        };

        let allow_warming = !guard.overlay_visible;
        let mut tracked = HashSet::new();
        let mut warming = HashSet::new();
        if let Some(ref gmail_tab) = guard.gmail_tab {
            if let Some(ref l) = gmail_tab.webview_label {
                tracked.insert(l.clone());
            }
        }
        for svc in guard.services.values_mut() {
            for tab in &mut svc.tabs {
                if let Some(ref l) = tab.webview_label {
                    tracked.insert(l.clone());
                    if target.as_deref() == Some(l.as_str()) {
                        tab.warming_until = None;
                    } else if let Some(until) = tab.warming_until {
                        if until > now {
                            if allow_warming {
                                warming.insert(l.clone());
                            }
                        } else {
                            tab.warming_until = None;
                        }
                    }
                }
            }
        }
        let mut creating: HashSet<String> = guard
            .creating_tabs
            .values()
            .map(|(l, _)| l.clone())
            .collect();
        if let Some(ref gl) = guard.gmail_creating_label {
            creating.insert(gl.clone());
        }
        (
            target,
            guard.bounds,
            tracked,
            creating,
            warming,
            guard.overlay_visible,
        )
    };

    // メインウィンドウ配下の全子WebViewを実体ベースで走査し、
    // 1) 未追跡かつ生成中でもない孤立した子WebView（ゾンビ）は即座に非表示＆破棄する
    // 2) ウォームアップ中のバックグラウンドタブは画面外(-10000,-10000)で描画継続させ、SPAを最速読込する
    // 3) それ以外の非アクティブ／モーダル時の子WebViewは確実に非表示にする（重なり・残留を根絶）
    for (label, wv) in app.webviews() {
        if label == "shell" {
            continue;
        }
        if wv.window().label() != "main" {
            continue;
        }
        if !tracked_labels.contains(&label) && !creating_labels.contains(&label) {
            close_webview_cleanly(&wv);
            continue;
        }
        if target_label.as_deref() != Some(label.as_str()) {
            if warming_labels.contains(&label) {
                let _ = wv.set_bounds(Rect {
                    position: LogicalPosition::new(-10000.0, -10000.0).into(),
                    size: LogicalSize::new(bounds.width.max(1.0), bounds.height.max(1.0)).into(),
                });
            } else {
                let _ = wv.hide();
            }
        }
    }

    if let Some(label) = target_label {
        if let Some(wv) = app.get_webview(&label) {
            let _ = wv.set_bounds(Rect {
                position: LogicalPosition::new(bounds.x, bounds.y).into(),
                size: LogicalSize::new(bounds.width, bounds.height).into(),
            });
            let _ = wv.show();
            #[cfg(windows)]
            {
                let _ = wv.with_webview(|platform_wv| {
                    crate::platform_win::bring_controller_to_top(&platform_wv.controller());
                });
            }
        }
    } else if let Some(shell) = app.get_webview("shell") {
        #[cfg(windows)]
        {
            let _ = shell.with_webview(|platform_wv| {
                crate::platform_win::bring_controller_to_top(&platform_wv.controller());
            });
        }
        if should_focus_shell {
            let _ = shell.set_focus();
        }
    }

    sync_gesture_host_state(app, shared);
}

pub fn activate_tab(app: &AppHandle, shared: &SharedState, instance_id: Option<String>) {
    let needs_create: Option<(ServiceInstance, String, String)> = {
        let mut guard = shared.inner.lock().unwrap();
        guard.gmail_open = false;
        guard.active_instance_id = instance_id.clone();

        match instance_id {
            None => None,
            Some(ref id) => {
                if let Some(inst) = guard.store.get_instance(id) {
                    let gkey = service_group_key(&inst.service_id, &inst.url, &inst.instance_id);
                    guard.last_active_by_group.insert(gkey, inst.instance_id.clone());
                    let (tab_id, target_url, has_webview) = {
                        let svc = guard
                            .services
                            .entry(id.clone())
                            .or_insert_with(|| ServiceTabs::new_initial(&inst));
                        if svc.tabs.is_empty() {
                            let first = BrowserTabEntry::new_for_service(
                                &inst,
                                inst.url.clone(),
                                inst.name.clone(),
                            );
                            svc.active_tab_id = first.tab_id.clone();
                            svc.tabs.push(first);
                        }
                        let tab = svc.active_tab().unwrap();
                        (
                            tab.tab_id.clone(),
                            tab.current_url.clone(),
                            tab.webview_label.is_some(),
                        )
                    };
                    if !has_webview {
                        if guard.creating_tabs.contains_key(&tab_id) {
                            guard
                                .pending_tab_nav
                                .entry(tab_id.clone())
                                .or_insert_with(|| {
                                    if target_url.is_empty() {
                                        inst.url.clone()
                                    } else {
                                        target_url.clone()
                                    }
                                });
                            None
                        } else {
                            Some((inst, tab_id, target_url))
                        }
                    } else {
                        None
                    }
                } else {
                    guard.active_instance_id = None;
                    None
                }
            }
        }
    };

    if let Some((inst, tab_id, target_url)) = needs_create {
        create_tab_webview(app, shared, inst, tab_id, target_url);
    }

    update_bounds_from_window(app, shared);
}

pub fn activate_subtab(app: &AppHandle, shared: &SharedState, instance_id: &str, tab_id: &str) {
    let needs_create: Option<(ServiceInstance, String, String)> = {
        let mut guard = shared.inner.lock().unwrap();
        let Some(inst) = guard.store.get_instance(instance_id) else {
            return;
        };
        let gkey = service_group_key(&inst.service_id, &inst.url, &inst.instance_id);
        guard.gmail_open = false;
        guard.last_active_by_group.insert(gkey, inst.instance_id.clone());
        guard.active_instance_id = Some(instance_id.to_string());
        guard.store.update_settings(UpdateSettingsPatch {
            active_instance_id: Some(Some(instance_id.to_string())),
            ..Default::default()
        });
        let (has_webview, tab_url) = {
            let Some(svc) = guard.services.get_mut(instance_id) else {
                return;
            };
            let Some(tab) = svc.tabs.iter().find(|t| t.tab_id == tab_id) else {
                return;
            };
            let info = (tab.webview_label.is_some(), tab.current_url.clone());
            svc.active_tab_id = tab_id.to_string();
            info
        };
        let tab_info = if !has_webview {
            if guard.creating_tabs.contains_key(tab_id) {
                guard
                    .pending_tab_nav
                    .entry(tab_id.to_string())
                    .or_insert_with(|| {
                        if tab_url.is_empty() {
                            inst.url.clone()
                        } else {
                            tab_url.clone()
                        }
                    });
                None
            } else {
                Some((inst, tab_id.to_string(), tab_url))
            }
        } else {
            None
        };
        persist_service_tabs(&mut guard, instance_id);
        tab_info
    };

    if let Some((inst, tid, url)) = needs_create {
        create_tab_webview(app, shared, inst, tid, url);
    }

    update_bounds_from_window(app, shared);
    emit_state_updated(app, shared);
}

pub fn create_subtab_with_options(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    url_override: Option<String>,
    insert_after_tab_id: Option<&str>,
    activate: bool,
) -> Result<(String, usize), String> {
    let (inst, tab_id, target_url, total_tabs) = {
        let mut guard = shared.inner.lock().unwrap();
        let inst = guard
            .store
            .get_instance(instance_id)
            .ok_or_else(|| "対象サービスが見つかりません".to_string())?;
        let (tid, target_url, total_tabs) = {
            let first_creating = guard
                .services
                .get(instance_id)
                .and_then(|s| s.tabs.first())
                .map(|t| guard.creating_tabs.contains_key(&t.tab_id))
                .unwrap_or(false);
            let svc = guard
                .services
                .entry(instance_id.to_string())
                .or_insert_with(|| ServiceTabs::new_initial(&inst));

            let target_url = url_override
                .as_deref()
                .and_then(normalize_service_url)
                .unwrap_or_else(|| inst.url.clone());

            // 最後のタブを閉じて休止中のアカウントで新規タブ／復元した場合は、
            // 休止中の1枚目をそのまま再利用して起こす（空の休止タブが増えないようにする）
            let reuse_first = activate
                && svc.tabs.len() == 1
                && svc.tabs[0].is_sleeping
                && svc.tabs[0].webview_label.is_none()
                && !first_creating;
            if reuse_first {
                let initial_title = if url_override.is_some() {
                    url::Url::parse(&target_url)
                        .ok()
                        .and_then(|u| u.host_str().map(|h| h.to_string()))
                        .unwrap_or_else(|| inst.name.clone())
                } else {
                    inst.name.clone()
                };
                svc.tabs[0].current_url = target_url.clone();
                svc.tabs[0].title = initial_title;
                svc.tabs[0].load_error = None;
                let tid = svc.tabs[0].tab_id.clone();
                svc.active_tab_id = tid.clone();
                (tid, target_url, 1)
            } else {
                if svc.tabs.len() >= MAX_SUBTABS_PER_SERVICE {
                    return Err(format!(
                        "1つのサービスで開けるタブは最大 {MAX_SUBTABS_PER_SERVICE} 枚です"
                    ));
                }

                let initial_title = if url_override.is_some() {
                    url::Url::parse(&target_url)
                        .ok()
                        .and_then(|u| u.host_str().map(|h| h.to_string()))
                        .unwrap_or_else(|| inst.name.clone())
                } else {
                    inst.name.clone()
                };
                let entry =
                    BrowserTabEntry::new_for_service(&inst, target_url.clone(), initial_title);
                let tid = entry.tab_id.clone();

                if let Some(after_id) = insert_after_tab_id {
                    if let Some(pos) = svc.tabs.iter().position(|t| t.tab_id == after_id) {
                        svc.tabs.insert(pos + 1, entry);
                    } else {
                        svc.tabs.push(entry);
                    }
                } else {
                    svc.tabs.push(entry);
                }

                if activate {
                    svc.active_tab_id = tid.clone();
                }
                (tid, target_url, svc.tabs.len())
            }
        };

        if activate {
            guard.gmail_open = false;
            guard.active_instance_id = Some(instance_id.to_string());
            guard.store.update_settings(UpdateSettingsPatch {
                active_instance_id: Some(Some(instance_id.to_string())),
                ..Default::default()
            });
        }
        persist_service_tabs(&mut guard, instance_id);
        (inst, tid, target_url, total_tabs)
    };

    // WebView2 生成開始前にタブ一覧を先行反映し、タブチップを 0ms で即座に表示する
    emit_state_updated(app, shared);
    create_tab_webview(app, shared, inst, tab_id.clone(), target_url);
    update_bounds_from_window(app, shared);
    emit_state_updated(app, shared);
    Ok((tab_id, total_tabs))
}

pub fn create_subtab(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    url_override: Option<String>,
) -> Result<String, String> {
    create_subtab_with_options(app, shared, instance_id, url_override, None, true)
        .map(|(tab_id, _)| tab_id)
}

pub fn navigate_subtab(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    raw_url: &str,
) -> Result<String, String> {
    let target_url = normalize_service_url(raw_url)
        .ok_or_else(|| "有効な http:// または https:// URL を入力してください".to_string())?;

    let (existing_label, needs_create) = {
        let mut guard = shared.inner.lock().unwrap();
        let inst = guard
            .store
            .get_instance(instance_id)
            .ok_or_else(|| "対象サービスが見つかりません".to_string())?;
        let (active_tab_id, existing_lbl) = {
            let svc = guard
                .services
                .entry(instance_id.to_string())
                .or_insert_with(|| ServiceTabs::new_initial(&inst));
            if svc.tabs.is_empty() {
                let first =
                    BrowserTabEntry::new_for_service(&inst, target_url.clone(), inst.name.clone());
                svc.active_tab_id = first.tab_id.clone();
                svc.tabs.push(first);
            }
            let active_id = svc.active_tab_id.clone();
            let active_idx = svc
                .tabs
                .iter()
                .position(|t| t.tab_id == active_id)
                .unwrap_or(0);
            let tab = &mut svc.tabs[active_idx];
            tab.current_url = target_url.clone();
            tab.load_error = None;
            (tab.tab_id.clone(), tab.webview_label.clone())
        };
        let res = if let Some(label) = existing_lbl {
            guard.pending_tab_nav.remove(&active_tab_id);
            (Some(label), None)
        } else if guard.creating_tabs.contains_key(&active_tab_id) {
            // 生成中の WebView2 が完了次第、この URL へ遷移または再生成する
            guard
                .pending_tab_nav
                .insert(active_tab_id.clone(), target_url.clone());
            (None, None)
        } else {
            (None, Some((inst, active_tab_id, target_url.clone())))
        };
        persist_service_tabs(&mut guard, instance_id);
        res
    };

    if let Some(label) = existing_label {
        if let Some(wv) = app.get_webview(&label) {
            let url_owned = target_url.clone();
            #[cfg(windows)]
            let _ = wv.with_webview(move |pwv| {
                crate::platform_win::navigate(&pwv.controller(), &url_owned);
            });
        }
    } else if let Some((inst, tid, url)) = needs_create {
        create_tab_webview(app, shared, inst, tid, url);
    }

    refresh_attached_view(app, shared);
    emit_runtime_updated(app, shared, instance_id);
    Ok(target_url)
}

pub fn duplicate_subtab(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    tab_id: &str,
) -> Result<String, String> {
    let url = {
        let guard = shared.inner.lock().unwrap();
        guard
            .services
            .get(instance_id)
            .and_then(|s| s.tabs.iter().find(|t| t.tab_id == tab_id))
            .map(|t| t.current_url.clone())
    };
    create_subtab(app, shared, instance_id, url)
}

pub fn close_subtab(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    tab_id: &str,
) -> Option<String> {
    enum CloseOutcome {
        ClosedSubTab {
            closed_label: Option<String>,
            activate_next: Option<(ServiceInstance, String, String)>,
        },
        LastTabSlept {
            closed_label: Option<String>,
            service_name: String,
        },
        AlreadySleeping {
            service_name: String,
        },
    }

    let outcome = {
        let mut guard = shared.inner.lock().unwrap();
        let Some(inst) = guard.store.get_instance(instance_id) else {
            return None;
        };
        let sub_count = guard
            .services
            .get(instance_id)
            .map(|s| s.tabs.len())
            .unwrap_or(0);

        if sub_count >= 2 {
            let (removed, needs_create) = {
                let is_creating_map = guard.creating_tabs.clone();
                let svc = guard.services.get_mut(instance_id).unwrap();
                let Some(pos) = svc.tabs.iter().position(|t| t.tab_id == tab_id) else {
                    return None;
                };
                let was_active = svc.active_tab_id == tab_id;
                let removed = svc.tabs.remove(pos);
                let next_idx = pos.min(svc.tabs.len() - 1);
                let next_tab_id = svc.tabs[next_idx].tab_id.clone();
                let needs_create = if was_active
                    && svc.tabs[next_idx].webview_label.is_none()
                    && !is_creating_map.contains_key(&next_tab_id)
                {
                    Some((
                        inst.clone(),
                        next_tab_id.clone(),
                        svc.tabs[next_idx].current_url.clone(),
                    ))
                } else {
                    None
                };
                if was_active {
                    svc.active_tab_id = next_tab_id;
                }
                (removed, needs_create)
            };
            persist_service_tabs(&mut guard, instance_id);
            push_closed_entry(
                &mut guard,
                ClosedEntry::SubTab {
                    instance_id: instance_id.to_string(),
                    url: removed.current_url,
                    title: removed.title,
                },
            );
            CloseOutcome::ClosedSubTab {
                closed_label: removed.webview_label,
                activate_next: needs_create,
            }
        } else {
            // 最後のタブを閉じてもサイドバー／アカウント一覧からは絶対に削除せず、
            // WebView2 のみ閉じて休止状態にし、閉じたページは復元履歴へ積む。
            let creating_first = guard
                .services
                .get(instance_id)
                .and_then(|s| s.tabs.first())
                .map(|t| guard.creating_tabs.contains_key(&t.tab_id))
                .unwrap_or(false);
            let closed_info = guard.services.get_mut(instance_id).and_then(|svc| {
                let tab = svc.tabs.first_mut()?;
                if tab.is_sleeping && tab.webview_label.is_none() && !creating_first {
                    return None;
                }
                let label = tab.webview_label.take();
                let prev_url = tab.current_url.clone();
                let prev_title = tab.title.clone();
                tab.creation_epoch = tab.creation_epoch.wrapping_add(1);
                tab.is_sleeping = true;
                tab.is_loading = false;
                tab.unread_count = 0;
                tab.can_go_back = false;
                tab.can_go_forward = false;
                tab.load_error = None;
                tab.current_url = inst.url.clone();
                tab.title = inst.name.clone();
                Some((label, prev_url, prev_title))
            });
            if let Some((closed_label, prev_url, prev_title)) = closed_info {
                persist_service_tabs(&mut guard, instance_id);
                push_closed_entry(
                    &mut guard,
                    ClosedEntry::SubTab {
                        instance_id: instance_id.to_string(),
                        url: prev_url,
                        title: prev_title,
                    },
                );
                CloseOutcome::LastTabSlept {
                    closed_label,
                    service_name: inst.name,
                }
            } else {
                CloseOutcome::AlreadySleeping {
                    service_name: inst.name,
                }
            }
        }
    };

    match outcome {
        CloseOutcome::ClosedSubTab {
            closed_label,
            activate_next,
        } => {
            if let Some(label) = closed_label {
                if let Some(wv) = app.get_webview(&label) {
                    close_webview_cleanly(&wv);
                }
            }
            if let Some((inst, tid, url)) = activate_next {
                create_tab_webview(app, shared, inst, tid, url);
            }
            update_bounds_from_window(app, shared);
            emit_state_updated(app, shared);
            None
        }
        CloseOutcome::LastTabSlept {
            closed_label,
            service_name,
        } => {
            if let Some(label) = closed_label {
                if let Some(wv) = app.get_webview(&label) {
                    close_webview_cleanly(&wv);
                }
            }
            update_bounds_from_window(app, shared);
            emit_state_updated(app, shared);
            Some(format!(
                "「{service_name}」のタブを閉じました（休止状態 · サイドバーに残ります）"
            ))
        }
        CloseOutcome::AlreadySleeping { service_name } => {
            Some(format!("「{service_name}」のタブはすでに閉じています"))
        }
    }
}

pub fn close_other_subtabs(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    keep_tab_id: &str,
) -> usize {
    let (closed_labels, closed_count, wake_kept): (
        Vec<String>,
        usize,
        Option<(ServiceInstance, String, String)>,
    ) = {
        let mut guard = shared.inner.lock().unwrap();
        let mut labels = Vec::new();
        let mut closed_entries = Vec::new();
        let mut closed_tab_ids = Vec::new();
        let mut kept_sleeping_info: Option<(String, String)> = None;
        if let Some(svc) = guard.services.get_mut(instance_id) {
            if svc.tabs.len() <= 1 || !svc.tabs.iter().any(|t| t.tab_id == keep_tab_id) {
                return 0;
            }
            let mut kept = Vec::new();
            for tab in svc.tabs.drain(..) {
                if tab.tab_id == keep_tab_id {
                    kept.push(tab);
                } else {
                    closed_tab_ids.push(tab.tab_id.clone());
                    if let Some(l) = tab.webview_label {
                        labels.push(l);
                    }
                    closed_entries.push(ClosedEntry::SubTab {
                        instance_id: instance_id.to_string(),
                        url: tab.current_url,
                        title: tab.title,
                    });
                }
            }
            svc.tabs = kept;
            svc.active_tab_id = svc.tabs[0].tab_id.clone();
            if svc.tabs[0].webview_label.is_none() {
                kept_sleeping_info =
                    Some((svc.tabs[0].tab_id.clone(), svc.tabs[0].current_url.clone()));
            }
        }
        for tid in closed_tab_ids {
            guard.pending_tab_nav.remove(&tid);
        }
        let closed_count = closed_entries.len();
        for entry in closed_entries {
            push_closed_entry(&mut guard, entry);
        }
        if closed_count == 0 {
            return 0;
        }
        let wake_info = kept_sleeping_info.and_then(|(tid, url)| {
            if guard.active_instance_id.as_deref() == Some(instance_id)
                && !guard.creating_tabs.contains_key(&tid)
            {
                guard.store.get_instance(instance_id).map(|inst| {
                    let target = if url.is_empty() { inst.url.clone() } else { url };
                    (inst, tid, target)
                })
            } else {
                None
            }
        });
        persist_service_tabs(&mut guard, instance_id);
        (labels, closed_count, wake_info)
    };

    for label in closed_labels {
        if let Some(wv) = app.get_webview(&label) {
            close_webview_cleanly(&wv);
        }
    }
    if let Some((inst, tid, url)) = wake_kept {
        create_tab_webview(app, shared, inst, tid, url);
    }
    update_bounds_from_window(app, shared);
    emit_state_updated(app, shared);
    closed_count
}

pub fn restore_closed_tab(app: &AppHandle, shared: &SharedState) -> Result<String, String> {
    let popped = {
        let mut guard = shared.inner.lock().unwrap();
        guard.closed_tabs.pop()
    };

    let Some(entry) = popped else {
        return Err("復元できる閉じたタブはありません".to_string());
    };

    match entry {
        ClosedEntry::SubTab {
            instance_id,
            url,
            title,
        } => {
            let exists = {
                let guard = shared.inner.lock().unwrap();
                guard.store.get_instance(&instance_id).is_some()
            };
            let res = if exists {
                create_subtab(app, shared, &instance_id, Some(url.clone()))
            } else {
                // 親サービスが消えていた場合は現在のアクティブサービスに復元
                match ensure_safe_active_instance(shared) {
                    Some(fallback) => create_subtab(app, shared, &fallback, Some(url.clone())),
                    None => Err("復元先のサービスがありません".to_string()),
                }
            };
            match res {
                Ok(_) => Ok(format!("「{title}」を復元しました")),
                Err(err) => {
                    // 復元失敗時（タブ上限など）は履歴を失わないよう戻す
                    let mut guard = shared.inner.lock().unwrap();
                    push_closed_entry(
                        &mut guard,
                        ClosedEntry::SubTab {
                            instance_id,
                            url,
                            title,
                        },
                    );
                    Err(err)
                }
            }
        }
        ClosedEntry::Service {
            instance,
            url,
            title,
        } => {
            let restored = {
                let mut guard = shared.inner.lock().unwrap();
                let restored = guard.store.restore_instance(instance);
                let mut svc = ServiceTabs::new_initial(&restored);
                if let Some(first) = svc.tabs.first_mut() {
                    if let Some(norm) = normalize_service_url(&url) {
                        first.current_url = norm;
                    }
                    if !title.trim().is_empty() {
                        first.title = title.clone();
                    }
                }
                guard.services.insert(restored.instance_id.clone(), svc);
                restored
            };
            activate_tab(app, shared, Some(restored.instance_id));
            emit_state_updated(app, shared);
            Ok(format!("「{}」を復元しました", restored.name))
        }
    }
}

pub fn step_active_service(app: &AppHandle, shared: &SharedState, delta: isize) -> Result<(), &'static str> {
    let target_id = {
        let mut guard = shared.inner.lock().unwrap();
        let settings = guard.store.get_settings();
        let instances = guard.store.get_instances();
        if instances.is_empty() {
            return Err("切り替えられるSNSが1つしかありません");
        }

        // 同一SNSをグループ化してSNS単位で切り替える
        let mut groups: Vec<(String, Vec<String>)> = Vec::new();
        for inst in &instances {
            let gkey = service_group_key(&inst.service_id, &inst.url, &inst.instance_id);
            if let Some((_, ids)) = groups.iter_mut().find(|(k, _)| k == &gkey) {
                ids.push(inst.instance_id.clone());
            } else {
                groups.push((gkey, vec![inst.instance_id.clone()]));
            }
        }
        if groups.len() <= 1 {
            return Err("切り替えられるSNSが1つしかありません");
        }

        let cur_group_idx = guard
            .active_instance_id
            .as_deref()
            .and_then(|aid| groups.iter().position(|(_, ids)| ids.iter().any(|x| x == aid)))
            .unwrap_or(0);
        let next_group_idx = step_tab_index(groups.len(), cur_group_idx, delta, settings.gesture.wrap_tabs)?;
        let (next_gkey, next_ids) = &groups[next_group_idx];

        let next_id = guard
            .last_active_by_group
            .get(next_gkey)
            .filter(|saved| next_ids.iter().any(|x| x == *saved))
            .cloned()
            .unwrap_or_else(|| next_ids[0].clone());

        guard.store.update_settings(UpdateSettingsPatch {
            active_instance_id: Some(Some(next_id.clone())),
            ..Default::default()
        });
        next_id
    };

    activate_tab(app, shared, Some(target_id));
    emit_state_updated(app, shared);
    Ok(())
}

/// 同一SNS内のアカウントを前後に瞬時切替する。
pub fn step_active_account(app: &AppHandle, shared: &SharedState, delta: isize) -> Result<(), &'static str> {
    let target_id = {
        let mut guard = shared.inner.lock().unwrap();
        let wrap = guard.store.get_settings().gesture.wrap_tabs;
        let instances = guard.store.get_instances();
        let Some(active_id) = guard.active_instance_id.clone() else {
            return Err("選択中のSNSがありません");
        };
        let Some(active_inst) = instances.iter().find(|i| i.instance_id == active_id) else {
            return Err("選択中のSNSがありません");
        };
        let gkey = service_group_key(&active_inst.service_id, &active_inst.url, &active_inst.instance_id);
        let siblings: Vec<String> = instances
            .iter()
            .filter(|i| service_group_key(&i.service_id, &i.url, &i.instance_id) == gkey)
            .map(|i| i.instance_id.clone())
            .collect();
        if siblings.len() <= 1 {
            return Err("このSNSのアカウントは1つだけです");
        }
        let cur_idx = siblings.iter().position(|id| id == &active_id).unwrap_or(0);
        let next_idx = step_tab_index(siblings.len(), cur_idx, delta, wrap)?;
        let next_id = siblings[next_idx].clone();
        guard.store.update_settings(UpdateSettingsPatch {
            active_instance_id: Some(Some(next_id.clone())),
            ..Default::default()
        });
        next_id
    };

    activate_tab(app, shared, Some(target_id));
    emit_state_updated(app, shared);
    Ok(())
}

/// 同一SNS内の指定番号（0始まり）アカウントへ瞬時切替する。
pub fn activate_account_by_index(app: &AppHandle, shared: &SharedState, index: usize) {
    let target_id = {
        let mut guard = shared.inner.lock().unwrap();
        let instances = guard.store.get_instances();
        let Some(active_id) = guard.active_instance_id.clone() else {
            return;
        };
        let Some(active_inst) = instances.iter().find(|i| i.instance_id == active_id) else {
            return;
        };
        let gkey = service_group_key(&active_inst.service_id, &active_inst.url, &active_inst.instance_id);
        let siblings: Vec<String> = instances
            .iter()
            .filter(|i| service_group_key(&i.service_id, &i.url, &i.instance_id) == gkey)
            .map(|i| i.instance_id.clone())
            .collect();
        let Some(next_id) = siblings.get(index).cloned() else {
            return;
        };
        if next_id == active_id {
            return;
        }
        guard.store.update_settings(UpdateSettingsPatch {
            active_instance_id: Some(Some(next_id.clone())),
            ..Default::default()
        });
        next_id
    };

    activate_tab(app, shared, Some(target_id));
    emit_state_updated(app, shared);
}

/// 前のタブ / 次のタブへ切替。
/// 現在のサービス内にサブタブが2枚以上あればサブタブを切替え、1枚のみの時はSNSサービスを切替える。
pub fn step_active_tab(app: &AppHandle, shared: &SharedState, delta: isize) -> Result<(), &'static str> {
    let sub_target: Option<(String, String)> = {
        let guard = shared.inner.lock().unwrap();
        let wrap = guard.store.get_settings().gesture.wrap_tabs;
        if let Some(ref inst_id) = guard.active_instance_id {
            if let Some(svc) = guard.services.get(inst_id) {
                if svc.tabs.len() >= 2 {
                    let cur_idx = svc
                        .tabs
                        .iter()
                        .position(|t| t.tab_id == svc.active_tab_id)
                        .unwrap_or(0);
                    let next_idx = step_tab_index(svc.tabs.len(), cur_idx, delta, wrap)?;
                    Some((inst_id.clone(), svc.tabs[next_idx].tab_id.clone()))
                } else {
                    None
                }
            } else {
                None
            }
        } else {
            None
        }
    };

    if let Some((inst_id, tab_id)) = sub_target {
        activate_subtab(app, shared, &inst_id, &tab_id);
        Ok(())
    } else {
        step_active_service(app, shared, delta)
    }
}

fn create_tab_webview(
    app: &AppHandle,
    shared: &SharedState,
    instance: ServiceInstance,
    tab_id: String,
    target_url: String,
) {
    let Some(win) = app.get_window("main") else {
        return;
    };

    let Ok(parsed_url) = url::Url::parse(&target_url) else {
        return;
    };

    let gen = WEBVIEW_GEN.fetch_add(1, Ordering::Relaxed);
    let label = format!(
        "tab-{}-{}",
        sanitize_profile_segment(&instance.instance_id),
        gen
    );

    // ロック下で重複生成ガード（creating_tabs）と現在エポックを確保
    let Some((bounds, profile_dir, chrome_ver, start_offscreen, my_epoch)) = ({
        let mut guard = shared.inner.lock().unwrap();
        if guard.is_quitting || guard.creating_tabs.contains_key(&tab_id) {
            None
        } else {
            let tab_meta = guard
                .services
                .get(&instance.instance_id)
                .and_then(|s| s.tabs.iter().find(|t| t.tab_id == tab_id))
                .and_then(|t| {
                    if t.webview_label.is_some() {
                        None
                    } else {
                        Some(t.creation_epoch)
                    }
                });
            if let Some(epoch) = tab_meta {
                let is_active_tab = !guard.gmail_open
                    && guard.active_instance_id.as_deref()
                        == Some(instance.instance_id.as_str())
                    && guard
                        .services
                        .get(&instance.instance_id)
                        .map(|s| s.active_tab_id == tab_id)
                        .unwrap_or(false);
                let start_offscreen = guard.overlay_visible || !is_active_tab;
                guard
                    .creating_tabs
                    .insert(tab_id.clone(), (label.clone(), epoch));
                Some((
                    guard.bounds,
                    profile_dir_for(&guard.profiles_root, &instance.instance_id),
                    guard.chrome_version.clone(),
                    start_offscreen,
                    epoch,
                ))
            } else {
                None
            }
        }
    }) else {
        return;
    };

    let _ = fs::create_dir_all(&profile_dir);
    let ua = build_user_agent(&instance.ua_mode, &chrome_ver);

    let instance_id = instance.instance_id.clone();
    let instance_name = instance.name.clone();
    let instance_url = instance.url.clone();

    let app_for_title = app.clone();
    let shared_for_title = shared.clone();
    let id_for_title = instance_id.clone();
    let tid_for_title = tab_id.clone();
    let label_for_title = label.clone();
    let fallback_name = instance_name.clone();

    let app_for_popup = app.clone();
    let shared_for_popup = shared.clone();
    let id_for_popup = instance_id.clone();
    let tid_for_popup = tab_id.clone();
    let label_for_popup = label.clone();
    let name_for_popup = instance_name.clone();
    let fallback_url_for_popup = instance_url.clone();

    #[cfg(windows)]
    let bridge_token = crate::platform_win::generate_bridge_token();
    let initial_target_url_str = parsed_url.to_string();
    #[cfg(windows)]
    let builder_initial_url = url::Url::parse("about:blank").unwrap();
    #[cfg(not(windows))]
    let builder_initial_url = parsed_url;

    #[allow(unused_mut)]
    let mut builder = WebviewBuilder::new(&label, WebviewUrl::External(builder_initial_url))
        .data_directory(profile_dir)
        .user_agent(&ua)
        .disable_drag_drop_handler()
        .zoom_hotkeys_enabled(true)
        .focused(false)
        .on_navigation(|url| {
            matches!(url.scheme(), "http" | "https" | "about" | "blob" | "data")
                && !is_internal_tauri_url(url)
        });

    #[cfg(windows)]
    {
        builder = builder
            .additional_browser_args(WEBVIEW2_FAST_BROWSER_ARGS)
            .initialization_script(crate::platform_win::build_follow_tracker_js(&bridge_token))
            .initialization_script(crate::platform_win::build_profile_stats_js(&bridge_token));
    }

    let builder = builder
        .on_permission_request(|_wv, kind| match kind {
            PermissionKind::Notifications | PermissionKind::MediaKeySystemAccess => {
                PermissionResponse::Allow
            }
            _ => PermissionResponse::Default,
        })
        .on_document_title_changed(move |_wv, title| {
            let clean_title = if title.trim().is_empty() {
                fallback_name.clone()
            } else {
                title
            };
            let unread = parse_unread_count_from_title(&clean_title);
            let changed = {
                let mut guard = shared_for_title.inner.lock().unwrap();
                let mut multi = false;
                let updated = if let Some(svc) = guard.services.get_mut(&id_for_title) {
                    multi = svc.tabs.len() >= 2;
                    if let Some(tab) = svc.tab_mut(&tid_for_title) {
                        if tab.webview_label.as_deref() == Some(label_for_title.as_str()) {
                            tab.title = clean_title;
                            tab.unread_count = unread;
                            true
                        } else {
                            false
                        }
                    } else {
                        false
                    }
                } else {
                    false
                };
                if updated && multi {
                    persist_service_tabs(&mut guard, &id_for_title);
                }
                updated
            };
            if changed {
                emit_runtime_updated(&app_for_title, &shared_for_title, &id_for_title);
            }
        })
        .on_new_window(move |target_url, features| {
            if is_internal_tauri_url(&target_url) {
                return NewWindowResponse::Deny;
            }
            let (is_alive, current_url, latest_ua) = {
                let guard = shared_for_popup.inner.lock().unwrap();
                let tab_opt = guard
                    .services
                    .get(&id_for_popup)
                    .and_then(|s| s.tabs.iter().find(|t| t.tab_id == tid_for_popup));
                let alive = tab_opt
                    .map(|t| t.webview_label.as_deref() == Some(label_for_popup.as_str()))
                    .unwrap_or(false);
                let cur = tab_opt
                    .map(|t| t.current_url.clone())
                    .filter(|u| !u.is_empty())
                    .unwrap_or_else(|| fallback_url_for_popup.clone());
                let ua_mode = guard
                    .store
                    .get_instance(&id_for_popup)
                    .map(|i| i.ua_mode)
                    .unwrap_or_else(|| "desktop".to_string());
                (alive, cur, build_user_agent(&ua_mode, &guard.chrome_version))
            };
            if !is_alive {
                return NewWindowResponse::Deny;
            }

            let target_str = target_url.as_str();
            let has_popup_features = features.size().is_some() || features.position().is_some();
            #[cfg(windows)]
            let (is_user_new_tab, force_foreground) = crate::gesture_win::consume_new_tab_click_intent();
            #[cfg(not(windows))]
            let (is_user_new_tab, force_foreground) = (false, false);

            let should_open_auth_popup = (!is_user_new_tab
                && is_auth_popup_for_site(target_str, &current_url))
                || (has_popup_features && is_auth_popup_url(target_str));

            if should_open_auth_popup {
                // OAuth / SSO は window.opener を保つネイティブ子ウィンドウで開く
                let popup_id = POPUP_GEN.fetch_add(1, Ordering::Relaxed);
                let popup_label = format!("popup-{popup_id}");
                let blank_url: url::Url = "about:blank".parse().unwrap();

                let popup_builder = WebviewWindowBuilder::new(
                    &app_for_popup,
                    &popup_label,
                    WebviewUrl::External(blank_url),
                )
                .title(format!("{name_for_popup} - 認証 / ウィンドウ"))
                .inner_size(560.0, 760.0)
                .user_agent(&latest_ua)
                .disable_drag_drop_handler()
                .on_navigation(|url| {
                    matches!(url.scheme(), "http" | "https" | "about" | "blob" | "data")
                        && !is_internal_tauri_url(url)
                })
                .on_permission_request(|_, _| PermissionResponse::Default)
                .window_features(features)
                .on_document_title_changed(|win, title| {
                    if !title.trim().is_empty() {
                        let _ = win.set_title(&title);
                    }
                });

                let popup_builder =
                    if let Some(icon) = app_for_popup.default_window_icon().cloned() {
                        match popup_builder.icon(icon) {
                            Ok(b) => b,
                            Err(_) => return NewWindowResponse::Deny,
                        }
                    } else {
                        popup_builder
                    };

                match popup_builder.build() {
                    Ok(window) => NewWindowResponse::Create { window },
                    Err(_) => NewWindowResponse::Deny,
                }
            } else if is_user_new_tab && is_http_url(target_str) {
                // Ctrl+クリック / 中クリック / Ctrl+クリックジェスチャー時は、
                // 同一アカウントのセッションを保ったまま別ページを新しいタブで開く！
                let app_bg = app_for_popup.clone();
                let shared_bg = shared_for_popup.clone();
                let inst_bg = id_for_popup.clone();
                let after_tid = tid_for_popup.clone();
                let url_bg = target_str.to_string();
                let activate = force_foreground;
                tauri::async_runtime::spawn(async move {
                    match create_subtab_with_options(
                        &app_bg,
                        &shared_bg,
                        &inst_bg,
                        Some(url_bg),
                        Some(&after_tid),
                        activate,
                    ) {
                        Ok((_, total)) => {
                            if !activate {
                                show_overlay_notice(
                                    &shared_bg,
                                    format!("別タブで開きました（全{total}タブ）"),
                                    false,
                                );
                            }
                        }
                        Err(err) => {
                            show_overlay_notice(&shared_bg, err, true);
                        }
                    }
                });
                NewWindowResponse::Deny
            } else if is_same_site_url(target_str, &current_url) {
                // 同一サービスの target="_blank" リンクは同アカウント内の新しいタブで開く
                let app_bg = app_for_popup.clone();
                let shared_bg = shared_for_popup.clone();
                let inst_bg = id_for_popup.clone();
                let after_tid = tid_for_popup.clone();
                let url_bg = target_str.to_string();
                tauri::async_runtime::spawn(async move {
                    let _ = create_subtab_with_options(
                        &app_bg,
                        &shared_bg,
                        &inst_bg,
                        Some(url_bg),
                        Some(&after_tid),
                        true,
                    );
                });
                NewWindowResponse::Deny
            } else {
                if is_http_url(target_str) {
                    #[cfg(windows)]
                    crate::platform_win::open_external_url(target_str);
                }
                NewWindowResponse::Deny
            }
        });

    // 非アクティブ・モーダル表示中に生成されるタブは画面外へ配置してから即非表示にし、
    // 一瞬でもモーダルや他タブの上に重ならないようにする
    let init_pos = if start_offscreen {
        LogicalPosition::new(-10000.0, -10000.0)
    } else {
        LogicalPosition::new(bounds.x, bounds.y)
    };
    let init_size = LogicalSize::new(bounds.width.max(1.0), bounds.height.max(1.0));

    let Ok(webview) = win.add_child(builder, init_pos, init_size) else {
        let mut guard = shared.inner.lock().unwrap();
        guard.creating_tabs.remove(&tab_id);
        guard.pending_tab_nav.remove(&tab_id);
        return;
    };

    let (committed, started_warming, should_hide_immediately, final_nav_url, recreate_after_abort) = {
        let mut guard = shared.inner.lock().unwrap();
        guard.creating_tabs.remove(&tab_id);
        let pending_url = guard.pending_tab_nav.remove(&tab_id);
        let is_active_now = !guard.gmail_open
            && guard.active_instance_id.as_deref() == Some(instance_id.as_str())
            && guard
                .services
                .get(&instance_id)
                .map(|s| s.active_tab_id == tab_id)
                .unwrap_or(false);
        let overlay = guard.overlay_visible;
        let inst_latest = guard.store.get_instance(&instance_id);
        if guard.is_quitting {
            (false, false, true, initial_target_url_str.clone(), None)
        } else if let Some(tab) = guard
            .services
            .get_mut(&instance_id)
            .and_then(|s| s.tab_mut(&tab_id))
        {
            if tab.creation_epoch == my_epoch && tab.webview_label.is_none() {
                tab.webview_label = Some(label.clone());
                tab.is_sleeping = false;
                tab.is_loading = true;
                tab.load_error = None;
                let nav_url = pending_url.unwrap_or_else(|| initial_target_url_str.clone());
                let warm = !overlay && !is_active_now;
                tab.warming_until = if warm {
                    Some(Instant::now() + Duration::from_secs(BG_WARM_MAX_SECS))
                } else {
                    None
                };
                // モーダル表示中のみ即座に非表示化。アクティブタブや画面外ウォーム中の
                // バックグラウンドタブは hide() せず描画優先度を維持する。
                let hide_now = overlay || (!is_active_now && !warm);
                (true, warm, hide_now, nav_url, None)
            } else {
                // 生成中に sleep/close -> 再アクティブ化または遷移要求が届いていた場合は
                // 破棄後に最新 URL で再生成してタブの永久休止化を防ぐ
                let need_recreate = if tab.webview_label.is_none()
                    && (pending_url.is_some() || (is_active_now && !tab.is_sleeping))
                {
                    let next_url = pending_url
                        .or_else(|| {
                            if tab.current_url.is_empty() {
                                None
                            } else {
                                Some(tab.current_url.clone())
                            }
                        })
                        .unwrap_or_else(|| instance.url.clone());
                    inst_latest.map(|inst_l| (inst_l, tab_id.clone(), next_url))
                } else {
                    None
                };
                (false, false, true, initial_target_url_str.clone(), need_recreate)
            }
        } else {
            (false, false, true, initial_target_url_str.clone(), None)
        }
    };

    if !committed {
        // 生成中にタブが削除・休止・置換されていた場合は即座に破棄してゾンビWebViewを防ぐ
        close_webview_cleanly(&webview);
        if let Some((inst_next, tid_next, url_next)) = recreate_after_abort {
            let app_re = app.clone();
            let shared_re = shared.clone();
            tauri::async_runtime::spawn(async move {
                create_tab_webview(&app_re, &shared_re, inst_next, tid_next, url_next);
            });
        }
        refresh_attached_view(app, shared);
        return;
    }

    if should_hide_immediately {
        let _ = webview.hide();
    }

    #[cfg(windows)]
    {
        attach_windows_handlers(
            app,
            shared,
            &webview,
            &instance,
            &tab_id,
            &label,
            &ua,
            bridge_token,
            Some(final_nav_url),
        );
    }
    #[cfg(not(windows))]
    {
        let _ = final_nav_url;
    }

    if started_warming {
        // 最大ウォーム時間経過後に自動で非表示化してメモリ・GPUを節約
        let app_warm = app.clone();
        let shared_warm = shared.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(BG_WARM_MAX_SECS * 1000 + 300));
            refresh_attached_view(&app_warm, &shared_warm);
        });
    }

    emit_runtime_updated(app, shared, &instance_id);
    refresh_attached_view(app, shared);
}

#[cfg(windows)]
#[allow(clippy::too_many_arguments)]
fn attach_windows_handlers(
    app: &AppHandle,
    shared: &SharedState,
    webview: &Webview,
    instance: &ServiceInstance,
    tab_id: &str,
    webview_label: &str,
    ua: &str,
    bridge_token: String,
    initial_navigate_url: Option<String>,
) {
    let instance_id = instance.instance_id.clone();
    let tid = tab_id.to_string();
    let wv_label = webview_label.to_string();
    let fallback_url = instance.url.clone();
    let muted = instance.muted;
    let zoom = instance.zoom_factor;
    let ua_owned = ua.to_string();

    let app_start = app.clone();
    let shared_start = shared.clone();
    let id_start = instance_id.clone();
    let tid_start = tid.clone();
    let label_start = wv_label.clone();

    let app_done = app.clone();
    let shared_done = shared.clone();
    let id_done = instance_id.clone();
    let tid_done = tid.clone();
    let label_done = wv_label.clone();
    let fallback_done = fallback_url.clone();

    let app_nav = app.clone();
    let shared_nav = shared.clone();
    let id_nav = instance_id.clone();
    let tid_nav = tid.clone();
    let label_nav = wv_label.clone();
    let fallback_nav = fallback_url.clone();

    let app_fav = app.clone();
    let shared_fav = shared.clone();
    let id_fav = instance_id.clone();
    let tid_fav = tid.clone();
    let label_fav = wv_label.clone();

    let app_zoom = app.clone();
    let shared_zoom = shared.clone();
    let id_zoom = instance_id.clone();
    let tid_zoom = tid.clone();
    let label_zoom = wv_label.clone();

    let app_key = app.clone();
    let shared_key = shared.clone();

    let app_follow = app.clone();
    let shared_follow = shared.clone();
    let id_follow = instance_id.clone();
    let tid_follow = tid.clone();
    let label_follow = wv_label.clone();

    let app_unfollow = app.clone();
    let shared_unfollow = shared.clone();
    let id_unfollow = instance_id.clone();
    let tid_unfollow = tid.clone();
    let label_unfollow = wv_label.clone();

    let app_ident = app.clone();
    let shared_ident = shared.clone();
    let id_ident = instance_id.clone();
    let tid_ident = tid.clone();
    let label_ident = wv_label.clone();

    let callbacks = crate::platform_win::TabWebviewCallbacks {
        on_navigation_starting: Arc::new(move || {
            let (changed, was_error) = {
                let mut guard = shared_start.inner.lock().unwrap();
                if let Some(tab) = guard
                    .services
                    .get_mut(&id_start)
                    .and_then(|s| s.tab_mut(&tid_start))
                {
                    if tab.webview_label.as_deref() == Some(label_start.as_str()) {
                        let had_err = tab.load_error.is_some();
                        tab.is_loading = true;
                        tab.is_sleeping = false;
                        tab.load_error = None;
                        (true, had_err)
                    } else {
                        (false, false)
                    }
                } else {
                    (false, false)
                }
            };
            if was_error {
                refresh_attached_view(&app_start, &shared_start);
            }
            if changed {
                emit_runtime_updated(&app_start, &shared_start, &id_start);
            }
        }),
        on_navigation_completed: Arc::new(move |ok, err_msg, url, can_back, can_fwd| {
            let (changed, schedule_warm_end) = {
                let mut guard = shared_done.inner.lock().unwrap();
                let mut multi = false;
                let mut warm_shorten = false;
                let updated = if let Some(svc) = guard.services.get_mut(&id_done) {
                    multi = svc.tabs.len() >= 2;
                    if let Some(tab) = svc.tab_mut(&tid_done) {
                        if tab.webview_label.as_deref() == Some(label_done.as_str()) {
                            tab.is_loading = false;
                            tab.is_sleeping = false;
                            if !url.is_empty() {
                                tab.current_url = url;
                            } else if tab.current_url.is_empty() {
                                tab.current_url = fallback_done.clone();
                            }
                            tab.can_go_back = can_back;
                            tab.can_go_forward = can_fwd;
                            tab.load_error = if ok { None } else { err_msg };
                            if tab.warming_until.is_some() {
                                tab.warming_until = Some(
                                    Instant::now() + Duration::from_millis(BG_WARM_POST_LOAD_MS),
                                );
                                warm_shorten = true;
                            }
                            true
                        } else {
                            false
                        }
                    } else {
                        false
                    }
                } else {
                    false
                };
                if updated && multi {
                    persist_service_tabs(&mut guard, &id_done);
                }
                (updated, warm_shorten)
            };
            if schedule_warm_end {
                let app_end = app_done.clone();
                let shared_end = shared_done.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(BG_WARM_POST_LOAD_MS + 150));
                    refresh_attached_view(&app_end, &shared_end);
                });
            }
            if changed && !ok {
                refresh_attached_view(&app_done, &shared_done);
            }
            if changed {
                emit_runtime_updated(&app_done, &shared_done, &id_done);
            }
        }),
        on_nav_flags_changed: Arc::new(move |url, can_back, can_fwd| {
            let changed = {
                let mut guard = shared_nav.inner.lock().unwrap();
                let mut multi = false;
                let updated = if let Some(svc) = guard.services.get_mut(&id_nav) {
                    multi = svc.tabs.len() >= 2;
                    if let Some(tab) = svc.tab_mut(&tid_nav) {
                        if tab.webview_label.as_deref() == Some(label_nav.as_str()) {
                            if !url.is_empty() {
                                tab.current_url = url;
                            } else if tab.current_url.is_empty() {
                                tab.current_url = fallback_nav.clone();
                            }
                            tab.can_go_back = can_back;
                            tab.can_go_forward = can_fwd;
                            true
                        } else {
                            false
                        }
                    } else {
                        false
                    }
                } else {
                    false
                };
                if updated && multi {
                    persist_service_tabs(&mut guard, &id_nav);
                }
                updated
            };
            if changed {
                emit_runtime_updated(&app_nav, &shared_nav, &id_nav);
            }
        }),
        on_favicon_changed: Arc::new(move |favicon| {
            let changed = {
                let mut guard = shared_fav.inner.lock().unwrap();
                if let Some(tab) = guard
                    .services
                    .get_mut(&id_fav)
                    .and_then(|s| s.tab_mut(&tid_fav))
                {
                    if tab.webview_label.as_deref() == Some(label_fav.as_str()) {
                        tab.favicon_url = Some(favicon);
                        true
                    } else {
                        false
                    }
                } else {
                    false
                }
            };
            if changed {
                emit_runtime_updated(&app_fav, &shared_fav, &id_fav);
            }
        }),
        on_zoom_factor_changed: Arc::new(move |raw_zoom| {
            let next_zoom = ((raw_zoom * 100.0).round() / 100.0).clamp(0.3, 3.0);
            let sibling_labels: Option<Vec<String>> = {
                let mut guard = shared_zoom.inner.lock().unwrap();
                let alive = guard
                    .services
                    .get(&id_zoom)
                    .and_then(|s| s.tabs.iter().find(|t| t.tab_id == tid_zoom))
                    .map(|t| t.webview_label.as_deref() == Some(label_zoom.as_str()))
                    .unwrap_or(false);
                if !alive {
                    None
                } else {
                    let cur_zoom = guard
                        .store
                        .get_instance(&id_zoom)
                        .map(|i| i.zoom_factor)
                        .unwrap_or(1.0);
                    if (cur_zoom - next_zoom).abs() < 0.005 {
                        None
                    } else {
                        guard.store.update_instance(
                            &id_zoom,
                            crate::models::UpdateInstancePatch {
                                zoom_factor: Some(next_zoom),
                                ..Default::default()
                            },
                        );
                        let siblings = guard
                            .services
                            .get(&id_zoom)
                            .map(|s| {
                                s.tabs
                                    .iter()
                                    .filter_map(|t| t.webview_label.clone())
                                    .filter(|l| l != &label_zoom)
                                    .collect()
                            })
                            .unwrap_or_default();
                        Some(siblings)
                    }
                }
            };
            if let Some(siblings) = sibling_labels {
                for l in siblings {
                    if let Some(wv) = app_zoom.get_webview(&l) {
                        let _ = wv.with_webview(move |pwv| {
                            crate::platform_win::set_zoom_factor(&pwv.controller(), next_zoom);
                        });
                    }
                }
                show_overlay_notice(
                    &shared_zoom,
                    format!("拡大率: {}%", (next_zoom * 100.0).round() as i32),
                    false,
                );
                emit_state_updated(&app_zoom, &shared_zoom);
            }
        }),
        on_shortcut: Arc::new(move |action, payload| {
            handle_shortcut_from_child(&app_key, &shared_key, action, payload);
        }),
        on_follow_detected: Arc::new(move |service_hint| {
            let target_id = {
                let guard = shared_follow.inner.lock().unwrap();
                let tab_url = guard
                    .services
                    .get(&id_follow)
                    .and_then(|s| s.tabs.iter().find(|t| t.tab_id == tid_follow))
                    .and_then(|t| {
                        if t.webview_label.as_deref() == Some(label_follow.as_str()) {
                            Some(t.current_url.clone())
                        } else {
                            None
                        }
                    });
                tab_url.and_then(|url| {
                    resolve_counter_target_instance_id(
                        &guard,
                        &id_follow,
                        Some(url.as_str()),
                        service_hint.as_deref(),
                        None,
                    )
                })
            };
            if let Some(tid) = target_id {
                adjust_follow_count(&app_follow, &shared_follow, &tid, 1);
            }
        }),
        on_unfollow_detected: Arc::new(move |service_hint| {
            let target_id = {
                let guard = shared_unfollow.inner.lock().unwrap();
                let tab_url = guard
                    .services
                    .get(&id_unfollow)
                    .and_then(|s| s.tabs.iter().find(|t| t.tab_id == tid_unfollow))
                    .and_then(|t| {
                        if t.webview_label.as_deref() == Some(label_unfollow.as_str()) {
                            Some(t.current_url.clone())
                        } else {
                            None
                        }
                    });
                tab_url.and_then(|url| {
                    resolve_counter_target_instance_id(
                        &guard,
                        &id_unfollow,
                        Some(url.as_str()),
                        service_hint.as_deref(),
                        None,
                    )
                })
            };
            if let Some(tid) = target_id {
                adjust_unfollow_count(&app_unfollow, &shared_unfollow, &tid, 1);
            }
        }),
        on_account_identity: Arc::new(move |service_hint, handle, following, followers| {
                let (target_id, cross_site_changed) = {
                    let mut guard = shared_ident.inner.lock().unwrap();
                    let tab_url = guard
                        .services
                        .get(&id_ident)
                        .and_then(|s| s.tabs.iter().find(|t| t.tab_id == tid_ident))
                        .and_then(|t| {
                            if t.webview_label.as_deref() == Some(label_ident.as_str()) {
                                Some(t.current_url.clone())
                            } else {
                                None
                            }
                        });
                    if let Some(url) = tab_url {
                        let mut cs_changed = false;
                        if let Some(ref svc) = service_hint {
                            let source_svc = guard
                                .store
                                .get_instance(&id_ident)
                                .map(|i| i.service_id);
                            if source_svc.as_deref() != Some(svc.as_str()) {
                                if let Some(norm) =
                                    crate::follow_sync::normalize_account_handle(&handle)
                                {
                                    let next_pair = (svc.clone(), norm);
                                    if guard.cross_site_identities.get(&id_ident)
                                        != Some(&next_pair)
                                    {
                                        guard
                                            .cross_site_identities
                                            .insert(id_ident.clone(), next_pair);
                                        cs_changed = true;
                                    }
                                }
                            }
                        }
                        let tid = resolve_counter_target_instance_id(
                            &guard,
                            &id_ident,
                            Some(url.as_str()),
                            service_hint.as_deref(),
                            Some(handle.as_str()),
                        );
                        (tid, cs_changed)
                    } else {
                        (None, false)
                    }
                };
                if cross_site_changed {
                    emit_runtime_updated(&app_ident, &shared_ident, &id_ident);
                }
                if let Some(tid) = target_id {
                    handle_account_identity(
                        &app_ident,
                        &shared_ident,
                        &tid,
                        &handle,
                        following,
                        followers,
                    );
                }
            }),
    };

    let instance_home_url = fallback_url.clone();
    let _ = webview.with_webview(move |platform_wv| {
        let controller = platform_wv.controller();
        crate::platform_win::attach_tab_handlers(
            &controller,
            muted,
            zoom,
            &ua_owned,
            bridge_token,
            instance_home_url,
            initial_navigate_url,
            callbacks,
        );
    });
}

pub fn handle_shortcut_from_child(
    app: &AppHandle,
    shared: &SharedState,
    action: &str,
    payload: Option<usize>,
) {
    match action {
        "switch-account" => {
            if let Some(idx) = payload {
                let app_bg = app.clone();
                let shared_bg = shared.clone();
                tauri::async_runtime::spawn(async move {
                    activate_account_by_index(&app_bg, &shared_bg, idx);
                });
            }
            return;
        }
        "previous-account" | "next-account" | "new-tab" | "close-tab" | "restore-closed"
        | "previous-tab" | "next-tab" | "zoom-in" | "zoom-out" | "zoom-reset" => {
            let app_bg = app.clone();
            let shared_bg = shared.clone();
            let act = action.to_string();
            tauri::async_runtime::spawn(async move {
                execute_gesture_action(&app_bg, &shared_bg, &act);
            });
            return;
        }
        _ => {}
    }

    let _ = app.emit_to(
        EventTarget::webview("shell"),
        "app:shortcut",
        crate::models::ShortcutEventPayload {
            action: action.to_string(),
            payload,
        },
    );
    if action == "open-catalog"
        || action == "open-gesture-settings"
        || action == "focus-address-bar"
    {
        if let Some(shell) = app.get_webview("shell") {
            let _ = shell.set_focus();
        }
    }
}

pub fn set_overlay_visible(app: &AppHandle, shared: &SharedState, visible: bool) {
    let changed = {
        let mut guard = shared.inner.lock().unwrap();
        let prev = guard.overlay_visible;
        guard.overlay_visible = visible;
        prev != visible
    };
    if changed || visible {
        refresh_attached_view(app, shared);
    }
}

pub fn sleep_tab(app: &AppHandle, shared: &SharedState, instance_id: &str) {
    let labels: Vec<String> = {
        let mut guard = shared.inner.lock().unwrap();
        let mut out = Vec::new();
        let mut tab_ids = Vec::new();
        if let Some(svc) = guard.services.get_mut(instance_id) {
            for tab in &mut svc.tabs {
                tab_ids.push(tab.tab_id.clone());
                tab.creation_epoch = tab.creation_epoch.wrapping_add(1);
                if let Some(l) = tab.webview_label.take() {
                    out.push(l);
                }
                tab.is_sleeping = true;
                tab.is_loading = false;
                tab.unread_count = 0;
                tab.load_error = None;
            }
        }
        for tid in tab_ids {
            guard.pending_tab_nav.remove(&tid);
        }
        out
    };

    for label in labels {
        if let Some(wv) = app.get_webview(&label) {
            close_webview_cleanly(&wv);
        }
    }
    refresh_attached_view(app, shared);
    emit_runtime_updated(app, shared, instance_id);
}

pub fn destroy_all_views(app: &AppHandle, shared: &SharedState) {
    let labels: Vec<String> = {
        let mut guard = shared.inner.lock().unwrap();
        guard.active_instance_id = None;
        guard.gmail_open = false;
        guard.gmail_creating_label = None;
        guard.creating_tabs.clear();
        guard.pending_tab_nav.clear();
        let mut out = Vec::new();
        if let Some(ref mut gt) = guard.gmail_tab {
            gt.creation_epoch = gt.creation_epoch.wrapping_add(1);
            if let Some(l) = gt.webview_label.take() {
                out.push(l);
            }
        }
        for svc in guard.services.values_mut() {
            for tab in &mut svc.tabs {
                tab.creation_epoch = tab.creation_epoch.wrapping_add(1);
                if let Some(l) = tab.webview_label.take() {
                    out.push(l);
                }
            }
        }
        out
    };
    for label in labels {
        if let Some(wv) = app.get_webview(&label) {
            close_webview_cleanly(&wv);
        }
    }
    for (label, wv) in app.webviews() {
        if label != "shell" && wv.window().label() == "main" {
            close_webview_cleanly(&wv);
        }
    }
    // 認証用 OAuth ポップアップ（popup-*）が残っているとプロセス終了を妨げるため確実に閉じる
    for (label, win) in app.webview_windows() {
        if label.starts_with("popup-") {
            let _ = win.close();
        }
    }
}

fn get_active_webview_for_service(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
) -> Option<Webview> {
    let label = {
        let guard = shared.inner.lock().unwrap();
        guard
            .services
            .get(instance_id)
            .and_then(|s| s.active_tab())
            .and_then(|t| t.webview_label.clone())
    }?;
    app.get_webview(&label)
}

fn get_all_open_webviews_for_service(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
) -> Vec<Webview> {
    let labels: Vec<String> = {
        let guard = shared.inner.lock().unwrap();
        guard
            .services
            .get(instance_id)
            .map(|s| {
                s.tabs
                    .iter()
                    .filter_map(|t| t.webview_label.clone())
                    .collect()
            })
            .unwrap_or_default()
    };
    labels
        .into_iter()
        .filter_map(|l| app.get_webview(&l))
        .collect()
}

pub fn get_current_active_webview(app: &AppHandle, shared: &SharedState) -> Option<Webview> {
    let label = {
        let guard = shared.inner.lock().unwrap();
        if guard.gmail_open {
            guard.gmail_tab.as_ref().and_then(|t| t.webview_label.clone())
        } else {
            guard
                .active_instance_id
                .as_deref()
                .and_then(|id| guard.services.get(id))
                .and_then(|s| s.active_tab())
                .and_then(|t| t.webview_label.clone())
        }
    }?;
    app.get_webview(&label)
}

/// ドラッグ中ライブスクロール（16msごと）を現在アクティブなタブのWebView2へ送る。
pub fn dispatch_live_scroll(
    app: &AppHandle,
    shared: &SharedState,
    origin_css_x: f64,
    origin_css_y: f64,
    dx: f64,
    dy: f64,
) {
    #[cfg(windows)]
    if let Some(wv) = get_current_active_webview(app, shared) {
        let _ = wv.with_webview(move |pwv| {
            crate::platform_win::dispatch_wheel_scroll(
                &pwv.controller(),
                origin_css_x,
                origin_css_y,
                dx,
                dy,
            );
        });
    }
    #[cfg(not(windows))]
    {
        let _ = (app, shared, origin_css_x, origin_css_y, dx, dy);
    }
}

/// アプリ内 Gmail パネルを開閉する（ログインセッションは維持される）。
pub fn set_gmail_open(app: &AppHandle, shared: &SharedState, open: Option<bool>) -> bool {
    let (next_open, needs_create) = {
        let mut guard = shared.inner.lock().unwrap();
        let next = open.unwrap_or(!guard.gmail_open);
        guard.gmail_open = next;
        let needs = if next {
            if guard.gmail_tab.is_none() {
                guard.gmail_tab = Some(BrowserTabEntry {
                    tab_id: "gmail-tab".to_string(),
                    instance_id: "omnisns-gmail".to_string(),
                    webview_label: None,
                    creation_epoch: 0,
                    warming_until: None,
                    current_url: GMAIL_HOME_URL.to_string(),
                    title: "Gmail".to_string(),
                    favicon_url: None,
                    unread_count: 0,
                    is_loading: false,
                    is_sleeping: true,
                    can_go_back: false,
                    can_go_forward: false,
                    load_error: None,
                });
            }
            let has_wv = guard
                .gmail_tab
                .as_ref()
                .and_then(|t| t.webview_label.as_ref())
                .is_some();
            !has_wv && guard.gmail_creating_label.is_none()
        } else {
            false
        };
        (next, needs)
    };

    if needs_create {
        create_gmail_webview(app, shared);
    }

    update_bounds_from_window(app, shared);
    emit_state_updated(app, shared);
    next_open
}

fn create_gmail_webview(app: &AppHandle, shared: &SharedState) {
    let Some(win) = app.get_window("main") else {
        return;
    };

    let Ok(parsed_url) = url::Url::parse(GMAIL_HOME_URL) else {
        return;
    };

    let gen = WEBVIEW_GEN.fetch_add(1, Ordering::Relaxed);
    let label = format!("gmail-{gen}");

    let Some((bounds, profile_dir, chrome_ver, start_offscreen, my_epoch)) = ({
        let mut guard = shared.inner.lock().unwrap();
        if guard.is_quitting || guard.gmail_creating_label.is_some() {
            None
        } else if let Some(ref tab) = guard.gmail_tab {
            if tab.webview_label.is_some() {
                None
            } else {
                let epoch = tab.creation_epoch;
                let start_offscreen = guard.overlay_visible || !guard.gmail_open;
                guard.gmail_creating_label = Some(label.clone());
                Some((
                    guard.bounds,
                    guard.profiles_root.join("omnisns-gmail"),
                    guard.chrome_version.clone(),
                    start_offscreen,
                    epoch,
                ))
            }
        } else {
            None
        }
    }) else {
        return;
    };

    let _ = fs::create_dir_all(&profile_dir);
    let ua = build_user_agent("desktop", &chrome_ver);

    let app_for_title = app.clone();
    let shared_for_title = shared.clone();
    let label_for_title = label.clone();

    let app_for_popup = app.clone();
    let shared_for_popup = shared.clone();
    let label_for_popup = label.clone();
    let ua_for_popup = ua.clone();

    let gmail_target_url_str = parsed_url.to_string();
    #[cfg(windows)]
    let gmail_builder_url = url::Url::parse("about:blank").unwrap();
    #[cfg(not(windows))]
    let gmail_builder_url = parsed_url;

    #[allow(unused_mut)]
    let mut builder = WebviewBuilder::new(&label, WebviewUrl::External(gmail_builder_url))
        .data_directory(profile_dir)
        .user_agent(&ua)
        .disable_drag_drop_handler()
        .zoom_hotkeys_enabled(true)
        .focused(false)
        .on_navigation(|url| {
            matches!(url.scheme(), "http" | "https" | "about" | "blob" | "data")
                && !is_internal_tauri_url(url)
        });

    #[cfg(windows)]
    {
        builder = builder.additional_browser_args(WEBVIEW2_FAST_BROWSER_ARGS);
    }

    let builder = builder
        .on_permission_request(|_wv, kind| match kind {
            PermissionKind::Notifications => PermissionResponse::Allow,
            _ => PermissionResponse::Default,
        })
        .on_document_title_changed(move |_wv, title| {
            let clean_title = if title.trim().is_empty() {
                "Gmail".to_string()
            } else {
                title
            };
            let changed = {
                let mut guard = shared_for_title.inner.lock().unwrap();
                if let Some(ref mut tab) = guard.gmail_tab {
                    if tab.webview_label.as_deref() == Some(label_for_title.as_str()) {
                        tab.title = clean_title;
                        true
                    } else {
                        false
                    }
                } else {
                    false
                }
            };
            if changed {
                emit_state_updated(&app_for_title, &shared_for_title);
            }
        })
        .on_new_window(move |target_url, features| {
            if is_internal_tauri_url(&target_url) {
                return NewWindowResponse::Deny;
            }
            let (is_alive, current_url) = {
                let guard = shared_for_popup.inner.lock().unwrap();
                let alive = guard
                    .gmail_tab
                    .as_ref()
                    .map(|t| t.webview_label.as_deref() == Some(label_for_popup.as_str()))
                    .unwrap_or(false);
                let cur = guard
                    .gmail_tab
                    .as_ref()
                    .map(|t| t.current_url.clone())
                    .filter(|u| !u.is_empty())
                    .unwrap_or_else(|| GMAIL_HOME_URL.to_string());
                (alive, cur)
            };
            if !is_alive {
                return NewWindowResponse::Deny;
            }
            let target_str = target_url.as_str();
            let has_popup_features = features.size().is_some() || features.position().is_some();
            if is_auth_popup_for_site(target_str, &current_url)
                || (has_popup_features && is_auth_popup_url(target_str))
            {
                let popup_id = POPUP_GEN.fetch_add(1, Ordering::Relaxed);
                let popup_label = format!("popup-{popup_id}");
                let blank_url: url::Url = "about:blank".parse().unwrap();
                let popup_builder = WebviewWindowBuilder::new(
                    &app_for_popup,
                    &popup_label,
                    WebviewUrl::External(blank_url),
                )
                .title("Gmail - 認証 / ウィンドウ")
                .inner_size(560.0, 760.0)
                .user_agent(&ua_for_popup)
                .disable_drag_drop_handler()
                .on_navigation(|url| {
                    matches!(url.scheme(), "http" | "https" | "about" | "blob" | "data")
                        && !is_internal_tauri_url(url)
                })
                .on_permission_request(|_, _| PermissionResponse::Default)
                .window_features(features);
                let popup_builder =
                    if let Some(icon) = app_for_popup.default_window_icon().cloned() {
                        match popup_builder.icon(icon) {
                            Ok(b) => b,
                            Err(_) => return NewWindowResponse::Deny,
                        }
                    } else {
                        popup_builder
                    };
                match popup_builder.build() {
                    Ok(window) => NewWindowResponse::Create { window },
                    Err(_) => NewWindowResponse::Deny,
                }
            } else if is_same_site_url(target_str, &current_url) {
                let app_bg = app_for_popup.clone();
                let shared_bg = shared_for_popup.clone();
                let url_bg = target_str.to_string();
                tauri::async_runtime::spawn(async move {
                    let _ = navigate_gmail(&app_bg, &shared_bg, &url_bg);
                });
                NewWindowResponse::Deny
            } else {
                if is_http_url(target_str) {
                    #[cfg(windows)]
                    crate::platform_win::open_external_url(target_str);
                }
                NewWindowResponse::Deny
            }
        });

    let init_pos = if start_offscreen {
        LogicalPosition::new(-10000.0, -10000.0)
    } else {
        LogicalPosition::new(bounds.x, bounds.y)
    };
    let init_size = LogicalSize::new(bounds.width.max(1.0), bounds.height.max(1.0));

    let Ok(webview) = win.add_child(builder, init_pos, init_size) else {
        let mut guard = shared.inner.lock().unwrap();
        guard.gmail_creating_label = None;
        return;
    };

    let (committed, should_hide_immediately) = {
        let mut guard = shared.inner.lock().unwrap();
        guard.gmail_creating_label = None;
        if guard.is_quitting {
            (false, true)
        } else {
            let hide_now = guard.overlay_visible || !guard.gmail_open;
            if let Some(ref mut tab) = guard.gmail_tab {
                if tab.creation_epoch == my_epoch && tab.webview_label.is_none() {
                    tab.webview_label = Some(label.clone());
                    tab.is_sleeping = false;
                    tab.is_loading = true;
                    tab.load_error = None;
                    (true, hide_now)
                } else {
                    (false, true)
                }
            } else {
                (false, true)
            }
        }
    };

    if !committed {
        close_webview_cleanly(&webview);
        refresh_attached_view(app, shared);
        return;
    }

    if should_hide_immediately {
        let _ = webview.hide();
    }

    #[cfg(windows)]
    {
        let app_start = app.clone();
        let shared_start = shared.clone();
        let label_start = label.clone();

        let app_done = app.clone();
        let shared_done = shared.clone();
        let label_done = label.clone();

        let app_nav = app.clone();
        let shared_nav = shared.clone();
        let label_nav = label.clone();

        let app_fav = app.clone();
        let shared_fav = shared.clone();
        let label_fav = label.clone();

        let app_key = app.clone();
        let shared_key = shared.clone();

        let ua_owned = ua.clone();
        let callbacks = crate::platform_win::TabWebviewCallbacks {
            on_navigation_starting: Arc::new(move || {
                let (changed, was_error) = {
                    let mut guard = shared_start.inner.lock().unwrap();
                    if let Some(ref mut tab) = guard.gmail_tab {
                        if tab.webview_label.as_deref() == Some(label_start.as_str()) {
                            let had_err = tab.load_error.is_some();
                            tab.is_loading = true;
                            tab.is_sleeping = false;
                            tab.load_error = None;
                            (true, had_err)
                        } else {
                            (false, false)
                        }
                    } else {
                        (false, false)
                    }
                };
                if was_error {
                    refresh_attached_view(&app_start, &shared_start);
                }
                if changed {
                    emit_state_updated(&app_start, &shared_start);
                }
            }),
            on_navigation_completed: Arc::new(move |ok, err_msg, url, can_back, can_fwd| {
                let changed = {
                    let mut guard = shared_done.inner.lock().unwrap();
                    if let Some(ref mut tab) = guard.gmail_tab {
                        if tab.webview_label.as_deref() == Some(label_done.as_str()) {
                            tab.is_loading = false;
                            tab.is_sleeping = false;
                            if !url.is_empty() {
                                tab.current_url = url;
                            }
                            tab.can_go_back = can_back;
                            tab.can_go_forward = can_fwd;
                            tab.load_error = if ok { None } else { err_msg };
                            true
                        } else {
                            false
                        }
                    } else {
                        false
                    }
                };
                if changed && !ok {
                    refresh_attached_view(&app_done, &shared_done);
                }
                if changed {
                    emit_state_updated(&app_done, &shared_done);
                }
            }),
            on_nav_flags_changed: Arc::new(move |url, can_back, can_fwd| {
                let changed = {
                    let mut guard = shared_nav.inner.lock().unwrap();
                    if let Some(ref mut tab) = guard.gmail_tab {
                        if tab.webview_label.as_deref() == Some(label_nav.as_str()) {
                            if !url.is_empty() {
                                tab.current_url = url;
                            }
                            tab.can_go_back = can_back;
                            tab.can_go_forward = can_fwd;
                            true
                        } else {
                            false
                        }
                    } else {
                        false
                    }
                };
                if changed {
                    emit_state_updated(&app_nav, &shared_nav);
                }
            }),
            on_favicon_changed: Arc::new(move |favicon| {
                let changed = {
                    let mut guard = shared_fav.inner.lock().unwrap();
                    if let Some(ref mut tab) = guard.gmail_tab {
                        if tab.webview_label.as_deref() == Some(label_fav.as_str()) {
                            tab.favicon_url = Some(favicon);
                            true
                        } else {
                            false
                        }
                    } else {
                        false
                    }
                };
                if changed {
                    emit_state_updated(&app_fav, &shared_fav);
                }
            }),
            on_zoom_factor_changed: Arc::new(move |_zoom| {}),
            on_shortcut: Arc::new(move |action, payload| {
                handle_shortcut_from_child(&app_key, &shared_key, action, payload);
            }),
            on_follow_detected: Arc::new(move |_| {}),
            on_unfollow_detected: Arc::new(move |_| {}),
            on_account_identity: Arc::new(move |_s, _h, _flwng, _flwrs| {}),
        };

        let _ = webview.with_webview(move |platform_wv| {
            let controller = platform_wv.controller();
            crate::platform_win::attach_tab_handlers(
                &controller,
                false,
                1.0,
                &ua_owned,
                String::new(),
                String::new(),
                Some(gmail_target_url_str),
                callbacks,
            );
        });
    }
    #[cfg(not(windows))]
    {
        let _ = gmail_target_url_str;
    }

    emit_state_updated(app, shared);
    refresh_attached_view(app, shared);
}

pub fn perform_gmail_action(app: &AppHandle, shared: &SharedState, action: &str) {
    if action == "close" {
        let _ = set_gmail_open(app, shared, Some(false));
        return;
    }

    let (label_opt, current_url) = {
        let guard = shared.inner.lock().unwrap();
        let label = guard.gmail_tab.as_ref().and_then(|t| t.webview_label.clone());
        let url = guard
            .gmail_tab
            .as_ref()
            .map(|t| t.current_url.clone())
            .filter(|u| !u.is_empty())
            .unwrap_or_else(|| GMAIL_HOME_URL.to_string());
        (label, url)
    };

    match action {
        "back" => {
            #[cfg(windows)]
            if let Some(wv) = label_opt.and_then(|l| app.get_webview(&l)) {
                let _ = wv.with_webview(|pwv| crate::platform_win::go_back(&pwv.controller()));
            }
        }
        "forward" => {
            #[cfg(windows)]
            if let Some(wv) = label_opt.and_then(|l| app.get_webview(&l)) {
                let _ = wv.with_webview(|pwv| crate::platform_win::go_forward(&pwv.controller()));
            }
        }
        "reload" | "hard-reload" => {
            let hard = action == "hard-reload";
            if let Some(wv) = label_opt.and_then(|l| app.get_webview(&l)) {
                #[cfg(windows)]
                let _ = wv.with_webview(move |pwv| {
                    crate::platform_win::reload(&pwv.controller(), hard)
                });
            } else {
                let _ = set_gmail_open(app, shared, Some(true));
            }
        }
        "home" => {
            if let Some(wv) = label_opt.and_then(|l| app.get_webview(&l)) {
                #[cfg(windows)]
                let _ = wv.with_webview(|pwv| {
                    crate::platform_win::navigate(&pwv.controller(), GMAIL_HOME_URL)
                });
            } else {
                let _ = set_gmail_open(app, shared, Some(true));
            }
            refresh_attached_view(app, shared);
        }
        "open-external" => {
            if is_http_url(&current_url) {
                #[cfg(windows)]
                crate::platform_win::open_external_url(&current_url);
            }
        }
        "devtools" => {
            #[cfg(windows)]
            if let Some(wv) = label_opt.and_then(|l| app.get_webview(&l)) {
                let _ = wv.with_webview(|pwv| crate::platform_win::open_devtools(&pwv.controller()));
            }
        }
        "scroll-top" | "scroll-bottom" => {
            let to_top = action == "scroll-top";
            #[cfg(windows)]
            if let Some(wv) = label_opt.and_then(|l| app.get_webview(&l)) {
                let _ = wv.with_webview(move |pwv| {
                    crate::platform_win::scroll_to_edge(&pwv.controller(), to_top)
                });
            }
        }
        _ => {}
    }
}

pub fn navigate_gmail(
    app: &AppHandle,
    shared: &SharedState,
    raw_url: &str,
) -> Result<String, String> {
    let target_url = normalize_service_url(raw_url)
        .ok_or_else(|| "有効な http:// または https:// URL を入力してください".to_string())?;
    let label_opt = {
        let mut guard = shared.inner.lock().unwrap();
        if let Some(ref mut tab) = guard.gmail_tab {
            tab.current_url = target_url.clone();
            tab.load_error = None;
            tab.webview_label.clone()
        } else {
            None
        }
    };
    if let Some(wv) = label_opt.and_then(|l| app.get_webview(&l)) {
        let url_owned = target_url.clone();
        #[cfg(windows)]
        let _ = wv.with_webview(move |pwv| {
            crate::platform_win::navigate(&pwv.controller(), &url_owned);
        });
    } else {
        let _ = set_gmail_open(app, shared, Some(true));
    }
    refresh_attached_view(app, shared);
    emit_state_updated(app, shared);
    Ok(target_url)
}

pub fn perform_tab_action(app: &AppHandle, shared: &SharedState, instance_id: &str, action: &str) {
    let instance = {
        let guard = shared.inner.lock().unwrap();
        guard.store.get_instance(instance_id)
    };
    let Some(instance) = instance else {
        return;
    };

    match action {
        "back" => {
            #[cfg(windows)]
            if let Some(wv) = get_active_webview_for_service(app, shared, instance_id) {
                let _ = wv.with_webview(|pwv| crate::platform_win::go_back(&pwv.controller()));
            }
        }
        "forward" => {
            #[cfg(windows)]
            if let Some(wv) = get_active_webview_for_service(app, shared, instance_id) {
                let _ = wv.with_webview(|pwv| crate::platform_win::go_forward(&pwv.controller()));
            }
        }
        "reload" | "hard-reload" => {
            let hard = action == "hard-reload";
            if let Some(wv) = get_active_webview_for_service(app, shared, instance_id) {
                #[cfg(windows)]
                let _ = wv.with_webview(move |pwv| {
                    crate::platform_win::reload(&pwv.controller(), hard)
                });
            } else {
                activate_tab(app, shared, Some(instance_id.to_string()));
            }
        }
        "home" => {
            if let Some(wv) = get_active_webview_for_service(app, shared, instance_id) {
                let home = instance.url.clone();
                #[cfg(windows)]
                let _ = wv.with_webview(move |pwv| {
                    crate::platform_win::navigate(&pwv.controller(), &home)
                });
            } else {
                activate_tab(app, shared, Some(instance_id.to_string()));
            }
            refresh_attached_view(app, shared);
        }
        "sleep" => {
            sleep_tab(app, shared, instance_id);
        }
        "wake" => {
            activate_tab(app, shared, Some(instance_id.to_string()));
        }
        "toggle-mute" => {
            let next_muted = !instance.muted;
            {
                let mut guard = shared.inner.lock().unwrap();
                guard.store.update_instance(
                    instance_id,
                    crate::models::UpdateInstancePatch {
                        muted: Some(next_muted),
                        ..Default::default()
                    },
                );
            }
            #[cfg(windows)]
            for wv in get_all_open_webviews_for_service(app, shared, instance_id) {
                let _ = wv.with_webview(move |pwv| {
                    crate::platform_win::set_muted(&pwv.controller(), next_muted)
                });
            }
            emit_state_updated(app, shared);
        }
        "zoom-in" | "zoom-out" | "zoom-reset" => {
            let next_zoom = match action {
                "zoom-in" => ((instance.zoom_factor + 0.1) * 100.0).round() / 100.0,
                "zoom-out" => ((instance.zoom_factor - 0.1) * 100.0).round() / 100.0,
                _ => 1.0,
            }
            .clamp(0.3, 3.0);

            {
                let mut guard = shared.inner.lock().unwrap();
                guard.store.update_instance(
                    instance_id,
                    crate::models::UpdateInstancePatch {
                        zoom_factor: Some(next_zoom),
                        ..Default::default()
                    },
                );
            }
            #[cfg(windows)]
            for wv in get_all_open_webviews_for_service(app, shared, instance_id) {
                let _ = wv.with_webview(move |pwv| {
                    crate::platform_win::set_zoom_factor(&pwv.controller(), next_zoom)
                });
            }
            show_overlay_notice(
                shared,
                format!("拡大率: {}%", (next_zoom * 100.0).round() as i32),
                false,
            );
            emit_state_updated(app, shared);
        }
        "toggle-ua" => {
            let next_ua = if instance.ua_mode == "desktop" {
                "mobile".to_string()
            } else {
                "desktop".to_string()
            };
            let ua_str = {
                let mut guard = shared.inner.lock().unwrap();
                guard.store.update_instance(
                    instance_id,
                    crate::models::UpdateInstancePatch {
                        ua_mode: Some(next_ua.clone()),
                        ..Default::default()
                    },
                );
                build_user_agent(&next_ua, &guard.chrome_version)
            };
            #[cfg(windows)]
            for wv in get_all_open_webviews_for_service(app, shared, instance_id) {
                let ua_c = ua_str.clone();
                let _ = wv.with_webview(move |pwv| {
                    crate::platform_win::set_user_agent_and_reload(&pwv.controller(), &ua_c)
                });
            }
            emit_state_updated(app, shared);
        }
        "clear-session" => {
            let (keep_active_label, close_labels, purge_dir_opt) = {
                let mut guard = shared.inner.lock().unwrap();
                guard.cross_site_identities.remove(instance_id);
                guard.store.clear_instance_identity(instance_id);

                let active_label = guard
                    .services
                    .get(instance_id)
                    .and_then(|s| s.active_tab())
                    .and_then(|t| t.webview_label.clone());

                let mut to_close = Vec::new();
                let mut had_live_or_creating = false;
                let mut cleared_tab_ids = Vec::new();
                let creating_tab_ids: HashSet<String> =
                    guard.creating_tabs.keys().cloned().collect();
                if let Some(svc) = guard.services.get_mut(instance_id) {
                    let active_tid = svc.active_tab_id.clone();
                    for tab in &mut svc.tabs {
                        let is_kept_active =
                            active_label.is_some() && tab.tab_id == active_tid;
                        if is_kept_active {
                            continue;
                        }
                        cleared_tab_ids.push(tab.tab_id.clone());
                        if creating_tab_ids.contains(&tab.tab_id) {
                            had_live_or_creating = true;
                        }
                        tab.creation_epoch = tab.creation_epoch.wrapping_add(1);
                        if let Some(l) = tab.webview_label.take() {
                            had_live_or_creating = true;
                            to_close.push(l);
                        }
                        tab.is_sleeping = true;
                        tab.is_loading = false;
                        tab.unread_count = 0;
                        tab.load_error = None;
                    }
                }
                for tid in cleared_tab_ids {
                    guard.pending_tab_nav.remove(&tid);
                }

                let purge = if active_label.is_none() {
                    Some((
                        profile_dir_for(&guard.profiles_root, instance_id),
                        had_live_or_creating,
                    ))
                } else {
                    None
                };
                (active_label, to_close, purge)
            };

            for label in close_labels {
                if let Some(wv) = app.get_webview(&label) {
                    close_webview_cleanly(&wv);
                }
            }
            if let Some(label) = keep_active_label {
                if let Some(wv) = app.get_webview(&label) {
                    let home = instance.url.clone();
                    #[cfg(windows)]
                    let _ = wv.with_webview(move |pwv| {
                        crate::platform_win::clear_browsing_data_and_navigate(
                            &pwv.controller(),
                            home,
                        )
                    });
                }
            } else if let Some((profile_dir, had_live)) = purge_dir_opt {
                spawn_profile_dir_cleanup(
                    shared,
                    vec![(Some(instance_id.to_string()), profile_dir, had_live)],
                );
            }
            refresh_attached_view(app, shared);
            emit_state_updated(app, shared);
        }
        "devtools" => {
            #[cfg(windows)]
            if let Some(wv) = get_active_webview_for_service(app, shared, instance_id) {
                let _ = wv.with_webview(|pwv| {
                    crate::platform_win::open_devtools(&pwv.controller())
                });
            }
        }
        "open-external" => {
            let target_url = {
                let guard = shared.inner.lock().unwrap();
                guard
                    .services
                    .get(instance_id)
                    .and_then(|s| s.active_tab())
                    .map(|t| t.current_url.clone())
                    .filter(|u| !u.is_empty())
                    .unwrap_or_else(|| instance.url.clone())
            };
            if is_http_url(&target_url) {
                #[cfg(windows)]
                crate::platform_win::open_external_url(&target_url);
            }
        }
        "scroll-top" | "scroll-bottom" => {
            let to_top = action == "scroll-top";
            #[cfg(windows)]
            if let Some(wv) = get_active_webview_for_service(app, shared, instance_id) {
                let _ = wv.with_webview(move |pwv| {
                    crate::platform_win::scroll_to_edge(&pwv.controller(), to_top)
                });
            }
        }
        _ => {}
    }
}

/// ジェスチャー開始位置へ Ctrl+クリック を送信する。
pub fn dispatch_ctrl_click(
    app: &AppHandle,
    shared: &SharedState,
    origin_css_x: f64,
    origin_css_y: f64,
) {
    #[cfg(windows)]
    if let Some(wv) = get_current_active_webview(app, shared) {
        crate::gesture_win::mark_gesture_ctrl_click();
        let _ = wv.with_webview(move |pwv| {
            crate::platform_win::dispatch_ctrl_click(
                &pwv.controller(),
                origin_css_x,
                origin_css_y,
            );
        });
    }
    #[cfg(not(windows))]
    {
        let _ = (app, shared, origin_css_x, origin_css_y);
    }
}

/// ジェスチャーまたはショートカットから渡された操作を実行する。
pub fn execute_gesture_action(app: &AppHandle, shared: &SharedState, action: &str) {
    execute_gesture_action_with_origin(app, shared, action, None, None);
}

/// 開始座標つきでジェスチャー操作を実行する（Ctrl+クリック等）。
pub fn execute_gesture_action_with_origin(
    app: &AppHandle,
    shared: &SharedState,
    action: &str,
    origin_lx: Option<f64>,
    origin_ly: Option<f64>,
) {
    let (gmail_open, gmail_nav, active_pair) = {
        let guard = shared.inner.lock().unwrap();
        let g_nav = guard
            .gmail_tab
            .as_ref()
            .map(|t| (t.can_go_back, t.can_go_forward))
            .unwrap_or((false, false));
        let pair = guard.active_instance_id.as_ref().and_then(|inst_id| {
            guard.services.get(inst_id).and_then(|svc| {
                svc.active_tab().map(|t| {
                    (
                        inst_id.clone(),
                        t.tab_id.clone(),
                        t.can_go_back,
                        t.can_go_forward,
                    )
                })
            })
        });
        (guard.gmail_open, g_nav, pair)
    };

    if gmail_open {
        match action {
            "close-tab" => {
                let _ = set_gmail_open(app, shared, Some(false));
                show_overlay_notice(shared, "Gmailを閉じました", false);
                return;
            }
            "go-back" => {
                if gmail_nav.0 {
                    perform_gmail_action(app, shared, "back");
                } else {
                    show_overlay_notice(shared, "これ以上戻れません", false);
                }
                return;
            }
            "go-forward" => {
                if gmail_nav.1 {
                    perform_gmail_action(app, shared, "forward");
                } else {
                    show_overlay_notice(shared, "これ以上進めません", false);
                }
                return;
            }
            "reload" | "hard-reload" | "home" | "open-external" | "scroll-top"
            | "scroll-bottom" => {
                perform_gmail_action(app, shared, action);
                return;
            }
            _ => {}
        }
    }

    match action {
        "previous-tab" => {
            if let Err(reason) = step_active_tab(app, shared, -1) {
                show_overlay_notice(shared, reason, false);
            }
        }
        "next-tab" => {
            if let Err(reason) = step_active_tab(app, shared, 1) {
                show_overlay_notice(shared, reason, false);
            }
        }
        "previous-service" => {
            if let Err(reason) = step_active_service(app, shared, -1) {
                show_overlay_notice(shared, reason, false);
            }
        }
        "next-service" => {
            if let Err(reason) = step_active_service(app, shared, 1) {
                show_overlay_notice(shared, reason, false);
            }
        }
        "previous-account" => {
            if let Err(reason) = step_active_account(app, shared, -1) {
                show_overlay_notice(shared, reason, false);
            }
        }
        "next-account" => {
            if let Err(reason) = step_active_account(app, shared, 1) {
                show_overlay_notice(shared, reason, false);
            }
        }
        "new-tab" => {
            if let Some((inst_id, _, _, _)) = active_pair {
                if let Err(e) = create_subtab(app, shared, &inst_id, None) {
                    show_overlay_notice(shared, e, true);
                }
            }
        }
        "ctrl-click" => {
            if let (Some(ox), Some(oy)) = (origin_lx, origin_ly) {
                dispatch_ctrl_click(app, shared, ox, oy);
            }
        }
        "duplicate-tab" => {
            if let Some((inst_id, tab_id, _, _)) = active_pair {
                if let Err(e) = duplicate_subtab(app, shared, &inst_id, &tab_id) {
                    show_overlay_notice(shared, e, true);
                }
            }
        }
        "close-tab" => {
            if let Some((inst_id, tab_id, _, _)) = active_pair {
                if let Some(msg) = close_subtab(app, shared, &inst_id, &tab_id) {
                    show_overlay_notice(shared, msg, false);
                }
            }
        }
        "close-other-tabs" => {
            if let Some((inst_id, tab_id, _, _)) = active_pair {
                let n = close_other_subtabs(app, shared, &inst_id, &tab_id);
                if n == 0 {
                    show_overlay_notice(shared, "他に閉じられるタブはありません", false);
                } else {
                    show_overlay_notice(shared, format!("他のタブ {n} 枚を閉じました"), false);
                }
            }
        }
        "restore-closed" => match restore_closed_tab(app, shared) {
            Ok(msg) => show_overlay_notice(shared, msg, false),
            Err(msg) => show_overlay_notice(shared, msg, false),
        },
        "go-back" => {
            if let Some((inst_id, _, can_back, _)) = active_pair {
                if can_back {
                    perform_tab_action(app, shared, &inst_id, "back");
                } else {
                    show_overlay_notice(shared, "これ以上戻れません", false);
                }
            }
        }
        "go-forward" => {
            if let Some((inst_id, _, _, can_fwd)) = active_pair {
                if can_fwd {
                    perform_tab_action(app, shared, &inst_id, "forward");
                } else {
                    show_overlay_notice(shared, "これ以上進めません", false);
                }
            }
        }
        "reload" | "hard-reload" | "home" | "toggle-ua" | "toggle-mute" | "zoom-in"
        | "zoom-out" | "zoom-reset" | "open-external" | "scroll-top" | "scroll-bottom" => {
            if let Some((inst_id, _, _, _)) = active_pair {
                perform_tab_action(app, shared, &inst_id, action);
            }
        }
        "sleep-tab" => {
            if let Some((inst_id, _, _, _)) = active_pair {
                perform_tab_action(app, shared, &inst_id, "sleep");
            }
        }
        "open-catalog" => {
            handle_shortcut_from_child(app, shared, "open-catalog", None);
        }
        "gesture:settings" => {
            handle_shortcut_from_child(app, shared, "open-gesture-settings", None);
        }
        _ => {}
    }
}

pub fn update_gesture_settings(
    app: &AppHandle,
    shared: &SharedState,
    gesture: GestureSettings,
) -> GestureSettings {
    let updated = {
        let mut guard = shared.inner.lock().unwrap();
        let next = guard.store.update_settings(UpdateSettingsPatch {
            gesture: Some(gesture),
            ..Default::default()
        });
        next.gesture
    };
    sync_gesture_host_state(app, shared);
    emit_state_updated(app, shared);
    updated
}

/// タブ内で別SNS（例: ThreadsタブからInstagramへ遷移）を表示している場合、
/// 実際に表示中のサービスに一致するアカウントインスタンスを解決する。
/// 一致するサービスのインスタンスが存在しない場合は `None` を返し、元SNSのカウントを誤加算しない。
fn resolve_counter_target_instance_id(
    guard: &AppStateInner,
    source_instance_id: &str,
    current_url: Option<&str>,
    service_hint: Option<&str>,
    handle_hint: Option<&str>,
) -> Option<String> {
    let instances = guard.store.get_instances();
    let source = instances
        .iter()
        .find(|i| i.instance_id == source_instance_id)?;

    let effective_service = service_hint
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| !s.is_empty())
        .or_else(|| {
            current_url
                .and_then(detect_platform_service_from_url)
                .map(|s| s.to_string())
        })
        .unwrap_or_else(|| source.service_id.clone());

    if effective_service == source.service_id {
        return Some(source.instance_id.clone());
    }

    let candidates: Vec<&ServiceInstance> = instances
        .iter()
        .filter(|i| i.service_id == effective_service)
        .collect();
    if candidates.is_empty() {
        return None;
    }

    // 1. 判明しているハンドル（明示/クロスサイト検出ハンドルを優先、無ければ元インスタンスのハンドル）
    let effective_handle = handle_hint
        .and_then(crate::follow_sync::normalize_account_handle)
        .or_else(|| {
            guard
                .cross_site_identities
                .get(source_instance_id)
                .filter(|(svc, _)| svc == &effective_service)
                .map(|(_, h)| h.clone())
        });
    let known_handle = effective_handle.or_else(|| {
        source
            .detected_handle
            .as_deref()
            .and_then(crate::follow_sync::normalize_account_handle)
    });

    if let Some(ref h) = known_handle {
        if let Some(matched) = candidates
            .iter()
            .find(|c| c.detected_handle.as_deref() == Some(h.as_str()))
        {
            return Some(matched.instance_id.clone());
        }
    }

    // クロスサイト時に別ハンドルが既に紐付いている既存アカウントへ誤ってフォールバック・上書きしない
    let fallback_candidates: Vec<&ServiceInstance> = if known_handle.is_some() {
        candidates
            .iter()
            .copied()
            .filter(|c| c.detected_handle.is_none())
            .collect()
    } else {
        candidates
    };
    if fallback_candidates.is_empty() {
        return None;
    }

    // 2. 対象サービスで直近アクティブだったアカウント
    if let Some(last_id) = guard.last_active_by_group.get(&effective_service) {
        if let Some(matched) = fallback_candidates
            .iter()
            .find(|c| &c.instance_id == last_id)
        {
            return Some(matched.instance_id.clone());
        }
    }

    // 4. アカウントラベル一致（例: 「サブ」「アカウント 2」）
    if let Some(ref lbl) = source.account_label {
        let trimmed = lbl.trim();
        if !trimmed.is_empty() {
            if let Some(matched) = fallback_candidates
                .iter()
                .find(|c| c.account_label.as_deref().map(str::trim) == Some(trimmed))
            {
                return Some(matched.instance_id.clone());
            }
        }
    }

    Some(fallback_candidates[0].instance_id.clone())
}

pub fn adjust_follow_count(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    delta: i32,
) -> Option<ServiceInstance> {
    let updated = {
        let mut guard = shared.inner.lock().unwrap();
        guard.store.adjust_follow_count(instance_id, delta)
    };
    if updated.is_some() {
        emit_state_updated(app, shared);
        notify_follow_ledger_changed(app, shared);
    }
    updated
}

pub fn reset_follow_count(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    reset_total: bool,
) -> Option<ServiceInstance> {
    let updated = {
        let mut guard = shared.inner.lock().unwrap();
        guard.store.reset_follow_count(instance_id, reset_total)
    };
    if updated.is_some() {
        emit_state_updated(app, shared);
        notify_follow_ledger_changed(app, shared);
    }
    updated
}

pub fn adjust_unfollow_count(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    delta: i32,
) -> Option<ServiceInstance> {
    let updated = {
        let mut guard = shared.inner.lock().unwrap();
        guard.store.adjust_unfollow_count(instance_id, delta)
    };
    if updated.is_some() {
        emit_state_updated(app, shared);
        notify_follow_ledger_changed(app, shared);
    }
    updated
}

pub fn reset_unfollow_count(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    reset_total: bool,
) -> Option<ServiceInstance> {
    let updated = {
        let mut guard = shared.inner.lock().unwrap();
        guard.store.reset_unfollow_count(instance_id, reset_total)
    };
    if updated.is_some() {
        emit_state_updated(app, shared);
        notify_follow_ledger_changed(app, shared);
    }
    updated
}

pub fn handle_account_identity(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    handle: &str,
    following: Option<u32>,
    followers: Option<u32>,
) {
    let (ui_changed, ledger_changed) = {
        let mut guard = shared.inner.lock().unwrap();
        guard
            .store
            .record_account_identity(instance_id, handle, following, followers)
    };
    if ui_changed {
        emit_state_updated(app, shared);
    }
    if ledger_changed {
        notify_follow_ledger_changed(app, shared);
    }
}

pub fn set_instance_handle(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    raw_handle: &str,
) -> Result<ServiceInstance, String> {
    let (updated, ledger_changed) = {
        let mut guard = shared.inner.lock().unwrap();
        guard.store.set_instance_handle(instance_id, raw_handle)?
    };
    emit_state_updated(app, shared);
    if ledger_changed {
        notify_follow_ledger_changed(app, shared);
    }
    Ok(updated)
}

pub fn notify_follow_ledger_changed(app: &AppHandle, shared: &SharedState) {
    let (token, gen_arc, worker_running) = {
        let guard = shared.inner.lock().unwrap();
        let fs = guard.store.get_follow_sync_settings();
        (
            fs.github_token,
            guard.cloud_sync_gen.clone(),
            guard.cloud_sync_worker_running.clone(),
        )
    };

    if token.trim().is_empty() {
        return;
    }

    gen_arc.fetch_add(1, Ordering::SeqCst);
    // 単一のデバウンスワーカーのみ起動し、連続イベントによる無制限スレッド生成（panic=abort）を防ぐ
    if worker_running
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return;
    }

    let app_bg = app.clone();
    let shared_bg = shared.clone();
    let worker_bg = worker_running.clone();
    if std::thread::Builder::new()
        .name("omnisns-cloud-debounce".to_string())
        .spawn(move || {
            loop {
                let target_gen = gen_arc.load(Ordering::SeqCst);
                std::thread::sleep(Duration::from_millis(2000));
                if shared_bg.inner.lock().unwrap().is_quitting {
                    worker_bg.store(false, Ordering::SeqCst);
                    return;
                }
                if gen_arc.load(Ordering::SeqCst) != target_gen {
                    continue;
                }
                let _ = sync_cloud_gist_once_blocking(&app_bg, &shared_bg);
                if gen_arc.load(Ordering::SeqCst) == target_gen {
                    worker_bg.store(false, Ordering::SeqCst);
                    // クリア直前に新たな更新が割り込んだ場合はもう一度だけ再確認して取りこぼしを防ぐ
                    if gen_arc.load(Ordering::SeqCst) != target_gen
                        && worker_bg
                            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                            .is_ok()
                    {
                        continue;
                    }
                    break;
                }
            }
        })
        .is_err()
    {
        worker_running.store(false, Ordering::SeqCst);
    }
}

pub fn sync_cloud_gist_once_blocking(
    app: &AppHandle,
    shared: &SharedState,
) -> Result<FollowSyncSettings, String> {
    // 定期同期・デバウンス同期・手動同期を直列化し、重複 Gist 作成や GET->PATCH 競合を防止
    let _sync_guard = shared
        .cloud_sync_lock
        .lock()
        .unwrap_or_else(|e| e.into_inner());

    let (token, gist_id, local_ledger, config_gen_before, config_gen_arc) = {
        let guard = shared.inner.lock().unwrap();
        let fs = guard.store.get_follow_sync_settings();
        let cfg_arc = guard.cloud_sync_config_gen.clone();
        let cfg_gen = cfg_arc.load(Ordering::SeqCst);
        (
            fs.github_token,
            fs.gist_id,
            guard.store.get_follow_ledger(),
            cfg_gen,
            cfg_arc,
        )
    };

    if token.trim().is_empty() {
        return Err("GitHub Personal Access Token（gist権限）が未設定です".to_string());
    }

    let today = crate::store::local_today_ymd();
    match crate::follow_sync::sync_with_github_gist(&token, &gist_id, &local_ledger, &today) {
        Ok((resolved_gist_id, merged_ledger, _remote_changed)) => {
            let now = crate::follow_sync::now_unix_secs();
            let updated_settings = {
                let mut guard = shared.inner.lock().unwrap();
                // 同期実行中にユーザーが Token / Gist ID を変更した場合は古い結果を破棄する
                if config_gen_arc.load(Ordering::SeqCst) != config_gen_before {
                    return Ok(guard.store.get_follow_sync_settings());
                }
                let _ = guard.store.merge_follow_ledger(&merged_ledger);
                guard.store.set_follow_sync_status(
                    Some(resolved_gist_id),
                    "クラウド同期完了".to_string(),
                    Some(now),
                )
            };
            emit_state_updated(app, shared);
            Ok(updated_settings)
        }
        Err(err) => {
            {
                let mut guard = shared.inner.lock().unwrap();
                if config_gen_arc.load(Ordering::SeqCst) == config_gen_before {
                    guard
                        .store
                        .set_follow_sync_status(None, format!("同期エラー: {err}"), None);
                }
            }
            emit_state_updated(app, shared);
            Err(err)
        }
    }
}

pub fn update_follow_sync_settings(
    app: &AppHandle,
    shared: &SharedState,
    patch: UpdateFollowSyncPatch,
) -> FollowSyncSettings {
    let updated = {
        let mut guard = shared.inner.lock().unwrap();
        guard.cloud_sync_config_gen.fetch_add(1, Ordering::SeqCst);
        guard.store.update_follow_sync_settings(patch)
    };
    emit_state_updated(app, shared);
    updated
}

pub async fn trigger_follow_sync_now(
    app: &AppHandle,
    shared: &SharedState,
) -> Result<FollowSyncSettings, String> {
    let token = {
        let guard = shared.inner.lock().unwrap();
        guard.store.get_follow_sync_settings().github_token
    };

    if !token.trim().is_empty() {
        let app_bg = app.clone();
        let shared_bg = shared.clone();
        return tauri::async_runtime::spawn_blocking(move || {
            sync_cloud_gist_once_blocking(&app_bg, &shared_bg)
        })
        .await
        .map_err(|e| format!("同期タスクの実行に失敗しました: {e}"))?;
    }

    Err("GitHub Personal Access Token（gist権限）を入力してください".to_string())
}
