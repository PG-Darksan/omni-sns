use serde::{Deserialize, Serialize};
use crate::gesture::GestureSettings;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogService {
    pub id: String,
    pub name: String,
    pub aliases: Vec<String>,
    pub category: String,
    pub url: String,
    pub home_url: String,
    pub color: String,
    pub badge: String,
    pub default_ua: String,
    pub description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub requires_custom_url: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_pinned: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CategoryMeta {
    pub id: String,
    pub label: String,
    pub description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceInstance {
    pub instance_id: String,
    pub service_id: String,
    pub name: String,
    pub category: String,
    pub url: String,
    pub color: String,
    pub badge: String,
    pub ua_mode: String,
    pub muted: bool,
    pub zoom_factor: f64,
    pub notifications_enabled: bool,
    pub order: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserTabInfo {
    pub tab_id: String,
    pub instance_id: String,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TabRuntimeState {
    pub instance_id: String,
    pub current_url: String,
    pub title: String,
    pub favicon_url: Option<String>,
    pub unread_count: u32,
    pub is_loading: bool,
    pub is_sleeping: bool,
    pub can_go_back: bool,
    pub can_go_forward: bool,
    pub muted: bool,
    pub zoom_factor: f64,
    pub ua_mode: String,
    pub load_error: Option<String>,
    pub active_tab_id: String,
    pub tabs: Vec<BrowserTabInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    pub theme: String,
    pub minimize_to_tray: bool,
    pub lock_pin: String,
    pub sidebar_width: u32,
    pub active_instance_id: Option<String>,
    #[serde(default)]
    pub gesture: GestureSettings,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowBounds {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub y: Option<i32>,
    pub width: u32,
    pub height: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_maximized: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppConfig {
    pub version: u32,
    pub settings: AppSettings,
    pub instances: Vec<ServiceInstance>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_bounds: Option<WindowBounds>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddInstancePayload {
    pub service_id: String,
    pub name: String,
    pub category: String,
    pub url: String,
    pub color: String,
    pub badge: String,
    pub ua_mode: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInstancePatch {
    pub name: Option<String>,
    pub url: Option<String>,
    pub ua_mode: Option<String>,
    pub muted: Option<bool>,
    pub zoom_factor: Option<f64>,
    pub notifications_enabled: Option<bool>,
    pub color: Option<String>,
    pub badge: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateSettingsPatch {
    pub theme: Option<String>,
    pub minimize_to_tray: Option<bool>,
    pub lock_pin: Option<String>,
    pub sidebar_width: Option<u32>,
    #[serde(default, deserialize_with = "deserialize_double_option")]
    pub active_instance_id: Option<Option<String>>,
    pub gesture: Option<GestureSettings>,
}

fn deserialize_double_option<'de, T, D>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    T: Deserialize<'de>,
    D: serde::Deserializer<'de>,
{
    Deserialize::deserialize(deserializer).map(Some)
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BootstrapPayload {
    pub config: AppConfig,
    pub catalog: Vec<CatalogService>,
    pub categories: Vec<CategoryMeta>,
    pub runtime_states: Vec<TabRuntimeState>,
    pub app_version: String,
    pub is_locked: bool,
    pub closed_tabs_count: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StateUpdatedPayload {
    pub config: AppConfig,
    pub runtime_states: Vec<TabRuntimeState>,
    pub is_locked: bool,
    pub closed_tabs_count: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AddTabResponse {
    pub created: ServiceInstance,
    pub config: AppConfig,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LockResult {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShortcutEventPayload {
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payload: Option<usize>,
}
