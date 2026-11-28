use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

pub const GIST_FILENAME: &str = "omnisns-follow-sync.json";
pub const MAX_EVENT_RETENTION_SECS: u64 = 7 * 24 * 3600 + 3600;
pub const MAX_EVENTS_PER_DEVICE: usize = 4000;

pub fn now_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn prune_event_timestamps(events: &mut Vec<u64>, min_exclusive: u64, retention_cutoff: u64) {
    events.retain(|&t| t > min_exclusive && t >= retention_cutoff);
    events.sort_unstable();
    if events.len() > MAX_EVENTS_PER_DEVICE {
        let drop_n = events.len() - MAX_EVENTS_PER_DEVICE;
        events.drain(0..drop_n);
    }
}

pub fn count_events_in_window(events: &[u64], min_exclusive: u64, cutoff: u64) -> usize {
    events
        .iter()
        .filter(|&&t| t > min_exclusive && t >= cutoff)
        .count()
}

/// 指定ウィンドウ内で有効なイベント群から `(次の1件が減少する UNIX 秒, 全件リセットされて 0 になる UNIX 秒)` を算出する。
pub fn window_event_reset_bounds(
    events: &[u64],
    min_exclusive: u64,
    cutoff: u64,
    window_secs: u64,
) -> (Option<u64>, Option<u64>) {
    let mut oldest: Option<u64> = None;
    let mut newest: Option<u64> = None;
    for &t in events {
        if t > min_exclusive && t >= cutoff {
            oldest = Some(oldest.map_or(t, |cur| cur.min(t)));
            newest = Some(newest.map_or(t, |cur| cur.max(t)));
        }
    }
    (
        oldest.map(|t| t.saturating_add(window_secs)),
        newest.map(|t| t.saturating_add(window_secs)),
    )
}

pub fn normalize_account_handle(raw: &str) -> Option<String> {
    let clean = raw.trim().trim_start_matches('@').to_lowercase();
    if clean.is_empty() || clean.len() > 64 {
        return None;
    }
    if clean
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | ':'))
    {
        Some(clean)
    } else {
        None
    }
}

pub fn make_account_sync_key(service_id: &str, handle: &str) -> Option<String> {
    let norm = normalize_account_handle(handle)?;
    let svc = service_id.trim().to_lowercase();
    if svc.is_empty() {
        return None;
    }
    Some(format!("{svc}:{norm}"))
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct DeviceFollowEntry {
    #[serde(default)]
    pub today: i32,
    #[serde(default)]
    pub total: i32,
    #[serde(default)]
    pub today_epoch: u64,
    #[serde(default)]
    pub total_epoch: u64,
    #[serde(default)]
    pub unfollow_today: i32,
    #[serde(default)]
    pub unfollow_total: i32,
    #[serde(default)]
    pub unfollow_today_epoch: u64,
    #[serde(default)]
    pub unfollow_total_epoch: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub follow_events: Vec<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub follow_deductions: Vec<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unfollow_events: Vec<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unfollow_deductions: Vec<u64>,
    #[serde(default)]
    pub updated_at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct AccountFollowLedger {
    #[serde(default)]
    pub date: String,
    #[serde(default)]
    pub reset_epoch: u64,
    #[serde(default)]
    pub total_reset_epoch: u64,
    #[serde(default)]
    pub unfollow_reset_epoch: u64,
    #[serde(default)]
    pub unfollow_total_reset_epoch: u64,
    #[serde(default)]
    pub follow_reset_at: u64,
    #[serde(default)]
    pub unfollow_reset_at: u64,
    #[serde(default)]
    pub devices: HashMap<String, DeviceFollowEntry>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sns_following: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sns_followers: Option<u32>,
    #[serde(default)]
    pub sns_updated_at: u64,
}

pub fn is_valid_ymd(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return false;
    }
    if !(b[0..4].iter().all(|c| c.is_ascii_digit())
        && b[5..7].iter().all(|c| c.is_ascii_digit())
        && b[8..10].iter().all(|c| c.is_ascii_digit()))
    {
        return false;
    }
    let Ok(year) = s[0..4].parse::<u32>() else {
        return false;
    };
    let Ok(month) = s[5..7].parse::<u32>() else {
        return false;
    };
    let Ok(day) = s[8..10].parse::<u32>() else {
        return false;
    };
    if year < 1970 || !(1..=12).contains(&month) {
        return false;
    }
    let max_day = days_in_month(year, month);
    (1..=max_day).contains(&day)
}

fn days_in_month(year: u32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0) {
                29
            } else {
                28
            }
        }
        _ => 0,
    }
}

pub fn next_ymd(ymd: &str) -> Option<String> {
    if !is_valid_ymd(ymd) {
        return None;
    }
    let mut year: u32 = ymd[0..4].parse().ok()?;
    let mut month: u32 = ymd[5..7].parse().ok()?;
    let mut day: u32 = ymd[8..10].parse().ok()?;
    day += 1;
    if day > days_in_month(year, month) {
        day = 1;
        month += 1;
        if month > 12 {
            month = 1;
            year = year.checked_add(1)?;
        }
    }
    Some(format!("{year:04}-{month:02}-{day:02}"))
}

/// GitHub Personal Access Token の形式検証（CRLF ヘッダインジェクション・不正文字防止）。
/// エラーメッセージにトークン本体を含めない。
pub fn validate_github_token(raw: &str) -> Result<&str, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("GitHub Personal Access Token（gist 権限）を入力してください".to_string());
    }
    if trimmed.len() > 512
        || trimmed
            .bytes()
            .any(|b| !b.is_ascii() || b <= 0x20 || b >= 0x7F)
    {
        return Err(
            "GitHub Token に使用できない文字（改行・空白・全角文字など）が含まれています"
                .to_string(),
        );
    }
    Ok(trimmed)
}

/// GitHub Gist ID の形式検証（パストラバーサル / 任意 API エンドポイント送信防止）。
/// 空文字列は新規自動作成として許可する。
pub fn validate_gist_id(raw: &str) -> Result<&str, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok("");
    }
    if trimmed.len() > 64
        || !trimmed
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return Err("Gist ID の形式が不正です（半角英数字のみ指定してください）".to_string());
    }
    Ok(trimmed)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteGistFileState {
    Missing,
    Content(String),
    Truncated { raw_url: Option<String> },
}

pub fn extract_remote_gist_file(get_resp: &str) -> Result<RemoteGistFileState, String> {
    let remote_val: serde_json::Value =
        serde_json::from_str(get_resp).map_err(|e| format!("Gist応答の解析に失敗: {e}"))?;
    let Some(file_obj) = remote_val
        .get("files")
        .and_then(|f| f.get(GIST_FILENAME))
        .and_then(|f| f.as_object())
    else {
        return Ok(RemoteGistFileState::Missing);
    };

    if file_obj
        .get("truncated")
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
    {
        let raw_url = file_obj
            .get("raw_url")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        return Ok(RemoteGistFileState::Truncated { raw_url });
    }

    match file_obj.get("content").and_then(|c| c.as_str()) {
        Some(content) => Ok(RemoteGistFileState::Content(content.to_string())),
        None => Ok(RemoteGistFileState::Missing),
    }
}

pub fn parse_remote_ledger_content(content: &str) -> Result<FollowSyncLedger, String> {
    if content.trim().is_empty() {
        return Ok(FollowSyncLedger::default());
    }
    serde_json::from_str::<FollowSyncLedger>(content).map_err(|_| {
        "リモート Gist の同期データが破損しているため上書きを中断しました（データ保護）"
            .to_string()
    })
}

impl AccountFollowLedger {
    pub fn roll_date(&mut self, today: &str) {
        let max_allowed = next_ymd(today).unwrap_or_else(|| today.to_string());
        if !is_valid_ymd(&self.date)
            || self.date.as_str() < today
            || self.date.as_str() > max_allowed.as_str()
        {
            self.date = today.to_string();
            for entry in self.devices.values_mut() {
                entry.today = 0;
                entry.today_epoch = self.reset_epoch;
                entry.unfollow_today = 0;
                entry.unfollow_today_epoch = self.unfollow_reset_epoch;
            }
        }
    }

    #[allow(dead_code)]
    pub fn effective_counts(&self, today: &str) -> (u32, u32) {
        // タイムゾーン差や数分の時計ズレ（+1日以内）で当日カウントを凍結させない一方、
        // 異常な未来日付（> today+1日）による永続汚染は無効化する。
        let max_allowed = next_ymd(today).unwrap_or_else(|| today.to_string());
        let same_day = is_valid_ymd(&self.date)
            && self.date.as_str() >= today
            && self.date.as_str() <= max_allowed.as_str();
        let mut sum_today: i64 = 0;
        let mut sum_total: i64 = 0;
        for entry in self.devices.values() {
            if same_day && entry.today_epoch >= self.reset_epoch {
                sum_today += entry.today as i64;
            }
            if entry.total_epoch >= self.total_reset_epoch {
                sum_total += entry.total as i64;
            }
        }
        (
            sum_today.clamp(0, u32::MAX as i64) as u32,
            sum_total.clamp(0, u32::MAX as i64) as u32,
        )
    }

    #[allow(dead_code)]
    pub fn effective_unfollow_counts(&self, today: &str) -> (u32, u32) {
        let max_allowed = next_ymd(today).unwrap_or_else(|| today.to_string());
        let same_day = is_valid_ymd(&self.date)
            && self.date.as_str() >= today
            && self.date.as_str() <= max_allowed.as_str();
        let mut sum_today: i64 = 0;
        let mut sum_total: i64 = 0;
        for entry in self.devices.values() {
            if same_day && entry.unfollow_today_epoch >= self.unfollow_reset_epoch {
                sum_today += entry.unfollow_today as i64;
            }
            if entry.unfollow_total_epoch >= self.unfollow_total_reset_epoch {
                sum_total += entry.unfollow_total as i64;
            }
        }
        (
            sum_today.clamp(0, u32::MAX as i64) as u32,
            sum_total.clamp(0, u32::MAX as i64) as u32,
        )
    }

    /// 指定時間内（直近 `window_hours` 時間）の合算フォロー数を返す。
    pub fn effective_window_follow_count(&self, now_secs: u64, window_hours: u32) -> u32 {
        let hours = window_hours.clamp(1, 168) as u64;
        let cutoff = now_secs.saturating_sub(hours * 3600);
        let reset_at = self.follow_reset_at;
        let mut sum: i64 = 0;
        for entry in self.devices.values() {
            let has_events = !entry.follow_events.is_empty() || !entry.follow_deductions.is_empty();
            if has_events {
                sum += count_events_in_window(&entry.follow_events, reset_at, cutoff) as i64;
                sum -= count_events_in_window(&entry.follow_deductions, reset_at, cutoff) as i64;
            } else if entry.today > 0
                && entry.today_epoch >= self.reset_epoch
                && entry.updated_at > reset_at
                && entry.updated_at >= cutoff
            {
                // 旧バージョン端末（タイムスタンプ配列未対応）からの同期データを優雅に集計
                sum += entry.today as i64;
            }
        }
        sum.clamp(0, u32::MAX as i64) as u32
    }

    /// 指定時間内（直近 `window_hours` 時間）の合算アンフォロー（解除）数を返す。
    pub fn effective_window_unfollow_count(&self, now_secs: u64, window_hours: u32) -> u32 {
        let hours = window_hours.clamp(1, 168) as u64;
        let cutoff = now_secs.saturating_sub(hours * 3600);
        let reset_at = self.unfollow_reset_at;
        let mut sum: i64 = 0;
        for entry in self.devices.values() {
            let has_events =
                !entry.unfollow_events.is_empty() || !entry.unfollow_deductions.is_empty();
            if has_events {
                sum += count_events_in_window(&entry.unfollow_events, reset_at, cutoff) as i64;
                sum -= count_events_in_window(&entry.unfollow_deductions, reset_at, cutoff) as i64;
            } else if entry.unfollow_today > 0
                && entry.unfollow_today_epoch >= self.unfollow_reset_epoch
                && entry.updated_at > reset_at
                && entry.updated_at >= cutoff
            {
                sum += entry.unfollow_today as i64;
            }
        }
        sum.clamp(0, u32::MAX as i64) as u32
    }

    /// 指定時間内（直近 `window_hours` 時間）のフォローカウントについて、
    /// `(次の1件が減少する UNIX 秒, 全件リセットされて 0 になる UNIX 秒)` を返す。
    pub fn effective_window_follow_reset_times(
        &self,
        now_secs: u64,
        window_hours: u32,
    ) -> (Option<u64>, Option<u64>) {
        let window_secs = window_hours.clamp(1, 168) as u64 * 3600;
        let cutoff = now_secs.saturating_sub(window_secs);
        let reset_at = self.follow_reset_at;
        let mut active: Vec<u64> = Vec::new();
        let mut total_deductions: usize = 0;
        for entry in self.devices.values() {
            let has_events = !entry.follow_events.is_empty() || !entry.follow_deductions.is_empty();
            if has_events {
                for &t in &entry.follow_events {
                    if t > reset_at && t >= cutoff {
                        active.push(t);
                    }
                }
                total_deductions = total_deductions.saturating_add(count_events_in_window(
                    &entry.follow_deductions,
                    reset_at,
                    cutoff,
                ));
            } else if entry.today > 0
                && entry.today_epoch >= self.reset_epoch
                && entry.updated_at > reset_at
                && entry.updated_at >= cutoff
            {
                let n = (entry.today as usize).min(1000);
                active.resize(active.len() + n, entry.updated_at);
            }
        }
        if active.is_empty() || total_deductions >= active.len() {
            return (None, None);
        }
        active.sort_unstable();
        if total_deductions > 0 {
            let keep = active.len() - total_deductions;
            active.truncate(keep);
        }
        let next_at = active.first().map(|&t| t.saturating_add(window_secs));
        let full_at = active.last().map(|&t| t.saturating_add(window_secs));
        (next_at, full_at)
    }

    /// 指定時間内（直近 `window_hours` 時間）のアンフォローカウントについて、
    /// `(次の1件が減少する UNIX 秒, 全件リセットされて 0 になる UNIX 秒)` を返す。
    pub fn effective_window_unfollow_reset_times(
        &self,
        now_secs: u64,
        window_hours: u32,
    ) -> (Option<u64>, Option<u64>) {
        let window_secs = window_hours.clamp(1, 168) as u64 * 3600;
        let cutoff = now_secs.saturating_sub(window_secs);
        let reset_at = self.unfollow_reset_at;
        let mut active: Vec<u64> = Vec::new();
        let mut total_deductions: usize = 0;
        for entry in self.devices.values() {
            let has_events =
                !entry.unfollow_events.is_empty() || !entry.unfollow_deductions.is_empty();
            if has_events {
                for &t in &entry.unfollow_events {
                    if t > reset_at && t >= cutoff {
                        active.push(t);
                    }
                }
                total_deductions = total_deductions.saturating_add(count_events_in_window(
                    &entry.unfollow_deductions,
                    reset_at,
                    cutoff,
                ));
            } else if entry.unfollow_today > 0
                && entry.unfollow_today_epoch >= self.unfollow_reset_epoch
                && entry.updated_at > reset_at
                && entry.updated_at >= cutoff
            {
                let n = (entry.unfollow_today as usize).min(1000);
                active.resize(active.len() + n, entry.updated_at);
            }
        }
        if active.is_empty() || total_deductions >= active.len() {
            return (None, None);
        }
        active.sort_unstable();
        if total_deductions > 0 {
            let keep = active.len() - total_deductions;
            active.truncate(keep);
        }
        let next_at = active.first().map(|&t| t.saturating_add(window_secs));
        let full_at = active.last().map(|&t| t.saturating_add(window_secs));
        (next_at, full_at)
    }

    pub fn max_follow_event_ts(&self) -> u64 {
        let mut mx = self.follow_reset_at;
        for entry in self.devices.values() {
            if let Some(&t) = entry.follow_events.iter().max() {
                mx = mx.max(t);
            }
            if let Some(&t) = entry.follow_deductions.iter().max() {
                mx = mx.max(t);
            }
            if entry.follow_events.is_empty() && entry.today > 0 {
                mx = mx.max(entry.updated_at);
            }
        }
        mx
    }

    pub fn max_unfollow_event_ts(&self) -> u64 {
        let mut mx = self.unfollow_reset_at;
        for entry in self.devices.values() {
            if let Some(&t) = entry.unfollow_events.iter().max() {
                mx = mx.max(t);
            }
            if let Some(&t) = entry.unfollow_deductions.iter().max() {
                mx = mx.max(t);
            }
            if entry.unfollow_events.is_empty() && entry.unfollow_today > 0 {
                mx = mx.max(entry.updated_at);
            }
        }
        mx
    }

    /// 相手側のレジャーを競合なくマージする。ローカルに変化があれば true。
    pub fn merge_from(&mut self, other: &AccountFollowLedger, today: &str) -> bool {
        let mut changed = false;

        // 異常な未来日付による永続汚染を防ぐため、許可する最大日付を today + 1日 に制限する
        let max_allowed = next_ymd(today).unwrap_or_else(|| today.to_string());
        let valid_self_date = is_valid_ymd(&self.date) && self.date.as_str() <= max_allowed.as_str();
        let valid_other_date =
            is_valid_ymd(&other.date) && other.date.as_str() <= max_allowed.as_str();

        let target_date = [
            if valid_self_date {
                Some(self.date.as_str())
            } else {
                None
            },
            if valid_other_date {
                Some(other.date.as_str())
            } else {
                None
            },
            if is_valid_ymd(today) {
                Some(today)
            } else {
                None
            },
        ]
        .into_iter()
        .flatten()
        .max()
        .unwrap_or(today)
        .to_string();

        if self.date != target_date {
            if !valid_self_date || self.date.as_str() < target_date.as_str() {
                for entry in self.devices.values_mut() {
                    entry.today = 0;
                    entry.today_epoch = self.reset_epoch;
                    entry.unfollow_today = 0;
                    entry.unfollow_today_epoch = self.unfollow_reset_epoch;
                }
            }
            self.date = target_date.clone();
            changed = true;
        }

        if other.reset_epoch > self.reset_epoch {
            self.reset_epoch = other.reset_epoch;
            for entry in self.devices.values_mut() {
                if entry.today_epoch < self.reset_epoch {
                    entry.today = 0;
                    entry.today_epoch = self.reset_epoch;
                }
            }
            changed = true;
        }

        if other.total_reset_epoch > self.total_reset_epoch {
            self.total_reset_epoch = other.total_reset_epoch;
            for entry in self.devices.values_mut() {
                if entry.total_epoch < self.total_reset_epoch {
                    entry.total = 0;
                    entry.total_epoch = self.total_reset_epoch;
                }
            }
            changed = true;
        }

        if other.unfollow_reset_epoch > self.unfollow_reset_epoch {
            self.unfollow_reset_epoch = other.unfollow_reset_epoch;
            for entry in self.devices.values_mut() {
                if entry.unfollow_today_epoch < self.unfollow_reset_epoch {
                    entry.unfollow_today = 0;
                    entry.unfollow_today_epoch = self.unfollow_reset_epoch;
                }
            }
            changed = true;
        }

        if other.unfollow_total_reset_epoch > self.unfollow_total_reset_epoch {
            self.unfollow_total_reset_epoch = other.unfollow_total_reset_epoch;
            for entry in self.devices.values_mut() {
                if entry.unfollow_total_epoch < self.unfollow_total_reset_epoch {
                    entry.unfollow_total = 0;
                    entry.unfollow_total_epoch = self.unfollow_total_reset_epoch;
                }
            }
            changed = true;
        }

        if other.follow_reset_at > self.follow_reset_at {
            self.follow_reset_at = other.follow_reset_at;
            for entry in self.devices.values_mut() {
                entry.follow_events.retain(|&t| t > self.follow_reset_at);
                entry
                    .follow_deductions
                    .retain(|&t| t > self.follow_reset_at);
            }
            changed = true;
        }

        if other.unfollow_reset_at > self.unfollow_reset_at {
            self.unfollow_reset_at = other.unfollow_reset_at;
            for entry in self.devices.values_mut() {
                entry
                    .unfollow_events
                    .retain(|&t| t > self.unfollow_reset_at);
                entry
                    .unfollow_deductions
                    .retain(|&t| t > self.unfollow_reset_at);
            }
            changed = true;
        }

        let other_same_day = valid_other_date && other.date == target_date;
        for (dev_id, remote_entry) in &other.devices {
            let mut normalized = remote_entry.clone();
            if !other_same_day || normalized.today_epoch < self.reset_epoch {
                normalized.today = 0;
                normalized.today_epoch = self.reset_epoch;
            }
            if normalized.total_epoch < self.total_reset_epoch {
                normalized.total = 0;
                normalized.total_epoch = self.total_reset_epoch;
            }
            if !other_same_day || normalized.unfollow_today_epoch < self.unfollow_reset_epoch {
                normalized.unfollow_today = 0;
                normalized.unfollow_today_epoch = self.unfollow_reset_epoch;
            }
            if normalized.unfollow_total_epoch < self.unfollow_total_reset_epoch {
                normalized.unfollow_total = 0;
                normalized.unfollow_total_epoch = self.unfollow_total_reset_epoch;
            }
            normalized
                .follow_events
                .retain(|&t| t > self.follow_reset_at);
            normalized.follow_events.sort_unstable();
            normalized
                .follow_deductions
                .retain(|&t| t > self.follow_reset_at);
            normalized.follow_deductions.sort_unstable();
            normalized
                .unfollow_events
                .retain(|&t| t > self.unfollow_reset_at);
            normalized.unfollow_events.sort_unstable();
            normalized
                .unfollow_deductions
                .retain(|&t| t > self.unfollow_reset_at);
            normalized.unfollow_deductions.sort_unstable();

            match self.devices.get_mut(dev_id) {
                Some(local_entry) => {
                    if normalized.updated_at > local_entry.updated_at {
                        if *local_entry != normalized {
                            *local_entry = normalized;
                            changed = true;
                        }
                    } else if normalized.updated_at == local_entry.updated_at {
                        // 同一秒タイムスタンプのタイブレークはフィールド単位で大きい側を採用し、他フィールドの後退を防ぐ
                        let mut merged_entry = local_entry.clone();
                        if normalized.today_epoch > merged_entry.today_epoch {
                            merged_entry.today_epoch = normalized.today_epoch;
                            merged_entry.today = normalized.today;
                        } else if normalized.today_epoch == merged_entry.today_epoch
                            && normalized.today > merged_entry.today
                        {
                            merged_entry.today = normalized.today;
                        }
                        if normalized.total_epoch > merged_entry.total_epoch {
                            merged_entry.total_epoch = normalized.total_epoch;
                            merged_entry.total = normalized.total;
                        } else if normalized.total_epoch == merged_entry.total_epoch
                            && normalized.total > merged_entry.total
                        {
                            merged_entry.total = normalized.total;
                        }
                        if normalized.unfollow_today_epoch > merged_entry.unfollow_today_epoch {
                            merged_entry.unfollow_today_epoch = normalized.unfollow_today_epoch;
                            merged_entry.unfollow_today = normalized.unfollow_today;
                        } else if normalized.unfollow_today_epoch
                            == merged_entry.unfollow_today_epoch
                            && normalized.unfollow_today > merged_entry.unfollow_today
                        {
                            merged_entry.unfollow_today = normalized.unfollow_today;
                        }
                        if normalized.unfollow_total_epoch > merged_entry.unfollow_total_epoch {
                            merged_entry.unfollow_total_epoch = normalized.unfollow_total_epoch;
                            merged_entry.unfollow_total = normalized.unfollow_total;
                        } else if normalized.unfollow_total_epoch
                            == merged_entry.unfollow_total_epoch
                            && normalized.unfollow_total > merged_entry.unfollow_total
                        {
                            merged_entry.unfollow_total = normalized.unfollow_total;
                        }
                        if normalized.follow_events.len() > merged_entry.follow_events.len() {
                            merged_entry.follow_events = normalized.follow_events;
                        }
                        if normalized.follow_deductions.len() > merged_entry.follow_deductions.len()
                        {
                            merged_entry.follow_deductions = normalized.follow_deductions;
                        }
                        if normalized.unfollow_events.len() > merged_entry.unfollow_events.len() {
                            merged_entry.unfollow_events = normalized.unfollow_events;
                        }
                        if normalized.unfollow_deductions.len()
                            > merged_entry.unfollow_deductions.len()
                        {
                            merged_entry.unfollow_deductions = normalized.unfollow_deductions;
                        }
                        if *local_entry != merged_entry {
                            *local_entry = merged_entry;
                            changed = true;
                        }
                    }
                }
                None => {
                    self.devices.insert(dev_id.clone(), normalized);
                    changed = true;
                }
            }
        }

        if other.sns_updated_at > self.sns_updated_at
            || (other.sns_updated_at == self.sns_updated_at
                && ((self.sns_following.is_none() && other.sns_following.is_some())
                    || (self.sns_followers.is_none() && other.sns_followers.is_some())))
        {
            let next_flwng = other.sns_following.or(self.sns_following);
            let next_flwrs = other.sns_followers.or(self.sns_followers);
            if self.sns_following != next_flwng
                || self.sns_followers != next_flwrs
                || self.sns_updated_at != other.sns_updated_at
            {
                self.sns_following = next_flwng;
                self.sns_followers = next_flwrs;
                self.sns_updated_at = other.sns_updated_at;
                changed = true;
            }
        }

        changed
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct FollowSyncLedger {
    #[serde(default = "default_ledger_version")]
    pub version: u32,
    #[serde(default)]
    pub accounts: HashMap<String, AccountFollowLedger>,
}

fn default_ledger_version() -> u32 {
    1
}

impl Default for FollowSyncLedger {
    fn default() -> Self {
        Self {
            version: 1,
            accounts: HashMap::new(),
        }
    }
}

impl FollowSyncLedger {
    pub fn merge_from(&mut self, other: &FollowSyncLedger, today: &str) -> bool {
        let mut changed = false;
        for (key, remote_acc) in &other.accounts {
            match self.accounts.get_mut(key) {
                Some(local_acc) => {
                    if local_acc.merge_from(remote_acc, today) {
                        changed = true;
                    }
                }
                None => {
                    let mut fresh = AccountFollowLedger::default();
                    fresh.merge_from(remote_acc, today);
                    self.accounts.insert(key.clone(), fresh);
                    changed = true;
                }
            }
        }
        changed
    }

    /// 相手側にローカルより古い／不足しているデータがあるかを判定する（返信要否の判定用）。
    pub fn has_newer_data_than(&self, other: &FollowSyncLedger, today: &str) -> bool {
        let mut probe = other.clone();
        probe.merge_from(self, today)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct FollowSyncSettings {
    #[serde(default)]
    pub device_id: String,
    #[serde(default)]
    pub github_token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub github_token_encrypted: Option<String>,
    #[serde(default)]
    pub gist_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_sync_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_sync_status: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateFollowSyncPatch {
    pub github_token: Option<String>,
    pub gist_id: Option<String>,
}

/// GitHub 非公開 Gist を使ったクラウド同期（4G/5G 外出先対応）。
/// `gist_id` が空の場合は自動で非公開 Gist を新規作成してその ID を返す。
#[cfg(windows)]
pub fn sync_with_github_gist(
    token: &str,
    gist_id: &str,
    local_ledger: &FollowSyncLedger,
    today: &str,
) -> Result<(String, FollowSyncLedger, bool), String> {
    let token_trimmed = validate_github_token(token)?;
    let trimmed_id = validate_gist_id(gist_id)?;
    let auth_header = format!("Bearer {token_trimmed}");
    let base_headers = [
        ("Authorization", auth_header.as_str()),
        ("Accept", "application/vnd.github+json"),
        ("X-GitHub-Api-Version", "2022-11-28"),
        ("Content-Type", "application/json; charset=utf-8"),
    ];

    let mut merged = local_ledger.clone();

    if trimmed_id.is_empty() {
        let content_str = serde_json::to_string_pretty(&merged)
            .map_err(|e| format!("JSON生成に失敗しました: {e}"))?;
        let payload = serde_json::json!({
            "description": "OmniSNS Follow Counter Sync (Private)",
            "public": false,
            "files": {
                GIST_FILENAME: { "content": content_str }
            }
        })
        .to_string();
        let (status, resp) = crate::platform_win::winhttp_json_request(
            "POST",
            "api.github.com",
            "/gists",
            &base_headers,
            Some(&payload),
        )?;
        if !(200..300).contains(&status) {
            return Err(format!("GitHub Gist の作成に失敗しました (HTTP {status})"));
        }
        let parsed: serde_json::Value =
            serde_json::from_str(&resp).map_err(|e| format!("応答の解析に失敗: {e}"))?;
        let created_id = parsed
            .get("id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "作成された Gist ID を取得できませんでした".to_string())?;
        let created_id = validate_gist_id(created_id)?.to_string();
        if created_id.is_empty() {
            return Err("作成された Gist ID を取得できませんでした".to_string());
        }
        return Ok((created_id, merged, false));
    }

    // 1. 既存 Gist を取得してマージ
    let path = format!("/gists/{trimmed_id}");
    let (get_status, get_resp) = crate::platform_win::winhttp_json_request(
        "GET",
        "api.github.com",
        &path,
        &base_headers,
        None,
    )?;
    if get_status == 404 {
        return Err("指定された Gist ID が見つかりません（空欄で自動作成できます）".to_string());
    }
    if !(200..300).contains(&get_status) {
        return Err(format!("GitHub Gist の取得に失敗しました (HTTP {get_status})"));
    }

    let file_state = extract_remote_gist_file(&get_resp)?;
    let (remote_missing, remote_content_opt) = match file_state {
        RemoteGistFileState::Missing => (true, None),
        RemoteGistFileState::Content(c) => (false, Some(c)),
        RemoteGistFileState::Truncated { raw_url } => {
            // GitHub Gist のファイルが大きすぎて API 応答が省略された場合、raw_url から全文取得を試みる。
            // 取得できなければ既存データ保護のため絶対に PATCH 上書きせずエラーで中断する。
            let Some(url_str) = raw_url else {
                return Err(
                    "リモート Gist が省略されたためデータ保護のため同期を中断しました".to_string(),
                );
            };
            let parsed_raw = url::Url::parse(&url_str)
                .map_err(|_| "リモート Gist raw_url の解析に失敗しました".to_string())?;
            let expected_raw_segment = format!("/{trimmed_id}/raw/");
            if parsed_raw.scheme() != "https"
                || parsed_raw.host_str() != Some("gist.githubusercontent.com")
                || parsed_raw.port().is_some()
                || !parsed_raw.username().is_empty()
                || parsed_raw.password().is_some()
                || !parsed_raw.path().contains(&expected_raw_segment)
            {
                return Err("信頼できない raw_url ホストまたはパスのため同期を中断しました".to_string());
            }
            let raw_path = match parsed_raw.query() {
                Some(q) => format!("{}?{q}", parsed_raw.path()),
                None => parsed_raw.path().to_string(),
            };
            // gist.githubusercontent.com の raw_url は署名済み/機能 URL であり API トークン不要。
            // CDN ドメインへ GitHub PAT を送信しない。
            let (raw_status, raw_body) = crate::platform_win::winhttp_json_request(
                "GET",
                "gist.githubusercontent.com",
                &raw_path,
                &[],
                None,
            )?;
            if !(200..300).contains(&raw_status) {
                return Err(format!(
                    "省略された Gist 本文の取得に失敗しました (HTTP {raw_status})"
                ));
            }
            (false, Some(raw_body))
        }
    };

    let mut remote_ledger = FollowSyncLedger::default();
    let mut local_changed = false;
    if let Some(content) = remote_content_opt {
        remote_ledger = parse_remote_ledger_content(&content)?;
        local_changed = merged.merge_from(&remote_ledger, today);
    }

    // 2. ローカル側にリモートより新しいデータがあれば PATCH で反映
    if merged.has_newer_data_than(&remote_ledger, today) || remote_missing {
        let content_str = serde_json::to_string_pretty(&merged)
            .map_err(|e| format!("JSON生成に失敗しました: {e}"))?;
        let patch_body = serde_json::json!({
            "files": {
                GIST_FILENAME: { "content": content_str }
            }
        })
        .to_string();
        let (patch_status, _) = crate::platform_win::winhttp_json_request(
            "PATCH",
            "api.github.com",
            &path,
            &base_headers,
            Some(&patch_body),
        )?;
        if !(200..300).contains(&patch_status) {
            return Err(format!(
                "GitHub Gist の更新に失敗しました (HTTP {patch_status})"
            ));
        }
    }

    Ok((trimmed_id.to_string(), merged, local_changed))
}

#[cfg(not(windows))]
pub fn sync_with_github_gist(
    token: &str,
    gist_id: &str,
    _local_ledger: &FollowSyncLedger,
    _today: &str,
) -> Result<(String, FollowSyncLedger, bool), String> {
    let _ = validate_github_token(token)?;
    let _ = validate_gist_id(gist_id)?;
    Err("このOSではWinHTTPクラウド同期は未対応です".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crdt_merge_sums_pc_and_android_without_double_count() {
        let today = "2026-11-23";
        let mut pc = FollowSyncLedger::default();
        let mut acc_pc = AccountFollowLedger {
            date: today.to_string(),
            sns_following: Some(120),
            sns_followers: Some(340),
            sns_updated_at: 100,
            ..Default::default()
        };
        acc_pc.devices.insert(
            "win-1111".to_string(),
            DeviceFollowEntry {
                today: 12,
                total: 40,
                today_epoch: 0,
                total_epoch: 0,
                unfollow_today: 2,
                unfollow_total: 10,
                unfollow_today_epoch: 0,
                unfollow_total_epoch: 0,
                updated_at: 100,
                ..Default::default()
            },
        );
        pc.accounts.insert("instagram:darksan560".to_string(), acc_pc);

        let mut android = FollowSyncLedger::default();
        let mut acc_and = AccountFollowLedger {
            date: today.to_string(),
            sns_following: Some(128),
            sns_followers: Some(345),
            sns_updated_at: 200,
            ..Default::default()
        };
        acc_and.devices.insert(
            "and-2222".to_string(),
            DeviceFollowEntry {
                today: 8,
                total: 25,
                today_epoch: 0,
                total_epoch: 0,
                unfollow_today: 3,
                unfollow_total: 7,
                unfollow_today_epoch: 0,
                unfollow_total_epoch: 0,
                updated_at: 200,
                ..Default::default()
            },
        );
        android
            .accounts
            .insert("instagram:darksan560".to_string(), acc_and);

        assert!(pc.merge_from(&android, today));
        // Idempotent second merge
        assert!(!pc.merge_from(&android, today));

        let merged = pc.accounts.get("instagram:darksan560").unwrap();
        assert_eq!(merged.effective_counts(today), (20, 65));
        assert_eq!(merged.effective_unfollow_counts(today), (5, 17));
        assert_eq!(merged.sns_following, Some(128));
        assert_eq!(merged.sns_followers, Some(345));
    }

    #[test]
    fn crdt_merge_propagates_reset_epoch_and_date_rollover() {
        let mut a = FollowSyncLedger::default();
        let mut acc_a = AccountFollowLedger {
            date: "2026-11-23".to_string(),
            reset_epoch: 0,
            total_reset_epoch: 0,
            ..Default::default()
        };
        acc_a.devices.insert(
            "win-1".to_string(),
            DeviceFollowEntry {
                today: 10,
                total: 50,
                today_epoch: 0,
                total_epoch: 0,
                updated_at: 100,
                ..Default::default()
            },
        );
        a.accounts.insert("threads:darksan560".to_string(), acc_a);

        // Android resets today (reset_epoch = 1) and adds 3 new follows
        let mut b = FollowSyncLedger::default();
        let mut acc_b = AccountFollowLedger {
            date: "2026-11-23".to_string(),
            reset_epoch: 1,
            total_reset_epoch: 0,
            ..Default::default()
        };
        acc_b.devices.insert(
            "and-2".to_string(),
            DeviceFollowEntry {
                today: 3,
                total: 15,
                today_epoch: 1,
                total_epoch: 0,
                updated_at: 200,
                ..Default::default()
            },
        );
        b.accounts.insert("threads:darksan560".to_string(), acc_b);

        a.merge_from(&b, "2026-11-23");
        let acc = a.accounts.get("threads:darksan560").unwrap();
        // Old epoch today=10 was wiped by reset_epoch=1; new epoch today=3 kept; totals preserved (50+15)
        assert_eq!(acc.effective_counts("2026-11-23"), (3, 65));
        // Next day rollover zeroes today but keeps total
        assert_eq!(acc.effective_counts("2026-11-24"), (0, 65));
    }

    #[test]
    fn token_and_gist_id_validation_blocks_injection() {
        assert_eq!(validate_github_token("  ghp_abc123XYZ  "), Ok("ghp_abc123XYZ"));
        assert!(validate_github_token("").is_err());
        assert!(validate_github_token("ghp_abc\r\nX-Injected: 1").is_err());
        assert!(validate_github_token("ghp_abc\nfoo").is_err());
        assert!(validate_github_token("ghp_日本語").is_err());
        // Error message must never leak the token itself
        let err = validate_github_token("ghp_SECRET123\r\nEvil: 1").unwrap_err();
        assert!(!err.contains("ghp_SECRET123"));

        assert_eq!(validate_gist_id(""), Ok(""));
        assert_eq!(validate_gist_id("0123456789abcdef"), Ok("0123456789abcdef"));
        assert_eq!(validate_gist_id("gist_abc-123"), Ok("gist_abc-123"));
        assert!(validate_gist_id("../user").is_err());
        assert!(validate_gist_id("abc/comments").is_err());
        assert!(validate_gist_id("abc?foo=bar").is_err());
        assert!(validate_gist_id("abc#frag").is_err());
        assert!(validate_gist_id("abc def").is_err());
    }

    #[test]
    fn remote_gist_parsing_fails_closed_on_truncation_or_corruption() {
        let truncated_resp = r#"{"files":{"omnisns-follow-sync.json":{"truncated":true,"raw_url":"https://gist.githubusercontent.com/u/id/raw/omnisns-follow-sync.json","content":"{partial"}}}"#;
        assert_eq!(
            extract_remote_gist_file(truncated_resp).unwrap(),
            RemoteGistFileState::Truncated {
                raw_url: Some(
                    "https://gist.githubusercontent.com/u/id/raw/omnisns-follow-sync.json"
                        .to_string()
                )
            }
        );

        assert!(parse_remote_ledger_content("{corrupt json").is_err());
        assert_eq!(
            parse_remote_ledger_content("   ").unwrap(),
            FollowSyncLedger::default()
        );
    }

    #[test]
    fn crdt_date_validation_prevents_poisoning_and_timezone_freeze() {
        let mut local = AccountFollowLedger {
            date: "2026-11-23".to_string(),
            ..Default::default()
        };
        local.devices.insert(
            "win-1".to_string(),
            DeviceFollowEntry {
                today: 4,
                total: 10,
                updated_at: 100,
                ..Default::default()
            },
        );

        // Corrupt or far-future date must NOT poison local.date
        let corrupt = AccountFollowLedger {
            date: "not-a-date".to_string(),
            ..Default::default()
        };
        local.merge_from(&corrupt, "2026-11-23");
        assert_eq!(local.date, "2026-11-23");
        assert_eq!(local.effective_counts("2026-11-23"), (4, 10));

        let far_future = AccountFollowLedger {
            date: "2099-12-31".to_string(),
            ..Default::default()
        };
        local.merge_from(&far_future, "2026-11-23");
        assert_eq!(local.date, "2026-11-23");
        assert_eq!(local.effective_counts("2026-11-23"), (4, 10));

        // +1 day timezone skew from peer must NOT freeze local today at 0
        let mut ahead_peer = AccountFollowLedger {
            date: "2026-11-24".to_string(),
            ..Default::default()
        };
        ahead_peer.devices.insert(
            "and-2".to_string(),
            DeviceFollowEntry {
                today: 2,
                total: 5,
                updated_at: 200,
                ..Default::default()
            },
        );
        local.merge_from(&ahead_peer, "2026-11-23");
        assert_eq!(local.date, "2026-11-24");
        assert_eq!(local.effective_counts("2026-11-23"), (2, 15));
    }

    #[test]
    fn crdt_same_timestamp_tiebreak_does_not_regress_other_fields() {
        let mut local = AccountFollowLedger {
            date: "2026-11-23".to_string(),
            ..Default::default()
        };
        local.devices.insert(
            "win-1".to_string(),
            DeviceFollowEntry {
                today: 5,
                total: 20,
                unfollow_today: 1,
                unfollow_total: 3,
                updated_at: 500,
                ..Default::default()
            },
        );
        let mut remote = AccountFollowLedger {
            date: "2026-11-23".to_string(),
            ..Default::default()
        };
        remote.devices.insert(
            "win-1".to_string(),
            DeviceFollowEntry {
                today: 4,
                total: 19,
                unfollow_today: 2,
                unfollow_total: 4,
                updated_at: 500,
                ..Default::default()
            },
        );
        assert!(local.merge_from(&remote, "2026-11-23"));
        let entry = local.devices.get("win-1").unwrap();
        assert_eq!(entry.today, 5);
        assert_eq!(entry.total, 20);
        assert_eq!(entry.unfollow_today, 2);
        assert_eq!(entry.unfollow_total, 4);
    }

    #[test]
    fn crdt_new_remote_account_far_future_date_sanitized_no_patch_loop() {
        let mut poisoned_acc = AccountFollowLedger {
            date: "2099-12-31".to_string(),
            ..Default::default()
        };
        poisoned_acc.devices.insert(
            "bad-dev".to_string(),
            DeviceFollowEntry {
                today: 7,
                total: 12,
                updated_at: 300,
                ..Default::default()
            },
        );
        // Directly calling effective_counts on a poisoned future date must treat today as 0
        assert_eq!(poisoned_acc.effective_counts("2026-11-23"), (0, 12));

        let mut remote = FollowSyncLedger::default();
        remote
            .accounts
            .insert("instagram:alice".to_string(), poisoned_acc);

        let mut local = FollowSyncLedger::default();
        assert!(local.merge_from(&remote, "2026-11-23"));
        let acc = local.accounts.get("instagram:alice").unwrap();
        assert_eq!(acc.date, "2026-11-23");
        assert_eq!(acc.effective_counts("2026-11-23"), (0, 12));

        // Once sanitized, merging local again with itself must NOT keep reporting changes
        assert!(!local.has_newer_data_than(&local, "2026-11-23"));
    }

    #[test]
    fn window_reset_times_compute_oldest_and_newest_across_devices_and_deductions() {
        let now: u64 = 1_795_400_000;
        let window_hours: u32 = 24;
        let window_secs: u64 = window_hours as u64 * 3600;
        let mut acc = AccountFollowLedger {
            date: "2026-11-28".to_string(),
            ..Default::default()
        };
        acc.devices.insert(
            "win-1".to_string(),
            DeviceFollowEntry {
                follow_events: vec![now - 100_000, now - 7200, now - 600],
                unfollow_events: vec![now - 3600],
                updated_at: now - 600,
                ..Default::default()
            },
        );
        acc.devices.insert(
            "and-1".to_string(),
            DeviceFollowEntry {
                follow_events: vec![now - 3600, now - 120],
                follow_deductions: vec![now - 60],
                updated_at: now - 60,
                ..Default::default()
            },
        );
        assert_eq!(acc.effective_window_follow_count(now, window_hours), 3);
        let (f_next, f_full) = acc.effective_window_follow_reset_times(now, window_hours);
        assert_eq!(f_next, Some((now - 7200) + window_secs));
        assert_eq!(f_full, Some((now - 600) + window_secs));

        let (u_next, u_full) = acc.effective_window_unfollow_reset_times(now, window_hours);
        assert_eq!(u_next, Some((now - 3600) + window_secs));
        assert_eq!(u_full, Some((now - 3600) + window_secs));

        // 1時間ウィンドウでは cutoff = now - 3600（境界含む）により [now-3600, now-600, now-120] から
        // 減算1件を除いた [now-3600, now-600] が有効となる
        assert_eq!(acc.effective_window_follow_count(now, 1), 2);
        let (f_next_1h, f_full_1h) = acc.effective_window_follow_reset_times(now, 1);
        assert_eq!(f_next_1h, Some(now));
        assert_eq!(f_full_1h, Some((now - 600) + 3600));
    }
}
