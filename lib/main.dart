import 'package:flutter/material.dart';

import 'screens/draw_screen.dart';
import 'services/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(OrtakCizimApp(settings: settings));
}

class OrtakCizimApp extends StatelessWidget {
  final AppSettings settings;
  const OrtakCizimApp({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OrtakÇizim',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3949AB),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: DrawScreen(settings: settings),
    );
  }
}
