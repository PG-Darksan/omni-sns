import 'package:flutter_test/flutter_test.dart';
import 'package:omni_sns_mobile/models/service_models.dart';
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

  test('URL normalization, UA generation, unread parsing, and account helpers work cleanly', () {
    expect(normalizeServiceUrl('tinder.com'), 'https://tinder.com');
    expect(normalizeServiceUrl('javascript:alert(1)'), isNull);

    final mobileUa = buildUserAgent(UserAgentMode.mobile);
    final desktopUa = buildUserAgent(UserAgentMode.desktop);
    expect(mobileUa.contains('; wv)'), isFalse);
    expect(mobileUa.contains('Mobile Safari'), isTrue);
    expect(desktopUa.contains('Windows NT 10.0'), isTrue);

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
      uaMode: UserAgentMode.mobile,
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
      uaMode: UserAgentMode.mobile,
      notificationsEnabled: true,
      order: 1,
    );
    expect(serviceGroupKey(ig1), 'instagram');
    expect(serviceGroupKey(ig2), 'instagram');
    expect(accountDisplayLabel(ig1, 0, baseServiceName: 'Instagram'), 'メイン');
    expect(accountDisplayLabel(ig2, 1, baseServiceName: 'Instagram'), 'サブ垢');
    expect(nextDefaultAccountLabel(['メイン', 'サブ垢']), 'アカウント 3');
  });
}
