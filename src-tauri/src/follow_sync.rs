use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

pub const GIST_FILENAME: &str = "omnisns-follow-sync.json";

pub fn now_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
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
    pub devices: HashMap<String, DeviceFollowEntry>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sns_following: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sns_followers: Option<u32>,
    #[serde(default)]
    pub sns_updated_at: u64,
}

impl AccountFollowLedger {
    pub fn roll_date(&mut self, today: &str) {
        if self.date.as_str() < today {
            self.date = today.to_string();
            for entry in self.devices.values_mut() {
                entry.today = 0;
                entry.today_epoch = self.reset_epoch;
                entry.unfollow_today = 0;
                entry.unfollow_today_epoch = self.unfollow_reset_epoch;
            }
        } else if self.date.is_empty() {
            self.date = today.to_string();
        }
    }

    pub fn effective_counts(&self, today: &str) -> (u32, u32) {
        let same_day = self.date == today;
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

    pub fn effective_unfollow_counts(&self, today: &str) -> (u32, u32) {
        let same_day = self.date == today;
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

    /// 相手側のレジャーを競合なくマージする。ローカルに変化があれば true。
    pub fn merge_from(&mut self, other: &AccountFollowLedger, today: &str) -> bool {
        let mut changed = false;

        let target_date = [self.date.as_str(), other.date.as_str(), today]
            .into_iter()
            .filter(|s| !s.is_empty())
            .max()
            .unwrap_or(today)
            .to_string();

        if self.date != target_date {
            if self.date.as_str() < target_date.as_str() {
                for entry in self.devices.values_mut() {
                    entry.today = 0;
                    entry.unfollow_today = 0;
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

        let other_same_day = other.date == target_date;
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

            match self.devices.get_mut(dev_id) {
                Some(local_entry) => {
                    let remote_newer = normalized.updated_at > local_entry.updated_at
                        || (normalized.updated_at == local_entry.updated_at
                            && (normalized.total > local_entry.total
                                || normalized.today > local_entry.today
                                || normalized.unfollow_total > local_entry.unfollow_total
                                || normalized.unfollow_today > local_entry.unfollow_today));
                    if remote_newer && *local_entry != normalized {
                        *local_entry = normalized;
                        changed = true;
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
                    let mut cloned = remote_acc.clone();
                    cloned.roll_date(today);
                    self.accounts.insert(key.clone(), cloned);
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
    let token_trimmed = token.trim();
    if token_trimmed.is_empty() {
        return Err("GitHub Personal Access Token（gist 権限）を入力してください".to_string());
    }
    let auth_header = format!("Bearer {token_trimmed}");
    let base_headers = [
        ("Authorization", auth_header.as_str()),
        ("Accept", "application/vnd.github+json"),
        ("X-GitHub-Api-Version", "2022-11-28"),
        ("Content-Type", "application/json; charset=utf-8"),
    ];

    let mut merged = local_ledger.clone();
    let trimmed_id = gist_id.trim();

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
            .ok_or_else(|| "作成された Gist ID を取得できませんでした".to_string())?
            .to_string();
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

    let remote_val: serde_json::Value =
        serde_json::from_str(&get_resp).map_err(|e| format!("Gist応答の解析に失敗: {e}"))?;
    let remote_content = remote_val
        .get("files")
        .and_then(|f| f.get(GIST_FILENAME))
        .and_then(|file| file.get("content"))
        .and_then(|c| c.as_str());

    let mut remote_ledger = FollowSyncLedger::default();
    let mut local_changed = false;
    if let Some(content) = remote_content {
        if let Ok(parsed_ledger) = serde_json::from_str::<FollowSyncLedger>(content) {
            remote_ledger = parsed_ledger;
            local_changed = merged.merge_from(&remote_ledger, today);
        }
    }

    // 2. ローカル側にリモートより新しいデータがあれば PATCH で反映
    if merged.has_newer_data_than(&remote_ledger, today) || remote_content.is_none() {
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
    _token: &str,
    _gist_id: &str,
    _local_ledger: &FollowSyncLedger,
    _today: &str,
) -> Result<(String, FollowSyncLedger, bool), String> {
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
}
