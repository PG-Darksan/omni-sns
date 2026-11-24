use std::collections::HashMap;
use serde::{Deserialize, Serialize};

/// 12 通りの形 (1方向: ← → ↑ ↓ を先にまとめ、2方向を後ろに並べる — HisatorNotebook w387 準拠)
pub const GESTURE_SHAPES: [&str; 12] = [
    "L", "R", "U", "D", "LU", "LD", "RU", "RD", "UL", "UR", "DL", "DR",
];

/// 割り当て可能な全操作 ID
pub const GESTURE_ACTIONS: &[&str] = &[
    "none",
    // タブ操作
    "previous-tab",
    "next-tab",
    "new-tab",
    "ctrl-click",
    "duplicate-tab",
    "close-tab",
    "close-other-tabs",
    "restore-closed",
    // SNS サービス / アカウント切替
    "previous-service",
    "next-service",
    "previous-account",
    "next-account",
    "open-catalog",
    "sleep-tab",
    // ページ・ナビゲーション
    "go-back",
    "go-forward",
    "reload",
    "hard-reload",
    "home",
    // スクロール (ドラッグ中リアルタイム進行 + 端へ移動)
    "scroll:up",
    "scroll:down",
    "scroll:left",
    "scroll:right",
    "scroll-top",
    "scroll-bottom",
    // 表示・アプリ操作
    "toggle-ua",
    "toggle-mute",
    "zoom-in",
    "zoom-out",
    "zoom-reset",
    "open-external",
    "gesture:settings",
];

pub const DEFAULT_TREMOR_PX: u32 = 4;
pub const MIN_TREMOR_PX: u32 = 1;
pub const MAX_TREMOR_PX: u32 = 30;

/// 描いている途中の向き判定比 (HisatorNotebook W246GesturePath 準拠)
pub const AXIS_RATIO: f64 = 1.8;
/// 離した時の保留向き判定比 (HisatorNotebook b545/w247 準拠)
pub const RELEASE_AXIS_RATIO: f64 = 1.3;
/// 離した時の保留を1本として読む最小長さ (論理 px)
pub const RELEASE_MIN_LEN: f64 = 16.0;
/// 形の末尾の揺れとして捨てる割合・下限・上限 (論理 px)
pub const RELEASE_TAIL_RATIO: f64 = 0.25;
pub const RELEASE_TAIL_MIN: f64 = 20.0;
pub const RELEASE_TAIL_MAX: f64 = 40.0;
pub const MAX_POINTS: usize = 200_000;
pub const MAX_COORD: f64 = 1e6;

/// ライブスクロール定数 (HisatorNotebook w367_gesture_ops.dart 準拠)
pub const SCROLL_START_LEN: f64 = 22.0;
pub const SCROLL_BASE_SPEED: f64 = 500.0;
pub const SCROLL_SPEED_PER_PX: f64 = 9.0;
pub const SCROLL_MAX_SPEED: f64 = 4000.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    pub fn dist(self, other: Self) -> f64 {
        let dx = self.x - other.x;
        let dy = self.y - other.y;
        (dx * dx + dy * dy).sqrt()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GestureSettings {
    pub enabled: bool,
    pub wrap_tabs: bool,
    pub show_trail: bool,
    pub show_feedback: bool,
    pub allow_dup: bool,
    pub tremor: u32,
    pub gestures: HashMap<String, String>,
}

impl Default for GestureSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            wrap_tabs: true,
            show_trail: true,
            show_feedback: true,
            allow_dup: false,
            tremor: DEFAULT_TREMOR_PX,
            gestures: default_gesture_map(),
        }
    }
}

pub fn default_gesture_map() -> HashMap<String, String> {
    let pairs = [
        ("L", "previous-tab"),
        ("R", "next-tab"),
        ("U", "scroll:up"),
        ("D", "scroll:down"),
        ("LU", "previous-service"),
        ("LD", "go-forward"),
        ("RU", "next-service"),
        ("RD", "reload"),
        ("UL", "go-back"),
        ("UR", "restore-closed"),
        ("DL", "new-tab"),
        ("DR", "close-tab"),
    ];
    pairs
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

pub fn is_valid_action(action: &str) -> bool {
    GESTURE_ACTIONS.contains(&action)
}

pub fn sanitize_gesture_settings(raw: GestureSettings) -> GestureSettings {
    let mut map = default_gesture_map();
    for shape in GESTURE_SHAPES {
        if let Some(act) = raw.gestures.get(shape) {
            map.insert(
                shape.to_string(),
                if is_valid_action(act) {
                    act.clone()
                } else {
                    "none".to_string()
                },
            );
        } else {
            map.insert(shape.to_string(), "none".to_string());
        }
    }
    GestureSettings {
        enabled: raw.enabled,
        wrap_tabs: raw.wrap_tabs,
        show_trail: raw.show_trail,
        show_feedback: raw.show_feedback,
        allow_dup: raw.allow_dup,
        tremor: raw.tremor.clamp(MIN_TREMOR_PX, MAX_TREMOR_PX),
        gestures: map,
    }
}

impl GestureSettings {
    pub fn action_for(&self, shape: &str) -> &str {
        self.gestures
            .get(shape)
            .map(|s| s.as_str())
            .unwrap_or("none")
    }
}

pub fn shape_arrows(shape: &str) -> String {
    shape
        .chars()
        .map(|c| match c {
            'L' => '←',
            'R' => '→',
            'U' => '↑',
            'D' => '↓',
            _ => ' ',
        })
        .collect()
}

pub fn shape_name_ja(shape: &str) -> String {
    shape
        .chars()
        .filter_map(|c| match c {
            'L' => Some("左"),
            'R' => Some("右"),
            'U' => Some("上"),
            'D' => Some("下"),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("→")
}

pub fn action_label_ja(action: &str) -> &'static str {
    match action {
        "none" => "未割り当て",
        "previous-tab" => "前のタブへ",
        "next-tab" => "次のタブへ",
        "new-tab" => "新しいタブを開く",
        "ctrl-click" => "Ctrl+クリック",
        "duplicate-tab" => "現在のタブを複製",
        "close-tab" => "現在のタブを閉じる",
        "close-other-tabs" => "このタブ以外を閉じる",
        "restore-closed" => "閉じたタブを復元",
        "previous-service" => "前のSNSへ",
        "next-service" => "次のSNSへ",
        "previous-account" => "前のアカウントへ",
        "next-account" => "次のアカウントへ",
        "open-catalog" => "SNSカタログを開く",
        "sleep-tab" => "このSNSを休止",
        "go-back" => "戻る",
        "go-forward" => "進む",
        "reload" => "再読み込み",
        "hard-reload" => "スーパーリロード",
        "home" => "ホーム / DM画面へ",
        "scroll:up" => "上へスクロール",
        "scroll:down" => "下へスクロール",
        "scroll:left" => "左へスクロール",
        "scroll:right" => "右へスクロール",
        "scroll-top" => "一番上へスクロール",
        "scroll-bottom" => "一番下へスクロール",
        "toggle-ua" => "PC / スマホ UA切替",
        "toggle-mute" => "ミュート切替",
        "zoom-in" => "拡大",
        "zoom-out" => "縮小",
        "zoom-reset" => "ズームリセット",
        "open-external" => "既定ブラウザで開く",
        "gesture:settings" => "ジェスチャー設定を開く",
        _ => "未割り当て",
    }
}

/// 1 回の右ドラッグの経路判定 (HisatorNotebook W246GesturePath 完全準拠)
pub struct GesturePath {
    tremor: f64,
    origin: Point,
    pivot: Point,
    last: Point,
    end: Point,
    corner: Option<Point>,
    dirs: Vec<char>,
    max_len: f64,
    count: usize,
    invalid: bool,
    pending: bool,
    ever_recognized: bool,
}

impl GesturePath {
    pub fn new(start: Point, tremor_px: u32) -> Self {
        let tremor = (tremor_px.clamp(MIN_TREMOR_PX, MAX_TREMOR_PX)) as f64;
        Self {
            tremor,
            origin: start,
            pivot: start,
            last: start,
            end: start,
            corner: None,
            dirs: Vec::with_capacity(2),
            max_len: 0.0,
            count: 1,
            invalid: false,
            pending: false,
            ever_recognized: false,
        }
    }

    pub fn tolerance(&self) -> f64 {
        self.tremor.max((self.max_len * 0.15).min(6.0))
    }

    pub fn origin(&self) -> Point {
        self.origin
    }

    pub fn invalid(&self) -> bool {
        self.invalid
    }

    pub fn pending(&self) -> bool {
        self.pending
    }

    pub fn ever_recognized(&self) -> bool {
        self.ever_recognized
    }

    pub fn shape(&self) -> Option<String> {
        if self.invalid || self.pending || self.dirs.is_empty() {
            None
        } else {
            Some(self.dirs.iter().collect())
        }
    }

    pub fn vertices(&self) -> Vec<Point> {
        let mut pts = Vec::with_capacity(3);
        pts.push(self.origin);
        if let Some(c) = self.corner {
            pts.push(c);
        }
        if !self.dirs.is_empty() {
            pts.push(self.end);
        }
        pts
    }

    pub fn add(&mut self, p: Point) {
        if self.invalid {
            return;
        }
        if !p.x.is_finite() || !p.y.is_finite() || p.x.abs() > MAX_COORD || p.y.abs() > MAX_COORD {
            self.invalid = true;
            return;
        }
        if (p.x - self.last.x).abs() < f64::EPSILON && (p.y - self.last.y).abs() < f64::EPSILON {
            return;
        }
        self.last = p;
        self.count += 1;
        if self.count > MAX_POINTS {
            self.invalid = true;
            return;
        }

        let tol = self.tolerance();
        let dx = p.x - self.pivot.x;
        let dy = p.y - self.pivot.y;
        if dx.abs().max(dy.abs()) <= tol {
            self.pending = false;
            return;
        }

        let Some(dir) = classify_dir(dx, dy, AXIS_RATIO) else {
            self.pending = true;
            return;
        };
        self.pending = false;
        self.step(p, dir, tol);
    }

    fn step(&mut self, p: Point, dir: char, tol: f64) {
        if self.dirs.is_empty() {
            self.dirs.push(dir);
            self.advance(p, dir, tol);
        } else if Some(&dir) == self.dirs.last() {
            self.advance(p, dir, tol);
        } else if Some(opposite_dir(dir)) == self.dirs.last().copied() || self.dirs.len() >= 2 {
            self.invalid = true;
            return;
        } else {
            self.corner = Some(self.end);
            self.dirs.push(dir);
            self.advance(p, dir, tol);
        }
        if self.shape().is_some() {
            self.ever_recognized = true;
        }
    }

    pub fn finish(&mut self, p: Point) -> Option<String> {
        self.add(p);
        self.release()
    }

    pub fn release(&mut self) -> Option<String> {
        if self.pending && !self.invalid {
            self.resolve_pending_at_release();
        }
        self.shape()
    }

    fn resolve_pending_at_release(&mut self) {
        let dx = self.last.x - self.pivot.x;
        let dy = self.last.y - self.pivot.y;
        let ax = dx.abs();
        let ay = dy.abs();
        let len = ax.max(ay);
        let dir = if ax >= ay * RELEASE_AXIS_RATIO {
            Some(if dx > 0.0 { 'R' } else { 'L' })
        } else if ay >= ax * RELEASE_AXIS_RATIO {
            Some(if dy > 0.0 { 'D' } else { 'U' })
        } else {
            None
        };

        let tol = self.tolerance();
        if !self.dirs.is_empty() {
            let tail = (self.max_len * RELEASE_TAIL_RATIO).clamp(RELEASE_TAIL_MIN, RELEASE_TAIL_MAX);
            if len <= tail {
                self.pending = false;
                if let Some(d) = dir {
                    if Some(d) == self.dirs.last().copied() {
                        self.advance(self.last, d, tol);
                    }
                }
                return;
            }
        }

        let Some(d) = dir else {
            return;
        };
        if len < RELEASE_MIN_LEN {
            return;
        }
        self.pending = false;
        self.step(self.last, d, tol);
    }

    fn advance(&mut self, p: Point, dir: char, tol: f64) {
        let horizontal = dir == 'L' || dir == 'R';
        let start = self.corner.unwrap_or(self.origin);
        if horizontal {
            let y = p.y - (p.y - self.pivot.y).clamp(-tol, tol);
            self.pivot = Point::new(p.x, y);
            self.end = Point::new(p.x, start.y);
            self.max_len = self.max_len.max((p.x - start.x).abs());
        } else {
            let x = p.x - (p.x - self.pivot.x).clamp(-tol, tol);
            self.pivot = Point::new(x, p.y);
            self.end = Point::new(start.x, p.y);
            self.max_len = self.max_len.max((p.y - start.y).abs());
        }
    }
}

fn classify_dir(dx: f64, dy: f64, ratio: f64) -> Option<char> {
    let ax = dx.abs();
    let ay = dy.abs();
    if ax > ay * ratio {
        Some(if dx > 0.0 { 'R' } else { 'L' })
    } else if ay > ax * ratio {
        Some(if dy > 0.0 { 'D' } else { 'U' })
    } else {
        None
    }
}

fn opposite_dir(dir: char) -> char {
    match dir {
        'L' => 'R',
        'R' => 'L',
        'U' => 'D',
        _ => 'U',
    }
}

// ── 描いている間のリアルタイムスクロール (HisatorNotebook w367 準拠) ─────────

pub fn scroll_dir_of(action: &str) -> Option<char> {
    match action {
        "scroll:up" => Some('U'),
        "scroll:down" => Some('D'),
        "scroll:left" => Some('L'),
        "scroll:right" => Some('R'),
        _ => None,
    }
}

pub fn scroll_speed_for(leg_len: f64) -> f64 {
    if !leg_len.is_finite() || leg_len <= SCROLL_START_LEN {
        return 0.0;
    }
    (SCROLL_BASE_SPEED + (leg_len - SCROLL_START_LEN) * SCROLL_SPEED_PER_PX).min(SCROLL_MAX_SPEED)
}

pub fn leg_length(vertices: &[Point]) -> f64 {
    if vertices.len() < 2 {
        return 0.0;
    }
    vertices[vertices.len() - 1].dist(vertices[vertices.len() - 2])
}

#[derive(Debug, Clone, PartialEq)]
pub struct LiveScrollSpec {
    pub dir: Option<char>,
    pub speed: f64,
    pub shape: Option<String>,
}

pub fn live_scroll_of<'a>(
    shape: Option<&str>,
    pending: bool,
    invalid: bool,
    canceled: bool,
    vertices: &[Point],
    settings: &GestureSettings,
    last_shape: Option<&'a str>,
) -> LiveScrollSpec {
    if canceled || invalid {
        return LiveScrollSpec {
            dir: None,
            speed: 0.0,
            shape: None,
        };
    }
    let effective = shape.or(if pending { last_shape } else { None });
    let Some(s) = effective else {
        return LiveScrollSpec {
            dir: None,
            speed: 0.0,
            shape: None,
        };
    };
    let action = settings.action_for(s);
    let Some(dir) = scroll_dir_of(action) else {
        return LiveScrollSpec {
            dir: None,
            speed: 0.0,
            shape: Some(s.to_string()),
        };
    };
    LiveScrollSpec {
        dir: Some(dir),
        speed: scroll_speed_for(leg_length(vertices)),
        shape: Some(s.to_string()),
    }
}

pub fn reveal_delta(dir: char, px: f64) -> (f64, f64) {
    match dir {
        'U' => (0.0, -px),
        'D' => (0.0, px),
        'L' => (-px, 0.0),
        'R' => (px, 0.0),
        _ => (0.0, 0.0),
    }
}

pub fn step_tab_index(count: usize, from: usize, step: isize, wrap: bool) -> Result<usize, &'static str> {
    if count <= 1 {
        return Err("タブが1つしかありません");
    }
    let next = from as isize + step;
    if next < 0 {
        if wrap {
            Ok(count - 1)
        } else {
            Err("最初のタブです")
        }
    } else if next >= count as isize {
        if wrap {
            Ok(0)
        } else {
            Err("最後のタブです")
        }
    } else {
        Ok(next as usize)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_single_and_two_step_shapes_by_order() {
        let mut p1 = GesturePath::new(Point::new(100.0, 100.0), 4);
        p1.add(Point::new(100.0, 160.0));
        p1.add(Point::new(170.0, 160.0));
        assert_eq!(p1.release().as_deref(), Some("DR"));

        let mut p2 = GesturePath::new(Point::new(100.0, 100.0), 4);
        p2.add(Point::new(160.0, 100.0));
        p2.add(Point::new(160.0, 170.0));
        assert_eq!(p2.release().as_deref(), Some("RD"));
    }

    #[test]
    fn tremor_threshold_filters_small_jitter() {
        let mut p = GesturePath::new(Point::new(100.0, 100.0), 10);
        p.add(Point::new(108.0, 102.0));
        assert_eq!(p.shape(), None);
        assert!(!p.ever_recognized());

        p.add(Point::new(125.0, 102.0));
        assert_eq!(p.shape().as_deref(), Some("R"));
        assert!(p.ever_recognized());
    }

    #[test]
    fn reversal_and_third_segment_invalidate_gesture() {
        let mut rev = GesturePath::new(Point::new(100.0, 100.0), 4);
        rev.add(Point::new(160.0, 100.0));
        rev.add(Point::new(120.0, 100.0));
        assert!(rev.invalid());
        assert_eq!(rev.release(), None);

        let mut three = GesturePath::new(Point::new(100.0, 100.0), 4);
        three.add(Point::new(100.0, 160.0));
        three.add(Point::new(160.0, 160.0));
        three.add(Point::new(160.0, 220.0));
        assert!(three.invalid());
        assert_eq!(three.release(), None);
    }

    #[test]
    fn release_forgives_short_diagonal_tail_wobble() {
        let mut p = GesturePath::new(Point::new(100.0, 100.0), 4);
        p.add(Point::new(220.0, 100.0)); // R, maxLen = 120, tail = 30
        p.add(Point::new(234.0, 112.0)); // diagonal wobble (14px <= 30px)
        assert!(p.pending());
        assert_eq!(p.release().as_deref(), Some("R"));
    }

    #[test]
    fn live_scroll_ramps_with_length_and_stops_on_turn() {
        let settings = GestureSettings::default(); // D = scroll:down, DR = close-tab
        let mut p = GesturePath::new(Point::new(100.0, 100.0), 4);
        p.add(Point::new(100.0, 115.0)); // 15px <= 22px
        let s1 = live_scroll_of(
            p.shape().as_deref(),
            p.pending(),
            p.invalid(),
            false,
            &p.vertices(),
            &settings,
            None,
        );
        assert_eq!(s1.dir, Some('D'));
        assert_eq!(s1.speed, 0.0);

        p.add(Point::new(100.0, 222.0)); // 122px -> 500 + 100*9 = 1400
        let s2 = live_scroll_of(
            p.shape().as_deref(),
            p.pending(),
            p.invalid(),
            false,
            &p.vertices(),
            &settings,
            s1.shape.as_deref(),
        );
        assert_eq!(s2.dir, Some('D'));
        assert!((s2.speed - 1400.0).abs() < 1.0);

        // Turn right -> DR is close-tab (not scroll), so live scroll stops immediately
        p.add(Point::new(180.0, 222.0));
        let s3 = live_scroll_of(
            p.shape().as_deref(),
            p.pending(),
            p.invalid(),
            false,
            &p.vertices(),
            &settings,
            s2.shape.as_deref(),
        );
        assert_eq!(s3.dir, None);
        assert_eq!(s3.speed, 0.0);
        assert_eq!(p.release().as_deref(), Some("DR"));
    }

    #[test]
    fn tab_step_wraps_or_clamps() {
        assert_eq!(step_tab_index(3, 0, -1, true), Ok(2));
        assert_eq!(step_tab_index(3, 2, 1, true), Ok(0));
        assert!(step_tab_index(3, 0, -1, false).is_err());
        assert!(step_tab_index(1, 0, 1, true).is_err());
    }

    #[test]
    fn ctrl_click_action_is_valid_and_preserved_by_sanitize() {
        assert!(is_valid_action("ctrl-click"));
        assert_eq!(action_label_ja("ctrl-click"), "Ctrl+クリック");
        let mut settings = GestureSettings::default();
        settings
            .gestures
            .insert("DR".to_string(), "ctrl-click".to_string());
        let sanitized = sanitize_gesture_settings(settings);
        assert_eq!(sanitized.action_for("DR"), "ctrl-click");
    }
}
