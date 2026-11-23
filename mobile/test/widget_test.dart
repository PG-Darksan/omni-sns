import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_sns_mobile/models/service_models.dart';
import 'package:omni_sns_mobile/screens/catalog_sheet.dart';
import 'package:omni_sns_mobile/screens/home_screen.dart';
import 'package:omni_sns_mobile/services/app_store.dart';
import 'package:omni_sns_mobile/services/omni_webview.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    final threads = data.services.firstWhere((s) => s.id == 'threads');
    expect(threads.url, 'https://www.threads.com/');
  });

  test('isHttpOrHttpsUrl rejects blank/error/non-http URLs', () {
    expect(isHttpOrHttpsUrl('https://www.threads.com/'), isTrue);
    expect(isHttpOrHttpsUrl('http://example.com/path'), isTrue);
    expect(isHttpOrHttpsUrl('about:blank'), isFalse);
    expect(isHttpOrHttpsUrl('chrome-error://chromewebdata/'), isFalse);
    expect(isHttpOrHttpsUrl('javascript:alert(1)'), isFalse);
    expect(isHttpOrHttpsUrl(''), isFalse);
    expect(isHttpOrHttpsUrl(null), isFalse);
  });

  test('AppStore migrates legacy threads.net URL to threads.com preserving profile', () async {
    SharedPreferences.setMockInitialValues({
      'omnisns_instances_v1': jsonEncode([
        {
          'instanceId': 'svc-threads-default',
          'serviceId': 'threads',
          'name': 'Threads',
          'accountLabel': 'メイン',
          'profileName': 'omnisns_svc-threads-default',
          'category': 'major-sns',
          'url': 'https://www.threads.net/',
          'colorHex': '#18181B',
          'badge': 'TH',
          'notificationsEnabled': true,
          'order': 0,
        },
      ]),
    });

    final store = AppStore();
    final catalog = await store.loadCatalog();
    final (_, instances) = await store.loadState(catalog.services);

    expect(instances.length, 1);
    expect(instances.first.url, 'https://www.threads.com/');
    expect(instances.first.profileName, 'omnisns_svc-threads-default');
  });

  test('OmniWebViewController reload queues fallback before attach and passes fallbackUrl after attach', () async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('com.pgdarksan.omnisns/webview_99');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final ctrl = OmniWebViewController(
      initialUrl: 'https://www.threads.com/',
      profileName: 'omnisns_threads',
      userAgent: buildMobileUserAgent(),
    );

    // 未アタッチ時の reload は破棄されず、アタッチ時に loadUrl として確実に実行される
    await ctrl.reload(fallbackUrl: 'https://www.threads.com/@user');
    ctrl.attachPlatformView(99);
    await Future<void>.delayed(Duration.zero);

    expect(calls.length, 1);
    expect(calls.first.method, 'loadUrl');
    expect((calls.first.arguments as Map)['url'], 'https://www.threads.com/@user');

    // アタッチ後の reload は fallbackUrl 付きでネイティブ reload を呼ぶ
    await ctrl.reload(fallbackUrl: 'https://www.threads.com/@user/post/1');
    expect(calls.length, 2);
    expect(calls[1].method, 'reload');
    expect(
      (calls[1].arguments as Map)['fallbackUrl'],
      'https://www.threads.com/@user/post/1',
    );

    ctrl.dispose();
  });

  testWidgets('HomeScreen header reload, collapse toggle, and follow counter work cleanly', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const mgrChannel = MethodChannel('com.pgdarksan.omnisns/webview_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mgrChannel, (call) async {
      if (call.method == 'isMultiProfileSupported') return true;
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mgrChannel, null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          store: AppStore(),
          onThemeChanged: (_) {},
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // ヘッダーに再読み込みボタンと折り畳みボタンが表示される
    final reloadBtn = find.byKey(const ValueKey('header-reload-button'));
    expect(reloadBtn, findsOneWidget);
    expect(find.byTooltip('再読み込み'), findsOneWidget);
    await tester.tap(reloadBtn);
    await tester.pump();

    // フォロー回数チップをタップして +1 / -1 できる
    final followChip = find.byKey(const ValueKey('follow-counter-chip'));
    expect(followChip, findsOneWidget);
    await tester.tap(followChip);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('follow-sheet-today')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('follow-sheet-inc')));
    await tester.pump();
    expect(find.text('1'), findsAtLeastNWidgets(2));
    Navigator.of(tester.element(find.byKey(const ValueKey('follow-sheet-today')))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // ヘッダーを折り畳んでも再読み込みボタン・展開ボタンが押せる
    await tester.tap(find.byKey(const ValueKey('header-collapse-button')));
    await tester.pump();
    expect(find.byKey(const ValueKey('collapsed-header-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('header-reload-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('header-expand-button')));
    await tester.pump();
    expect(find.byKey(const ValueKey('collapsed-header-bar')), findsNothing);
  });

  test('Follow count daily rollover, delta, reset, and headerCollapsed roundtrip work cleanly', () {
    final day1 = DateTime(2026, 11, 22);
    final day2 = DateTime(2026, 11, 23);
    const base = ServiceInstance(
      instanceId: 'svc-threads-default',
      serviceId: 'threads',
      name: 'Threads',
      category: 'major-sns',
      url: 'https://www.threads.com/',
      colorHex: '#18181B',
      badge: 'TH',
      notificationsEnabled: true,
      order: 0,
    );

    final after2 = base.withFollowDelta(1, day1).withFollowDelta(1, day1);
    expect(after2.effectiveFollowCountToday(day1), 2);
    expect(after2.followCountTotal, 2);
    // 翌日になると「今日」は自動で0、累計は維持
    expect(after2.effectiveFollowCountToday(day2), 0);
    final nextDay = after2.withFollowDelta(1, day2);
    expect(nextDay.effectiveFollowCountToday(day2), 1);
    expect(nextDay.followCountTotal, 3);

    final resetToday = nextDay.withFollowReset(resetTotal: false, now: day2);
    expect(resetToday.effectiveFollowCountToday(day2), 0);
    expect(resetToday.followCountTotal, 3);

    final resetAll = nextDay.withFollowReset(resetTotal: true, now: day2);
    expect(resetAll.effectiveFollowCountToday(day2), 0);
    expect(resetAll.followCountTotal, 0);

    const settings = AppSettings(
      isDarkMode: true,
      activeInstanceId: 'svc-threads-default',
      isBottomTabsCollapsed: true,
      isHeaderCollapsed: true,
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.isHeaderCollapsed, isTrue);
    expect(restored.isBottomTabsCollapsed, isTrue);
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
