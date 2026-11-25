import { UserAgentMode } from './types';

/**
 * WebView2 / Chromium バージョンに基づき、GoogleログインやWhatsApp Web等に弾かれない
 * クリーンなChrome互換User-Agentを生成する。
 */
export function buildUserAgent(mode: UserAgentMode, chromeVersion = '136.0.0.0'): string {
  const safeVersion = /^\d+\.\d+\.\d+\.\d+$/.test(chromeVersion)
    ? chromeVersion
    : '136.0.0.0';

  if (mode === 'mobile') {
    return (
      `Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 ` +
      `(KHTML, like Gecko) Chrome/${safeVersion} Mobile Safari/537.36`
    );
  }

  return (
    `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ` +
    `(KHTML, like Gecko) Chrome/${safeVersion} Safari/537.36`
  );
}

const INTERNAL_TAURI_HOSTS = ['tauri.localhost', 'ipc.localhost', 'asset.localhost'];

export function isInternalTauriUrl(parsed: URL): boolean {
  if (parsed.protocol === 'tauri:' || parsed.protocol === 'ipc:' || parsed.protocol === 'asset:') {
    return true;
  }
  const host = parsed.hostname.toLowerCase();
  return INTERNAL_TAURI_HOSTS.some((h) => host === h || host.endsWith(`.${h}`));
}

/**
 * ユーザー入力URLを正規化し、安全な http/https URL のみ許可する。
 */
export function normalizeServiceUrl(rawInput: string): string | null {
  const trimmed = rawInput.trim();
  if (!trimmed || /[\x00-\x1f\x7f\s"\\]/.test(trimmed)) return null;

  const candidate = /^[a-zA-Z][a-zA-Z\d+\-.]*:\/\//.test(trimmed)
    ? trimmed
    : `https://${trimmed}`;

  try {
    const parsed = new URL(candidate);
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
      return null;
    }
    if (!parsed.hostname || isInternalTauriUrl(parsed)) {
      return null;
    }
    return parsed.toString();
  } catch {
    return null;
  }
}

const SAFE_DATA_IMAGE_PREFIXES = [
  'data:image/png;',
  'data:image/jpeg;',
  'data:image/jpg;',
  'data:image/gif;',
  'data:image/webp;',
  'data:image/x-icon;',
  'data:image/vnd.microsoft.icon;',
  'data:image/bmp;'
];

/**
 * ファビコンとして安全な URL（http/https または raster data:image/*）のみ許可する。
 * data:image/svg+xml、file://、javascript:、内部 tauri.localhost 等を拒否する。
 */
export function isSafeFaviconUrl(rawUrl?: string | null): boolean {
  if (!rawUrl) return false;
  const trimmed = rawUrl.trim();
  if (!trimmed || /[\x00-\x1f\x7f]/.test(trimmed)) return false;
  const lower = trimmed.toLowerCase();
  if (SAFE_DATA_IMAGE_PREFIXES.some((prefix) => lower.startsWith(prefix))) {
    return true;
  }
  if (/[\s"\\]/.test(trimmed)) return false;
  try {
    const parsed = new URL(trimmed);
    return (
      (parsed.protocol === 'https:' || parsed.protocol === 'http:') &&
      Boolean(parsed.hostname) &&
      !isInternalTauriUrl(parsed)
    );
  } catch {
    return false;
  }
}

export function isValidGitHubToken(token: string): boolean {
  const trimmed = token.trim();
  return /^[\x21-\x7E]{1,512}$/.test(trimmed);
}

export function isValidGistId(gistId: string): boolean {
  const trimmed = gistId.trim();
  return trimmed === '' || /^[A-Za-z0-9_-]{1,64}$/.test(trimmed);
}

export function parseSharedSyncConfig(raw: string): { token: string; gistId: string } | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;
  const jsonPart = trimmed.startsWith('OMNISNS_SYNC_V1:')
    ? trimmed.slice('OMNISNS_SYNC_V1:'.length).trim()
    : trimmed;
  if (!jsonPart.startsWith('{')) return null;
  try {
    const parsed = JSON.parse(jsonPart) as { token?: unknown; gistId?: unknown };
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
    const token = typeof parsed.token === 'string' ? parsed.token.trim() : '';
    const gistId = typeof parsed.gistId === 'string' ? parsed.gistId.trim() : '';
    if (!token && !gistId) return null;
    if (token && !isValidGitHubToken(token)) return null;
    if (!isValidGistId(gistId)) return null;
    return { token, gistId };
  } catch {
    return null;
  }
}

/**
 * ページタイトルから未読件数を抽出する。
 * 例: "(3) X / Messages", "[12] Discord", "• 5 messages", "99+ 未読"
 */
export function parseUnreadCountFromTitle(title: string): number {
  if (!title) return 0;

  // パターン1: 先頭や括弧内の数値 "(3)", "(99+)", "[5]"
  const bracketMatch = title.match(/^\s*[(\[]\s*(\d+)\+?\s*[)\]]/);
  if (bracketMatch) {
    return Math.min(999, parseInt(bracketMatch[1], 10) || 0);
  }

  // パターン2: タイトル途中の "(3)" 等（ただし西暦2024など4桁以上は除外）
  const inlineMatch = title.match(/[(\[](\d{1,3})\+?[)\]]/);
  if (inlineMatch) {
    return Math.min(999, parseInt(inlineMatch[1], 10) || 0);
  }

  // パターン3: 未読ドット記号（Discord/Slackの "•" や "●"）
  if (/^\s*[•●🔴]/.test(title)) {
    return 1;
  }

  return 0;
}

const AUTH_HOST_PATTERNS: RegExp[] = [
  /(^|\.)accounts\.google\.com$/i,
  /(^|\.)appleid\.apple\.com$/i,
  /(^|\.)access\.line\.me$/i,
  /(^|\.)login\.microsoftonline\.com$/i,
  /(^|\.)login\.live\.com$/i,
  /(^|\.)auth\.login\.yahoo\.co\.jp$/i,
  /(^|\.)login\.yahoo\.co\.jp$/i,
  /(^|\.)facebook\.com$/i,
  /(^|\.)api\.twitter\.com$/i,
  /(^|\.)twitter\.com$/i,
  /(^|\.)x\.com$/i,
  /(^|\.)github\.com$/i,
  /(^|\.)discord\.com$/i,
  /(^|\.)id\.mixi\.social$/i,
  /(^|\.)auth\./i,
  /(^|\.)sso\./i,
  /(^|\.)oauth\./i,
  /(^|\.)login\./i,
  /(^|\.)signin\./i
];

const AUTH_PATH_KEYWORDS = [
  '/oauth',
  '/auth',
  '/login',
  '/signin',
  '/sign-in',
  '/sso',
  '/authorize',
  '/dialog/oauth',
  '/verify',
  '/captcha',
  '/challenge'
];

function canonicalSiteGroup(domain: string): string {
  return domain === 'threads.net' ? 'threads.com' : domain;
}

export function isSameSiteUrl(targetUrl: string, currentServiceUrl: string): boolean {
  try {
    const target = new URL(targetUrl);
    if (target.protocol !== 'https:' && target.protocol !== 'http:') {
      return false;
    }
    const current = new URL(currentServiceUrl);
    return (
      canonicalSiteGroup(getRegistrableDomainHint(target.hostname)) ===
      canonicalSiteGroup(getRegistrableDomainHint(current.hostname))
    );
  } catch {
    return false;
  }
}

/**
 * ポップアップURLが認証（OAuth / SSO / 本人確認）や同一サービスのサブウィンドウかを判定する。
 * true なら同じセッションパーティションを共有するアプリ内子ウィンドウで開く。
 */
export function shouldOpenInAppPopup(targetUrl: string, currentServiceUrl: string): boolean {
  try {
    const target = new URL(targetUrl);
    if (target.protocol !== 'https:' && target.protocol !== 'http:') {
      return false;
    }

    if (AUTH_HOST_PATTERNS.some((pattern) => pattern.test(target.hostname))) {
      return true;
    }

    const lowerPath = target.pathname.toLowerCase();
    if (AUTH_PATH_KEYWORDS.some((kw) => lowerPath.includes(kw))) {
      return true;
    }

    // 同一ルートドメイン（サブドメイン・threads.net/threads.com 含む）はアプリ内で許可
    if (isSameSiteUrl(targetUrl, currentServiceUrl)) {
      return true;
    }

    return false;
  } catch {
    return false;
  }
}

/**
 * 簡易的にルートドメイン末尾2〜3ラベル（co.jp 等考慮）を取り出す。
 */
export function getRegistrableDomainHint(hostname: string): string {
  const parts = hostname.toLowerCase().split('.').filter(Boolean);
  if (parts.length <= 2) return parts.join('.');
  const lastTwo = parts.slice(-2).join('.');
  if (['co.jp', 'ne.jp', 'or.jp', 'ac.jp', 'go.jp', 'co.uk', 'com.au'].includes(lastTwo)) {
    return parts.slice(-3).join('.');
  }
  return lastTwo;
}

/**
 * サービス名から最大2文字のバッジ文字を生成する。
 */
export function makeBadgeText(name: string): string {
  const cleaned = name.trim();
  if (!cleaned) return 'SN';

  const asciiWords = cleaned.match(/[A-Za-z0-9]+/g);
  if (asciiWords && asciiWords.length >= 2) {
    return (asciiWords[0][0] + asciiWords[1][0]).toUpperCase();
  }
  if (asciiWords && asciiWords.length === 1 && asciiWords[0].length >= 2) {
    return asciiWords[0].slice(0, 2).toUpperCase();
  }
  return Array.from(cleaned).slice(0, 2).join('').toUpperCase();
}

/**
 * 同一SNSをグルーピングするためのキーを返す。
 * カタログ登録サービスは serviceId で束ね、カスタムサービスはホスト名単位で束ねる。
 */
export function getServiceGroupKey(inst: {
  serviceId: string;
  url: string;
  instanceId: string;
}): string {
  const sid = inst.serviceId?.trim();
  if (sid && sid !== 'custom') {
    return sid;
  }
  try {
    const parsed = new URL(inst.url);
    if (parsed.hostname) {
      return `custom:${parsed.hostname.toLowerCase()}`;
    }
  } catch {
    // ignore
  }
  return `custom:${inst.instanceId}`;
}

/**
 * 同一SNS内でのアカウント表示名（ヘッダー切替ピル用）を決定する。
 */
export function getAccountDisplayLabel(
  inst: { name: string; accountLabel?: string },
  siblingIndex: number,
  baseServiceName?: string
): string {
  const explicit = inst.accountLabel?.trim();
  if (explicit) return explicit;

  const rawName = inst.name.trim();
  const base = baseServiceName?.trim();
  if (base && rawName) {
    if (rawName === base) {
      return siblingIndex === 0 ? 'メイン' : `アカウント ${siblingIndex + 1}`;
    }
    if (rawName.startsWith(base)) {
      const rest = rawName.slice(base.length).trim();
      const numMatch = rest.match(/^\((\d+)\)$/);
      if (numMatch) {
        return `アカウント ${numMatch[1]}`;
      }
      const cleaned = rest.replace(/^[-–—・:/／\s]+/, '').trim();
      if (cleaned) return cleaned;
    }
    return rawName;
  }

  return siblingIndex === 0 ? 'メイン' : `アカウント ${siblingIndex + 1}`;
}

/**
 * 既存アカウント名と重複しない次の既定アカウント名を返す。
 */
export function nextDefaultAccountLabel(existingLabels: string[]): string {
  const used = new Set(existingLabels.map((s) => s.trim()).filter(Boolean));
  if (used.size === 0) return 'メイン';
  let n = used.size + 1;
  while (used.has(`アカウント ${n}`)) {
    n += 1;
  }
  return `アカウント ${n}`;
}

/**
 * 現在表示中のURLから対応する主要SNSカタログIDを推定する。
 * 例: Threadsタブ内で Instagram を開いた際に 'instagram' を返す。
 */
export function detectPlatformServiceFromUrl(rawUrl?: string | null): string | null {
  if (!rawUrl || !rawUrl.trim()) return null;
  try {
    const parsed = new URL(rawUrl.trim());
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return null;
    const host = parsed.hostname.toLowerCase();
    const matchHost = (domain: string) => host === domain || host.endsWith(`.${domain}`);
    if (matchHost('instagram.com')) return 'instagram';
    if (matchHost('threads.com') || matchHost('threads.net')) return 'threads';
    if (matchHost('bsky.app') || matchHost('bsky.social')) return 'bluesky';
    if (matchHost('mixi.social')) return 'mixi2';
    if (matchHost('x.com') || matchHost('twitter.com')) return 'x';
    if (matchHost('tiktok.com')) return 'tiktok';
    if (matchHost('facebook.com')) return 'facebook';
    if (matchHost('messenger.com')) return 'messenger';
    if (matchHost('note.com')) return 'note';
    if (matchHost('youtube.com')) return 'youtube';
    if (matchHost('twitch.tv')) return 'twitch';
    if (matchHost('reddit.com')) return 'reddit';
    if (matchHost('pinterest.com') || matchHost('pinterest.jp')) return 'pinterest';
    if (matchHost('linkedin.com')) return 'linkedin';
    if (matchHost('tumblr.com')) return 'tumblr';
    if (matchHost('pixiv.net')) return 'pixiv';
  } catch {
    // ignore
  }
  return null;
}
