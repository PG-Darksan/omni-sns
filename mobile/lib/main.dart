import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'services/app_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OmniSnsApp());
}

class OmniSnsApp extends StatefulWidget {
  const OmniSnsApp({super.key});

  @override
  State<OmniSnsApp> createState() => _OmniSnsAppState();
}

class _OmniSnsAppState extends State<OmniSnsApp> {
  final AppStore _store = AppStore();
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OmniSNS',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B82F6),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F1219),
      ),
      home: HomeScreen(
        store: _store,
        onThemeChanged: (isDark) {
          setState(() {
            _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
          });
        },
      ),
    );
  }
}
