import test from 'node:test';
import assert from 'node:assert/strict';
import { CATEGORIES, SERVICE_CATALOG } from '../src/shared/catalog';
import {
  buildUserAgent,
  getAccountDisplayLabel,
  getServiceGroupKey,
  isSameSiteUrl,
  makeBadgeText,
  nextDefaultAccountLabel,
  normalizeServiceUrl,
  parseUnreadCountFromTitle,
  shouldOpenInAppPopup
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
