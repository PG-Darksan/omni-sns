use url::Url;

/// WebView2 / Chromium バージョンに基づき、GoogleログインやWhatsApp Web等に弾かれない
/// クリーンなChrome互換User-Agentを生成する。
pub fn build_user_agent(mode: &str, chrome_version: &str) -> String {
    let safe_version = if is_valid_version_quad(chrome_version) {
        chrome_version
    } else {
        "136.0.0.0"
    };

    if mode == "mobile" {
        format!(
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 \
             (KHTML, like Gecko) Chrome/{safe_version} Mobile Safari/537.36"
        )
    } else {
        format!(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
             (KHTML, like Gecko) Chrome/{safe_version} Safari/537.36"
        )
    }
}

fn is_valid_version_quad(v: &str) -> bool {
    let parts: Vec<&str> = v.split('.').collect();
    parts.len() == 4
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
}

/// ユーザー入力URLを正規化し、安全な http/https URL のみ許可する。
pub fn normalize_service_url(raw_input: &str) -> Option<String> {
    let trimmed = raw_input.trim();
    if trimmed.is_empty() {
        return None;
    }

    let candidate = if has_scheme_prefix(trimmed) {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    };

    let parsed = Url::parse(&candidate).ok()?;
    let scheme = parsed.scheme();
    if scheme != "https" && scheme != "http" {
        return None;
    }
    if parsed.host_str().map(|h| h.is_empty()).unwrap_or(true) {
        return None;
    }
    Some(parsed.to_string())
}

fn has_scheme_prefix(s: &str) -> bool {
    if let Some(pos) = s.find("://") {
        let prefix = &s[..pos];
        let mut chars = prefix.chars();
        if let Some(first) = chars.next() {
            return first.is_ascii_alphabetic()
                && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
        }
    }
    false
}

pub fn is_http_url(url: &str) -> bool {
    url.get(..7).map(|p| p.eq_ignore_ascii_case("http://")).unwrap_or(false)
        || url.get(..8).map(|p| p.eq_ignore_ascii_case("https://")).unwrap_or(false)
}

pub fn is_valid_hex_color(color: &str) -> bool {
    let bytes = color.as_bytes();
    bytes.len() == 7 && bytes[0] == b'#' && bytes[1..].iter().all(|b| b.is_ascii_hexdigit())
}

/// ページタイトルから未読件数を抽出する。
/// 例: "(3) X / Messages", "[12] Discord", "• 5 messages", "(99+) Instagram"
pub fn parse_unread_count_from_title(title: &str) -> u32 {
    if title.is_empty() {
        return 0;
    }

    let trimmed = title.trim_start();

    // パターン1: 先頭の括弧内数値 "(3)", "(99+)", "[5]"
    if let Some(num) = extract_leading_bracket_number(trimmed) {
        return num.min(999);
    }

    // パターン2: タイトル途中の "(3)" 等（ただし西暦2026など4桁以上は除外）
    if let Some(num) = extract_inline_short_bracket_number(title) {
        return num.min(999);
    }

    // パターン3: 未読ドット記号（Discord/Slackの "•" や "●" や "🔴"）
    if let Some(first) = trimmed.chars().next() {
        if matches!(first, '•' | '●' | '🔴') {
            return 1;
        }
    }

    0
}

fn extract_leading_bracket_number(s: &str) -> Option<u32> {
    let mut chars = s.chars();
    let open = chars.next()?;
    if open != '(' && open != '[' {
        return None;
    }
    let rest = chars.as_str().trim_start();
    let digit_end = rest
        .bytes()
        .take_while(|b| b.is_ascii_digit())
        .count();
    if digit_end == 0 {
        return None;
    }
    let digits = &rest[..digit_end];
    let after_digits = &rest[digit_end..];
    let after_plus = after_digits.strip_prefix('+').unwrap_or(after_digits);
    let after_ws = after_plus.trim_start();
    if after_ws.starts_with(')') || after_ws.starts_with(']') {
        digits.parse::<u32>().ok()
    } else {
        None
    }
}

fn extract_inline_short_bracket_number(s: &str) -> Option<u32> {
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'(' || bytes[i] == b'[' {
            let start = i + 1;
            let mut j = start;
            while j < bytes.len() && bytes[j].is_ascii_digit() {
                j += 1;
            }
            let digit_len = j - start;
            if (1..=3).contains(&digit_len) {
                let mut k = j;
                if k < bytes.len() && bytes[k] == b'+' {
                    k += 1;
                }
                if k < bytes.len() && (bytes[k] == b')' || bytes[k] == b']') {
                    if let Ok(n) = s[start..j].parse::<u32>() {
                        return Some(n);
                    }
                }
            }
        }
        i += 1;
    }
    None
}

const AUTH_EXACT_OR_SUBDOMAIN_HOSTS: &[&str] = &[
    "accounts.google.com",
    "appleid.apple.com",
    "access.line.me",
    "login.microsoftonline.com",
    "login.live.com",
    "auth.login.yahoo.co.jp",
    "login.yahoo.co.jp",
    "facebook.com",
    "api.twitter.com",
    "twitter.com",
    "x.com",
    "github.com",
    "discord.com",
    "id.mixi.social",
];

const AUTH_HOST_LABELS: &[&str] = &["auth", "sso", "oauth", "login", "signin"];

const AUTH_PATH_KEYWORDS: &[&str] = &[
    "/oauth",
    "/auth",
    "/login",
    "/signin",
    "/sign-in",
    "/sso",
    "/authorize",
    "/dialog/oauth",
    "/verify",
    "/captcha",
    "/challenge",
];

fn matches_auth_host(host: &str) -> bool {
    let lower = host.to_ascii_lowercase();
    for suffix in AUTH_EXACT_OR_SUBDOMAIN_HOSTS {
        if lower == *suffix || lower.ends_with(&format!(".{suffix}")) {
            return true;
        }
    }
    for label in lower.split('.') {
        if AUTH_HOST_LABELS.contains(&label) {
            return true;
        }
    }
    false
}

/// ポップアップURLが認証（OAuth / SSO / 本人確認）専用かを判定する。
pub fn is_auth_popup_url(target_url: &str) -> bool {
    let Ok(target) = Url::parse(target_url) else {
        return false;
    };
    if target.scheme() != "https" && target.scheme() != "http" {
        return false;
    }
    let Some(target_host) = target.host_str() else {
        return false;
    };
    if matches_auth_host(target_host) {
        return true;
    }
    let lower_path = target.path().to_ascii_lowercase();
    AUTH_PATH_KEYWORDS.iter().any(|kw| lower_path.contains(kw))
}

/// 同一ルートドメイン（サブドメイン・同一サービス別ドメイン含む）のURLかを判定する。
fn canonical_site_group(domain: &str) -> &str {
    match domain {
        "threads.net" | "threads.com" => "threads.com",
        other => other,
    }
}

pub fn is_same_site_url(target_url: &str, current_service_url: &str) -> bool {
    let Ok(target) = Url::parse(target_url) else {
        return false;
    };
    if target.scheme() != "https" && target.scheme() != "http" {
        return false;
    }
    let Some(target_host) = target.host_str() else {
        return false;
    };
    if let Ok(current) = Url::parse(current_service_url) {
        if let Some(current_host) = current.host_str() {
            let td = get_registrable_domain_hint(target_host);
            let cd = get_registrable_domain_hint(current_host);
            return canonical_site_group(&td) == canonical_site_group(&cd);
        }
    }
    false
}

/// 現在のサイト文脈を考慮し、認証用ポップアップとして別ウィンドウで開くべきか判定する。
/// Facebook や Discord 等の同一サイト内の通常ページ遷移を OAuth ポップアップと誤判定しない。
pub fn is_auth_popup_for_site(target_url: &str, current_service_url: &str) -> bool {
    let Ok(target) = Url::parse(target_url) else {
        return false;
    };
    if target.scheme() != "https" && target.scheme() != "http" {
        return false;
    }
    let Some(target_host) = target.host_str() else {
        return false;
    };
    if is_same_site_url(target_url, current_service_url) {
        let lower_host = target_host.to_ascii_lowercase();
        let has_auth_label = lower_host
            .split('.')
            .any(|label| AUTH_HOST_LABELS.contains(&label) || matches!(label, "accounts" | "id"));
        if has_auth_label {
            return true;
        }
        let lower_path = target.path().to_ascii_lowercase();
        return AUTH_PATH_KEYWORDS.iter().any(|kw| lower_path.contains(kw));
    }
    is_auth_popup_url(target_url)
}

/// ポップアップURLが認証（OAuth / SSO / 本人確認）や同一サービスのサブウィンドウかを判定する。
#[allow(dead_code)]
pub fn should_open_in_app_popup(target_url: &str, current_service_url: &str) -> bool {
    is_auth_popup_url(target_url) || is_same_site_url(target_url, current_service_url)
}

/// 簡易的にルートドメイン末尾2〜3ラベル（co.jp 等考慮）を取り出す。
pub fn get_registrable_domain_hint(hostname: &str) -> String {
    let lower = hostname.to_ascii_lowercase();
    let parts: Vec<&str> = lower.split('.').filter(|p| !p.is_empty()).collect();
    if parts.len() <= 2 {
        return parts.join(".");
    }
    let last_two = format!("{}.{}", parts[parts.len() - 2], parts[parts.len() - 1]);
    if matches!(
        last_two.as_str(),
        "co.jp" | "ne.jp" | "or.jp" | "ac.jp" | "go.jp" | "co.uk" | "com.au"
    ) {
        return format!("{}.{last_two}", parts[parts.len() - 3]);
    }
    last_two
}

/// サービス名から最大2文字のバッジ文字を生成する。
pub fn make_badge_text(name: &str) -> String {
    let cleaned = name.trim();
    if cleaned.is_empty() {
        return "SN".to_string();
    }

    let mut ascii_words: Vec<&str> = Vec::new();
    let bytes = cleaned.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_alphanumeric() {
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_alphanumeric() {
                i += 1;
            }
            ascii_words.push(&cleaned[start..i]);
        } else {
            i += 1;
        }
    }

    if ascii_words.len() >= 2 {
        let a = ascii_words[0].chars().next().unwrap_or('S');
        let b = ascii_words[1].chars().next().unwrap_or('N');
        return format!("{a}{b}").to_uppercase();
    }
    if ascii_words.len() == 1 && ascii_words[0].len() >= 2 {
        return ascii_words[0][..2].to_ascii_uppercase();
    }

    cleaned.chars().take(2).collect::<String>().to_uppercase()
}

/// 同一SNSをグルーピングするためのキーを返す。
/// カタログ登録サービスは service_id で束ね、カスタムサービスはホスト名単位で束ねる。
pub fn service_group_key(service_id: &str, url: &str, instance_id: &str) -> String {
    let sid = service_id.trim();
    if !sid.is_empty() && sid != "custom" {
        return sid.to_string();
    }
    if let Ok(parsed) = Url::parse(url) {
        if let Some(host) = parsed.host_str() {
            if !host.is_empty() {
                return format!("custom:{}", host.to_ascii_lowercase());
            }
        }
    }
    format!("custom:{instance_id}")
}

/// 現在表示中のURLから対応する主要SNSカタログIDを推定する。
/// 例: Threadsタブ内で `https://www.instagram.com/...` を開いた際に `"instagram"` を返す。
pub fn detect_platform_service_from_url(raw_url: &str) -> Option<&'static str> {
    let parsed = Url::parse(raw_url.trim()).ok()?;
    let host = parsed.host_str()?.to_ascii_lowercase();
    let matches_host = |domain: &str| host == domain || host.ends_with(&format!(".{domain}"));
    if matches_host("instagram.com") {
        return Some("instagram");
    }
    if matches_host("threads.com") || matches_host("threads.net") {
        return Some("threads");
    }
    if matches_host("bsky.app") || matches_host("bsky.social") {
        return Some("bluesky");
    }
    if matches_host("mixi.social") {
        return Some("mixi2");
    }
    if matches_host("x.com") || matches_host("twitter.com") {
        return Some("x");
    }
    if matches_host("tiktok.com") {
        return Some("tiktok");
    }
    if matches_host("facebook.com") {
        return Some("facebook");
    }
    if matches_host("messenger.com") {
        return Some("messenger");
    }
    if matches_host("note.com") {
        return Some("note");
    }
    if matches_host("youtube.com") {
        return Some("youtube");
    }
    if matches_host("twitch.tv") {
        return Some("twitch");
    }
    if matches_host("reddit.com") {
        return Some("reddit");
    }
    if matches_host("pinterest.com") || matches_host("pinterest.jp") {
        return Some("pinterest");
    }
    if matches_host("linkedin.com") {
        return Some("linkedin");
    }
    if matches_host("tumblr.com") {
        return Some("tumblr");
    }
    if matches_host("pixiv.net") {
        return Some("pixiv");
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_agent_generation() {
        let desktop = build_user_agent("desktop", "136.0.0.0");
        let mobile = build_user_agent("mobile", "136.0.0.0");
        assert!(!desktop.contains("Electron"));
        assert!(!desktop.contains("Edg/"));
        assert!(desktop.contains("Windows NT 10.0"));
        assert!(desktop.contains("Chrome/136.0.0.0"));
        assert!(mobile.contains("Mobile Safari"));
        assert!(mobile.contains("Android"));
    }

    #[test]
    fn normalize_urls() {
        assert_eq!(
            normalize_service_url("bsky.app/messages").as_deref(),
            Some("https://bsky.app/messages")
        );
        assert_eq!(
            normalize_service_url("https://tinder.com/").as_deref(),
            Some("https://tinder.com/")
        );
        assert_eq!(normalize_service_url("javascript:alert(1)"), None);
        assert_eq!(normalize_service_url("file:///C:/Windows/System32"), None);
        assert_eq!(normalize_service_url("   "), None);
    }

    #[test]
    fn parse_unread_titles() {
        assert_eq!(parse_unread_count_from_title("(3) Bluesky / Messages"), 3);
        assert_eq!(parse_unread_count_from_title("(99+) Instagram"), 99);
        assert_eq!(parse_unread_count_from_title("[12] Discord"), 12);
        assert_eq!(parse_unread_count_from_title("• Slack - general"), 1);
        assert_eq!(parse_unread_count_from_title("Threads - Home"), 0);
        assert_eq!(parse_unread_count_from_title("Report (2026)"), 0);
    }

    #[test]
    fn popup_detection() {
        assert!(should_open_in_app_popup(
            "https://accounts.google.com/o/oauth2/auth",
            "https://tinder.com/"
        ));
        assert!(should_open_in_app_popup(
            "https://access.line.me/oauth2/v2.1/authorize",
            "https://mixi.social/"
        ));
        assert!(should_open_in_app_popup(
            "https://appleid.apple.com/auth/authorize",
            "https://bumble.com/app"
        ));
        assert!(should_open_in_app_popup(
            "https://sub.instagram.com/verify",
            "https://www.instagram.com/direct/inbox/"
        ));
        assert!(!should_open_in_app_popup(
            "https://news.yahoo.co.jp/articles/123",
            "https://bsky.app/messages"
        ));

        // Threads .net / .com は同一サービス扱い
        assert!(is_same_site_url(
            "https://www.threads.net/@alice",
            "https://www.threads.com/"
        ));
        // Facebook / Discord 上の通常ページは OAuth ポップアップ扱いせず同アカウントの別タブへ
        assert!(!is_auth_popup_for_site(
            "https://www.facebook.com/someone/posts/123",
            "https://www.facebook.com/"
        ));
        assert!(!is_auth_popup_for_site(
            "https://discord.com/channels/123/456",
            "https://discord.com/channels/@me"
        ));
        // 他サイトからの Facebook OAuth や同一サイト内の /oauth は引き続き認証ポップアップ扱い
        assert!(is_auth_popup_for_site(
            "https://www.facebook.com/v18.0/dialog/oauth",
            "https://tinder.com/"
        ));
        assert!(is_auth_popup_for_site(
            "https://discord.com/oauth2/authorize?client_id=1",
            "https://discord.com/channels/@me"
        ));
    }

    #[test]
    fn badge_generation() {
        assert_eq!(make_badge_text("Bluesky"), "BL");
        assert_eq!(make_badge_text("Steam Chat"), "SC");
        assert_eq!(make_badge_text("ミクシィ"), "ミク");
    }

    #[test]
    fn service_group_key_groups_catalog_and_custom_hosts() {
        assert_eq!(
            service_group_key("instagram", "https://www.instagram.com/direct/inbox/", "svc-1"),
            "instagram"
        );
        assert_eq!(
            service_group_key("custom", "https://Chat.Example.com/room", "svc-1"),
            "custom:chat.example.com"
        );
        assert_eq!(
            service_group_key("custom", "https://chat.example.com/dm", "svc-2"),
            "custom:chat.example.com"
        );
        assert_ne!(
            service_group_key("custom", "https://other.example.org/", "svc-3"),
            "custom:chat.example.com"
        );
    }

    #[test]
    fn detect_platform_service_handles_threads_to_instagram_navigation() {
        assert_eq!(
            detect_platform_service_from_url("https://www.instagram.com/alice/followers/"),
            Some("instagram")
        );
        assert_eq!(
            detect_platform_service_from_url("https://www.threads.com/@alice"),
            Some("threads")
        );
        assert_eq!(
            detect_platform_service_from_url("https://www.threads.net/@alice"),
            Some("threads")
        );
        assert_eq!(
            detect_platform_service_from_url("https://bsky.app/profile/alice.bsky.social"),
            Some("bluesky")
        );
        assert_eq!(
            detect_platform_service_from_url("https://mixi.social/home"),
            Some("mixi2")
        );
        assert_eq!(
            detect_platform_service_from_url("https://example.com/unknown"),
            None
        );
    }
}
