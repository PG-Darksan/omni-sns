import 'package:flutter/material.dart';
import '../models/service_models.dart';

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
  late final TextEditingController _pinController;

  @override
  void initState() {
    super.initState();
    _isDarkMode = widget.settings.isDarkMode;
    _pinController = TextEditingController(text: widget.settings.lockPin);
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  void _saveAndClose() {
    Navigator.of(context).pop(
      widget.settings.copyWith(
        isDarkMode: _isDarkMode,
        lockPin: _pinController.text.trim(),
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
          const SizedBox(height: 8),
          const Text(
            'プライバシーロック用PIN（任意）',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _pinController,
            obscureText: true,
            maxLength: 16,
            decoration: const InputDecoration(
              hintText: '空欄ならワンタップでロック解除',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
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
