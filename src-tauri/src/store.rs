use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Deserialize;

use crate::catalog;
use crate::gesture::{sanitize_gesture_settings, GestureSettings};
use crate::models::{
    AddInstancePayload, AppConfig, AppSettings, ServiceInstance, UpdateInstancePatch,
    UpdateSettingsPatch, WindowBounds,
};
use crate::url_utils::{is_valid_hex_color, make_badge_text, normalize_service_url};

const CONFIG_VERSION: u32 = 1;
static ID_COUNTER: AtomicU64 = AtomicU64::new(1);

fn next_short_hex_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let seq = ID_COUNTER.fetch_add(1, Ordering::Relaxed);
    let mixed = nanos.wrapping_mul(6364136223846793005).wrapping_add(seq);
    format!("{:08x}", (mixed ^ (mixed >> 32)) as u32)
}

pub fn create_default_settings() -> AppSettings {
    AppSettings {
        theme: "dark".to_string(),
        minimize_to_tray: false,
        lock_pin: String::new(),
        sidebar_width: 248,
        active_instance_id: None,
        gesture: GestureSettings::default(),
    }
}

pub fn create_default_instances() -> Vec<ServiceInstance> {
    catalog::services()
        .iter()
        .filter(|svc| svc.default_pinned.unwrap_or(false))
        .enumerate()
        .map(|(index, svc)| ServiceInstance {
            instance_id: format!("svc-{}-default", svc.id),
            service_id: svc.id.clone(),
            name: svc.name.clone(),
            category: svc.category.clone(),
            url: svc.url.clone(),
            color: svc.color.clone(),
            badge: svc.badge.clone(),
            ua_mode: svc.default_ua.clone(),
            muted: false,
            zoom_factor: 1.0,
            notifications_enabled: true,
            order: index,
        })
        .collect()
}

pub fn create_default_config() -> AppConfig {
    let instances = create_default_instances();
    let mut settings = create_default_settings();
    settings.active_instance_id = instances.first().map(|i| i.instance_id.clone());
    AppConfig {
        version: CONFIG_VERSION,
        settings,
        instances,
        window_bounds: Some(WindowBounds {
            x: None,
            y: None,
            width: 1380,
            height: 880,
            is_maximized: Some(false),
        }),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawConfig {
    settings: Option<RawSettings>,
    instances: Option<Vec<RawInstance>>,
    window_bounds: Option<WindowBounds>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawSettings {
    theme: Option<String>,
    minimize_to_tray: Option<bool>,
    lock_pin: Option<String>,
    sidebar_width: Option<u32>,
    active_instance_id: Option<String>,
    gesture: Option<GestureSettings>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawInstance {
    instance_id: Option<String>,
    service_id: Option<String>,
    name: Option<String>,
    category: Option<String>,
    url: Option<String>,
    color: Option<String>,
    badge: Option<String>,
    ua_mode: Option<String>,
    muted: Option<bool>,
    zoom_factor: Option<f64>,
    notifications_enabled: Option<bool>,
    order: Option<usize>,
}

pub struct ConfigStore {
    file_path: PathBuf,
    config: AppConfig,
}

impl ConfigStore {
    pub fn new(file_path: PathBuf) -> Self {
        let config = Self::load(&file_path);
        Self { file_path, config }
    }

    fn load(file_path: &PathBuf) -> AppConfig {
        if !file_path.exists() {
            let initial = create_default_config();
            let _ = Self::save_atomic(file_path, &initial);
            return initial;
        }

        let parsed = fs::read_to_string(file_path)
            .ok()
            .and_then(|raw| serde_json::from_str::<RawConfig>(&raw).ok());

        let Some(raw) = parsed else {
            let fallback = create_default_config();
            let _ = Self::save_atomic(file_path, &fallback);
            return fallback;
        };

        let defaults = create_default_config();
        let mut settings = defaults.settings;
        if let Some(rs) = raw.settings {
            if let Some(t) = rs.theme {
                if t == "dark" || t == "light" {
                    settings.theme = t;
                }
            }
            if let Some(v) = rs.minimize_to_tray {
                settings.minimize_to_tray = v;
            }
            if let Some(v) = rs.lock_pin {
                settings.lock_pin = v.chars().take(16).collect();
            }
            if let Some(w) = rs.sidebar_width {
                settings.sidebar_width = w.clamp(180, 360);
            }
            if let Some(g) = rs.gesture {
                settings.gesture = sanitize_gesture_settings(g);
            }
            settings.active_instance_id = rs.active_instance_id;
        }

        let mut migrated = false;
        let instances: Vec<ServiceInstance> = if let Some(raw_list) = raw.instances {
            let mut list: Vec<ServiceInstance> = raw_list
                .into_iter()
                .enumerate()
                .filter_map(|(idx, item)| {
                    let instance_id = item.instance_id?.trim().to_string();
                    let raw_url = item.url?;
                    if instance_id.is_empty() || raw_url.trim().is_empty() {
                        return None;
                    }
                    let service_id = item
                        .service_id
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| "custom".to_string());
                    // X (旧Twitter) はアプリ内ログイン不可のため旧設定からも自動除外する
                    if service_id == "x" || instance_id == "svc-x-default" {
                        migrated = true;
                        return None;
                    }
                    let name = item
                        .name
                        .filter(|n| !n.trim().is_empty())
                        .unwrap_or_else(|| "SNS".to_string());
                    let color = item
                        .color
                        .filter(|c| is_valid_hex_color(c))
                        .unwrap_or_else(|| "#3B82F6".to_string());
                    let badge = item
                        .badge
                        .filter(|b| !b.trim().is_empty())
                        .unwrap_or_else(|| make_badge_text(&name))
                        .chars()
                        .take(2)
                        .collect();
                    let ua_mode = if item.ua_mode.as_deref() == Some("mobile") {
                        "mobile".to_string()
                    } else {
                        "desktop".to_string()
                    };
                    let zoom_factor = item
                        .zoom_factor
                        .filter(|z| z.is_finite())
                        .map(|z| (z * 100.0).round() / 100.0)
                        .unwrap_or(1.0)
                        .clamp(0.5, 2.0);

                    Some(ServiceInstance {
                        instance_id,
                        service_id,
                        name,
                        category: item
                            .category
                            .filter(|c| !c.is_empty())
                            .unwrap_or_else(|| "custom".to_string()),
                        url: normalize_service_url(&raw_url)
                            .unwrap_or_else(|| "https://example.com/".to_string()),
                        color,
                        badge,
                        ua_mode,
                        muted: item.muted.unwrap_or(false),
                        zoom_factor,
                        notifications_enabled: item.notifications_enabled.unwrap_or(true),
                        order: item.order.unwrap_or(idx),
                    })
                })
                .collect();
            list.sort_by_key(|i| i.order);
            for (idx, item) in list.iter_mut().enumerate() {
                item.order = idx;
            }
            list
        } else {
            defaults.instances
        };

        let active_valid = settings
            .active_instance_id
            .as_deref()
            .map(|id| instances.iter().any(|i| i.instance_id == id))
            .unwrap_or(false);
        if !active_valid {
            settings.active_instance_id = instances.first().map(|i| i.instance_id.clone());
        }

        let loaded = AppConfig {
            version: CONFIG_VERSION,
            settings,
            instances,
            window_bounds: raw.window_bounds.or(defaults.window_bounds),
        };
        if migrated {
            let _ = Self::save_atomic(file_path, &loaded);
        }
        loaded
    }

    fn save_atomic(file_path: &PathBuf, data: &AppConfig) -> std::io::Result<()> {
        if let Some(dir) = file_path.parent() {
            fs::create_dir_all(dir)?;
        }
        let temp_path = file_path.with_extension("json.tmp");
        let serialized = serde_json::to_string_pretty(data)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
        fs::write(&temp_path, serialized)?;
        // Windowsではrename先が存在すると失敗する場合があるためフォールバック
        if fs::rename(&temp_path, file_path).is_err() {
            let _ = fs::remove_file(file_path);
            fs::rename(&temp_path, file_path)?;
        }
        Ok(())
    }

    fn persist(&self) {
        let _ = Self::save_atomic(&self.file_path, &self.config);
    }

    pub fn get_config(&self) -> AppConfig {
        self.config.clone()
    }

    pub fn get_instances(&self) -> Vec<ServiceInstance> {
        self.config.instances.clone()
    }

    pub fn get_instance(&self, instance_id: &str) -> Option<ServiceInstance> {
        self.config
            .instances
            .iter()
            .find(|i| i.instance_id == instance_id)
            .cloned()
    }

    pub fn get_settings(&self) -> AppSettings {
        self.config.settings.clone()
    }

    pub fn add_instance(&mut self, payload: AddInstancePayload) -> Result<ServiceInstance, String> {
        let normalized_url = normalize_service_url(&payload.url)
            .ok_or_else(|| "有効な http:// または https:// URL を入力してください。".to_string())?;

        let trimmed_name = if payload.name.trim().is_empty() {
            "カスタムSNS".to_string()
        } else {
            payload.name.trim().to_string()
        };

        let safe_prefix: String = payload
            .service_id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
            .collect();
        let safe_prefix = if safe_prefix.is_empty() {
            "custom".to_string()
        } else {
            safe_prefix
        };

        let badge = if payload.badge.trim().is_empty() {
            make_badge_text(&trimmed_name)
        } else {
            payload.badge.trim().chars().take(2).collect()
        };

        let instance = ServiceInstance {
            instance_id: format!("svc-{safe_prefix}-{}", next_short_hex_id()),
            service_id: if payload.service_id.is_empty() {
                "custom".to_string()
            } else {
                payload.service_id
            },
            name: trimmed_name,
            category: if payload.category.is_empty() {
                "custom".to_string()
            } else {
                payload.category
            },
            url: normalized_url,
            color: if is_valid_hex_color(&payload.color) {
                payload.color
            } else {
                "#3B82F6".to_string()
            },
            badge,
            ua_mode: if payload.ua_mode == "mobile" {
                "mobile".to_string()
            } else {
                "desktop".to_string()
            },
            muted: false,
            zoom_factor: 1.0,
            notifications_enabled: true,
            order: self.config.instances.len(),
        };

        self.config.settings.active_instance_id = Some(instance.instance_id.clone());
        self.config.instances.push(instance.clone());
        self.persist();
        Ok(instance)
    }

    pub fn restore_instance(&mut self, mut instance: ServiceInstance) -> ServiceInstance {
        if let Some(existing) = self
            .config
            .instances
            .iter()
            .find(|i| i.instance_id == instance.instance_id)
            .cloned()
        {
            self.config.settings.active_instance_id = Some(existing.instance_id.clone());
            self.persist();
            return existing;
        }
        let insert_at = instance.order.min(self.config.instances.len());
        self.config.instances.insert(insert_at, instance.clone());
        for (idx, item) in self.config.instances.iter_mut().enumerate() {
            item.order = idx;
        }
        instance.order = insert_at;
        self.config.settings.active_instance_id = Some(instance.instance_id.clone());
        self.persist();
        instance
    }

    pub fn remove_instance(&mut self, instance_id: &str) -> bool {
        let prev_len = self.config.instances.len();
        self.config
            .instances
            .retain(|item| item.instance_id != instance_id);
        if self.config.instances.len() == prev_len {
            return false;
        }
        for (idx, item) in self.config.instances.iter_mut().enumerate() {
            item.order = idx;
        }
        if self.config.settings.active_instance_id.as_deref() == Some(instance_id) {
            self.config.settings.active_instance_id =
                self.config.instances.first().map(|i| i.instance_id.clone());
        }
        self.persist();
        true
    }

    pub fn update_instance(
        &mut self,
        instance_id: &str,
        patch: UpdateInstancePatch,
    ) -> Option<ServiceInstance> {
        let target = self
            .config
            .instances
            .iter_mut()
            .find(|item| item.instance_id == instance_id)?;

        if let Some(name) = patch.name {
            let trimmed = name.trim();
            if !trimmed.is_empty() {
                target.name = trimmed.to_string();
            }
        }
        if let Some(url) = patch.url {
            if let Some(norm) = normalize_service_url(&url) {
                target.url = norm;
            }
        }
        if let Some(ua) = patch.ua_mode {
            if ua == "desktop" || ua == "mobile" {
                target.ua_mode = ua;
            }
        }
        if let Some(muted) = patch.muted {
            target.muted = muted;
        }
        if let Some(zoom) = patch.zoom_factor {
            if zoom.is_finite() {
                target.zoom_factor = ((zoom * 100.0).round() / 100.0).clamp(0.5, 2.0);
            }
        }
        if let Some(notif) = patch.notifications_enabled {
            target.notifications_enabled = notif;
        }
        if let Some(color) = patch.color {
            if is_valid_hex_color(&color) {
                target.color = color;
            }
        }
        if let Some(badge) = patch.badge {
            let trimmed = badge.trim();
            if !trimmed.is_empty() {
                target.badge = trimmed.chars().take(2).collect();
            }
        }

        let updated = target.clone();
        self.persist();
        Some(updated)
    }

    pub fn reorder_instances(&mut self, ordered_ids: &[String]) -> Vec<ServiceInstance> {
        let mut map: HashMap<String, ServiceInstance> = self
            .config
            .instances
            .drain(..)
            .map(|item| (item.instance_id.clone(), item))
            .collect();

        let mut reordered = Vec::with_capacity(map.len());
        for id in ordered_ids {
            if let Some(item) = map.remove(id) {
                reordered.push(item);
            }
        }
        let mut remaining: Vec<ServiceInstance> = map.into_values().collect();
        remaining.sort_by_key(|i| i.order);
        reordered.extend(remaining);

        for (idx, item) in reordered.iter_mut().enumerate() {
            item.order = idx;
        }
        self.config.instances = reordered;
        self.persist();
        self.config.instances.clone()
    }

    pub fn update_settings(&mut self, patch: UpdateSettingsPatch) -> AppSettings {
        if let Some(theme) = patch.theme {
            self.config.settings.theme = if theme == "light" {
                "light".to_string()
            } else {
                "dark".to_string()
            };
        }
        if let Some(tray) = patch.minimize_to_tray {
            self.config.settings.minimize_to_tray = tray;
        }
        if let Some(pin) = patch.lock_pin {
            self.config.settings.lock_pin = pin.chars().take(16).collect();
        }
        if let Some(w) = patch.sidebar_width {
            self.config.settings.sidebar_width = w.clamp(180, 360);
        }
        if let Some(active) = patch.active_instance_id {
            self.config.settings.active_instance_id = active;
        }
        if let Some(gesture) = patch.gesture {
            self.config.settings.gesture = sanitize_gesture_settings(gesture);
        }
        self.persist();
        self.config.settings.clone()
    }

    pub fn update_window_bounds(&mut self, bounds: WindowBounds) {
        self.config.window_bounds = Some(bounds);
        self.persist();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_store_roundtrip() {
        let tmp_dir = std::env::temp_dir().join(format!("omnisns-rust-test-{}", next_short_hex_id()));
        fs::create_dir_all(&tmp_dir).unwrap();
        let config_path = tmp_dir.join("config.json");

        {
            let mut store1 = ConfigStore::new(config_path.clone());
            let initial_count = store1.get_instances().len();
            assert!(initial_count >= 5);

            let added = store1
                .add_instance(AddInstancePayload {
                    service_id: "tinder".into(),
                    name: "Tinder メイン".into(),
                    category: "matching-global".into(),
                    url: "https://tinder.com/".into(),
                    color: "#FE3C72".into(),
                    badge: "TD".into(),
                    ua_mode: "desktop".into(),
                })
                .unwrap();
            assert_eq!(store1.get_instances().len(), initial_count + 1);
            assert_eq!(
                store1.get_settings().active_instance_id.as_deref(),
                Some(added.instance_id.as_str())
            );

            store1.update_instance(
                &added.instance_id,
                UpdateInstancePatch {
                    name: Some("Tinder サブ".into()),
                    ua_mode: Some("mobile".into()),
                    zoom_factor: Some(1.2),
                    ..Default::default()
                },
            );
            store1.update_settings(UpdateSettingsPatch {
                theme: Some("light".into()),
                lock_pin: Some("1234".into()),
                ..Default::default()
            });

            let mut ids: Vec<String> = store1
                .get_instances()
                .into_iter()
                .map(|i| i.instance_id)
                .collect();
            ids.reverse();
            store1.reorder_instances(&ids);

            let mut store2 = ConfigStore::new(config_path.clone());
            assert_eq!(store2.get_settings().theme, "light");
            assert_eq!(store2.get_settings().lock_pin, "1234");
            assert_eq!(store2.get_instances()[0].instance_id, ids[0]);

            let restored = store2.get_instance(&added.instance_id).unwrap();
            assert_eq!(restored.name, "Tinder サブ");
            assert_eq!(restored.ua_mode, "mobile");
            assert!((restored.zoom_factor - 1.2).abs() < 0.001);

            assert!(store2.remove_instance(&added.instance_id));
            assert!(store2.get_instance(&added.instance_id).is_none());
        }

        let _ = fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn legacy_config_strips_x_and_ignores_matching_flags() {
        let tmp_dir = std::env::temp_dir().join(format!("omnisns-rust-mig-{}", next_short_hex_id()));
        fs::create_dir_all(&tmp_dir).unwrap();
        let config_path = tmp_dir.join("config.json");

        let legacy_json = r##"{
            "version": 1,
            "settings": {
                "theme": "dark",
                "showMatchingServices": false,
                "minimizeToTray": false,
                "lockPin": "",
                "sidebarWidth": 248,
                "activeInstanceId": "svc-x-default"
            },
            "instances": [
                {
                    "instanceId": "svc-x-default",
                    "serviceId": "x",
                    "name": "X (旧Twitter)",
                    "category": "major-sns",
                    "url": "https://x.com/messages",
                    "color": "#111827",
                    "badge": "X",
                    "uaMode": "desktop",
                    "muted": false,
                    "zoomFactor": 1.0,
                    "isAdultOrMatching": false,
                    "notificationsEnabled": true,
                    "order": 0
                },
                {
                    "instanceId": "svc-instagram-default",
                    "serviceId": "instagram",
                    "name": "Instagram",
                    "category": "major-sns",
                    "url": "https://www.instagram.com/direct/inbox/",
                    "color": "#E1306C",
                    "badge": "IG",
                    "uaMode": "desktop",
                    "muted": false,
                    "zoomFactor": 1.0,
                    "isAdultOrMatching": false,
                    "notificationsEnabled": true,
                    "order": 1
                },
                {
                    "instanceId": "svc-pairs-default",
                    "serviceId": "pairs",
                    "name": "Pairs (ペアーズ)",
                    "category": "matching-jp",
                    "url": "https://pairs.lv/",
                    "color": "#2CB5E8",
                    "badge": "PR",
                    "uaMode": "desktop",
                    "muted": false,
                    "zoomFactor": 1.0,
                    "isAdultOrMatching": true,
                    "notificationsEnabled": true,
                    "order": 2
                }
            ]
        }"##;
        fs::write(&config_path, legacy_json).unwrap();

        let store = ConfigStore::new(config_path.clone());
        let instances = store.get_instances();
        assert_eq!(instances.len(), 2);
        assert_eq!(instances[0].service_id, "instagram");
        assert_eq!(instances[0].order, 0);
        assert_eq!(instances[1].service_id, "pairs");
        assert_eq!(instances[1].order, 1);
        assert_eq!(
            store.get_settings().active_instance_id.as_deref(),
            Some("svc-instagram-default")
        );

        let _ = fs::remove_dir_all(&tmp_dir);
    }
}
