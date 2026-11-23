import 'package:flutter/material.dart';
import '../models/gesture_models.dart';
import '../models/service_models.dart';
import 'gesture_settings_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.onClearAllCookies,
  });

  final AppSettings settings;
  final Future<void> Function() onClearAllCookies;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool _isDarkMode;
  late MobileGestureSettings _gesture;

  @override
  void initState() {
    super.initState();
    _isDarkMode = widget.settings.isDarkMode;
    _gesture = widget.settings.gesture;
  }

  void _saveAndClose() {
    Navigator.of(context).pop(
      widget.settings.copyWith(
        isDarkMode: _isDarkMode,
        gesture: _gesture,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('アプリ設定'),
        actions: [
          TextButton(
            onPressed: _saveAndClose,
            child: const Text('保存', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('ダークモード'),
            subtitle: const Text('OFFにするとライトテーマに切り替えます'),
            value: _isDarkMode,
            onChanged: (v) => setState(() => _isDarkMode = v),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.gesture_rounded),
            title: const Text('タッチジェスチャー設定'),
            subtitle: Text(
              _gesture.enabled
                  ? '有効 · 12方向ボード＆連続スクロール'
                  : '無効 · タップして設定を開く',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => GestureSettingsScreen(
                    initialSettings: _gesture,
                    onChanged: (next) {
                      setState(() => _gesture = next);
                    },
                  ),
                ),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: const Text('すべてのWebログイン情報・Cookieを消去'),
            subtitle: const Text('全サービスのCookieをリセットします'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('全Cookieを削除しますか？'),
                  content: const Text(
                    'アプリ内WebViewのすべてのサービスからログアウトされます。',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('キャンセル'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('削除する'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await widget.onClearAllCookies();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('すべてのCookieを消去しました')),
                  );
                }
              }
            },
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saveAndClose,
            child: const Text('設定を保存して閉じる'),
          ),
        ],
      ),
    );
  }
}
