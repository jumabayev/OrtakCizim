import 'package:flutter/material.dart';

import '../models/palette.dart';
import '../services/settings.dart';

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  const SettingsScreen({super.key, required this.settings});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _channel;
  late TextEditingController _port;
  late TextEditingController _name;
  late int _color;

  @override
  void initState() {
    super.initState();
    _channel = TextEditingController(text: widget.settings.channel);
    _port = TextEditingController(text: widget.settings.port.toString());
    _name = TextEditingController(text: widget.settings.name);
    _color = widget.settings.color;
  }

  @override
  void dispose() {
    _channel.dispose();
    _port.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final port = int.tryParse(_port.text.trim()) ?? 9101;
    final ch = _channel.text.trim();
    widget.settings
      ..channel = ch.isEmpty ? 'OrtakCizim' : ch
      ..port = port
      ..name = _name.text.trim().isEmpty ? 'Ressam' : _name.text.trim()
      ..color = _color;
    await widget.settings.save();
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ayarlar')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionLabel('KİM ÇİZİYOR'),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'İsmim',
              border: OutlineInputBorder(),
            ),
            maxLength: 30,
          ),
          const SizedBox(height: 12),
          const _SectionLabel('BENİM RENGİM'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in Palette.colors)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: _color == c ? 52 : 44,
                    height: _color == c ? 52 : 44,
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color == c ? Colors.black : Colors.black26,
                        width: _color == c ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          const _SectionLabel('KANAL (GİZLİ KELİME)'),
          const SizedBox(height: 8),
          TextField(
            controller: _channel,
            decoration: const InputDecoration(
              labelText: 'Kanal adı',
              helperText:
                  'Aynı kanaldaki herkes birbirinin çizimini görür. Farklı kanaldakiler göremez.',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.lock),
            ),
          ),
          const SizedBox(height: 16),
          ExpansionTile(
            title: const Text('Gelişmiş'),
            childrenPadding: const EdgeInsets.all(8),
            children: [
              TextField(
                controller: _port,
                decoration: const InputDecoration(
                  labelText: 'UDP port',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Kaydet'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Colors.black54,
        letterSpacing: 1.1,
      ),
    );
  }
}
