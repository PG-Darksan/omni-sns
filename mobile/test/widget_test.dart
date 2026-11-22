import 'package:flutter_test/flutter_test.dart';
import 'package:omni_sns_mobile/models/service_models.dart';
import 'package:omni_sns_mobile/services/app_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('catalog.json loads all 60 services without X and 7 categories', () async {
    final store = AppStore();
    final data = await store.loadCatalog();

    expect(data.categories.length, 7);
    expect(data.services.length, 60);
    expect(data.services.any((s) => s.id == 'x'), isFalse);
    expect(
      data.services.where((s) => s.category.startsWith('matching-')).length,
      greaterThanOrEqualTo(20),
    );
    for (final svc in data.services) {
      expect(normalizeServiceUrl(svc.url)?.startsWith('https://'), isTrue);
    }
  });

  test('URL normalization, UA generation, and unread parsing work cleanly', () {
    expect(normalizeServiceUrl('pairs.lv'), 'https://pairs.lv');
    expect(normalizeServiceUrl('javascript:alert(1)'), isNull);

    final mobileUa = buildUserAgent(UserAgentMode.mobile);
    final desktopUa = buildUserAgent(UserAgentMode.desktop);
    expect(mobileUa.contains('; wv)'), isFalse);
    expect(mobileUa.contains('Mobile Safari'), isTrue);
    expect(desktopUa.contains('Windows NT 10.0'), isTrue);

    expect(parseUnreadCountFromTitle('(5) X / Messages'), 5);
    expect(parseUnreadCountFromTitle('(99+) Instagram'), 99);
    expect(parseUnreadCountFromTitle('• Slack'), 1);
    expect(parseUnreadCountFromTitle('Report (2026)'), 0);
  });
}
