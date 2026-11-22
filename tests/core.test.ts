import test from 'node:test';
import assert from 'node:assert/strict';
import { CATEGORIES, SERVICE_CATALOG } from '../src/shared/catalog';
import {
  buildUserAgent,
  makeBadgeText,
  normalizeServiceUrl,
  parseUnreadCountFromTitle,
  shouldOpenInAppPopup
} from '../src/shared/url-utils';

test('SERVICE_CATALOG has unique IDs, valid HTTPS URLs, and valid categories', () => {
  assert.equal(SERVICE_CATALOG.length, 60, `Expected 60 services, got ${SERVICE_CATALOG.length}`);
  assert.ok(!SERVICE_CATALOG.some((s) => s.id === 'x'), 'X must not be in SERVICE_CATALOG');
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

  // マッチング系カテゴリも通常カテゴリとして収録されていること
  const matchingCount = SERVICE_CATALOG.filter((s) => s.category.startsWith('matching-')).length;
  assert.ok(matchingCount >= 18, `Expected at least 18 matching/dating services, got ${matchingCount}`);
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
  assert.equal(normalizeServiceUrl('x.com/messages'), 'https://x.com/messages');
  assert.equal(normalizeServiceUrl('https://pairs.lv/'), 'https://pairs.lv/');
  assert.equal(normalizeServiceUrl('javascript:alert(1)'), null);
  assert.equal(normalizeServiceUrl('file:///C:/Windows/System32'), null);
  assert.equal(normalizeServiceUrl('   '), null);
});

test('parseUnreadCountFromTitle extracts unread badges accurately', () => {
  assert.equal(parseUnreadCountFromTitle('(3) X / Messages'), 3);
  assert.equal(parseUnreadCountFromTitle('(99+) Instagram'), 99);
  assert.equal(parseUnreadCountFromTitle('[12] Discord'), 12);
  assert.equal(parseUnreadCountFromTitle('• Slack - general'), 1);
  assert.equal(parseUnreadCountFromTitle('Threads - Home'), 0);
  assert.equal(parseUnreadCountFromTitle('Report (2026)'), 0);
});

test('shouldOpenInAppPopup allows OAuth and same-site popups while sending external links out', () => {
  assert.equal(
    shouldOpenInAppPopup('https://accounts.google.com/o/oauth2/auth', 'https://pairs.lv/'),
    true
  );
  assert.equal(
    shouldOpenInAppPopup('https://access.line.me/oauth2/v2.1/authorize', 'https://with.is/'),
    true
  );
  assert.equal(
    shouldOpenInAppPopup('https://appleid.apple.com/auth/authorize', 'https://tinder.com/'),
    true
  );
  assert.equal(
    shouldOpenInAppPopup('https://sub.pairs.lv/verify', 'https://pairs.lv/'),
    true
  );
  assert.equal(
    shouldOpenInAppPopup('https://news.yahoo.co.jp/articles/123', 'https://x.com/messages'),
    false
  );
});

test('makeBadgeText generates concise 2-char badges', () => {
  assert.equal(makeBadgeText('Bluesky'), 'BL');
  assert.equal(makeBadgeText('Steam Chat'), 'SC');
  assert.equal(makeBadgeText('ハッピーメール'), 'ハッ');
});
