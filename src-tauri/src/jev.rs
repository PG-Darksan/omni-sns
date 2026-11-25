use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Cursor;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use image::imageops::FilterType;
use image::{GenericImageView, ImageFormat, Rgb, RgbImage};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub const JEV_ENDPOINT_URL: &str = "https://api.typesafe.ai/v1/systemone";
pub const JEV_MODEL_NAME: &str = "jev-latest";
pub const DEFAULT_JEV_CATEGORY: &str = "女の子";
pub const DEFAULT_JEV_THRESHOLD: f64 = 0.55;
pub const JEV_BATCH_SIZE: usize = 8;
pub const JEV_AVATAR_TARGET_PX: u32 = 320;
/// TypeSafe 公表料金: 入力 $0.042 / 100万トークン、出力トークンは無料 ($0)。
pub const JEV_INPUT_USD_PER_MTOK: f64 = 0.042;
pub const JEV_USD_TO_JPY_RATE: f64 = 155.0;
const CACHE_MAX_AGE_SECS: u64 = 90 * 24 * 60 * 60;
const MAX_CACHE_ENTRIES: usize = 8000;
const MAX_RECENT_CATEGORIES: usize = 10;

static NONCE_COUNTER: AtomicU64 = AtomicU64::new(1);

fn now_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn normalize_category(raw: &str) -> String {
    let trimmed = raw
        .replace(['\r', '\n', '\t'], " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if trimmed.is_empty() {
        return DEFAULT_JEV_CATEGORY.to_string();
    }
    trimmed.chars().take(60).collect()
}

/// ユーザーが入力した分類が「女の子・女性個人アカウント」系かどうかを判定する。
/// 該当する場合は nearby_insta で精度検証済みの女性個人アカウント向け詳細プロンプトを適用する。
pub fn is_female_preset_category(category: &str) -> bool {
    let norm = normalize_category(category).to_lowercase();
    matches!(
        norm.as_str(),
        "女の子"
            | "おんなのこ"
            | "女性"
            | "女子"
            | "女性のみ"
            | "女の子のみ"
            | "女性個人"
            | "女性アカウント"
            | "女性個人アカウント"
            | "female"
            | "girl"
            | "girls"
            | "woman"
            | "women"
    )
}

pub fn category_cache_token(category: &str) -> String {
    if is_female_preset_category(category) {
        "__preset_female__".to_string()
    } else {
        normalize_category(category).to_lowercase()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JevAccountCandidate {
    #[serde(alias = "u")]
    pub username: String,
    #[serde(default, alias = "n")]
    pub display_name: String,
    #[serde(default)]
    pub bio: String,
    #[serde(default, alias = "img")]
    pub avatar_url: String,
    #[serde(default, alias = "b64")]
    pub avatar_base64: Option<String>,
    #[serde(default, alias = "fmt")]
    pub avatar_format: Option<String>,
    #[serde(default = "default_platform", alias = "p")]
    pub platform: String,
}

fn default_platform() -> String {
    "instagram".to_string()
}

impl JevAccountCandidate {
    pub fn platform_label(&self) -> &'static str {
        match self.platform.trim().to_ascii_lowercase().as_str() {
            "instagram" => "Instagram",
            "tiktok" => "TikTok",
            "threads" => "Threads",
            "bluesky" => "Bluesky",
            "x" | "twitter" => "X",
            "facebook" => "Facebook",
            "youtube" => "YouTube",
            "mastodon" => "Mastodon",
            "misskey" => "Misskey",
            "mixi2" => "mixi2",
            "reddit" => "Reddit",
            "note" => "note",
            _ => "SNS",
        }
    }

    pub fn has_inline_avatar_base64(&self) -> bool {
        self.avatar_base64
            .as_deref()
            .map(|s| !s.trim().is_empty())
            .unwrap_or(false)
    }

    pub fn avatar_id(&self) -> String {
        let raw_url = self.avatar_url.trim();
        if !raw_url.is_empty() {
            if let Ok(parsed) = url::Url::parse(raw_url) {
                let segs: Vec<&str> = parsed
                    .path_segments()
                    .map(|it| it.filter(|s| !s.is_empty()).collect())
                    .unwrap_or_default();
                if let Some(&last_raw) = segs.last() {
                    let last = match last_raw.rsplit_once('@') {
                        Some((head, suffix))
                            if !head.is_empty()
                                && suffix.chars().all(|c| c.is_ascii_alphanumeric()) =>
                        {
                            head
                        }
                        _ => last_raw,
                    };
                    if segs.len() >= 2 && is_resolution_filename(last) {
                        return format!("{}_{}", segs[segs.len() - 2], last).to_ascii_lowercase();
                    }
                    return last.to_ascii_lowercase();
                }
            }
            return raw_url.to_ascii_lowercase();
        }
        if let Some(b64) = self.avatar_base64.as_deref() {
            let trimmed = b64.trim();
            if !trimmed.is_empty() {
                let tail: String = trimmed
                    .chars()
                    .rev()
                    .take(24)
                    .collect::<String>()
                    .chars()
                    .rev()
                    .collect();
                return format!("b64_{}_{}", trimmed.len(), tail);
            }
        }
        String::new()
    }

    pub fn cache_key(&self, category: &str) -> String {
        let cat = category_cache_token(category);
        let plat = self.platform.trim().to_ascii_lowercase();
        let u = self.username.trim().to_lowercase();
        let d = self.display_name.trim().to_lowercase();
        let av = self.avatar_id();
        let bio_part: String = self
            .bio
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .to_lowercase()
            .chars()
            .take(48)
            .collect();
        format!("{cat}|{plat}|{u}|{d}|{av}|{bio_part}")
    }
}

fn is_resolution_filename(s: &str) -> bool {
    let Some((stem, ext)) = s.rsplit_once('.') else {
        return false;
    };
    if ext.is_empty() || !ext.chars().all(|c| c.is_ascii_alphanumeric()) {
        return false;
    }
    let Some((w, h)) = stem.split_once('x') else {
        return false;
    };
    !w.is_empty()
        && !h.is_empty()
        && w.chars().all(|c| c.is_ascii_digit())
        && h.chars().all(|c| c.is_ascii_digit())
}

#[derive(Debug, Clone)]
pub struct PreparedAvatar {
    pub base64: String,
    pub format: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JevSettingsDisk {
    #[serde(default)]
    pub api_key: String,
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_category")]
    pub category: String,
    #[serde(default)]
    pub recent_categories: Vec<String>,
    #[serde(default = "default_threshold")]
    pub threshold: f64,
    #[serde(default)]
    pub total_input_tokens: u64,
    #[serde(default)]
    pub total_api_calls: u64,
    #[serde(default)]
    pub total_judged_accounts: u64,
    #[serde(default)]
    pub total_cost_usd: f64,
}

fn default_category() -> String {
    DEFAULT_JEV_CATEGORY.to_string()
}

fn default_threshold() -> f64 {
    DEFAULT_JEV_THRESHOLD
}

impl Default for JevSettingsDisk {
    fn default() -> Self {
        Self {
            api_key: String::new(),
            enabled: false,
            category: DEFAULT_JEV_CATEGORY.to_string(),
            recent_categories: vec![DEFAULT_JEV_CATEGORY.to_string()],
            threshold: DEFAULT_JEV_THRESHOLD,
            total_input_tokens: 0,
            total_api_calls: 0,
            total_judged_accounts: 0,
            total_cost_usd: 0.0,
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateJevSettingsPatch {
    pub api_key: Option<String>,
    pub enabled: Option<bool>,
    pub category: Option<String>,
    pub threshold: Option<f64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JevStateSnapshot {
    pub has_api_key: bool,
    pub api_key: String,
    pub enabled: bool,
    pub is_active: bool,
    pub category: String,
    pub recent_categories: Vec<String>,
    pub threshold: f64,
    pub total_input_tokens: u64,
    pub total_api_calls: u64,
    pub total_judged_accounts: u64,
    pub total_cost_usd: f64,
    pub session_input_tokens: u64,
    pub session_api_calls: u64,
    pub session_cost_usd: f64,
    pub cache_entries: usize,
    pub checking_requests: usize,
    pub last_error: Option<String>,
    pub live_in_list: bool,
    pub live_matched: u32,
    pub live_hidden: u32,
    pub live_auto_fetching: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JevTestResult {
    pub ok: bool,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CacheEntry {
    p: f64,
    t: u64,
    #[serde(default, skip_serializing_if = "is_false")]
    img: bool,
}

fn is_false(v: &bool) -> bool {
    !*v
}

#[derive(Debug, Clone, Default)]
pub struct JevLiveTabState {
    pub active: bool,
    pub matched: u32,
    pub hidden: u32,
    pub auto_fetching: bool,
}

struct JevInner {
    settings_path: PathBuf,
    cache_path: PathBuf,
    settings: JevSettingsDisk,
    cache: HashMap<String, CacheEntry>,
    avatar_memory: HashMap<String, PreparedAvatar>,
    session_input_tokens: u64,
    session_api_calls: u64,
    session_cost_usd: f64,
    checking_requests: usize,
    last_error: Option<String>,
    live_by_tab: HashMap<String, JevLiveTabState>,
}

#[derive(Clone)]
pub struct JevService {
    inner: Arc<Mutex<JevInner>>,
}

impl JevService {
    pub fn new(config_dir: PathBuf) -> Self {
        let settings_path = config_dir.join("jev_settings.json");
        let cache_path = config_dir.join("jev_category_cache_v1.json");
        let settings = load_settings(&settings_path);
        let cache = load_cache(&cache_path);
        Self {
            inner: Arc::new(Mutex::new(JevInner {
                settings_path,
                cache_path,
                settings,
                cache,
                avatar_memory: HashMap::new(),
                session_input_tokens: 0,
                session_api_calls: 0,
                session_cost_usd: 0.0,
                checking_requests: 0,
                last_error: None,
                live_by_tab: HashMap::new(),
            })),
        }
    }

    pub fn snapshot(&self, active_tab_id: Option<&str>) -> JevStateSnapshot {
        let g = self.inner.lock().unwrap();
        let has_key = !g.settings.api_key.trim().is_empty();
        let live = active_tab_id
            .and_then(|tid| g.live_by_tab.get(tid))
            .cloned()
            .unwrap_or_default();
        JevStateSnapshot {
            has_api_key: has_key,
            api_key: g.settings.api_key.clone(),
            enabled: g.settings.enabled,
            is_active: g.settings.enabled && has_key,
            category: g.settings.category.clone(),
            recent_categories: g.settings.recent_categories.clone(),
            threshold: g.settings.threshold,
            total_input_tokens: g.settings.total_input_tokens,
            total_api_calls: g.settings.total_api_calls,
            total_judged_accounts: g.settings.total_judged_accounts,
            total_cost_usd: g.settings.total_cost_usd,
            session_input_tokens: g.session_input_tokens,
            session_api_calls: g.session_api_calls,
            session_cost_usd: g.session_cost_usd,
            cache_entries: g.cache.len(),
            checking_requests: g.checking_requests,
            last_error: g.last_error.clone(),
            live_in_list: live.active,
            live_matched: live.matched,
            live_hidden: live.hidden,
            live_auto_fetching: live.auto_fetching,
        }
    }

    pub fn js_config_payload(&self, reset_judged: bool) -> Value {
        let g = self.inner.lock().unwrap();
        let has_key = !g.settings.api_key.trim().is_empty();
        json!({
            "enabled": g.settings.enabled && has_key,
            "category": g.settings.category,
            "threshold": g.settings.threshold,
            "resetJudged": reset_judged,
        })
    }

    /// 設定を更新し、`(カテゴリまたはしきい値が変化したか)` を返す。
    pub fn update_settings(&self, patch: UpdateJevSettingsPatch) -> bool {
        let mut g = self.inner.lock().unwrap();
        let prev_cat_token = category_cache_token(&g.settings.category);
        let prev_threshold = g.settings.threshold;

        if let Some(key) = patch.api_key {
            g.settings.api_key = key.trim().to_string();
        }
        if let Some(cat_raw) = patch.category {
            let norm = normalize_category(&cat_raw);
            g.settings.category = norm.clone();
            push_recent_category(&mut g.settings.recent_categories, &norm);
        }
        if let Some(enabled) = patch.enabled {
            g.settings.enabled = enabled;
        }
        if let Some(th) = patch.threshold {
            if th.is_finite() {
                g.settings.threshold = th.clamp(0.35, 0.90);
            }
        }
        g.last_error = None;
        save_settings(&g.settings_path, &g.settings);

        let next_cat_token = category_cache_token(&g.settings.category);
        prev_cat_token != next_cat_token || (prev_threshold - g.settings.threshold).abs() > 0.0001
    }

    pub fn reset_usage(&self) {
        let mut g = self.inner.lock().unwrap();
        g.settings.total_input_tokens = 0;
        g.settings.total_api_calls = 0;
        g.settings.total_judged_accounts = 0;
        g.settings.total_cost_usd = 0.0;
        g.session_input_tokens = 0;
        g.session_api_calls = 0;
        g.session_cost_usd = 0.0;
        save_settings(&g.settings_path, &g.settings);
    }

    pub fn clear_cache(&self) {
        let mut g = self.inner.lock().unwrap();
        g.cache.clear();
        g.avatar_memory.clear();
        let _ = fs::remove_file(&g.cache_path);
    }

    pub fn update_live_tab_state(&self, tab_id: &str, state: JevLiveTabState) {
        let mut g = self.inner.lock().unwrap();
        if state.active {
            g.live_by_tab.insert(tab_id.to_string(), state);
        } else {
            g.live_by_tab.remove(tab_id);
        }
    }

    #[allow(dead_code)]
    pub fn remove_live_tab_state(&self, tab_id: &str) {
        let mut g = self.inner.lock().unwrap();
        g.live_by_tab.remove(tab_id);
    }

    pub fn clear_error(&self) {
        let mut g = self.inner.lock().unwrap();
        g.last_error = None;
    }

    /// 候補アカウント群が現在の自由入力分類に一致するかを判定し、`username -> bool` を返す。
    /// ブロッキング通信を含むため、呼び出し元はバックグラウンドスレッドで実行する。
    pub fn judge_accounts_blocking(
        &self,
        candidates: Vec<JevAccountCandidate>,
    ) -> HashMap<String, bool> {
        let (api_key, enabled, category, threshold) = {
            let g = self.inner.lock().unwrap();
            (
                g.settings.api_key.trim().to_string(),
                g.settings.enabled,
                g.settings.category.clone(),
                g.settings.threshold,
            )
        };
        if !enabled || api_key.is_empty() || candidates.is_empty() {
            return HashMap::new();
        }

        let now = now_unix_secs();
        let mut result = HashMap::new();
        let mut pending: Vec<JevAccountCandidate> = Vec::new();
        let mut seen_keys = HashSet::new();

        {
            let g = self.inner.lock().unwrap();
            for c in candidates {
                let user = c.username.trim();
                if user.is_empty() {
                    continue;
                }
                let ckey = c.cache_key(&category);
                if let Some(hit) = g.cache.get(&ckey) {
                    let fresh = now.saturating_sub(hit.t) <= CACHE_MAX_AGE_SECS;
                    let needs_avatar_upgrade = !hit.img && c.has_inline_avatar_base64();
                    if fresh && !needs_avatar_upgrade {
                        result.insert(c.username.clone(), hit.p >= threshold);
                        continue;
                    }
                }
                if seen_keys.insert(ckey) {
                    pending.push(c);
                }
            }
        }

        if pending.is_empty() {
            return result;
        }

        {
            let mut g = self.inner.lock().unwrap();
            g.checking_requests += 1;
        }

        let batches: Vec<Vec<JevAccountCandidate>> = pending
            .chunks(JEV_BATCH_SIZE)
            .map(|ch| ch.to_vec())
            .collect();

        let mut cache_dirty = false;
        // 最大2ワーカーで並列処理
        let batch_results: Vec<(Vec<JevAccountCandidate>, HashMap<usize, PreparedAvatar>, Option<HashMap<String, f64>>)> =
            if batches.len() <= 1 {
                batches
                    .into_iter()
                    .map(|b| {
                        let avatars = self.prepare_batch_avatars(&b);
                        let probs = self.query_batch_blocking(&b, &avatars, &api_key, &category, true);
                        (b, avatars, probs)
                    })
                    .collect()
            } else {
                let shared_batches = Arc::new(Mutex::new(batches.into_iter()));
                let mut handles = Vec::new();
                for _ in 0..2 {
                    let svc = self.clone();
                    let iter_ref = Arc::clone(&shared_batches);
                    let key_c = api_key.clone();
                    let cat_c = category.clone();
                    handles.push(std::thread::spawn(move || {
                        let mut local = Vec::new();
                        loop {
                            let next = { iter_ref.lock().unwrap().next() };
                            let Some(b) = next else { break };
                            let avatars = svc.prepare_batch_avatars(&b);
                            let probs = svc.query_batch_blocking(&b, &avatars, &key_c, &cat_c, true);
                            local.push((b, avatars, probs));
                        }
                        local
                    }));
                }
                let mut merged = Vec::new();
                for h in handles {
                    if let Ok(part) = h.join() {
                        merged.extend(part);
                    }
                }
                merged
            };

        {
            let mut g = self.inner.lock().unwrap();
            g.checking_requests = g.checking_requests.saturating_sub(1);
            let ts = now_unix_secs();
            for (batch, avatars, probs_opt) in batch_results {
                let Some(probs) = probs_opt else { continue };
                for (i, c) in batch.iter().enumerate() {
                    if let Some(&p) = probs.get(&c.username) {
                        let ckey = c.cache_key(&category);
                        g.cache.insert(
                            ckey,
                            CacheEntry {
                                p: (p * 10000.0).round() / 10000.0,
                                t: ts,
                                img: avatars.contains_key(&i),
                            },
                        );
                        result.insert(c.username.clone(), p >= threshold);
                        cache_dirty = true;
                    }
                }
            }
            if cache_dirty {
                let cache_path = g.cache_path.clone();
                trim_and_save_cache(&cache_path, &mut g.cache);
            }
        }

        result
    }

    pub fn test_connection_blocking(
        &self,
        candidate_key: &str,
        candidate_category: Option<&str>,
    ) -> JevTestResult {
        let trimmed = candidate_key.trim();
        if trimmed.is_empty() {
            return JevTestResult {
                ok: false,
                message: "TypeSafe API キーを入力してください".to_string(),
            };
        }
        let category = candidate_category
            .map(normalize_category)
            .unwrap_or_else(|| self.inner.lock().unwrap().settings.category.clone());

        let solid_b64 = base64::engine::general_purpose::STANDARD
            .encode(make_solid_png(JEV_AVATAR_TARGET_PX, JEV_AVATAR_TARGET_PX));

        let (sample, label_a, label_b) = if is_female_preset_category(&category) {
            (
                vec![
                    JevAccountCandidate {
                        username: "hanako_sato_04".to_string(),
                        display_name: "佐藤 花子".to_string(),
                        bio: String::new(),
                        avatar_url: String::new(),
                        avatar_base64: Some(solid_b64.clone()),
                        avatar_format: Some("png".to_string()),
                        platform: "instagram".to_string(),
                    },
                    JevAccountCandidate {
                        username: "taro_yamada_1998".to_string(),
                        display_name: "山田 太郎".to_string(),
                        bio: String::new(),
                        avatar_url: String::new(),
                        avatar_base64: Some(solid_b64),
                        avatar_format: Some("png".to_string()),
                        platform: "instagram".to_string(),
                    },
                ],
                "佐藤花子".to_string(),
                "山田太郎".to_string(),
            )
        } else {
            (
                vec![
                    JevAccountCandidate {
                        username: "sample_match_01".to_string(),
                        display_name: format!("{} 好き", category),
                        bio: format!("{} について発信しています", category),
                        avatar_url: String::new(),
                        avatar_base64: Some(solid_b64.clone()),
                        avatar_format: Some("png".to_string()),
                        platform: "instagram".to_string(),
                    },
                    JevAccountCandidate {
                        username: "system_notice_bot".to_string(),
                        display_name: "公式お知らせBot".to_string(),
                        bio: "自動配信アカウント".to_string(),
                        avatar_url: String::new(),
                        avatar_base64: Some(solid_b64),
                        avatar_format: Some("png".to_string()),
                        platform: "instagram".to_string(),
                    },
                ],
                format!("一致サンプル"),
                "非一致サンプル".to_string(),
            )
        };

        let avatars = self.prepare_batch_avatars(&sample);
        let before_cost = self.inner.lock().unwrap().settings.total_cost_usd;
        let probs = self.query_batch_blocking(&sample, &avatars, trimmed, &category, true);
        let Some(probs) = probs else {
            let err = self
                .inner
                .lock()
                .unwrap()
                .last_error
                .clone()
                .unwrap_or_else(|| "Jev からの応答を取得できませんでした".to_string());
            return JevTestResult {
                ok: false,
                message: err,
            };
        };
        if probs.is_empty() {
            return JevTestResult {
                ok: false,
                message: "Jev から判定確率が返されませんでした".to_string(),
            };
        }
        let p_a = (probs.get(&sample[0].username).copied().unwrap_or(0.0) * 100.0).round() as i32;
        let p_b = (probs.get(&sample[1].username).copied().unwrap_or(0.0) * 100.0).round() as i32;
        let after_cost = self.inner.lock().unwrap().settings.total_cost_usd;
        let delta_usd = (after_cost - before_cost).max(0.0);
        JevTestResult {
            ok: true,
            message: format!(
                "Jev に接続できました（分類「{}」一致確率: {} {}% / {} {}% · 今回の通信費 {}）",
                category,
                label_a,
                p_a,
                label_b,
                p_b,
                format_cost_compact(delta_usd)
            ),
        }
    }

    fn prepare_batch_avatars(
        &self,
        batch: &[JevAccountCandidate],
    ) -> HashMap<usize, PreparedAvatar> {
        let mut out = HashMap::new();
        for (i, c) in batch.iter().enumerate() {
            if let Some(av) = self.resolve_avatar(c) {
                out.insert(i, av);
            }
        }
        out
    }

    fn resolve_avatar(&self, c: &JevAccountCandidate) -> Option<PreparedAvatar> {
        let id = c.avatar_id();
        if !id.is_empty() {
            let g = self.inner.lock().unwrap();
            if let Some(hit) = g.avatar_memory.get(&id) {
                return Some(hit.clone());
            }
        }

        if let Some(clean_b64) = clean_base64(c.avatar_base64.as_deref()) {
            let av = PreparedAvatar {
                base64: clean_b64,
                format: normalize_image_format(c.avatar_format.as_deref()).to_string(),
            };
            if !id.is_empty() {
                self.put_avatar_memory(&id, av.clone());
            }
            return Some(av);
        }

        let raw_url = c.avatar_url.trim();
        if raw_url.is_empty() {
            return None;
        }
        let av = download_and_prepare_avatar(raw_url)?;
        if !id.is_empty() {
            self.put_avatar_memory(&id, av.clone());
        }
        Some(av)
    }

    fn put_avatar_memory(&self, id: &str, av: PreparedAvatar) {
        let mut g = self.inner.lock().unwrap();
        if g.avatar_memory.len() >= 200 {
            if let Some(first_key) = g.avatar_memory.keys().next().cloned() {
                g.avatar_memory.remove(&first_key);
            }
        }
        g.avatar_memory.insert(id.to_string(), av);
    }

    fn query_batch_blocking(
        &self,
        batch: &[JevAccountCandidate],
        avatars: &HashMap<usize, PreparedAvatar>,
        api_key: &str,
        category: &str,
        record_error: bool,
    ) -> Option<HashMap<String, f64>> {
        let nonce = format!(
            "{:x}{}",
            now_unix_secs(),
            NONCE_COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        let has_images = !avatars.is_empty();
        let body = build_request_body(batch, category, avatars, &nonce);

        match post_system_one(api_key, &body, has_images) {
            Ok((status, text)) => {
                // 画像形式エラー時はテキストのみでフォールバック再試行
                if has_images && matches!(status, 400 | 415 | 422) {
                    let empty = HashMap::new();
                    let fb_body =
                        build_request_body(batch, category, &empty, &format!("{nonce}_txt"));
                    if let Ok((fb_status, fb_text)) = post_system_one(api_key, &fb_body, false) {
                        return self.handle_response(fb_status, &fb_text, batch, record_error);
                    }
                }
                self.handle_response(status, &text, batch, record_error)
            }
            Err(e) => {
                if record_error {
                    let mut g = self.inner.lock().unwrap();
                    g.last_error = Some(format!("Jev への通信に失敗しました: {e}"));
                }
                None
            }
        }
    }

    fn handle_response(
        &self,
        status: u16,
        body_text: &str,
        batch: &[JevAccountCandidate],
        record_error: bool,
    ) -> Option<HashMap<String, f64>> {
        if status != 200 {
            let msg = match status {
                401 | 403 => format!("Jev API キーが無効です（HTTP {status}）"),
                402 => "TypeSafe API のクレジット残高が不足しています（HTTP 402）".to_string(),
                429 => "Jev のリクエスト上限に達しました。しばらく待ってから再試行してください"
                    .to_string(),
                _ => format!("Jev エラー（HTTP {status}）"),
            };
            if record_error {
                let mut g = self.inner.lock().unwrap();
                g.last_error = Some(msg);
            }
            return None;
        }
        let decoded: Value = match serde_json::from_str(body_text) {
            Ok(v) => v,
            Err(e) => {
                if record_error {
                    let mut g = self.inner.lock().unwrap();
                    g.last_error = Some(format!("Jev 応答の解析に失敗しました: {e}"));
                }
                return None;
            }
        };

        {
            let mut g = self.inner.lock().unwrap();
            g.last_error = None;
            let (input_tokens, cost_usd) = extract_usage_cost(&decoded);
            g.settings.total_input_tokens = g.settings.total_input_tokens.saturating_add(input_tokens);
            g.settings.total_api_calls = g.settings.total_api_calls.saturating_add(1);
            g.settings.total_judged_accounts = g
                .settings
                .total_judged_accounts
                .saturating_add(batch.len() as u64);
            g.settings.total_cost_usd += cost_usd;

            g.session_input_tokens = g.session_input_tokens.saturating_add(input_tokens);
            g.session_api_calls = g.session_api_calls.saturating_add(1);
            g.session_cost_usd += cost_usd;
            save_settings(&g.settings_path, &g.settings);
        }

        Some(parse_response_probabilities(&decoded, batch))
    }
}

pub fn build_request_body(
    batch: &[JevAccountCandidate],
    category: &str,
    avatars: &HashMap<usize, PreparedAvatar>,
    nonce: &str,
) -> Value {
    let norm_category = normalize_category(category);
    let female_mode = is_female_preset_category(&norm_category);

    let mut labels: Vec<&'static str> = Vec::new();
    for c in batch {
        let lbl = c.platform_label();
        if !labels.contains(&lbl) {
            labels.push(lbl);
        }
    }
    let platform_scope = match labels.len() {
        0 => "SNS".to_string(),
        1 => labels[0].to_string(),
        _ => format!("SNS ({})", labels.join(" / ")),
    };

    let mut state = String::new();
    if female_mode {
        state.push_str(&format!(
            "Task: Judge whether each numbered {platform_scope} account is a FEMALE individual's personal account \
using BOTH its profile icon image (when provided in the question) and its @username, display_name, and bio/snippet (when provided).\n\
- True (female personal account): \
(1) Profile icon shows a woman/girl or feminine personal portrait/selfie/avatar of a female user, OR \
(2) @username, display_name, or bio contains a Japanese or foreign female given name in kanji, hiragana, katakana, or romaji \
(e.g. 花子, 美咲, 結衣, 葵, 陽菜, 凛, さくら, みゆ, あや, まな, ゆい, りな, もも, なな, まい, えり, かな, みなみ, はるか, まりな, ゆか, ちひろ, あかり, ほのか, \
hanako, misaki, yui, aoi, hina, sakura, miyu, aya, mana, rina, momo, nana, mai, eri, kana, minami, haruka, marina, yuka, akari, honoka, etc.) \
or female self-identifiers (女子, 女の子, ママ, ちゃん, OL, JD, JK, ♀, she/her, girl, miss), \
WITHOUT male face/portrait or business/shop indicators.\n\
- False (do NOT show — non-female): \
Male personal accounts (male face/portrait icon or male given name / 男子 / パパ / 俺 / 僕 / くん / Mr.), \
shops, cafes, salons, restaurants, brands, companies, schools, clubs, event/official/media/bot accounts \
(logos, storefronts, flyers, menus, products), \
or gender-unknown accounts where neither the profile icon nor the text indicates a female person \
(e.g. default grey silhouette, landscape, food, pet, or object icon paired with a gender-neutral handle).\n\nAccounts:\n"
        ));
    } else {
        let safe_cat = norm_category.replace('"', "'");
        state.push_str(&format!(
            "Task: Judge whether each numbered {platform_scope} account matches the user-specified target category: \"{safe_cat}\"\n\
Use ALL available clues: its profile icon image (when provided in the question), @username, display_name, and bio/snippet (when provided).\n\
- True (matches \"{safe_cat}\"): The profile icon image, @username, display_name, or bio/snippet clearly indicates that this account belongs to or strongly matches the category \"{safe_cat}\".\n\
- False (does NOT match \"{safe_cat}\"): The account belongs to a different category, is clearly unrelated, or lacks sufficient visual or textual evidence to conclude that it matches \"{safe_cat}\".\n\nAccounts:\n"
        ));
    }

    let mut assets = serde_json::Map::new();
    let mut questions = serde_json::Map::new();
    let safe_cat_q = norm_category.replace('"', "'");

    for (i, item) in batch.iter().enumerate() {
        let sns_label = item.platform_label();
        let u = item.username.trim().replace('"', "");
        let d_clean: String = item
            .display_name
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .replace('"', "'")
            .chars()
            .take(80)
            .collect();
        let display_label = if d_clean.is_empty() {
            "(none)".to_string()
        } else {
            d_clean
        };
        let bio_clean: String = item
            .bio
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .replace('"', "'")
            .chars()
            .take(140)
            .collect();

        if bio_clean.is_empty() {
            state.push_str(&format!(
                "#{i}: [{sns_label}] @username=\"{u}\" | display_name=\"{display_label}\"\n"
            ));
        } else {
            state.push_str(&format!(
                "#{i}: [{sns_label}] @username=\"{u}\" | display_name=\"{display_label}\" | bio=\"{bio_clean}\"\n"
            ));
        }

        let icon_clause = if let Some(av) = avatars.get(&i) {
            if !av.base64.is_empty() {
                let ref_id = format!("jevimg_{nonce}_{i}");
                assets.insert(
                    ref_id.clone(),
                    json!({
                        "type": "image",
                        "format": normalize_image_format(Some(&av.format)),
                        "data_base64": av.base64,
                    }),
                );
                format!("profile_icon: {ref_id}")
            } else {
                "profile_icon: (unavailable)".to_string()
            }
        } else {
            "profile_icon: (unavailable)".to_string()
        };

        let bio_clause = if bio_clean.is_empty() {
            String::new()
        } else {
            format!(", bio: \"{bio_clean}\"")
        };

        let q_obj = if female_mode {
            json!({
                "type": "noul",
                "instructions": format!(
                    "Account #{i} ({sns_label} @{u}, display_name: \"{display_label}\"{bio_clause}), {icon_clause} — Is this a female person's personal {sns_label} account?"
                ),
                "criteria": {
                    "true": format!("Personal {sns_label} account of a female individual (from profile icon and/or name/bio)"),
                    "false": "Male person, shop/brand/organization/club/bot, or gender-unknown account"
                }
            })
        } else {
            json!({
                "type": "noul",
                "instructions": format!(
                    "Account #{i} ({sns_label} @{u}, display_name: \"{display_label}\"{bio_clause}), {icon_clause} — Does this {sns_label} account match the target category \"{safe_cat_q}\"?"
                ),
                "criteria": {
                    "true": format!("Account clearly matches the category \"{safe_cat_q}\" based on profile icon, @username, display_name, and/or bio"),
                    "false": format!("Account does not match \"{safe_cat_q}\" or lacks sufficient indication")
                }
            })
        };
        questions.insert(format!("q_{i}"), q_obj);
    }

    let mut body = serde_json::Map::new();
    body.insert("model".to_string(), json!(JEV_MODEL_NAME));
    body.insert("state".to_string(), json!(state.trim_end()));
    if !assets.is_empty() {
        body.insert("assets".to_string(), Value::Object(assets));
    }
    body.insert("questions".to_string(), Value::Object(questions));
    Value::Object(body)
}

pub fn parse_response_probabilities(
    json: &Value,
    batch: &[JevAccountCandidate],
) -> HashMap<String, f64> {
    let mut out = HashMap::new();
    let Some(answers) = json.get("answers").and_then(|v| v.as_object()) else {
        return out;
    };
    for (i, item) in batch.iter().enumerate() {
        let key = format!("q_{i}");
        let Some(raw) = answers.get(&key).and_then(|v| v.as_object()) else {
            continue;
        };
        let prob = raw.get("noul").and_then(|v| v.as_f64()).or_else(|| {
            raw.get("probabilities")
                .and_then(|v| v.as_object())
                .and_then(|p| p.get("true"))
                .and_then(|v| v.as_f64())
        });
        if let Some(p) = prob {
            if p.is_finite() {
                out.insert(item.username.clone(), p.clamp(0.0, 1.0));
            }
        }
    }
    out
}

fn extract_usage_cost(response_json: &Value) -> (u64, f64) {
    let Some(usage) = response_json.get("usage").and_then(|v| v.as_object()) else {
        return (0, 0.0);
    };
    let input_tokens = usage
        .get("input_tokens")
        .or_else(|| usage.get("prompt_tokens"))
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let explicit_usd = usage
        .get("cost_usd")
        .or_else(|| usage.get("total_cost"))
        .or_else(|| usage.get("cost"))
        .and_then(|v| v.as_f64())
        .filter(|v| v.is_finite() && *v >= 0.0);
    let cost_usd = explicit_usd.unwrap_or((input_tokens as f64 / 1e6) * JEV_INPUT_USD_PER_MTOK);
    (input_tokens, cost_usd)
}

pub fn format_usd(usd: f64) -> String {
    if !usd.is_finite() || usd <= 0.0 {
        return "$0".to_string();
    }
    if usd < 0.0001 {
        return format!("${usd:.6}");
    }
    if usd < 0.01 {
        let s = format!("{usd:.5}");
        let trimmed = s.trim_end_matches('0');
        return if trimmed.ends_with('.') {
            format!("${trimmed}0")
        } else {
            format!("${trimmed}")
        };
    }
    if usd < 1.0 {
        return format!("${usd:.4}");
    }
    format!("${usd:.2}")
}

pub fn format_jpy(usd: f64) -> String {
    if !usd.is_finite() || usd <= 0.0 {
        return "¥0".to_string();
    }
    let jpy = usd * JEV_USD_TO_JPY_RATE;
    if jpy < 0.01 {
        return format!("約¥{jpy:.4}");
    }
    if jpy < 1.0 {
        return format!("約¥{jpy:.2}");
    }
    if jpy < 100.0 {
        return format!("約¥{jpy:.1}");
    }
    format!("約¥{}", jpy.round() as u64)
}

pub fn format_cost_compact(usd: f64) -> String {
    if !usd.is_finite() || usd <= 0.0 {
        return "$0 (¥0)".to_string();
    }
    format!("{} ({})", format_usd(usd), format_jpy(usd))
}

fn clean_base64(raw: Option<&str>) -> Option<String> {
    let mut s = raw?.trim();
    if s.is_empty() {
        return None;
    }
    if s.starts_with("data:") {
        if let Some((_, rest)) = s.split_once(',') {
            s = rest;
        }
    }
    let compact: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    if compact.len() >= 32 {
        Some(compact)
    } else {
        None
    }
}

fn normalize_image_format(fmt: Option<&str>) -> &'static str {
    let lower = fmt.unwrap_or("").trim().to_ascii_lowercase();
    if lower == "png" || lower.ends_with("/png") {
        "png"
    } else {
        "jpg"
    }
}

pub fn make_solid_png(width: u32, height: u32) -> Vec<u8> {
    let img = RgbImage::from_pixel(width, height, Rgb([245, 232, 238]));
    let mut out = Cursor::new(Vec::new());
    let _ = img.write_to(&mut out, ImageFormat::Png);
    out.into_inner()
}

pub fn resize_avatar_bytes_to_320_png(raw: &[u8]) -> Option<PreparedAvatar> {
    let decoded = image::load_from_memory(raw).ok()?;
    let (sw, sh) = decoded.dimensions();
    if sw == 0 || sh == 0 {
        return None;
    }
    let target = JEV_AVATAR_TARGET_PX;
    let scale = (target as f64 / sw as f64).max(target as f64 / sh as f64);
    let rw = ((sw as f64 * scale).round() as u32).max(target);
    let rh = ((sh as f64 * scale).round() as u32).max(target);
    let resized = decoded.resize_exact(rw, rh, FilterType::Triangle).to_rgba8();
    let cx = (rw.saturating_sub(target)) / 2;
    let cy = (rh.saturating_sub(target)) / 2;
    let mut canvas = RgbImage::from_pixel(target, target, Rgb([255, 255, 255]));
    for y in 0..target {
        for x in 0..target {
            let p = resized.get_pixel(cx + x, cy + y);
            let a = p[3] as u32;
            let inv = 255 - a;
            let r = ((p[0] as u32 * a + 255 * inv) / 255) as u8;
            let g = ((p[1] as u32 * a + 255 * inv) / 255) as u8;
            let b = ((p[2] as u32 * a + 255 * inv) / 255) as u8;
            canvas.put_pixel(x, y, Rgb([r, g, b]));
        }
    }
    let mut png_bytes = Cursor::new(Vec::new());
    canvas.write_to(&mut png_bytes, ImageFormat::Png).ok()?;
    let b64 = base64::engine::general_purpose::STANDARD.encode(png_bytes.into_inner());
    Some(PreparedAvatar {
        base64: b64,
        format: "png".to_string(),
    })
}

fn download_and_prepare_avatar(raw_url: &str) -> Option<PreparedAvatar> {
    let parsed = url::Url::parse(raw_url.trim()).ok()?;
    if parsed.scheme() != "https" && parsed.scheme() != "http" {
        return None;
    }
    let host_lower = parsed.host_str().unwrap_or("").to_ascii_lowercase();
    let referer = if host_lower.contains("tiktok")
        || host_lower.contains("musical.ly")
        || host_lower.contains("byteimg")
    {
        Some("https://www.tiktok.com/")
    } else if host_lower.contains("bsky.app")
        || host_lower.contains("bsky.social")
        || host_lower.contains("bsky.network")
    {
        Some("https://bsky.app/")
    } else if host_lower.contains("threads") {
        Some("https://www.threads.com/")
    } else if host_lower.contains("instagram") || host_lower.contains("fbcdn") {
        Some("https://www.instagram.com/")
    } else if host_lower.contains("twimg.com") || host_lower.contains("x.com") {
        Some("https://x.com/")
    } else {
        None
    };

    #[cfg(windows)]
    {
        let mut headers = vec![
            ("Accept", "image/jpeg,image/png,image/webp,image/*,*/*;q=0.8"),
            (
                "User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/136.0.0.0 Safari/537.36",
            ),
        ];
        if let Some(r) = referer {
            headers.push(("Referer", r));
        }
        let (status, bytes) =
            crate::platform_win::winhttp_request_bytes("GET", parsed.as_str(), &headers, None, 6000)
                .ok()?;
        if status != 200 || bytes.is_empty() {
            return None;
        }
        resize_avatar_bytes_to_320_png(&bytes)
    }
    #[cfg(not(windows))]
    {
        let _ = referer;
        None
    }
}

fn post_system_one(
    api_key: &str,
    body: &Value,
    include_image_header: bool,
) -> Result<(u16, String), String> {
    let body_str = serde_json::to_string(body).map_err(|e| e.to_string())?;
    let auth = format!("Bearer {}", api_key.trim());
    let mut headers: Vec<(&str, &str)> = vec![
        ("Content-Type", "application/json"),
        ("Authorization", auth.as_str()),
    ];
    if include_image_header {
        headers.push(("TypeSafe-Danger-Zone-Images", "true"));
    }

    #[cfg(windows)]
    {
        let (status, bytes) = crate::platform_win::winhttp_request_bytes(
            "POST",
            JEV_ENDPOINT_URL,
            &headers,
            Some(body_str.as_bytes()),
            20000,
        )?;
        Ok((status, String::from_utf8_lossy(&bytes).to_string()))
    }
    #[cfg(not(windows))]
    {
        let _ = (headers, body_str);
        Err("Windows 環境専用です".to_string())
    }
}

fn push_recent_category(list: &mut Vec<String>, category: &str) {
    let norm = normalize_category(category);
    list.retain(|x| x.to_lowercase() != norm.to_lowercase());
    list.insert(0, norm);
    if list.len() > MAX_RECENT_CATEGORIES {
        list.truncate(MAX_RECENT_CATEGORIES);
    }
}

fn load_settings(path: &PathBuf) -> JevSettingsDisk {
    let Ok(raw) = fs::read_to_string(path) else {
        return JevSettingsDisk::default();
    };
    let mut disk: JevSettingsDisk = serde_json::from_str(&raw).unwrap_or_default();
    disk.category = normalize_category(&disk.category);
    disk.threshold = if disk.threshold.is_finite() {
        disk.threshold.clamp(0.35, 0.90)
    } else {
        DEFAULT_JEV_THRESHOLD
    };
    if disk.recent_categories.is_empty() {
        disk.recent_categories.push(disk.category.clone());
    }
    disk
}

fn save_settings(path: &PathBuf, settings: &JevSettingsDisk) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(json) = serde_json::to_string_pretty(settings) {
        let _ = fs::write(path, json);
    }
}

fn load_cache(path: &PathBuf) -> HashMap<String, CacheEntry> {
    let Ok(raw) = fs::read_to_string(path) else {
        return HashMap::new();
    };
    let parsed: HashMap<String, CacheEntry> = serde_json::from_str(&raw).unwrap_or_default();
    let now = now_unix_secs();
    parsed
        .into_iter()
        .filter(|(_, v)| v.p.is_finite() && now.saturating_sub(v.t) <= CACHE_MAX_AGE_SECS)
        .collect()
}

fn trim_and_save_cache(path: &PathBuf, cache: &mut HashMap<String, CacheEntry>) {
    if cache.len() > MAX_CACHE_ENTRIES {
        let mut entries: Vec<(String, CacheEntry)> = cache.drain().collect();
        entries.sort_by(|a, b| b.1.t.cmp(&a.1.t));
        entries.truncate(MAX_CACHE_ENTRIES);
        for (k, v) in entries {
            cache.insert(k, v);
        }
    }
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(json) = serde_json::to_string(cache) {
        let _ = fs::write(path, json);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn category_normalization_and_female_preset_detection() {
        assert_eq!(normalize_category("  "), DEFAULT_JEV_CATEGORY);
        assert_eq!(normalize_category("  カフェ\n巡り  "), "カフェ 巡り");
        assert!(is_female_preset_category("女の子"));
        assert!(is_female_preset_category("女性個人"));
        assert!(!is_female_preset_category("カフェ"));
        assert!(!is_female_preset_category("20代女性・カフェ好き"));
    }

    #[test]
    fn cache_key_separates_different_categories() {
        let c = JevAccountCandidate {
            username: "hanako_01".to_string(),
            display_name: "花子".to_string(),
            bio: "カフェ巡り".to_string(),
            avatar_url: "https://cdn.example.com/p/abc123.jpg?sig=1".to_string(),
            avatar_base64: None,
            avatar_format: None,
            platform: "instagram".to_string(),
        };
        assert_eq!(c.cache_key("女の子"), c.cache_key("女性"));
        assert_ne!(c.cache_key("女の子"), c.cache_key("カフェ"));
    }

    #[test]
    fn build_request_body_supports_female_and_custom_categories() {
        let batch = vec![JevAccountCandidate {
            username: "latte_tokyo".to_string(),
            display_name: "東京カフェ部".to_string(),
            bio: "渋谷・代官山のカフェを紹介".to_string(),
            avatar_url: String::new(),
            avatar_base64: None,
            avatar_format: None,
            platform: "instagram".to_string(),
        }];
        let mut avatars = HashMap::new();
        avatars.insert(
            0,
            PreparedAvatar {
                base64: "AAAA".repeat(16),
                format: "png".to_string(),
            },
        );

        let custom_body = build_request_body(&batch, "カフェ・グルメ", &avatars, "n1");
        let state = custom_body["state"].as_str().unwrap();
        assert!(state.contains("カフェ・グルメ"));
        assert!(state.contains("bio=\"渋谷・代官山のカフェを紹介\""));
        assert!(custom_body["assets"]["jevimg_n1_0"]["format"] == "png");
        assert!(custom_body["questions"]["q_0"]["instructions"]
            .as_str()
            .unwrap()
            .contains("カフェ・グルメ"));

        let female_body = build_request_body(&batch, "女の子", &avatars, "n2");
        assert!(female_body["state"]
            .as_str()
            .unwrap()
            .contains("FEMALE individual"));
    }

    #[test]
    fn parse_probabilities_handles_noul_and_fallback_map() {
        let batch = vec![
            JevAccountCandidate {
                username: "u1".into(),
                display_name: String::new(),
                bio: String::new(),
                avatar_url: String::new(),
                avatar_base64: None,
                avatar_format: None,
                platform: "instagram".into(),
            },
            JevAccountCandidate {
                username: "u2".into(),
                display_name: String::new(),
                bio: String::new(),
                avatar_url: String::new(),
                avatar_base64: None,
                avatar_format: None,
                platform: "tiktok".into(),
            },
        ];
        let resp = json!({
            "answers": {
                "q_0": { "noul": 0.88 },
                "q_1": { "probabilities": { "true": 0.21 } }
            }
        });
        let probs = parse_response_probabilities(&resp, &batch);
        assert!((probs["u1"] - 0.88).abs() < 1e-6);
        assert!((probs["u2"] - 0.21).abs() < 1e-6);
    }

    #[test]
    fn solid_png_and_resize_pipeline_produces_320_png() {
        let png = make_solid_png(64, 48);
        let prepared = resize_avatar_bytes_to_320_png(&png).expect("resize must succeed");
        assert_eq!(prepared.format, "png");
        let decoded_bytes = base64::engine::general_purpose::STANDARD
            .decode(&prepared.base64)
            .unwrap();
        let img = image::load_from_memory(&decoded_bytes).unwrap();
        assert_eq!(img.dimensions(), (320, 320));
    }
}
