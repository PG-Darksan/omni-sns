import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_sns_mobile/models/service_models.dart';
import 'package:omni_sns_mobile/screens/catalog_sheet.dart';
import 'package:omni_sns_mobile/services/app_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('catalog.json loads all 44 free-messaging services and 5 categories', () async {
    final store = AppStore();
    final data = await store.loadCatalog();

    expect(data.categories.length, 5);
    expect(data.services.length, 44);
    for (final removed in [
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
      'meetup',
    ]) {
      expect(data.services.any((s) => s.id == removed), isFalse);
    }
    expect(
      data.services.where((s) => s.category == 'matching-global').length,
      5,
    );
    for (final svc in data.services) {
      expect(normalizeServiceUrl(svc.url)?.startsWith('https://'), isTrue);
    }
  });

  test('URL normalization, mobile-only UA, unread parsing, profile migration, and settings work cleanly', () {
    expect(normalizeServiceUrl('tinder.com'), 'https://tinder.com');
    expect(normalizeServiceUrl('javascript:alert(1)'), isNull);

    final mobileUa = buildMobileUserAgent();
    expect(mobileUa.contains('; wv)'), isFalse);
    expect(mobileUa.contains('Mobile Safari'), isTrue);
    expect(mobileUa.contains('Windows NT'), isFalse);

    expect(parseUnreadCountFromTitle('(5) Bluesky / Messages'), 5);
    expect(parseUnreadCountFromTitle('(99+) Instagram'), 99);
    expect(parseUnreadCountFromTitle('• Slack'), 1);
    expect(parseUnreadCountFromTitle('Report (2026)'), 0);

    const ig1 = ServiceInstance(
      instanceId: 'svc-ig-1',
      serviceId: 'instagram',
      name: 'Instagram',
      category: 'major-sns',
      url: 'https://www.instagram.com/direct/inbox/',
      colorHex: '#E1306C',
      badge: 'IG',
      notificationsEnabled: true,
      order: 0,
    );
    const ig2 = ServiceInstance(
      instanceId: 'svc-ig-2',
      serviceId: 'instagram',
      name: 'Instagram',
      accountLabel: 'サブ垢',
      category: 'major-sns',
      url: 'https://www.instagram.com/direct/inbox/',
      colorHex: '#E1306C',
      badge: 'IG',
      notificationsEnabled: true,
      order: 1,
    );
    expect(serviceGroupKey(ig1), 'instagram');
    expect(serviceGroupKey(ig2), 'instagram');
    expect(accountDisplayLabel(ig1, 0, baseServiceName: 'Instagram'), 'メイン');
    expect(accountDisplayLabel(ig2, 1, baseServiceName: 'Instagram'), 'サブ垢');
    expect(nextDefaultAccountLabel(['メイン', 'サブ垢']), 'アカウント 3');

    // レガシーデータ移行: 1つ目は Default を維持し、2つ目以降は独立プロファイルを割り当てる
    final migrated = assignProfilesForMigration([ig1, ig2]);
    expect(migrated[0].profileName, defaultWebViewProfileName);
    expect(migrated[1].profileName, makeProfileNameForInstance('svc-ig-2'));
    expect(migrated[0].effectiveProfileName != migrated[1].effectiveProfileName, isTrue);

    // 下部タブ折り畳み設定の永続化ラウンドトリップ
    const settings = AppSettings(
      isDarkMode: false,
      activeInstanceId: 'svc-ig-1',
      isBottomTabsCollapsed: true,
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.isDarkMode, isFalse);
    expect(restored.activeInstanceId, 'svc-ig-1');
    expect(restored.isBottomTabsCollapsed, isTrue);
  });

  testWidgets('CatalogScreen hides add-another-account UI when multi-profile is unsupported', (tester) async {
    const svc = CatalogService(
      id: 'instagram',
      name: 'Instagram',
      aliases: ['ig'],
      category: 'major-sns',
      url: 'https://www.instagram.com/direct/inbox/',
      homeUrl: 'https://www.instagram.com/',
      colorHex: '#E1306C',
      badge: 'IG',
      description: 'Instagram DM',
    );
    const existing = ServiceInstance(
      instanceId: 'svc-instagram-default',
      serviceId: 'instagram',
      name: 'Instagram',
      accountLabel: 'メイン',
      profileName: 'omnisns_svc-instagram-default',
      category: 'major-sns',
      url: 'https://www.instagram.com/direct/inbox/',
      colorHex: '#E1306C',
      badge: 'IG',
      notificationsEnabled: true,
      order: 0,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: CatalogScreen(
          categories: [
            CategoryMeta(
              id: 'major-sns',
              label: 'メジャーSNS',
              description: '',
            ),
          ],
          catalog: [svc],
          existingInstances: [existing],
          multiProfileSupported: false,
        ),
      ),
    );
    expect(find.text('＋ 別アカウント追加'), findsNothing);
    expect(find.text('開く'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: CatalogScreen(
          categories: [
            CategoryMeta(
              id: 'major-sns',
              label: 'メジャーSNS',
              description: '',
            ),
          ],
          catalog: [svc],
          existingInstances: [existing],
          multiProfileSupported: true,
        ),
      ),
    );
    expect(find.text('＋ 別アカウント追加'), findsOneWidget);
  });
}
