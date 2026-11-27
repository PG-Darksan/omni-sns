import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { CATEGORIES, SERVICE_CATALOG } from '../src/shared/catalog';
import {
  buildUserAgent,
  detectPlatformServiceFromUrl,
  formatArchivedAccountTitle,
  getAccountDisplayLabel,
  getServiceGroupKey,
  isGenericAccountLabel,
  isSafeFaviconUrl,
  isSameSiteUrl,
  isValidGistId,
  isValidGitHubToken,
  makeBadgeText,
  nextDefaultAccountLabel,
  normalizeServiceUrl,
  parseSharedSyncConfig,
  parseUnreadCountFromTitle,
  shouldOpenInAppPopup,
  sortCatalogServices
} from '../src/shared/url-utils';

test('SERVICE_CATALOG has unique IDs, valid HTTPS URLs, valid categories, and excludes paid-messaging SNS', () => {
  assert.equal(CATEGORIES.length, 5, `Expected 5 categories, got ${CATEGORIES.length}`);
  assert.equal(SERVICE_CATALOG.length, 44, `Expected 44 services, got ${SERVICE_CATALOG.length}`);
  for (const removed of [
    'x',
    'pairs',
    'with',
    'tapple',
    'omiai',
    'marrish',
    'ange',
    'youbride',
    'bridalnet',
    'tokyo-calendar-date',
    'match',
    'grindr',
    'happymail',
    'wakuwaku',
    'pcmax',
    'ikukuru',
    'meetup'
  ]) {
    assert.ok(
      !SERVICE_CATALOG.some((s) => s.id === removed),
      `${removed} must not be in SERVICE_CATALOG`
    );
  }

  const categoryIds = new Set(CATEGORIES.map((c) => c.id));
  const seenIds = new Set<string>();

  for (const svc of SERVICE_CATALOG) {
    assert.ok(!seenIds.has(svc.id), `Duplicate service id: ${svc.id}`);
    seenIds.add(svc.id);
    assert.ok(categoryIds.has(svc.category), `Unknown category ${svc.category} on ${svc.id}`);
    assert.ok(normalizeServiceUrl(svc.url)?.startsWith('https://'), `Invalid URL on ${svc.id}: ${svc.url}`);
    assert.ok(normalizeServiceUrl(svc.homeUrl)?.startsWith('https://'), `Invalid homeUrl on ${svc.id}`);
    assert.match(svc.color, /^#[0-9A-Fa-f]{6}$/, `Invalid color on ${svc.id}: ${svc.color}`);
    assert.ok(svc.badge.length >= 1 && svc.badge.length <= 2, `Invalid badge on ${svc.id}: ${svc.badge}`);
  }

  // 無料プランでメッセージ送信できるマッチングサービスのみ収録されていること
  const matchingCount = SERVICE_CATALOG.filter((s) => s.category === 'matching-global').length;
  assert.equal(matchingCount, 5, `Expected 5 free-messaging matching services, got ${matchingCount}`);
});

test('buildUserAgent strips Electron/Edg token and differentiates desktop vs mobile', () => {
  const desktopUa = buildUserAgent('desktop', '136.0.0.0');
  const mobileUa = buildUserAgent('mobile', '136.0.0.0');

  assert.ok(!desktopUa.includes('Electron'));
  assert.ok(!desktopUa.includes('Edg/'));
  assert.ok(desktopUa.includes('Windows NT 10.0'));
  assert.ok(desktopUa.includes('Chrome/136.0.0.0'));

  assert.ok(!mobileUa.includes('Electron'));
  assert.ok(!mobileUa.includes('Edg/'));
  assert.ok(mobileUa.includes('Mobile Safari'));
  assert.ok(mobileUa.includes('Android'));
});

test('normalizeServiceUrl validates and normalizes URLs safely', () => {
  assert.equal(normalizeServiceUrl('bsky.app/messages'), 'https://bsky.app/messages');
  assert.equal(normalizeServiceUrl('https://tinder.com/'), 'https://tinder.com/');
  assert.equal(normalizeServiceUrl('javascript:alert(1)'), null);
  assert.equal(normalizeServiceUrl('file:///C:/Windows/System32'), null);
  assert.equal(normalizeServiceUrl('   '), null);
});

test('parseUnreadCountFromTitle extracts unread badges accurately', () => {
  assert.equal(parseUnreadCountFromTitle('(3) Bluesky / Messages'), 3);
  assert.equal(parseUnreadCountFromTitle('(99+) Instagram'), 99);
  assert.equal(parseUnreadCountFromTitle('[12] Discord'), 12);
  assert.equal(parseUnreadCountFromTitle('• Slack - general'), 1);
  assert.equal(parseUnreadCountFromTitle('Threads - Home'), 0);
  assert.equal(parseUnreadCountFromTitle('Report (2026)'), 0);
});

test('shouldOpenInAppPopup allows OAuth and same-site popups while sending external links out', () => {
  assert.equal(
    shouldOpenInAppPopup('https://accounts.google.com/o/oauth2/auth', 'https://tinder.com/'),
    true
  );
  assert.equal(
    shouldOpenInAppPopup('https://access.line.me/oauth2/v2.1/authorize', 'https://mixi.social/'),
    true
  );
  assert.equal(
    shouldOpenInAppPopup('https://appleid.apple.com/auth/authorize', 'https://bumble.com/app'),
    true
  );
  assert.equal(
    shouldOpenInAppPopup('https://sub.instagram.com/verify', 'https://www.instagram.com/direct/inbox/'),
    true
  );
  assert.equal(
    shouldOpenInAppPopup('https://news.yahoo.co.jp/articles/123', 'https://bsky.app/messages'),
    false
  );
  assert.equal(
    isSameSiteUrl('https://www.threads.net/@alice', 'https://www.threads.com/'),
    true
  );
});

test('makeBadgeText generates concise 2-char badges', () => {
  assert.equal(makeBadgeText('Bluesky'), 'BL');
  assert.equal(makeBadgeText('Steam Chat'), 'SC');
  assert.equal(makeBadgeText('ミクシィ'), 'ミク');
});

test('account grouping and display label helpers work cleanly for multi-account SNS', () => {
  assert.equal(
    getServiceGroupKey({
      serviceId: 'instagram',
      url: 'https://www.instagram.com/direct/inbox/',
      instanceId: 'svc-ig-1'
    }),
    'instagram'
  );
  assert.equal(
    getServiceGroupKey({
      serviceId: 'custom',
      url: 'https://Chat.Example.com/room',
      instanceId: 'svc-c-1'
    }),
    'custom:chat.example.com'
  );

  assert.equal(getAccountDisplayLabel({ name: 'Instagram' }, 0, 'Instagram'), 'メイン');
  assert.equal(getAccountDisplayLabel({ name: 'Instagram (2)' }, 1, 'Instagram'), 'アカウント 2');
  assert.equal(getAccountDisplayLabel({ name: 'Instagram サブ' }, 1, 'Instagram'), 'サブ');
  assert.equal(
    getAccountDisplayLabel({ name: 'Instagram', accountLabel: '仕事用' }, 1, 'Instagram'),
    '仕事用'
  );

  assert.equal(nextDefaultAccountLabel([]), 'メイン');
  assert.equal(nextDefaultAccountLabel(['メイン']), 'アカウント 2');
  assert.equal(nextDefaultAccountLabel(['メイン', 'アカウント 2']), 'アカウント 3');
  assert.equal(nextDefaultAccountLabel(['メイン', 'アカウント 3', '仕事用']), 'アカウント 4');
});

test('detectPlatformServiceFromUrl identifies Instagram opened inside Threads tab', () => {
  assert.equal(
    detectPlatformServiceFromUrl('https://www.instagram.com/alice/followers/'),
    'instagram'
  );
  assert.equal(detectPlatformServiceFromUrl('https://www.threads.com/@alice'), 'threads');
  assert.equal(detectPlatformServiceFromUrl('https://www.threads.net/@alice'), 'threads');
  assert.equal(detectPlatformServiceFromUrl('https://bsky.app/profile/alice.bsky.social'), 'bluesky');
  assert.equal(detectPlatformServiceFromUrl('https://example.com/other'), null);
  assert.equal(detectPlatformServiceFromUrl('javascript://instagram.com/%0aalert(1)'), null);
});

test('security validators block internal Tauri hosts, SVG/script favicons, and sync header/path injection', () => {
  assert.equal(normalizeServiceUrl('http://tauri.localhost/index.html'), null);
  assert.equal(normalizeServiceUrl('https://sub.ipc.localhost/foo'), null);
  assert.equal(normalizeServiceUrl('https://example.com/\r\nX-Inject: 1'), null);
  assert.equal(normalizeServiceUrl('https://example.com/" --arg'), null);

  assert.equal(isSafeFaviconUrl('https://www.instagram.com/favicon.ico'), true);
  assert.equal(isSafeFaviconUrl('data:image/png;base64,iVBORw0KGgo='), true);
  assert.equal(isSafeFaviconUrl('data:image/svg+xml,<svg onload=alert(1)>'), false);
  assert.equal(isSafeFaviconUrl('javascript:alert(1)'), false);
  assert.equal(isSafeFaviconUrl('file:///C:/Windows/win.ini'), false);
  assert.equal(isSafeFaviconUrl('http://tauri.localhost/icon.png'), false);

  assert.equal(isValidGitHubToken('ghp_validToken123456'), true);
  assert.equal(isValidGitHubToken('ghp_bad\r\nX-Evil: 1'), false);
  assert.equal(isValidGitHubToken('ghp_bad token'), false);
  assert.equal(isValidGistId(''), true);
  assert.equal(isValidGistId('gist_abc123-XYZ'), true);
  assert.equal(isValidGistId('../users/me'), false);
  assert.equal(isValidGistId('abc?x=1'), false);

  assert.deepEqual(
    parseSharedSyncConfig('OMNISNS_SYNC_V1:{"token":"ghp_abc123","gistId":"gist_01"}'),
    { token: 'ghp_abc123', gistId: 'gist_01' }
  );
  assert.equal(
    parseSharedSyncConfig('OMNISNS_SYNC_V1:{"token":"ghp_abc\\r\\nEvil: 1","gistId":"gist_01"}'),
    null
  );
  assert.equal(
    parseSharedSyncConfig('OMNISNS_SYNC_V1:{"token":"ghp_abc123","gistId":"../other"}'),
    null
  );
});

test('Windows and Android PROFILE_STATS_JS are valid JS with universal mutual-follow, following-heavy color, and Instagram perf optimizations', () => {
  const winSrc = fs.readFileSync(
    path.resolve(process.cwd(), 'src-tauri/src/platform_win.rs'),
    'utf8'
  );
  const winMatch = /pub const PROFILE_STATS_JS: &str = r#"([\s\S]*?)"#;/.exec(winSrc);
  assert.ok(winMatch, 'Windows PROFILE_STATS_JS must exist');
  const winJs = winMatch[1];
  assert.doesNotThrow(() => new Function(winJs), 'Windows PROFILE_STATS_JS must parse cleanly');

  const ktSrc = fs.readFileSync(
    path.resolve(
      process.cwd(),
      'mobile/android/app/src/main/kotlin/com/pgdarksan/omni_sns_mobile/OmniWebView.kt'
    ),
    'utf8'
  );
  const partRe = /private val PROFILE_STATS_JS_PART_\d+: String = """\r?\n([\s\S]*?)\r?\n"""/g;
  const parts: string[] = [];
  let pm: RegExpExecArray | null;
  while ((pm = partRe.exec(ktSrc)) !== null) {
    assert.ok(
      Buffer.byteLength(pm[1], 'utf8') < 60000,
      'Each Kotlin string literal part must stay safely under JVM 65535-byte CONSTANT_Utf8 limit'
    );
    parts.push(pm[1]);
  }
  assert.ok(parts.length >= 2, 'Android PROFILE_STATS_JS should be split into safe parts');
  const andJs = parts.join('\n');
  assert.doesNotThrow(() => new Function(andJs), 'Android PROFILE_STATS_JS must parse cleanly');

  for (const [label, js] of [
    ['Windows', winJs],
    ['Android', andJs]
  ] as const) {
    // 相互フォロー判定ピル & フォロー中＞フォロワーの色分け
    assert.ok(js.includes('⇄ 相互'), `${label} must render mutual badge`);
    assert.ok(js.includes('→ 片思い'), `${label} must render oneway badge`);
    assert.ok(js.includes('← フォロワー'), `${label} must render follower badge`);
    assert.ok(js.includes('is-following-heavy'), `${label} must highlight following > followers users`);
    assert.ok(js.includes('data-omni-ff-heavy'), `${label} must accent following-heavy rows`);
    // 全SNS対応プラットフォーム判定
    for (const p of ['instagram', 'threads', 'bluesky', 'tiktok', 'mastodon', 'misskey', 'mixi2', 'pixiv', 'facebook', 'generic']) {
      assert.ok(js.includes(`'${p}'`), `${label} must support ${p}`);
    }
    // Instagram パフォーマンス最適化（CDN preconnect / 並列ワーカー / 失敗ルートスキップ / show_many バッチ）
    assert.ok(js.includes('injectInstagramPreconnects'), `${label} must inject Instagram CDN preconnects`);
    assert.ok(js.includes('igConcurrency'), `${label} must use parallel workers on Instagram`);
    assert.ok(js.includes('deadRouteUntil'), `${label} must skip failing Instagram routes`);
    assert.ok(js.includes('/api/v1/friendships/show_many/'), `${label} must batch-fetch Instagram friendships`);
    // 投稿数は取得・表示しない
    assert.ok(!js.includes("parts.push('投稿 '"), `${label} must not display post count in inline badge`);
    // コンパクトなフォロー・フォロワー表記（F/FW）と片思い経過時間メモリ
    assert.ok(js.includes("'/FW'"), `${label} must use compact F/FW inline stats format`);
    assert.ok(!js.includes("parts.push('フォロー '"), `${label} must not use verbose フォロー label in badge`);
    assert.ok(js.includes('FOLLOWED_AT_KEY'), `${label} must persist followed user timestamps`);
    assert.ok(js.includes('formatOnewayElapsedCompact'), `${label} must format oneway elapsed hours`);
    assert.ok(js.includes("totalHours + '時間'"), `${label} must display elapsed hours for oneway follows`);
    // フォロー一覧の行バッジがフォローボタンに隠れないよう配置を調整（PC版レイアウトを狭い画面で表示した時など）
    assert.ok(js.includes('function applyRowBadgePlacements'), `${label} must relocate row badges overlapped by the follow button`);
    assert.ok(js.includes('applyRowBadgePlacements(placements)'), `${label} must apply row badge placements after each list scan`);
    for (const mode of ['is-push', 'is-below', 'is-overlay', 'is-raised']) {
      assert.ok(js.includes(mode), `${label} must style ${mode} row badge placement`);
    }
    assert.ok(js.includes('rowColCache'), `${label} must cache the row text column between scans`);
    assert.ok(js.includes('__omniIsFollowingUser'), `${label} must expose follow-state cache for block-as-unfollow`);
    assert.ok(js.includes('/api/v1/accounts/current_user/'), `${label} must support cookie-based Instagram self-handle fallback`);
    assert.ok(js.includes('extractFetchUrl'), `${label} must extract URLs from URL/Request fetch inputs`);
    assert.ok(js.includes('stripInvisibleChars'), `${label} must strip Unicode bidi isolates from Bluesky handles`);
    assert.ok(js.includes('__omniAccountFilterApplyConfig'), `${label} must expose account condition filter config hook`);
    assert.ok(js.includes('omni-af-active'), `${label} must style account condition filter hiding`);
    assert.ok(js.includes('recordBlueskyProfile'), `${label} must record Bluesky stats by handle and DID`);
  }
});

test('Windows and Android LONG_PRESS_NEW_TAB_JS and JEV_FILTER_JS parse cleanly and fit JVM string limits', () => {
  const winSrc = fs.readFileSync(
    path.resolve(process.cwd(), 'src-tauri/src/platform_win.rs'),
    'utf8'
  );
  const ktSrc = fs.readFileSync(
    path.resolve(
      process.cwd(),
      'mobile/android/app/src/main/kotlin/com/pgdarksan/omni_sns_mobile/OmniWebView.kt'
    ),
    'utf8'
  );

  const winLpMatch = /pub const LONG_PRESS_NEW_TAB_JS: &str = r#"([\s\S]*?)"#;/.exec(winSrc);
  assert.ok(winLpMatch, 'Windows LONG_PRESS_NEW_TAB_JS must exist');
  assert.doesNotThrow(() => new Function(winLpMatch[1]));

  const winJevMatch = /pub const JEV_FILTER_JS: &str = r#"([\s\S]*?)"#;/.exec(winSrc);
  assert.ok(winJevMatch, 'Windows JEV_FILTER_JS must exist');
  assert.doesNotThrow(() => new Function(winJevMatch[1]));

  const ktLpMatch = /val LONG_PRESS_NEW_TAB_JS: String = """\r?\n([\s\S]*?)\r?\n"""/.exec(ktSrc);
  assert.ok(ktLpMatch, 'Android LONG_PRESS_NEW_TAB_JS must exist');
  assert.ok(Buffer.byteLength(ktLpMatch[1], 'utf8') < 60000);
  assert.doesNotThrow(() => new Function(ktLpMatch[1]));

  const jevPartRe = /private val JEV_FILTER_JS_PART_\d+: String = """\r?\n([\s\S]*?)\r?\n"""/g;
  const jevParts: string[] = [];
  let jm: RegExpExecArray | null;
  while ((jm = jevPartRe.exec(ktSrc)) !== null) {
    assert.ok(
      Buffer.byteLength(jm[1], 'utf8') < 60000,
      'Each Kotlin JEV_FILTER_JS part must stay under JVM 65535-byte limit'
    );
    jevParts.push(jm[1]);
  }
  assert.ok(jevParts.length >= 1, 'Android JEV_FILTER_JS parts must exist');
  const andJevJs = jevParts.join('\n');
  assert.doesNotThrow(() => new Function(andJevJs));

  for (const [label, lp, jev] of [
    ['Windows', winLpMatch[1], winJevMatch[1]],
    ['Android', ktLpMatch[1], andJevJs]
  ] as const) {
    assert.ok(lp.includes('omnisns:open-new-tab'), `${label} long-press must support Windows bridge`);
    assert.ok(lp.includes('onOpenNewTab'), `${label} long-press must support Android bridge`);
    assert.ok(jev.includes('__omniJevApplyConfig'), `${label} Jev filter must expose config hook`);
    assert.ok(jev.includes('__omniJevResolve'), `${label} Jev filter must expose batch resolver`);
    assert.ok(jev.includes('omni-jev-active'), `${label} Jev filter must toggle CSS class`);
  }
});

test('Windows and Android FOLLOW_TRACKER_JS parse cleanly, count followed-user blocks as unfollow, and fit JVM string limits', () => {
  const winSrc = fs.readFileSync(
    path.resolve(process.cwd(), 'src-tauri/src/platform_win.rs'),
    'utf8'
  );
  const ktSrc = fs.readFileSync(
    path.resolve(
      process.cwd(),
      'mobile/android/app/src/main/kotlin/com/pgdarksan/omni_sns_mobile/OmniWebView.kt'
    ),
    'utf8'
  );

  const winFtMatch = /pub const FOLLOW_TRACKER_JS: &str = r#"([\s\S]*?)"#;/.exec(winSrc);
  assert.ok(winFtMatch, 'Windows FOLLOW_TRACKER_JS must exist');
  assert.doesNotThrow(() => new Function(winFtMatch[1]), 'Windows FOLLOW_TRACKER_JS must parse cleanly');

  const ktFtMatch = /val FOLLOW_TRACKER_JS: String = """\r?\n([\s\S]*?)\r?\n[ \t]*"""/.exec(ktSrc);
  assert.ok(ktFtMatch, 'Android FOLLOW_TRACKER_JS must exist');
  assert.ok(
    Buffer.byteLength(ktFtMatch[1], 'utf8') < 60000,
    `Android FOLLOW_TRACKER_JS (${Buffer.byteLength(ktFtMatch[1], 'utf8')} bytes) must stay safely under JVM 65535-byte CONSTANT_Utf8 limit`
  );
  assert.doesNotThrow(() => new Function(ktFtMatch[1]), 'Android FOLLOW_TRACKER_JS must parse cleanly');

  for (const [label, js] of [
    ['Windows', winFtMatch[1]],
    ['Android', ktFtMatch[1]]
  ] as const) {
    assert.ok(js.includes('handleBlockCompleted'), `${label} must handle followed-user block as unfollow`);
    assert.ok(js.includes('__omniIsFollowingUser'), `${label} must inspect followed-user cache before counting block`);
    assert.ok(js.includes('friendships\\/(?:create|destroy|block)'), `${label} must detect Instagram/Threads block endpoints`);
    assert.ok(js.includes('app.bsky.graph.block'), `${label} must detect Bluesky block endpoints`);
    assert.ok(js.includes('extractFetchUrl'), `${label} must handle URL/Request objects passed to fetch`);
    assert.ok(js.includes('decodeBytesToString'), `${label} must decode Uint8Array/ArrayBuffer bodies`);
  }
});

test('Bluesky FOLLOW_TRACKER_JS counts URL/Uint8Array/Request rapid follows accurately without drops or post false-positives', async () => {
  const winSrc = fs.readFileSync(
    path.resolve(process.cwd(), 'src-tauri/src/platform_win.rs'),
    'utf8'
  );
  const winFtMatch = /pub const FOLLOW_TRACKER_JS: &str = r#"([\s\S]*?)"#;/.exec(winSrc);
  assert.ok(winFtMatch);

  const posted: Array<{ type: string; source?: string; service?: string }> = [];
  const boundUris: Array<[string, string]> = [];
  const baseFetch = async (input: unknown) => {
    const u = typeof input === 'string' ? input : (input instanceof URL ? input.href : (input as { url?: string })?.url || '');
    const isCreate = u.includes('createRecord');
    return {
      ok: true,
      status: 200,
      clone() {
        return {
          text: async () =>
            isCreate
              ? JSON.stringify({ uri: 'at://did:plc:self/app.bsky.graph.follow/rkey_test_1' })
              : '{}'
        };
      }
    };
  };

  const sandbox: Record<string, unknown> = {
    URL,
    URLSearchParams,
    TextDecoder,
    TextEncoder,
    Uint8Array,
    ArrayBuffer,
    Promise,
    Date,
    setTimeout,
    clearTimeout,
    location: { hostname: 'bsky.app', pathname: '/profile/someone.bsky.social/followers', href: 'https://bsky.app/profile/someone.bsky.social/followers' },
    document: {
      addEventListener() {},
      querySelector() { return null; }
    },
    XMLHttpRequest: undefined,
    chrome: {
      webview: {
        postMessage(raw: string) {
          posted.push(JSON.parse(raw));
        }
      }
    },
    __omniBindBlueskyFollowUri(subject: string, uri: string) {
      boundUris.push([subject, uri]);
    }
  };
  sandbox.window = sandbox;
  sandbox.top = sandbox;
  sandbox.fetch = baseFetch;

  vm.runInNewContext(winFtMatch[1], sandbox);
  const hookedFetch = sandbox.fetch as (input: unknown, init?: unknown) => Promise<unknown>;

  // 1. 連続5人を URL オブジェクト + Uint8Array / string body で素早くフォロー → 5件すべてカウント（取りこぼし無し）
  for (let i = 1; i <= 5; i++) {
    const bodyJson = JSON.stringify({
      repo: 'did:plc:self',
      collection: 'app.bsky.graph.follow',
      record: { subject: `did:plc:user${i}`, createdAt: new Date().toISOString() }
    });
    const body = i % 2 === 1 ? new TextEncoder().encode(bodyJson) : bodyJson;
    await hookedFetch(new URL('https://pds.bsky.network/xrpc/com.atproto.repo.createRecord'), {
      method: 'POST',
      body
    });
  }

  // 2. 本文に "app.bsky.graph.follow" を含む通常投稿（app.bsky.feed.post）は誤カウントしない
  await hookedFetch(new URL('https://pds.bsky.network/xrpc/com.atproto.repo.createRecord'), {
    method: 'POST',
    body: JSON.stringify({
      repo: 'did:plc:self',
      collection: 'app.bsky.feed.post',
      record: { text: 'testing app.bsky.graph.follow mention' }
    })
  });

  // 3. deleteRecord によるアンフォローを正確にカウントし、その直後の同一ユーザー再フォローもカウントする
  sandbox.__omniCanonicalTargetKey = (rawKey: string) =>
    rawKey === 'rkey_test_1' ? 'did:plc:user1' : rawKey;
  await hookedFetch(new URL('https://pds.bsky.network/xrpc/com.atproto.repo.deleteRecord'), {
    method: 'POST',
    body: JSON.stringify({
      repo: 'did:plc:self',
      collection: 'app.bsky.graph.follow',
      rkey: 'rkey_test_1'
    })
  });
  await hookedFetch(new URL('https://pds.bsky.network/xrpc/com.atproto.repo.createRecord'), {
    method: 'POST',
    body: JSON.stringify({
      repo: 'did:plc:self',
      collection: 'app.bsky.graph.follow',
      record: { subject: 'did:plc:user1', createdAt: new Date().toISOString() }
    })
  });

  // 4. applyWrites でフォロー作成
  await hookedFetch(new URL('https://pds.bsky.network/xrpc/com.atproto.repo.applyWrites'), {
    method: 'POST',
    body: JSON.stringify({
      repo: 'did:plc:self',
      writes: [
        {
          $type: 'com.atproto.repo.applyWrites#create',
          collection: 'app.bsky.graph.follow',
          value: { subject: 'did:plc:user6' }
        }
      ]
    })
  });

  await new Promise((r) => setTimeout(r, 20));

  const followEvents = posted.filter((m) => m.type === 'omnisns:follow');
  const unfollowEvents = posted.filter((m) => m.type === 'omnisns:unfollow');
  assert.equal(followEvents.length, 7, `Expected 7 follows (5 initial + 1 re-follow + 1 applyWrites), got ${followEvents.length}`);
  assert.equal(unfollowEvents.length, 1, `Expected 1 unfollow, got ${unfollowEvents.length}`);
  assert.ok(boundUris.length >= 1, 'Expected createRecord follow URI to be bound for rkey resolution');
});

test('PROFILE_STATS_JS account condition filter evaluates F/FW thresholds and following>followers accurately', () => {
  const winSrc = fs.readFileSync(
    path.resolve(process.cwd(), 'src-tauri/src/platform_win.rs'),
    'utf8'
  );
  const winMatch = /pub const PROFILE_STATS_JS: &str = r#"([\s\S]*?)"#;/.exec(winSrc);
  assert.ok(winMatch);

  const sandbox: Record<string, unknown> = {
    URL,
    URLSearchParams,
    Promise,
    Date,
    Set,
    WeakMap,
    setTimeout() { return 1; },
    clearTimeout() {},
    setInterval() { return 1; },
    clearInterval() {},
    CustomEvent: class { constructor(public type: string, public detail?: unknown) {} },
    dispatchEvent() {},
    addEventListener() {},
    location: { hostname: 'bsky.app', pathname: '/profile/someone.bsky.social/followers', search: '', href: 'https://bsky.app/profile/someone.bsky.social/followers' },
    history: { pushState() {}, replaceState() {} },
    document: {
      readyState: 'loading',
      visibilityState: 'visible',
      cookie: '',
      documentElement: {
        classList: { add() {}, remove() {}, contains() { return false; } },
        setAttribute() {},
        appendChild() {}
      },
      head: { appendChild() {} },
      body: { appendChild() {}, querySelectorAll() { return []; } },
      getElementById() { return null; },
      createElement() { return { style: {}, setAttribute() {}, classList: { add() {}, remove() {} } }; },
      querySelector() { return null; },
      querySelectorAll() { return []; },
      addEventListener() {}
    },
    chrome: { webview: { postMessage() {} } },
    fetch: async () => ({ ok: false, status: 500 })
  };
  sandbox.window = sandbox;
  sandbox.top = sandbox;

  vm.runInNewContext(winMatch[1], sandbox);
  const applyCfg = sandbox.__omniAccountFilterApplyConfig as (cfg: Record<string, unknown>) => void;
  const evalFn = sandbox.__omniEvaluateAccountFilter as (entry: Record<string, unknown> | null, handle: string) => string;

  // OFF のときは常に match
  applyCfg({ enabled: false, minFollowing: 100 });
  assert.equal(evalFn({ following: 10, followers: 500 }, 'alice.bsky.social'), 'match');

  // フォロー100人以上 + フォロワー50人以上 + フォロー多め (F > FW)
  applyCfg({
    enabled: true,
    minFollowing: 100,
    maxFollowing: 1000,
    minFollowers: 50,
    maxFollowers: null,
    followingGreaterThanFollowers: true
  });
  assert.equal(evalFn({ following: 200, followers: 100 }, 'match.bsky.social'), 'match');
  assert.equal(evalFn({ following: 99, followers: 50 }, 'lowf.bsky.social'), 'hide');
  assert.equal(evalFn({ following: 1001, followers: 50 }, 'highf.bsky.social'), 'hide');
  assert.equal(evalFn({ following: 200, followers: 49 }, 'lowfw.bsky.social'), 'hide');
  assert.equal(evalFn({ following: 200, followers: 200 }, 'eq.bsky.social'), 'hide');
  assert.equal(evalFn({ following: 200, followers: 300 }, 'fwheavy.bsky.social'), 'hide');
  assert.equal(evalFn(null, 'pending.bsky.social'), 'pending');

  // 逆転した min/max も自動補正される
  applyCfg({ enabled: true, minFollowing: 300, maxFollowing: 100, followingGreaterThanFollowers: false });
  assert.equal(evalFn({ following: 200, followers: 999 }, 'mid.bsky.social'), 'match');
  assert.equal(evalFn({ following: 99, followers: 999 }, 'below.bsky.social'), 'hide');
  assert.equal(evalFn({ following: 301, followers: 999 }, 'above.bsky.social'), 'hide');
});

test('catalog reordering and archived account title helpers work cleanly', () => {
  const ordered = sortCatalogServices(
    [
      { id: 'instagram' },
      { id: 'threads' },
      { id: 'bluesky' },
      { id: 'discord' }
    ],
    ['discord', 'bluesky', 'unknown-id', 'bluesky']
  );
  assert.deepEqual(
    ordered.map((s) => s.id),
    ['discord', 'bluesky', 'instagram', 'threads']
  );

  assert.equal(isGenericAccountLabel(''), true);
  assert.equal(isGenericAccountLabel('メイン'), true);
  assert.equal(isGenericAccountLabel('アカウント 3'), true);
  assert.equal(isGenericAccountLabel('仕事用'), false);
  assert.equal(isGenericAccountLabel('@hanako'), false);

  assert.equal(
    formatArchivedAccountTitle({
      name: 'Instagram',
      accountLabel: 'アカウント 3',
      detectedHandle: 'hanako'
    }),
    'Instagram · @hanako'
  );
  assert.equal(
    formatArchivedAccountTitle({
      name: 'Instagram',
      accountLabel: '@hanako',
      detectedHandle: 'hanako'
    }),
    'Instagram · @hanako'
  );
  assert.equal(
    formatArchivedAccountTitle({
      name: 'Instagram',
      accountLabel: 'サブ垢',
      detectedHandle: 'sub_user'
    }),
    'Instagram · サブ垢 (@sub_user)'
  );
  assert.equal(
    getAccountDisplayLabel(
      { name: 'Instagram', accountLabel: 'アカウント 3', detectedHandle: 'hanako' },
      2,
      'Instagram'
    ),
    '@hanako'
  );
});
