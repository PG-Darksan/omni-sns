import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_sns_mobile/models/gesture_models.dart';
import 'package:omni_sns_mobile/models/service_models.dart';
import 'package:omni_sns_mobile/screens/catalog_sheet.dart';
import 'package:omni_sns_mobile/screens/gesture_settings_screen.dart';
import 'package:omni_sns_mobile/screens/home_screen.dart';
import 'package:omni_sns_mobile/services/app_store.dart';
import 'package:omni_sns_mobile/services/follow_sync_service.dart';
import 'package:omni_sns_mobile/services/jev_service.dart';
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

    // ヘッダーに Gmail ボタン・再読み込みボタン・折り畳みボタンが表示される
    final gmailBtn = find.byKey(const ValueKey('header-gmail-button'));
    expect(gmailBtn, findsOneWidget);
    // Gmail ボタンをタップすると外部ブラウザではなくアプリ内 Gmail バーが開く
    await tester.tap(gmailBtn);
    await tester.pump();
    expect(find.byKey(const ValueKey('inapp-gmail-bar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gmail-back-to-sns-button')));
    await tester.pump();
    expect(find.byKey(const ValueKey('inapp-gmail-bar')), findsNothing);

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

    // ヘッダーを折り畳んでも Gmail・再読み込みボタン・展開ボタンが押せる
    await tester.tap(find.byKey(const ValueKey('header-collapse-button')));
    await tester.pump();
    expect(find.byKey(const ValueKey('collapsed-header-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('header-gmail-button')), findsOneWidget);
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
    expect(find.text('＋別垢'), findsNothing);
    expect(find.text('Instagram DM'), findsNothing);
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
    expect(find.text('＋別垢'), findsOneWidget);
    expect(find.text('Instagram DM'), findsNothing);
  });

  test('FollowSyncLedger CRDT merges PC and Android JSON cleanly and supports shared sync copy/paste', () {
    const today = '2026-11-23';
    // Rust 側から届く JSON 形式そのままを読み込めることを検証
    final pcJson = jsonDecode('''
    {
      "version": 1,
      "accounts": {
        "instagram:darksan560": {
          "date": "2026-11-23",
          "resetEpoch": 0,
          "totalResetEpoch": 0,
          "devices": {
            "win-aaaa": {
              "today": 11,
              "total": 35,
              "todayEpoch": 0,
              "totalEpoch": 0,
              "updatedAt": 100
            }
          },
          "snsFollowing": 180,
          "snsFollowers": 420,
          "snsUpdatedAt": 100
        }
      }
    }
    ''') as Map<String, dynamic>;

    final pcLedger = FollowSyncLedger.fromJson(pcJson);
    final androidLedger = FollowSyncLedger(
      accounts: {
        'instagram:darksan560': AccountFollowLedger(
          date: today,
          devices: {
            'and-bbbb': DeviceFollowEntry(
              today: 7,
              total: 19,
              todayEpoch: 0,
              totalEpoch: 0,
              updatedAt: 200,
            ),
          },
          snsFollowing: 187,
          snsFollowers: 425,
          snsUpdatedAt: 200,
        ),
      },
    );

    expect(androidLedger.mergeFrom(pcLedger, today), isTrue);
    expect(androidLedger.mergeFrom(pcLedger, today), isFalse);

    final acc = androidLedger.accounts['instagram:darksan560']!;
    expect(acc.effectiveCounts(today), (18, 54));
    expect(acc.snsFollowing, 187);
    expect(acc.snsFollowers, 425);
    // 翌日ロールオーバー
    expect(acc.effectiveCounts('2026-11-24'), (0, 54));

    // インスタンスへの投影
    const ig = ServiceInstance(
      instanceId: 'svc-ig',
      serviceId: 'instagram',
      name: 'Instagram',
      category: 'major-sns',
      url: 'https://www.instagram.com/direct/inbox/',
      colorHex: '#E1306C',
      badge: 'IG',
      notificationsEnabled: true,
      order: 0,
      detectedHandle: 'darksan560',
    );
    final (projected, changed) =
        projectLedgerToInstances([ig], androidLedger, today);
    expect(changed, isTrue);
    expect(projected.first.followCountToday, 18);
    expect(projected.first.followCountTotal, 54);
    expect(projected.first.snsFollowingCount, 187);
    expect(projected.first.snsFollowersCount, 425);

    // PC ⇄ スマホ 設定コピー文字列の往復
    final encoded = encodeSharedSyncConfig('ghp_testToken123', 'gist_abc456');
    final decoded = parseSharedSyncConfig(encoded);
    expect(decoded, isNotNull);
    expect(decoded!.token, 'ghp_testToken123');
    expect(decoded.gistId, 'gist_abc456');
    expect(parseSharedSyncConfig('invalid'), isNull);
  });

  test('Unfollow count rollover/reset, Threads-to-Instagram counter switch, and mobile gestures work cleanly', () {
    final day1 = DateTime(2026, 11, 22);
    final day2 = DateTime(2026, 11, 23);
    const threads = ServiceInstance(
      instanceId: 'svc-threads-1',
      serviceId: 'threads',
      name: 'Threads',
      accountLabel: 'メイン',
      category: 'major-sns',
      url: 'https://www.threads.com/',
      colorHex: '#18181B',
      badge: 'TH',
      notificationsEnabled: true,
      order: 0,
      followCountToday: 12,
      followCountTotal: 40,
      followCountDate: '2026-11-23',
      detectedHandle: 'darksan',
    );
    const ig = ServiceInstance(
      instanceId: 'svc-ig-1',
      serviceId: 'instagram',
      name: 'Instagram',
      accountLabel: 'メイン',
      category: 'major-sns',
      url: 'https://www.instagram.com/direct/inbox/',
      colorHex: '#E1306C',
      badge: 'IG',
      notificationsEnabled: true,
      order: 1,
      followCountToday: 3,
      followCountTotal: 15,
      followCountDate: '2026-11-23',
      detectedHandle: 'darksan',
    );

    // アンフォローカウント増減・日次ロールオーバー・リセット
    final uf2 = ig.withUnfollowDelta(1, day1).withUnfollowDelta(1, day1);
    expect(uf2.effectiveUnfollowCountToday(day1), 2);
    expect(uf2.unfollowCountTotal, 2);
    expect(uf2.effectiveUnfollowCountToday(day2), 0);
    final ufResetToday = uf2.withUnfollowDelta(1, day2).withUnfollowReset(resetTotal: false, now: day2);
    expect(ufResetToday.effectiveUnfollowCountToday(day2), 0);
    expect(ufResetToday.unfollowCountTotal, 3);

    // Threadsタブ内でInstagram URLを開いたらInstagramインスタンスへ切替（Threadsの12を引き継がない）
    expect(detectPlatformServiceFromUrl('https://www.instagram.com/alice/'), 'instagram');
    final resolvedIg = resolveCounterTargetInstance(
      source: threads,
      instances: [threads, ig],
      currentUrl: 'https://www.instagram.com/alice/',
    );
    expect(resolvedIg?.instanceId, 'svc-ig-1');
    expect(resolvedIg?.followCountToday, 3);

    // Instagramインスタンス未登録時はThreadsを返さず null を返す
    final resolvedMissing = resolveCounterTargetInstance(
      source: threads,
      instances: [threads],
      currentUrl: 'https://www.instagram.com/alice/',
    );
    expect(resolvedMissing, isNull);

    // 12方向ジェスチャー認識エンジン
    final path = GesturePath();
    path.reset(const Offset(200, 200));
    path.push(const Offset(160, 200));
    expect(path.shape, 'L');
    path.push(const Offset(160, 150));
    expect(path.shape, 'LU');
    // 180度逆戻りまたは3方向目はキャンセル
    path.push(const Offset(160, 210));
    expect(path.invalidated, isTrue);
    expect(path.shape, '');

    // 設定ラウンドトリップ
    final gSettings = const MobileGestureSettings(
      enabled: true,
      triggerSide: 'both',
      tremor: 14,
      handleXFraction: 0.12,
      handleYFraction: 0.72,
    );
    final appSettings = AppSettings(gesture: gSettings);
    final restored = AppSettings.fromJson(appSettings.toJson());
    expect(restored.gesture.enabled, isTrue);
    expect(restored.gesture.triggerSide, 'both');
    expect(restored.gesture.tremor, 14);
    expect(restored.gesture.actionFor('DL'), 'toggle-gmail');
  });

  testWidgets('GestureSettingsScreen renders 12-direction board and updates toggle', (tester) async {
    MobileGestureSettings? latest;
    await tester.pumpWidget(
      MaterialApp(
        home: GestureSettingsScreen(
          initialSettings: const MobileGestureSettings(),
          onChanged: (next) => latest = next,
        ),
      ),
    );
    expect(find.text('タッチジェスチャー設定'), findsOneWidget);
    expect(find.byKey(const ValueKey('gesture-card-L')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('gesture-card-DL')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('gesture-card-DL')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('gesture-enabled-switch')),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('gesture-enabled-switch')));
    await tester.pump();
    expect(latest?.enabled, isFalse);
  });

  testWidgets('ArchivedInstance roundtrips JSON and CatalogScreen displays saved logins tab for restore', (tester) async {
    const inst = ServiceInstance(
      instanceId: 'svc-instagram-sub01',
      serviceId: 'instagram',
      name: 'Instagram',
      accountLabel: 'サブ垢',
      profileName: 'omnisns_svc-instagram-sub01',
      category: 'major-sns',
      url: 'https://www.instagram.com/direct/inbox/',
      colorHex: '#E1306C',
      badge: 'IG',
      notificationsEnabled: true,
      order: 1,
      detectedHandle: 'sub_user',
    );
    const archived = ArchivedInstance(instance: inst, archivedAt: 1764000000);
    final roundtripped = ArchivedInstance.fromJson(archived.toJson(), 0);
    expect(roundtripped, isNotNull);
    expect(roundtripped!.instance.instanceId, 'svc-instagram-sub01');
    expect(roundtripped.instance.effectiveProfileName, 'omnisns_svc-instagram-sub01');
    expect(roundtripped.instance.detectedHandle, 'sub_user');
    expect(roundtripped.archivedAt, 1764000000);

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

    NewInstanceRequest? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await Navigator.of(ctx).push<NewInstanceRequest>(
                    MaterialPageRoute(
                      builder: (_) => const CatalogScreen(
                        categories: [
                          CategoryMeta(
                            id: 'major-sns',
                            label: 'メジャーSNS',
                            description: '',
                          ),
                        ],
                        catalog: [svc],
                        existingInstances: [],
                        multiProfileSupported: true,
                        archivedInstances: [archived],
                        initialCategory: 'archived',
                      ),
                    ),
                  );
                },
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();

    expect(find.text('ログイン記憶 (1)'), findsOneWidget);
    expect(find.text('Instagram · サブ垢 (@sub_user)'), findsOneWidget);
    await tester.tap(find.text('呼び出す'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.restoreArchivedInstanceId, 'svc-instagram-sub01');
  });

  test('JevService supports female preset and custom free-text categories with isolated caching', () async {
    expect(JevService.isFemalePresetCategory('女の子'), isTrue);
    expect(JevService.isFemalePresetCategory('カフェ・グルメ'), isFalse);

    final candidate = JevAccountCandidate(
      username: 'cafe_tokyo',
      displayName: '東京カフェ',
      bio: '渋谷のコーヒー屋巡り',
      avatarUrl: 'https://cdn.example.com/a/icon123.jpg?sig=abc',
      platform: 'instagram',
    );
    expect(candidate.cacheKey('女の子'), candidate.cacheKey('女性'));
    expect(candidate.cacheKey('女の子'), isNot(candidate.cacheKey('カフェ')));

    final customBody = JevService.buildRequestBody(
      [candidate],
      category: 'カフェ・グルメ',
      nonce: 'n1',
    );
    expect((customBody['state'] as String).contains('カフェ・グルメ'), isTrue);
    expect((customBody['state'] as String).contains('渋谷のコーヒー屋巡り'), isTrue);

    var apiCalls = 0;
    final jev = JevService(
      inMemoryOnly: true,
      avatarPreparer: (_) async => null,
      poster: ({required apiKey, required body, required includeImageHeader}) async {
        apiCalls++;
        final state = body['state'] as String;
        final isCafe = state.contains('target category: "カフェ"');
        return (
          statusCode: 200,
          body: jsonEncode({
            'answers': {
              'q_0': {'noul': isCafe ? 0.91 : 0.12},
            },
            'usage': {'input_tokens': 1000},
          }),
        );
      },
    );
    await jev.updateSettings(apiKey: 'test-key', enabled: true, category: 'カフェ');
    final r1 = await jev.judgeAccounts([candidate]);
    expect(r1['cafe_tokyo'], isTrue);
    expect(apiCalls, 1);
    expect(jev.totalJudgedAccounts, 1);
    expect(jev.totalCostUsd, greaterThan(0));

    // 同一カテゴリ再判定はキャッシュヒット（追加課金なし）
    final r2 = await jev.judgeAccounts([candidate]);
    expect(r2['cafe_tokyo'], isTrue);
    expect(apiCalls, 1);

    // 別カテゴリへ変更すると別キャッシュキーで再判定される
    final changed = await jev.updateSettings(category: '女の子');
    expect(changed, isTrue);
    final r3 = await jev.judgeAccounts([candidate]);
    expect(r3['cafe_tokyo'], isFalse);
    expect(apiCalls, 2);

    // PNG生成確認
    final png = JevService.makeSolidPng(width: 16, height: 16);
    expect(png.take(4).toList(), [0x89, 0x50, 0x4E, 0x47]);
  });

  test('ServiceInstance persists desktop uaMode and mobile gestures separate tabs from services', () {
    const inst = ServiceInstance(
      instanceId: 'svc-ig-1',
      serviceId: 'instagram',
      name: 'Instagram',
      category: 'major-sns',
      url: 'https://www.instagram.com/',
      colorHex: '#E1306C',
      badge: 'IG',
      notificationsEnabled: true,
      order: 0,
      uaMode: 'desktop',
    );
    final roundtripped = ServiceInstance.fromJson(inst.toJson(), 0);
    expect(roundtripped.isDesktopUa, isTrue);
    expect(buildUserAgentForMode('desktop'), contains('Windows NT'));
    expect(buildUserAgentForMode('mobile'), contains('Android'));

    final ids = kMobileGestureActions.map((a) => a.id).toSet();
    expect(ids.contains('previous-tab'), isTrue);
    expect(ids.contains('next-tab'), isTrue);
    expect(ids.contains('previous-service'), isTrue);
    expect(ids.contains('next-service'), isTrue);
  });
}
