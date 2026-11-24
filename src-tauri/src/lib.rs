mod catalog;
mod follow_sync;
mod gesture;
#[cfg(windows)]
mod gesture_win;
mod models;
#[cfg(windows)]
mod platform_win;
mod store;
mod url_utils;
mod view_manager;

use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::webview::WebviewBuilder;
use tauri::window::{Color, WindowBuilder};
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, State, Theme, WebviewUrl, WindowEvent};

use follow_sync::{FollowSyncSettings, UpdateFollowSyncPatch};
use gesture::GestureSettings;
use models::{
    AddInstancePayload, AddTabResponse, AppConfig, AppSettings, BootstrapPayload, ServiceInstance,
    UpdateInstancePatch, UpdateSettingsPatch, WindowBounds,
};
use store::ConfigStore;
use url_utils::is_http_url;
use view_manager::SharedState;

#[tauri::command]
async fn app_get_bootstrap(
    app: AppHandle,
    shared: State<'_, SharedState>,
) -> Result<BootstrapPayload, String> {
    {
        let mut guard = shared.inner.lock().unwrap();
        guard.bootstrapped = true;
    }
    view_manager::update_bounds_from_window(&app, &shared);
    let active_id = view_manager::ensure_safe_active_instance(&shared);
    let should_activate = {
        let guard = shared.inner.lock().unwrap();
        !guard.overlay_visible
    };
    if should_activate {
        view_manager::activate_tab(&app, &shared, active_id);
    }

    let (config, runtime_states, closed_tabs_count, gmail_open, gmail_runtime) = {
        let guard = shared.inner.lock().unwrap();
        (
            guard.store.get_config(),
            SharedState::build_all_runtime_states(&guard),
            guard.closed_tabs.len(),
            guard.gmail_open,
            guard.gmail_tab.as_ref().map(|t| t.to_info()),
        )
    };

    view_manager::update_window_title(&app, &shared);
    view_manager::sync_gesture_host_state(&app, &shared);

    Ok(BootstrapPayload {
        config,
        catalog: catalog::services().to_vec(),
        categories: catalog::categories().to_vec(),
        runtime_states,
        app_version: app.package_info().version.to_string(),
        closed_tabs_count,
        gmail_open,
        gmail_runtime,
    })
}

#[tauri::command]
async fn tab_activate(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: Option<String>,
) -> Result<AppConfig, String> {
    let next_id = {
        let mut guard = shared.inner.lock().unwrap();
        if let Some(ref id) = instance_id {
            if let Some(target) = guard.store.get_instance(id) {
                guard.store.update_settings(UpdateSettingsPatch {
                    active_instance_id: Some(Some(target.instance_id.clone())),
                    ..Default::default()
                });
                Some(target.instance_id)
            } else {
                guard.store.update_settings(UpdateSettingsPatch {
                    active_instance_id: Some(None),
                    ..Default::default()
                });
                None
            }
        } else {
            guard.store.update_settings(UpdateSettingsPatch {
                active_instance_id: Some(None),
                ..Default::default()
            });
            None
        }
    };

    view_manager::activate_tab(&app, &shared, next_id);
    view_manager::emit_state_updated(&app, &shared);

    let guard = shared.inner.lock().unwrap();
    Ok(guard.store.get_config())
}

#[tauri::command]
async fn tab_add(
    app: AppHandle,
    shared: State<'_, SharedState>,
    payload: AddInstancePayload,
) -> Result<AddTabResponse, String> {
    let (created, config) = {
        let mut guard = shared.inner.lock().unwrap();
        let created = guard.store.add_instance(payload)?;
        (created, guard.store.get_config())
    };

    view_manager::sync_instances(&app, &shared);
    view_manager::activate_tab(&app, &shared, Some(created.instance_id.clone()));
    view_manager::emit_state_updated(&app, &shared);

    Ok(AddTabResponse { created, config })
}

#[tauri::command]
async fn tab_remove(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
) -> Result<AppConfig, String> {
    let prev_active = {
        let mut guard = shared.inner.lock().unwrap();
        let prev = guard.active_instance_id.clone();
        guard.store.remove_instance(&instance_id);
        prev
    };

    view_manager::sync_instances(&app, &shared);
    let next_active = view_manager::ensure_safe_active_instance(&shared);
    if prev_active != next_active {
        view_manager::activate_tab(&app, &shared, next_active);
    } else {
        view_manager::update_bounds_from_window(&app, &shared);
    }
    view_manager::emit_state_updated(&app, &shared);

    let guard = shared.inner.lock().unwrap();
    Ok(guard.store.get_config())
}

#[tauri::command]
async fn tab_remove_many(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_ids: Vec<String>,
) -> Result<AppConfig, String> {
    let prev_active = {
        let mut guard = shared.inner.lock().unwrap();
        let prev = guard.active_instance_id.clone();
        guard.store.remove_instances(&instance_ids);
        prev
    };

    view_manager::sync_instances(&app, &shared);
    let next_active = view_manager::ensure_safe_active_instance(&shared);
    if prev_active != next_active {
        view_manager::activate_tab(&app, &shared, next_active);
    } else {
        view_manager::update_bounds_from_window(&app, &shared);
    }
    view_manager::emit_state_updated(&app, &shared);

    let guard = shared.inner.lock().unwrap();
    Ok(guard.store.get_config())
}

#[tauri::command]
async fn archived_restore(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
) -> Result<ServiceInstance, String> {
    view_manager::restore_archived_instance(&app, &shared, &instance_id)
}

#[tauri::command]
async fn archived_purge(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
) -> Result<bool, String> {
    view_manager::purge_archived_instance(&app, &shared, &instance_id)
}

#[tauri::command]
async fn archived_purge_all(
    app: AppHandle,
    shared: State<'_, SharedState>,
) -> Result<usize, String> {
    view_manager::purge_all_archived_instances(&app, &shared)
}

#[tauri::command]
async fn tab_update(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
    patch: UpdateInstancePatch,
) -> Result<Option<ServiceInstance>, String> {
    let updated = {
        let mut guard = shared.inner.lock().unwrap();
        guard.store.update_instance(&instance_id, patch)
    };
    if let Some(ref inst) = updated {
        view_manager::sync_sleeping_instance_metadata(&shared, inst);
    }
    view_manager::sync_instances(&app, &shared);
    view_manager::emit_state_updated(&app, &shared);
    Ok(updated)
}

#[tauri::command]
async fn tab_reorder(
    app: AppHandle,
    shared: State<'_, SharedState>,
    ordered_ids: Vec<String>,
) -> Result<AppConfig, String> {
    {
        let mut guard = shared.inner.lock().unwrap();
        guard.store.reorder_instances(&ordered_ids);
    }
    view_manager::sync_instances(&app, &shared);
    view_manager::emit_state_updated(&app, &shared);

    let guard = shared.inner.lock().unwrap();
    Ok(guard.store.get_config())
}

#[tauri::command]
async fn tab_action(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
    action: String,
) -> Result<(), String> {
    view_manager::perform_tab_action(&app, &shared, &instance_id, &action);
    Ok(())
}

#[tauri::command]
async fn subtab_create(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
    url: Option<String>,
) -> Result<String, String> {
    view_manager::create_subtab(&app, &shared, &instance_id, url)
}

#[tauri::command]
async fn subtab_activate(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
    tab_id: String,
) -> Result<(), String> {
    view_manager::activate_subtab(&app, &shared, &instance_id, &tab_id);
    Ok(())
}

#[tauri::command]
async fn subtab_close(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
    tab_id: String,
) -> Result<Option<String>, String> {
    Ok(view_manager::close_subtab(&app, &shared, &instance_id, &tab_id))
}

#[tauri::command]
async fn subtab_close_others(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
    tab_id: String,
) -> Result<usize, String> {
    Ok(view_manager::close_other_subtabs(&app, &shared, &instance_id, &tab_id))
}

#[tauri::command]
async fn subtab_duplicate(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
    tab_id: String,
) -> Result<String, String> {
    view_manager::duplicate_subtab(&app, &shared, &instance_id, &tab_id)
}

#[tauri::command]
async fn subtab_restore_closed(
    app: AppHandle,
    shared: State<'_, SharedState>,
) -> Result<String, String> {
    view_manager::restore_closed_tab(&app, &shared)
}

#[tauri::command]
async fn subtab_navigate(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
    url: String,
) -> Result<String, String> {
    view_manager::navigate_subtab(&app, &shared, &instance_id, &url)
}

#[tauri::command]
async fn gesture_update_settings(
    app: AppHandle,
    shared: State<'_, SharedState>,
    gesture: GestureSettings,
) -> Result<GestureSettings, String> {
    Ok(view_manager::update_gesture_settings(&app, &shared, gesture))
}

#[tauri::command]
async fn follow_adjust(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
    delta: i32,
) -> Result<Option<ServiceInstance>, String> {
    Ok(view_manager::adjust_follow_count(&app, &shared, &instance_id, delta))
}

#[tauri::command]
async fn follow_reset(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
    reset_total: bool,
) -> Result<Option<ServiceInstance>, String> {
    Ok(view_manager::reset_follow_count(&app, &shared, &instance_id, reset_total))
}

#[tauri::command]
async fn unfollow_adjust(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
    delta: i32,
) -> Result<Option<ServiceInstance>, String> {
    Ok(view_manager::adjust_unfollow_count(&app, &shared, &instance_id, delta))
}

#[tauri::command]
async fn unfollow_reset(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
    reset_total: bool,
) -> Result<Option<ServiceInstance>, String> {
    Ok(view_manager::reset_unfollow_count(&app, &shared, &instance_id, reset_total))
}

#[tauri::command]
async fn follow_set_handle(
    app: AppHandle,
    shared: State<'_, SharedState>,
    instance_id: String,
    handle: String,
) -> Result<ServiceInstance, String> {
    view_manager::set_instance_handle(&app, &shared, &instance_id, &handle)
}

#[tauri::command]
async fn follow_sync_update_settings(
    app: AppHandle,
    shared: State<'_, SharedState>,
    patch: UpdateFollowSyncPatch,
) -> Result<FollowSyncSettings, String> {
    Ok(view_manager::update_follow_sync_settings(&app, &shared, patch))
}

#[tauri::command]
async fn follow_sync_now(
    app: AppHandle,
    shared: State<'_, SharedState>,
) -> Result<FollowSyncSettings, String> {
    view_manager::trigger_follow_sync_now(&app, &shared).await
}

#[tauri::command]
async fn settings_update(
    app: AppHandle,
    shared: State<'_, SharedState>,
    patch: UpdateSettingsPatch,
) -> Result<AppSettings, String> {
    let explicit_active_change = patch.active_instance_id.is_some();
    let (prev_active, updated) = {
        let mut guard = shared.inner.lock().unwrap();
        let prev = guard.active_instance_id.clone();
        let updated = guard.store.update_settings(patch);
        (prev, updated)
    };

    if let Some(win) = app.get_window("main") {
        let theme = if updated.theme == "light" {
            Theme::Light
        } else {
            Theme::Dark
        };
        let _ = win.set_theme(Some(theme));
    }

    let safe_active = view_manager::ensure_safe_active_instance(&shared);
    if explicit_active_change || prev_active != safe_active {
        view_manager::activate_tab(&app, &shared, safe_active);
    } else {
        view_manager::update_bounds_from_window(&app, &shared);
    }
    view_manager::emit_state_updated(&app, &shared);
    Ok(updated)
}

#[tauri::command]
async fn ui_set_overlay(
    app: AppHandle,
    shared: State<'_, SharedState>,
    visible: bool,
) -> Result<(), String> {
    view_manager::set_overlay_visible(&app, &shared, visible);
    Ok(())
}

#[tauri::command]
fn ui_copy_text(text: String) {
    #[cfg(windows)]
    platform_win::copy_text_to_clipboard(&text);
}

#[tauri::command]
fn app_open_external_url(url: String) {
    if is_http_url(&url) {
        #[cfg(windows)]
        platform_win::open_external_url(&url);
    }
}

#[tauri::command]
async fn gmail_toggle(
    app: AppHandle,
    shared: State<'_, SharedState>,
    open: Option<bool>,
) -> Result<bool, String> {
    Ok(view_manager::set_gmail_open(&app, &shared, open))
}

#[tauri::command]
async fn gmail_action(
    app: AppHandle,
    shared: State<'_, SharedState>,
    action: String,
) -> Result<(), String> {
    view_manager::perform_gmail_action(&app, &shared, &action);
    Ok(())
}

#[tauri::command]
async fn gmail_navigate(
    app: AppHandle,
    shared: State<'_, SharedState>,
    url: String,
) -> Result<String, String> {
    view_manager::navigate_gmail(&app, &shared, &url)
}

fn shutdown_gesture_host(shared: &SharedState) {
    #[cfg(windows)]
    {
        let host = {
            let mut guard = shared.inner.lock().unwrap();
            guard.gesture_host.take()
        };
        if let Some(h) = host {
            h.shutdown();
        }
    }
    #[cfg(not(windows))]
    {
        let _ = shared;
    }
}

fn save_window_bounds(win: &tauri::Window, shared: &SharedState) {
    let is_minimized = win.is_minimized().unwrap_or(false);
    if is_minimized {
        return;
    }
    let is_maximized = win.is_maximized().unwrap_or(false);
    let scale = win.scale_factor().unwrap_or(1.0);

    let mut guard = shared.inner.lock().unwrap();
    let prev = guard
        .store
        .get_config()
        .window_bounds
        .unwrap_or(WindowBounds {
            x: None,
            y: None,
            width: 1380,
            height: 880,
            is_maximized: Some(false),
        });

    if is_maximized {
        guard.store.update_window_bounds(WindowBounds {
            x: prev.x,
            y: prev.y,
            width: prev.width,
            height: prev.height,
            is_maximized: Some(true),
        });
        return;
    }

    let size = win
        .inner_size()
        .map(|s| s.to_logical::<f64>(scale))
        .ok();
    let pos = win
        .outer_position()
        .map(|p| p.to_logical::<f64>(scale))
        .ok();

    let width = size
        .map(|s| (s.width.round() as u32).max(960))
        .unwrap_or(prev.width);
    let height = size
        .map(|s| (s.height.round() as u32).max(620))
        .unwrap_or(prev.height);

    guard.store.update_window_bounds(WindowBounds {
        x: pos.map(|p| p.x.round() as i32).or(prev.x),
        y: pos.map(|p| p.y.round() as i32).or(prev.y),
        width,
        height,
        is_maximized: Some(false),
    });
}

fn resolve_config_path(app: &AppHandle) -> PathBuf {
    let config_dir = app
        .path()
        .app_config_dir()
        .unwrap_or_else(|_| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let target = config_dir.join("omni-sns-config.json");

    if !target.exists() {
        if let Some(roaming) = config_dir.parent() {
            let legacy = roaming.join("omni-sns").join("omni-sns-config.json");
            if legacy.exists() {
                let _ = fs::create_dir_all(&config_dir);
                let _ = fs::copy(&legacy, &target);
            }
        }
    }

    target
}

fn setup_tray(app: &AppHandle, shared: SharedState) -> tauri::Result<()> {
    let show_item = MenuItem::with_id(app, "show", "OmniSNS を表示", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let quit_item = MenuItem::with_id(app, "quit", "終了", true, None::<&str>)?;

    let menu = Menu::with_items(app, &[&show_item, &sep, &quit_item])?;

    let mut tray_builder = TrayIconBuilder::with_id("main-tray")
        .tooltip("OmniSNS - All-in-One SNS Desk")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(move |app, event| match event.id().as_ref() {
            "show" => {
                if let Some(win) = app.get_window("main") {
                    let _ = win.unminimize();
                    let _ = win.show();
                    let _ = win.set_focus();
                }
            }
            "quit" => {
                {
                    let mut guard = shared.inner.lock().unwrap();
                    guard.is_quitting = true;
                }
                shutdown_gesture_host(&shared);
                view_manager::destroy_all_views(app, &shared);
                let _ = app.remove_tray_by_id("main-tray");
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Some(win) = app.get_window("main") {
                    let _ = win.unminimize();
                    let _ = win.show();
                    let _ = win.set_focus();
                }
            }
        });

    if let Some(icon) = app.default_window_icon().cloned() {
        tray_builder = tray_builder.icon(icon);
    }

    let _ = tray_builder.build(app)?;
    Ok(())
}

pub fn run() {
    let smoke_test = std::env::args().any(|a| a == "--smoke-test");

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(win) = app.get_window("main") {
                let _ = win.unminimize();
                let _ = win.show();
                let _ = win.set_focus();
            }
        }))
        .setup(move |app| {
            let app_handle = app.handle().clone();
            let config_path = resolve_config_path(&app_handle);
            let profiles_root = app
                .path()
                .app_local_data_dir()
                .unwrap_or_else(|_| config_path.parent().unwrap().to_path_buf())
                .join("profiles");
            let _ = fs::create_dir_all(&profiles_root);

            #[cfg(windows)]
            let chrome_version = platform_win::get_webview2_version();
            #[cfg(not(windows))]
            let chrome_version = "136.0.0.0".to_string();

            let store = ConfigStore::new(config_path);
            let initial_config = store.get_config();
            let shared = SharedState::new(store, profiles_root.clone(), chrome_version);
            app.manage(shared.clone());

            let bounds = initial_config.window_bounds.unwrap_or(WindowBounds {
                x: None,
                y: None,
                width: 1380,
                height: 880,
                is_maximized: Some(false),
            });
            let init_w = (bounds.width.max(960)) as f64;
            let init_h = (bounds.height.max(640)) as f64;
            let is_light = initial_config.settings.theme == "light";
            let bg_color = if is_light {
                Color(243, 245, 248, 255)
            } else {
                Color(15, 18, 25, 255)
            };

            let mut win_builder = WindowBuilder::new(app, "main")
                .title("OmniSNS")
                .inner_size(init_w, init_h)
                .min_inner_size(960.0, 620.0)
                .background_color(bg_color)
                .theme(Some(if is_light { Theme::Light } else { Theme::Dark }));

            if let (Some(x), Some(y)) = (bounds.x, bounds.y) {
                if x > -10000 && y > -10000 {
                    win_builder = win_builder.position(x as f64, y as f64);
                }
            }
            if let Some(icon) = app.default_window_icon().cloned() {
                win_builder = win_builder.icon(icon)?;
            }

            let window = win_builder.build()?;

            // Windows ネイティブマウスジェスチャー & 透明軌跡オーバーレイを起動
            #[cfg(windows)]
            if let Ok(hwnd) = window.hwnd() {
                let raw_hwnd = hwnd.0 as isize;
                let app_act = app_handle.clone();
                let shared_act = shared.clone();
                let app_scroll = app_handle.clone();
                let shared_scroll = shared.clone();
                let host = gesture_win::GestureWinHost::start(
                    raw_hwnd,
                    initial_config.settings.gesture.clone(),
                    gesture_win::GestureHostCallbacks {
                        on_action: Arc::new(move |action, _shape, ctx| {
                            let app_bg = app_act.clone();
                            let shared_bg = shared_act.clone();
                            tauri::async_runtime::spawn(async move {
                                view_manager::execute_gesture_action_with_origin(
                                    &app_bg,
                                    &shared_bg,
                                    &action,
                                    Some(ctx.origin_lx),
                                    Some(ctx.origin_ly),
                                );
                            });
                        }),
                        on_live_scroll: Arc::new(move |ox, oy, dx, dy| {
                            view_manager::dispatch_live_scroll(
                                &app_scroll,
                                &shared_scroll,
                                ox,
                                oy,
                                dx,
                                dy,
                            );
                        }),
                    },
                );
                {
                    let mut guard = shared.inner.lock().unwrap();
                    guard.main_hwnd = raw_hwnd;
                    guard.gesture_host = Some(host);
                }
            }

            // シェルUI用子WebView
            let shell_profile = profiles_root.join("shell");
            let _ = fs::create_dir_all(&shell_profile);

            let shell_builder = WebviewBuilder::new("shell", WebviewUrl::App("index.html".into()))
                .data_directory(shell_profile)
                .background_color(bg_color)
                .disable_drag_drop_handler()
                .on_navigation(|url| {
                    let scheme = url.scheme();
                    if scheme == "tauri" || url.host_str() == Some("tauri.localhost") {
                        return true;
                    }
                    if is_http_url(url.as_str()) {
                        #[cfg(windows)]
                        platform_win::open_external_url(url.as_str());
                    }
                    false
                });

            let _shell = window.add_child(
                shell_builder,
                LogicalPosition::new(0.0, 0.0),
                LogicalSize::new(init_w, init_h),
            )?;

            if bounds.is_maximized.unwrap_or(false) {
                let _ = window.maximize();
            }

            // ウィンドウイベント（リサイズ・移動・DPI変更・トレイ格納・終了）
            let app_for_win = app_handle.clone();
            let shared_for_win = shared.clone();
            let win_for_events = window.clone();
            window.on_window_event(move |event| match event {
                WindowEvent::Resized(size) => {
                    if size.width > 0 && size.height > 0 {
                        view_manager::update_bounds_from_window(&app_for_win, &shared_for_win);
                        save_window_bounds(&win_for_events, &shared_for_win);
                    }
                }
                WindowEvent::ScaleFactorChanged { .. } => {
                    view_manager::update_bounds_from_window(&app_for_win, &shared_for_win);
                }
                WindowEvent::Moved(_) => {
                    save_window_bounds(&win_for_events, &shared_for_win);
                    view_manager::sync_gesture_host_state(&app_for_win, &shared_for_win);
                }
                WindowEvent::CloseRequested { api, .. } => {
                    save_window_bounds(&win_for_events, &shared_for_win);
                    let (quitting, minimize_to_tray) = {
                        let guard = shared_for_win.inner.lock().unwrap();
                        (guard.is_quitting, guard.store.get_settings().minimize_to_tray)
                    };
                    if !quitting && minimize_to_tray {
                        api.prevent_close();
                        let _ = win_for_events.hide();
                    } else {
                        shutdown_gesture_host(&shared_for_win);
                        view_manager::destroy_all_views(&app_for_win, &shared_for_win);
                    }
                }
                WindowEvent::Destroyed => {
                    shutdown_gesture_host(&shared_for_win);
                    view_manager::destroy_all_views(&app_for_win, &shared_for_win);
                }
                _ => {}
            });

            let _ = setup_tray(&app_handle, shared.clone());

            // フォロー数クロスデバイス同期（GitHub非公開Gist定期同期）
            if !smoke_test {
                let app_cloud = app_handle.clone();
                let shared_cloud = shared.clone();
                std::thread::Builder::new()
                    .name("omnisns-cloud-sync".to_string())
                    .spawn(move || {
                        std::thread::sleep(Duration::from_secs(3));
                        loop {
                            let (quitting, has_token) = {
                                let g = shared_cloud.inner.lock().unwrap();
                                (
                                    g.is_quitting,
                                    !g.store
                                        .get_follow_sync_settings()
                                        .github_token
                                        .trim()
                                        .is_empty(),
                                )
                            };
                            if quitting {
                                break;
                            }
                            if has_token {
                                let _ = view_manager::sync_cloud_gist_once_blocking(
                                    &app_cloud,
                                    &shared_cloud,
                                );
                            }
                            for _ in 0..60 {
                                std::thread::sleep(Duration::from_secs(1));
                                if shared_cloud.inner.lock().unwrap().is_quitting {
                                    return;
                                }
                            }
                        }
                    })
                    .ok();
            }

            if smoke_test {
                let app_smoke = app_handle.clone();
                let shared_smoke = shared.clone();
                std::thread::spawn(move || {
                    for _ in 0..40 {
                        std::thread::sleep(std::time::Duration::from_millis(200));
                        let (bootstrapped, open_tabs, instance_count) = {
                            let g = shared_smoke.inner.lock().unwrap();
                            (
                                g.bootstrapped,
                                SharedState::open_webview_count(&g),
                                g.store.get_instances().len(),
                            )
                        };
                        if bootstrapped && (open_tabs >= 1 || instance_count == 0) {
                            println!(
                                "[smoke-test] OK: bootstrapped=true, open_tabs={open_tabs}, instances={instance_count}, shell_ready=true"
                            );
                            shutdown_gesture_host(&shared_smoke);
                            view_manager::destroy_all_views(&app_smoke, &shared_smoke);
                            let _ = app_smoke.remove_tray_by_id("main-tray");
                            app_smoke.exit(0);
                            return;
                        }
                    }
                    let (bootstrapped, open_tabs) = {
                        let g = shared_smoke.inner.lock().unwrap();
                        (g.bootstrapped, SharedState::open_webview_count(&g))
                    };
                    eprintln!(
                        "[smoke-test] TIMEOUT: bootstrapped={bootstrapped}, open_tabs={open_tabs}"
                    );
                    shutdown_gesture_host(&shared_smoke);
                    view_manager::destroy_all_views(&app_smoke, &shared_smoke);
                    app_smoke.exit(1);
                });
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            app_get_bootstrap,
            tab_activate,
            tab_add,
            tab_remove,
            tab_remove_many,
            archived_restore,
            archived_purge,
            archived_purge_all,
            tab_update,
            tab_reorder,
            tab_action,
            subtab_create,
            subtab_activate,
            subtab_close,
            subtab_close_others,
            subtab_duplicate,
            subtab_restore_closed,
            subtab_navigate,
            gesture_update_settings,
            follow_adjust,
            follow_reset,
            unfollow_adjust,
            unfollow_reset,
            follow_set_handle,
            follow_sync_update_settings,
            follow_sync_now,
            settings_update,
            ui_set_overlay,
            ui_copy_text,
            app_open_external_url,
            gmail_toggle,
            gmail_action,
            gmail_navigate
        ])
        .run(tauri::generate_context!())
        .expect("error while running OmniSNS");
}
