use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use tauri::webview::{NewWindowResponse, PermissionKind, PermissionResponse, WebviewBuilder};
use tauri::{
    AppHandle, Emitter, LogicalPosition, LogicalSize, Manager, Rect, Webview, WebviewUrl,
    WebviewWindowBuilder,
};

use crate::gesture::{step_tab_index, GestureSettings};
use crate::models::{BrowserTabInfo, ServiceInstance, TabRuntimeState, UpdateSettingsPatch};
use crate::store::ConfigStore;
use crate::url_utils::{
    build_user_agent, is_auth_popup_url, is_http_url, is_same_site_url, normalize_service_url,
    parse_unread_count_from_title, service_group_key,
};

pub const ACCOUNTBAR_HEIGHT: f64 = 40.0;
pub const TOOLBAR_HEIGHT: f64 = 44.0;
pub const TABBAR_HEIGHT: f64 = 34.0;
pub const TOP_HEADER_HEIGHT: f64 = ACCOUNTBAR_HEIGHT + TOOLBAR_HEIGHT + TABBAR_HEIGHT;

pub fn top_header_height(header_collapsed: bool) -> f64 {
    if header_collapsed {
        ACCOUNTBAR_HEIGHT
    } else {
        TOP_HEADER_HEIGHT
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

    fn to_info(&self) -> BrowserTabInfo {
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

    fn to_runtime_state(&self, inst: &ServiceInstance) -> TabRuntimeState {
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
    Service {
        instance: ServiceInstance,
        url: String,
        title: String,
    },
}

pub struct AppStateInner {
    pub store: ConfigStore,
    pub services: HashMap<String, ServiceTabs>,
    pub last_active_by_group: HashMap<String, String>,
    pub closed_tabs: Vec<ClosedEntry>,
    pub active_instance_id: Option<String>,
    pub overlay_visible: bool,
    pub is_quitting: bool,
    pub bootstrapped: bool,
    pub bounds: ContentBounds,
    pub profiles_root: PathBuf,
    pub chrome_version: String,
    pub main_hwnd: isize,
    #[cfg(windows)]
    pub gesture_host: Option<crate::gesture_win::GestureWinHost>,
}

#[derive(Clone)]
pub struct SharedState {
    pub inner: Arc<Mutex<AppStateInner>>,
}

impl SharedState {
    pub fn new(store: ConfigStore, profiles_root: PathBuf, chrome_version: String) -> Self {
        let mut services = HashMap::new();
        for inst in store.get_instances() {
            services.insert(inst.instance_id.clone(), ServiceTabs::new_initial(&inst));
        }
        let settings_init = store.get_settings();
        let sidebar_w = settings_init.sidebar_width as f64;
        let top_h = top_header_height(settings_init.header_collapsed);
        Self {
            inner: Arc::new(Mutex::new(AppStateInner {
                store,
                services,
                last_active_by_group: HashMap::new(),
                closed_tabs: Vec::new(),
                active_instance_id: None,
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
                #[cfg(windows)]
                gesture_host: None,
            })),
        }
    }

    pub fn build_all_runtime_states(guard: &AppStateInner) -> Vec<TabRuntimeState> {
        let mut out = Vec::new();
        for inst in guard.store.get_instances() {
            if let Some(st) = guard.services.get(&inst.instance_id) {
                out.push(st.to_runtime_state(&inst));
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
            let active_sleeping_or_err = guard
                .active_instance_id
                .as_deref()
                .and_then(|id| guard.services.get(id))
                .and_then(|s| s.active_tab())
                .map(|t| t.is_sleeping || t.load_error.is_some() || t.webview_label.is_none())
                .unwrap_or(true);
            let suspended = guard.overlay_visible
                || guard.active_instance_id.is_none()
                || active_sleeping_or_err;
            let st = guard.store.get_settings();
            (
                guard.gesture_host.clone(),
                guard.main_hwnd,
                st.sidebar_width as f64,
                top_header_height(st.header_collapsed),
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
        }
    };

    if let Some(shell) = app.get_webview("shell") {
        let _ = shell.emit("app:state-updated", payload);
    }
    update_window_title(app, shared);
}

pub fn emit_runtime_updated(app: &AppHandle, shared: &SharedState, instance_id: &str) {
    let state_opt = {
        let guard = shared.inner.lock().unwrap();
        guard
            .store
            .get_instance(instance_id)
            .and_then(|inst| guard.services.get(instance_id).map(|s| s.to_runtime_state(&inst)))
    };

    if let Some(state) = state_opt {
        if let Some(shell) = app.get_webview("shell") {
            let _ = shell.emit("tab:runtime-updated", state);
        }
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

/// ConfigStore のインスタンス一覧に合わせて ServiceTabs / 削除済みWebview を同期する。
/// `purge_profile` が false の場合は閉じたタブ復元のためディスク上のプロファイルを保持する。
pub fn sync_instances_ex(app: &AppHandle, shared: &SharedState, purge_profiles: bool) {
    let to_close: Vec<(String, Option<PathBuf>)> = {
        let mut guard = shared.inner.lock().unwrap();
        let instances = guard.store.get_instances();
        let valid_ids: HashSet<String> = instances.iter().map(|i| i.instance_id.clone()).collect();

        let removed_ids: Vec<String> = guard
            .services
            .keys()
            .filter(|id| !valid_ids.contains(*id))
            .cloned()
            .collect();

        let mut close_list = Vec::new();
        for id in &removed_ids {
            let prof = if purge_profiles {
                Some(profile_dir_for(&guard.profiles_root, id))
            } else {
                None
            };
            if let Some(svc) = guard.services.remove(id) {
                let mut had_open = false;
                for tab in svc.tabs {
                    if let Some(label) = tab.webview_label {
                        had_open = true;
                        close_list.push((label, prof.clone()));
                    }
                }
                if !had_open {
                    if let Some(dir) = prof {
                        let _ = fs::remove_dir_all(dir);
                    }
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

        close_list
    };

    for (label, maybe_profile_dir) in to_close {
        if let Some(wv) = app.get_webview(&label) {
            let _ = wv.close();
        }
        if let Some(profile_dir) = maybe_profile_dir {
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(600));
                let _ = fs::remove_dir_all(profile_dir);
            });
        }
    }
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
        let top_h = top_header_height(st.header_collapsed);
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
    let (target_label, bounds, all_labels, should_focus_shell) = {
        let guard = shared.inner.lock().unwrap();
        let active_tab = guard
            .active_instance_id
            .as_deref()
            .and_then(|id| guard.services.get(id))
            .and_then(|s| s.active_tab());

        let active_has_error = active_tab
            .map(|t| t.load_error.is_some())
            .unwrap_or(false);

        let should_hide = guard.overlay_visible
            || guard.active_instance_id.is_none()
            || active_has_error;

        let target = if should_hide {
            None
        } else {
            active_tab.and_then(|t| t.webview_label.clone())
        };

        let mut labels = Vec::new();
        for svc in guard.services.values() {
            for tab in &svc.tabs {
                if let Some(ref l) = tab.webview_label {
                    labels.push(l.clone());
                }
            }
        }
        (target, guard.bounds, labels, guard.overlay_visible)
    };

    for label in all_labels {
        if target_label.as_deref() == Some(label.as_str()) {
            continue;
        }
        if let Some(wv) = app.get_webview(&label) {
            let _ = wv.hide();
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
    } else if should_focus_shell {
        if let Some(shell) = app.get_webview("shell") {
            let _ = shell.set_focus();
        }
    }

    sync_gesture_host_state(app, shared);
}

pub fn activate_tab(app: &AppHandle, shared: &SharedState, instance_id: Option<String>) {
    let needs_create: Option<(ServiceInstance, String, String)> = {
        let mut guard = shared.inner.lock().unwrap();
        guard.active_instance_id = instance_id.clone();

        match instance_id {
            None => None,
            Some(ref id) => {
                if let Some(inst) = guard.store.get_instance(id) {
                    let gkey = service_group_key(&inst.service_id, &inst.url, &inst.instance_id);
                    guard.last_active_by_group.insert(gkey, inst.instance_id.clone());
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
                    if tab.webview_label.is_none() {
                        Some((inst, tab.tab_id.clone(), tab.current_url.clone()))
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

    refresh_attached_view(app, shared);
}

pub fn activate_subtab(app: &AppHandle, shared: &SharedState, instance_id: &str, tab_id: &str) {
    let needs_create: Option<(ServiceInstance, String, String)> = {
        let mut guard = shared.inner.lock().unwrap();
        let Some(inst) = guard.store.get_instance(instance_id) else {
            return;
        };
        let gkey = service_group_key(&inst.service_id, &inst.url, &inst.instance_id);
        guard.last_active_by_group.insert(gkey, inst.instance_id.clone());
        guard.active_instance_id = Some(instance_id.to_string());
        guard.store.update_settings(UpdateSettingsPatch {
            active_instance_id: Some(Some(instance_id.to_string())),
            ..Default::default()
        });
        let Some(svc) = guard.services.get_mut(instance_id) else {
            return;
        };
        let Some(tab) = svc.tabs.iter().find(|t| t.tab_id == tab_id) else {
            return;
        };
        svc.active_tab_id = tab_id.to_string();
        if tab.webview_label.is_none() {
            Some((inst, tab.tab_id.clone(), tab.current_url.clone()))
        } else {
            None
        }
    };

    if let Some((inst, tid, url)) = needs_create {
        create_tab_webview(app, shared, inst, tid, url);
    }

    refresh_attached_view(app, shared);
    emit_state_updated(app, shared);
}

pub fn create_subtab(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    url_override: Option<String>,
) -> Result<String, String> {
    let (inst, tab_id, target_url) = {
        let mut guard = shared.inner.lock().unwrap();
        let inst = guard
            .store
            .get_instance(instance_id)
            .ok_or_else(|| "対象サービスが見つかりません".to_string())?;
        let svc = guard
            .services
            .entry(instance_id.to_string())
            .or_insert_with(|| ServiceTabs::new_initial(&inst));
        if svc.tabs.len() >= MAX_SUBTABS_PER_SERVICE {
            return Err(format!(
                "1つのサービスで開けるタブは最大 {MAX_SUBTABS_PER_SERVICE} 枚です"
            ));
        }

        let target_url = url_override
            .as_deref()
            .and_then(normalize_service_url)
            .unwrap_or_else(|| inst.url.clone());
        let entry = BrowserTabEntry::new_for_service(&inst, target_url.clone(), inst.name.clone());
        let tid = entry.tab_id.clone();
        svc.tabs.push(entry);
        svc.active_tab_id = tid.clone();
        guard.active_instance_id = Some(instance_id.to_string());
        guard.store.update_settings(UpdateSettingsPatch {
            active_instance_id: Some(Some(instance_id.to_string())),
            ..Default::default()
        });
        (inst, tid, target_url)
    };

    create_tab_webview(app, shared, inst, tab_id.clone(), target_url);
    refresh_attached_view(app, shared);
    emit_state_updated(app, shared);
    Ok(tab_id)
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
        ClosedService {
            service_name: String,
        },
        LastServiceSlept {
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
            let svc = guard.services.get_mut(instance_id).unwrap();
            let Some(pos) = svc.tabs.iter().position(|t| t.tab_id == tab_id) else {
                return None;
            };
            let removed = svc.tabs.remove(pos);
            let next_idx = pos.min(svc.tabs.len() - 1);
            let next_tab_id = svc.tabs[next_idx].tab_id.clone();
            let needs_create = if svc.tabs[next_idx].webview_label.is_none() {
                Some((
                    inst.clone(),
                    next_tab_id.clone(),
                    svc.tabs[next_idx].current_url.clone(),
                ))
            } else {
                None
            };
            if svc.active_tab_id == tab_id {
                svc.active_tab_id = next_tab_id;
            }
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
            // 最後のサブタブ -> 他にサービスがあればこのサービスを閉じて履歴へ積む（プロファイルは保持！）
            let total_count = guard.store.get_instances().len();
            if total_count >= 2 {
                let (cur_url, cur_title) = guard
                    .services
                    .get(instance_id)
                    .and_then(|s| s.active_tab())
                    .map(|t| (t.current_url.clone(), t.title.clone()))
                    .unwrap_or_else(|| (inst.url.clone(), inst.name.clone()));
                push_closed_entry(
                    &mut guard,
                    ClosedEntry::Service {
                        instance: inst.clone(),
                        url: cur_url,
                        title: cur_title,
                    },
                );
                guard.store.remove_instance(instance_id);
                CloseOutcome::ClosedService {
                    service_name: inst.name,
                }
            } else {
                CloseOutcome::LastServiceSlept {
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
                    let _ = wv.close();
                }
            }
            if let Some((inst, tid, url)) = activate_next {
                create_tab_webview(app, shared, inst, tid, url);
            }
            refresh_attached_view(app, shared);
            emit_state_updated(app, shared);
            None
        }
        CloseOutcome::ClosedService { service_name } => {
            sync_instances_ex(app, shared, false);
            let next_active = ensure_safe_active_instance(shared);
            activate_tab(app, shared, next_active);
            emit_state_updated(app, shared);
            Some(format!(
                "「{service_name}」を閉じました（閉じたタブを復元で戻せます）"
            ))
        }
        CloseOutcome::LastServiceSlept { service_name } => {
            sleep_tab(app, shared, instance_id);
            Some(format!(
                "最後のサービス「{service_name}」を休止しました"
            ))
        }
    }
}

pub fn close_other_subtabs(
    app: &AppHandle,
    shared: &SharedState,
    instance_id: &str,
    keep_tab_id: &str,
) -> usize {
    let closed_labels: Vec<String> = {
        let mut guard = shared.inner.lock().unwrap();
        let mut labels = Vec::new();
        let mut closed_entries = Vec::new();
        if let Some(svc) = guard.services.get_mut(instance_id) {
            if svc.tabs.len() <= 1 {
                return 0;
            }
            let mut kept = Vec::new();
            for tab in svc.tabs.drain(..) {
                if tab.tab_id == keep_tab_id {
                    kept.push(tab);
                } else {
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
            if kept.is_empty() {
                return 0;
            }
            svc.tabs = kept;
            svc.active_tab_id = svc.tabs[0].tab_id.clone();
        }
        let closed_count = closed_entries.len();
        for entry in closed_entries {
            push_closed_entry(&mut guard, entry);
        }
        if closed_count == 0 {
            return 0;
        }
        labels
    };

    let closed_num = closed_labels.len();
    for label in closed_labels {
        if let Some(wv) = app.get_webview(&label) {
            let _ = wv.close();
        }
    }
    refresh_attached_view(app, shared);
    emit_state_updated(app, shared);
    closed_num.max(1)
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
            if exists {
                create_subtab(app, shared, &instance_id, Some(url))?;
                Ok(format!("「{title}」を復元しました"))
            } else {
                // 親サービスが消えていた場合は現在のアクティブサービスに復元
                let fallback = ensure_safe_active_instance(shared)
                    .ok_or_else(|| "復元先のサービスがありません".to_string())?;
                create_subtab(app, shared, &fallback, Some(url))?;
                Ok(format!("「{title}」を復元しました"))
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

    let (bounds, profile_dir, chrome_ver, initial_visible) = {
        let guard = shared.inner.lock().unwrap();
        let is_active_tab = guard.active_instance_id.as_deref()
            == Some(instance.instance_id.as_str())
            && guard
                .services
                .get(&instance.instance_id)
                .map(|s| s.active_tab_id == tab_id)
                .unwrap_or(false);
        let visible = !guard.overlay_visible && is_active_tab;
        (
            guard.bounds,
            profile_dir_for(&guard.profiles_root, &instance.instance_id),
            guard.chrome_version.clone(),
            visible,
        )
    };

    let _ = fs::create_dir_all(&profile_dir);

    let Ok(parsed_url) = url::Url::parse(&target_url) else {
        return;
    };

    let gen = WEBVIEW_GEN.fetch_add(1, Ordering::Relaxed);
    let label = format!(
        "tab-{}-{}",
        sanitize_profile_segment(&instance.instance_id),
        gen
    );
    let ua = build_user_agent(&instance.ua_mode, &chrome_ver);

    let instance_id = instance.instance_id.clone();
    let instance_name = instance.name.clone();
    let instance_url = instance.url.clone();

    let app_for_title = app.clone();
    let shared_for_title = shared.clone();
    let id_for_title = instance_id.clone();
    let tid_for_title = tab_id.clone();
    let fallback_name = instance_name.clone();

    let app_for_popup = app.clone();
    let shared_for_popup = shared.clone();
    let id_for_popup = instance_id.clone();
    let tid_for_popup = tab_id.clone();
    let name_for_popup = instance_name.clone();
    let fallback_url_for_popup = instance_url.clone();

    let builder = WebviewBuilder::new(&label, WebviewUrl::External(parsed_url))
        .data_directory(profile_dir)
        .user_agent(&ua)
        .disable_drag_drop_handler()
        .enable_clipboard_access()
        .zoom_hotkeys_enabled(true)
        .focused(false)
        .on_permission_request(|_wv, kind| match kind {
            PermissionKind::Notifications
            | PermissionKind::Camera
            | PermissionKind::Microphone
            | PermissionKind::ClipboardRead
            | PermissionKind::Geolocation
            | PermissionKind::DisplayCapture
            | PermissionKind::WindowManagement
            | PermissionKind::PointerLock
            | PermissionKind::MediaKeySystemAccess => PermissionResponse::Allow,
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
                if let Some(tab) = guard
                    .services
                    .get_mut(&id_for_title)
                    .and_then(|s| s.tab_mut(&tid_for_title))
                {
                    tab.title = clean_title;
                    tab.unread_count = unread;
                    true
                } else {
                    false
                }
            };
            if changed {
                emit_runtime_updated(&app_for_title, &shared_for_title, &id_for_title);
            }
        })
        .on_new_window(move |target_url, features| {
            let (current_url, latest_ua) = {
                let guard = shared_for_popup.inner.lock().unwrap();
                let cur = guard
                    .services
                    .get(&id_for_popup)
                    .and_then(|s| s.tabs.iter().find(|t| t.tab_id == tid_for_popup))
                    .map(|t| t.current_url.clone())
                    .filter(|u| !u.is_empty())
                    .unwrap_or_else(|| fallback_url_for_popup.clone());
                let ua_mode = guard
                    .store
                    .get_instance(&id_for_popup)
                    .map(|i| i.ua_mode)
                    .unwrap_or_else(|| "desktop".to_string());
                (cur, build_user_agent(&ua_mode, &guard.chrome_version))
            };

            let target_str = target_url.as_str();
            if is_auth_popup_url(target_str) {
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
                            Err(_) => return NewWindowResponse::Allow,
                        }
                    } else {
                        popup_builder
                    };

                match popup_builder.build() {
                    Ok(window) => NewWindowResponse::Create { window },
                    Err(_) => NewWindowResponse::Allow,
                }
            } else if is_same_site_url(target_str, &current_url) {
                // 同一サービスの別ページリンクは同サービス内の新しいサブタブで開く！
                let app_bg = app_for_popup.clone();
                let shared_bg = shared_for_popup.clone();
                let inst_bg = id_for_popup.clone();
                let url_bg = target_str.to_string();
                tauri::async_runtime::spawn(async move {
                    let _ = create_subtab(&app_bg, &shared_bg, &inst_bg, Some(url_bg));
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

    let Ok(webview) = win.add_child(
        builder,
        LogicalPosition::new(bounds.x, bounds.y),
        LogicalSize::new(bounds.width, bounds.height),
    ) else {
        return;
    };

    if !initial_visible {
        let _ = webview.hide();
    }

    let updated = {
        let mut guard = shared.inner.lock().unwrap();
        if let Some(tab) = guard
            .services
            .get_mut(&instance_id)
            .and_then(|s| s.tab_mut(&tab_id))
        {
            tab.webview_label = Some(label.clone());
            tab.is_sleeping = false;
            tab.is_loading = true;
            tab.load_error = None;
            true
        } else {
            false
        }
    };
    if updated {
        emit_runtime_updated(app, shared, &instance_id);
    }

    #[cfg(windows)]
    {
        attach_windows_handlers(app, shared, &webview, &instance, &tab_id, &ua, initial_visible);
    }
}

#[cfg(windows)]
fn attach_windows_handlers(
    app: &AppHandle,
    shared: &SharedState,
    webview: &Webview,
    instance: &ServiceInstance,
    tab_id: &str,
    ua: &str,
    initial_visible: bool,
) {
    let instance_id = instance.instance_id.clone();
    let tid = tab_id.to_string();
    let fallback_url = instance.url.clone();
    let muted = instance.muted;
    let zoom = instance.zoom_factor;
    let ua_owned = ua.to_string();

    let app_start = app.clone();
    let shared_start = shared.clone();
    let id_start = instance_id.clone();
    let tid_start = tid.clone();

    let app_done = app.clone();
    let shared_done = shared.clone();
    let id_done = instance_id.clone();
    let tid_done = tid.clone();
    let fallback_done = fallback_url.clone();

    let app_nav = app.clone();
    let shared_nav = shared.clone();
    let id_nav = instance_id.clone();
    let tid_nav = tid.clone();
    let fallback_nav = fallback_url.clone();

    let app_fav = app.clone();
    let shared_fav = shared.clone();
    let id_fav = instance_id.clone();
    let tid_fav = tid.clone();

    let app_key = app.clone();
    let shared_key = shared.clone();

    let app_follow = app.clone();
    let shared_follow = shared.clone();
    let id_follow = instance_id.clone();

    let callbacks = crate::platform_win::TabWebviewCallbacks {
        on_navigation_starting: Arc::new(move || {
            let (changed, was_error) = {
                let mut guard = shared_start.inner.lock().unwrap();
                if let Some(tab) = guard
                    .services
                    .get_mut(&id_start)
                    .and_then(|s| s.tab_mut(&tid_start))
                {
                    let had_err = tab.load_error.is_some();
                    tab.is_loading = true;
                    tab.is_sleeping = false;
                    tab.load_error = None;
                    (true, had_err)
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
            let changed = {
                let mut guard = shared_done.inner.lock().unwrap();
                if let Some(tab) = guard
                    .services
                    .get_mut(&id_done)
                    .and_then(|s| s.tab_mut(&tid_done))
                {
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
                    true
                } else {
                    false
                }
            };
            if !ok {
                refresh_attached_view(&app_done, &shared_done);
            }
            if changed {
                emit_runtime_updated(&app_done, &shared_done, &id_done);
            }
        }),
        on_nav_flags_changed: Arc::new(move |url, can_back, can_fwd| {
            let changed = {
                let mut guard = shared_nav.inner.lock().unwrap();
                if let Some(tab) = guard
                    .services
                    .get_mut(&id_nav)
                    .and_then(|s| s.tab_mut(&tid_nav))
                {
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
                    tab.favicon_url = Some(favicon);
                    true
                } else {
                    false
                }
            };
            if changed {
                emit_runtime_updated(&app_fav, &shared_fav, &id_fav);
            }
        }),
        on_shortcut: Arc::new(move |action, payload| {
            handle_shortcut_from_child(&app_key, &shared_key, action, payload);
        }),
        on_follow_detected: Arc::new(move || {
            adjust_follow_count(&app_follow, &shared_follow, &id_follow, 1);
        }),
    };

    let _ = webview.with_webview(move |platform_wv| {
        let controller = platform_wv.controller();
        crate::platform_win::attach_tab_handlers(&controller, muted, zoom, &ua_owned, callbacks);
        if initial_visible {
            crate::platform_win::bring_controller_to_top(&controller);
        }
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
        | "previous-tab" | "next-tab" => {
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

    if let Some(shell) = app.get_webview("shell") {
        let _ = shell.emit(
            "app:shortcut",
            crate::models::ShortcutEventPayload {
                action: action.to_string(),
                payload,
            },
        );
        if action == "open-catalog" || action == "open-gesture-settings" {
            let _ = shell.set_focus();
        }
    }
}

pub fn set_overlay_visible(app: &AppHandle, shared: &SharedState, visible: bool) {
    {
        let mut guard = shared.inner.lock().unwrap();
        if guard.overlay_visible == visible {
            return;
        }
        guard.overlay_visible = visible;
    }
    refresh_attached_view(app, shared);
}

pub fn sleep_tab(app: &AppHandle, shared: &SharedState, instance_id: &str) {
    let labels: Vec<String> = {
        let mut guard = shared.inner.lock().unwrap();
        let mut out = Vec::new();
        if let Some(svc) = guard.services.get_mut(instance_id) {
            for tab in &mut svc.tabs {
                if let Some(l) = tab.webview_label.take() {
                    out.push(l);
                }
                tab.is_sleeping = true;
                tab.is_loading = false;
                tab.unread_count = 0;
                tab.load_error = None;
            }
        }
        out
    };

    for label in labels {
        if let Some(wv) = app.get_webview(&label) {
            let _ = wv.close();
        }
    }
    refresh_attached_view(app, shared);
    emit_runtime_updated(app, shared, instance_id);
}

pub fn destroy_all_views(app: &AppHandle, shared: &SharedState) {
    let labels: Vec<String> = {
        let mut guard = shared.inner.lock().unwrap();
        guard.active_instance_id = None;
        let mut out = Vec::new();
        for svc in guard.services.values_mut() {
            for tab in &mut svc.tabs {
                if let Some(l) = tab.webview_label.take() {
                    out.push(l);
                }
            }
        }
        out
    };
    for label in labels {
        if let Some(wv) = app.get_webview(&label) {
            let _ = wv.close();
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
        guard
            .active_instance_id
            .as_deref()
            .and_then(|id| guard.services.get(id))
            .and_then(|s| s.active_tab())
            .and_then(|t| t.webview_label.clone())
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
            .clamp(0.5, 2.0);

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
            if let Some(wv) = get_active_webview_for_service(app, shared, instance_id) {
                let home = instance.url.clone();
                #[cfg(windows)]
                let _ = wv.with_webview(move |pwv| {
                    crate::platform_win::clear_browsing_data_and_navigate(&pwv.controller(), home)
                });
            } else {
                let profile_dir = {
                    let guard = shared.inner.lock().unwrap();
                    profile_dir_for(&guard.profiles_root, instance_id)
                };
                let _ = fs::remove_dir_all(profile_dir);
            }
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

/// ジェスチャーまたはショートカットから渡された操作を実行する。
pub fn execute_gesture_action(app: &AppHandle, shared: &SharedState, action: &str) {
    let active_pair: Option<(String, String, bool, bool)> = {
        let guard = shared.inner.lock().unwrap();
        guard.active_instance_id.as_ref().and_then(|inst_id| {
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
        })
    };

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
    }
    updated
}
