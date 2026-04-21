import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/palette.dart';

class AppSettings {
  static const _kChannel = 'channel';
  static const _kPort = 'port';
  static const _kName = 'name';
  static const _kColor = 'color';
  static const _kUserId = 'userId';

  String channel;
  int port;
  String name;
  int color;
  final String userId;

  AppSettings({
    required this.channel,
    required this.port,
    required this.name,
    required this.color,
    required this.userId,
  });

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final rng = Random.secure();

    String userId = p.getString(_kUserId) ?? '';
    if (userId.length != 32) {
      userId = List.generate(
        16,
        (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await p.setString(_kUserId, userId);
    }

    String name = (p.getString(_kName) ?? '').trim();
    if (name.isEmpty) {
      name = 'Ressam-${1000 + rng.nextInt(9000)}';
      await p.setString(_kName, name);
    }

    int color = p.getInt(_kColor) ?? 0;
    if (color == 0) {
      color = Palette.random();
      await p.setInt(_kColor, color);
    }

    return AppSettings(
      channel: p.getString(_kChannel) ?? 'OrtakCizim',
      port: p.getInt(_kPort) ?? 9101,
      name: name,
      color: color,
      userId: userId,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kChannel, channel.isEmpty ? 'OrtakCizim' : channel);
    await p.setInt(_kPort, port);
    await p.setString(_kName, name);
    await p.setInt(_kColor, color);
    await p.setString(_kUserId, userId);
  }
}
