use serde::{Deserialize, Serialize};
use crate::follow_sync::{FollowSyncLedger, FollowSyncSettings};
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

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default)]
pub struct SavedSubTab {
    pub url: String,
    pub title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceInstance {
    pub instance_id: String,
    pub service_id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_label: Option<String>,
    pub category: String,
    pub url: String,
    pub color: String,
    pub badge: String,
    pub ua_mode: String,
    pub muted: bool,
    pub zoom_factor: f64,
    pub notifications_enabled: bool,
    pub order: usize,
    #[serde(default)]
    pub follow_count_today: u32,
    #[serde(default)]
    pub follow_count_total: u32,
    #[serde(default)]
    pub unfollow_count_today: u32,
    #[serde(default)]
    pub unfollow_count_total: u32,
    #[serde(default)]
    pub follow_count_date: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub follow_events: Vec<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unfollow_events: Vec<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub follow_next_reset_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub follow_full_reset_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unfollow_next_reset_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unfollow_full_reset_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detected_handle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sns_following_count: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sns_followers_count: Option<u32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub saved_tabs: Vec<SavedSubTab>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub saved_active_tab_index: Option<usize>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cross_site_service: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cross_site_handle: Option<String>,
}

pub const DEFAULT_VIEWPORT_BOTTOM_INSET: u32 = 44;
pub const MAX_VIEWPORT_BOTTOM_INSET: u32 = 160;
pub const DEFAULT_FOLLOW_WINDOW_HOURS: u32 = 24;
pub const MIN_FOLLOW_WINDOW_HOURS: u32 = 1;
pub const MAX_FOLLOW_WINDOW_HOURS: u32 = 168;

fn default_viewport_bottom_inset() -> u32 {
    DEFAULT_VIEWPORT_BOTTOM_INSET
}

fn default_follow_window_hours() -> u32 {
    DEFAULT_FOLLOW_WINDOW_HOURS
}

pub fn default_header_account_scope() -> String {
    "all".to_string()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default)]
pub struct AccountFilterSettings {
    pub enabled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_following: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_following: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_followers: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_followers: Option<u32>,
    pub following_greater_than_followers: bool,
}

impl AccountFilterSettings {
    pub fn has_any_condition(&self) -> bool {
        self.min_following.is_some()
            || self.max_following.is_some()
            || self.min_followers.is_some()
            || self.max_followers.is_some()
            || self.following_greater_than_followers
    }

    pub fn is_active(&self) -> bool {
        self.enabled && self.has_any_condition()
    }

    pub fn sanitized(mut self) -> Self {
        const MAX_COUNT: u32 = 1_000_000_000;
        self.min_following = self.min_following.map(|v| v.min(MAX_COUNT));
        self.max_following = self.max_following.map(|v| v.min(MAX_COUNT));
        self.min_followers = self.min_followers.map(|v| v.min(MAX_COUNT));
        self.max_followers = self.max_followers.map(|v| v.min(MAX_COUNT));
        if let (Some(lo), Some(hi)) = (self.min_following, self.max_following) {
            if lo > hi {
                self.min_following = Some(hi);
                self.max_following = Some(lo);
            }
        }
        if let (Some(lo), Some(hi)) = (self.min_followers, self.max_followers) {
            if lo > hi {
                self.min_followers = Some(hi);
                self.max_followers = Some(lo);
            }
        }
        self
    }

    pub fn to_js_payload(&self) -> serde_json::Value {
        serde_json::json!({
            "enabled": self.is_active(),
            "minFollowing": self.min_following,
            "maxFollowing": self.max_following,
            "minFollowers": self.min_followers,
            "maxFollowers": self.max_followers,
            "followingGreaterThanFollowers": self.following_greater_than_followers,
        })
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default)]
pub struct AccountFilterLiveState {
    pub active: bool,
    pub matched: u32,
    pub hidden: u32,
    pub pending: u32,
    pub auto_fetching: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    pub theme: String,
    pub minimize_to_tray: bool,
    pub sidebar_width: u32,
    pub active_instance_id: Option<String>,
    #[serde(default)]
    pub header_collapsed: bool,
    #[serde(default = "default_header_account_scope")]
    pub header_account_scope: String,
    #[serde(default = "default_viewport_bottom_inset")]
    pub viewport_bottom_inset: u32,
    #[serde(default = "default_follow_window_hours")]
    pub follow_window_hours: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub catalog_order: Vec<String>,
    #[serde(default)]
    pub gesture: GestureSettings,
    #[serde(default)]
    pub follow_sync: FollowSyncSettings,
    #[serde(default)]
    pub account_filter: AccountFilterSettings,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
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

impl Default for WindowBounds {
    fn default() -> Self {
        Self {
            x: None,
            y: None,
            width: 1380,
            height: 880,
            is_maximized: Some(false),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArchivedInstance {
    pub instance: ServiceInstance,
    pub archived_at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppConfig {
    pub version: u32,
    pub settings: AppSettings,
    pub instances: Vec<ServiceInstance>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub archived_instances: Vec<ArchivedInstance>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_bounds: Option<WindowBounds>,
    #[serde(default)]
    pub follow_ledger: FollowSyncLedger,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddInstancePayload {
    pub service_id: String,
    pub name: String,
    #[serde(default)]
    pub account_label: Option<String>,
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
    pub account_label: Option<String>,
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
    pub sidebar_width: Option<u32>,
    #[serde(default, deserialize_with = "deserialize_double_option")]
    pub active_instance_id: Option<Option<String>>,
    pub header_collapsed: Option<bool>,
    pub header_account_scope: Option<String>,
    pub viewport_bottom_inset: Option<u32>,
    pub follow_window_hours: Option<u32>,
    pub catalog_order: Option<Vec<String>>,
    pub gesture: Option<GestureSettings>,
    pub account_filter: Option<AccountFilterSettings>,
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
    pub closed_tabs_count: usize,
    pub gmail_open: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gmail_runtime: Option<BrowserTabInfo>,
    pub account_filter_live: AccountFilterLiveState,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StateUpdatedPayload {
    pub config: AppConfig,
    pub runtime_states: Vec<TabRuntimeState>,
    pub closed_tabs_count: usize,
    pub gmail_open: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gmail_runtime: Option<BrowserTabInfo>,
    pub account_filter_live: AccountFilterLiveState,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AddTabResponse {
    pub created: ServiceInstance,
    pub config: AppConfig,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShortcutEventPayload {
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payload: Option<usize>,
}
