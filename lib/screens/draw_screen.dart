import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/palette.dart';
import '../models/stroke.dart';
import '../services/channel_codec.dart';
import '../services/settings.dart';
import '../services/udp_draw.dart';
import '../widgets/canvas_painter.dart';
import 'settings_screen.dart';

String? _subnetBroadcast(String? ip, String? mask) {
  if (ip == null || mask == null) return null;
  try {
    final ipp = ip.split('.').map(int.parse).toList();
    final mp = mask.split('.').map(int.parse).toList();
    if (ipp.length != 4 || mp.length != 4) return null;
    return List.generate(4, (i) => (ipp[i] | (~mp[i] & 0xFF)) & 0xFF).join('.');
  } catch (_) {
    return null;
  }
}

class _Peer {
  final String id;
  String name;
  int color;
  DateTime lastSeen;
  _Peer({
    required this.id,
    required this.name,
    required this.color,
    required this.lastSeen,
  });
}

class DrawScreen extends StatefulWidget {
  final AppSettings settings;
  const DrawScreen({super.key, required this.settings});

  @override
  State<DrawScreen> createState() => _DrawScreenState();
}

class _DrawScreenState extends State<DrawScreen> {
  final _udp = UdpDraw();
  StreamSubscription<IncomingDrawEvent>? _sub;
  Timer? _presenceTimer;
  Timer? _cleanupTimer;
  Timer? _flushTimer;
  final _rng = Random();

  final Map<String, Stroke> _strokes = {}; // key = senderId#strokeId
  final List<String> _strokeOrder = []; // çizim sıralaması
  final Map<String, _Peer> _online = {};

  // TX durumu — kendi aktif çizgimiz
  int _myStrokeId = 0;
  String? _myActiveStrokeKey;
  final List<DrawPoint> _pendingPoints = [];
  Size _canvasSize = Size.zero;
  double _brushSize = Brushes.defaultSize;
  late int _color;
  int _repaint = 0;

  String? _ownIp;
  String? _error;
  bool _starting = true;

  static const int _maxStrokes = 2000;
  static const Duration _presenceInterval = Duration(seconds: 3);
  static const Duration _presenceTimeout = Duration(seconds: 10);
  static const Duration _flushCadence = Duration(milliseconds: 40);

  @override
  void initState() {
    super.initState();
    _color = widget.settings.color;
    WakelockPlus.enable();
    _start();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _sub?.cancel();
    _presenceTimer?.cancel();
    _cleanupTimer?.cancel();
    _flushTimer?.cancel();
    _udp.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final codec = await ChannelCodec.fromChannel(widget.settings.channel);
      String? bcast;
      try {
        final info = NetworkInfo();
        _ownIp = await info.getWifiIP();
        final mask = await info.getWifiSubmask();
        bcast = _subnetBroadcast(_ownIp, mask);
      } catch (_) {}

      await _udp.start(
        port: widget.settings.port,
        codec: codec,
        selfUserId: widget.settings.userId,
        broadcastAddress: bcast,
      );
      _sub = _udp.incoming.listen(_onIncoming);

      _sendPresence();
      _presenceTimer = Timer.periodic(_presenceInterval, (_) => _sendPresence());
      _cleanupTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final cutoff = DateTime.now().subtract(_presenceTimeout);
        final before = _online.length;
        _online.removeWhere((_, p) => p.lastSeen.isBefore(cutoff));
        if (mounted && before != _online.length) setState(() {});
      });

      if (mounted) setState(() => _starting = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _starting = false;
        });
      }
    }
  }

  void _sendPresence() {
    _udp.sendPresence(
      port: widget.settings.port,
      userId: widget.settings.userId,
      name: widget.settings.name,
      color: _color,
    );
  }

  void _onIncoming(IncomingDrawEvent e) {
    switch (e) {
      case IncomingPresence p:
        final existed = _online.containsKey(p.senderId);
        _online[p.senderId] = _Peer(
          id: p.senderId,
          name: p.senderName,
          color: p.color,
          lastSeen: DateTime.now(),
        );
        if (!existed) {
          _sendPresence();
          if (mounted) setState(() {});
        } else {
          _online[p.senderId]!.lastSeen = DateTime.now();
        }
        break;
      case IncomingClear _:
        setState(() {
          _strokes.clear();
          _strokeOrder.clear();
          _repaint++;
        });
        break;
      case IncomingStroke s:
        // Gönderici peer bilgisini de güncelle
        final existed = _online.containsKey(s.senderId);
        _online[s.senderId] = _Peer(
          id: s.senderId,
          name: s.senderName,
          color: s.color,
          lastSeen: DateTime.now(),
        );
        if (!existed) _sendPresence();

        final key = '${s.senderId}#${s.strokeId}';
        final existing = _strokes[key];
        if (existing == null) {
          final stroke = Stroke(
            senderId: s.senderId,
            strokeId: s.strokeId,
            color: s.color,
            brushSize: s.brushSize,
            points: List.of(s.points),
            finished: s.strokeEnd,
          );
          _strokes[key] = stroke;
          _strokeOrder.add(key);
          _evictOldIfNeeded();
        } else {
          existing.points.addAll(s.points);
          if (s.strokeEnd) existing.finished = true;
        }
        setState(() => _repaint++);
        break;
    }
  }

  void _evictOldIfNeeded() {
    while (_strokeOrder.length > _maxStrokes) {
      final old = _strokeOrder.removeAt(0);
      _strokes.remove(old);
    }
  }

  // ------- Yerel (kendi) çizim -----------------------------------------------

  void _onPanDown(DragDownDetails d) {
    if (_canvasSize == Size.zero) return;
    _myStrokeId = _rng.nextInt(0xFFFFFFFF);
    final key = '${widget.settings.userId}#$_myStrokeId';
    _myActiveStrokeKey = key;
    final stroke = Stroke(
      senderId: widget.settings.userId,
      strokeId: _myStrokeId,
      color: _color,
      brushSize: _brushSize,
      points: [_normalize(d.localPosition)],
    );
    _strokes[key] = stroke;
    _strokeOrder.add(key);
    _evictOldIfNeeded();
    _pendingPoints
      ..clear()
      ..add(stroke.points.first);
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushCadence, (_) => _flushPending());
    setState(() => _repaint++);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final key = _myActiveStrokeKey;
    if (key == null) return;
    final s = _strokes[key];
    if (s == null) return;
    final p = _normalize(d.localPosition);
    s.points.add(p);
    _pendingPoints.add(p);
    setState(() => _repaint++);
    if (_pendingPoints.length >= 20) _flushPending();
  }

  void _onPanEnd(DragEndDetails _) {
    _flushTimer?.cancel();
    _flushPending(end: true);
    _myActiveStrokeKey = null;
  }

  void _onPanCancel() {
    _flushTimer?.cancel();
    _flushPending(end: true);
    _myActiveStrokeKey = null;
  }

  DrawPoint _normalize(Offset local) {
    final w = _canvasSize.width == 0 ? 1 : _canvasSize.width;
    final h = _canvasSize.height == 0 ? 1 : _canvasSize.height;
    return DrawPoint(
      (local.dx / w).clamp(0.0, 1.0),
      (local.dy / h).clamp(0.0, 1.0),
    );
  }

  void _flushPending({bool end = false}) {
    if (_pendingPoints.isEmpty && !end) return;
    final chunk = List<DrawPoint>.from(_pendingPoints);
    _pendingPoints.clear();
    _udp.sendStrokeChunk(
      port: widget.settings.port,
      userId: widget.settings.userId,
      name: widget.settings.name,
      strokeId: _myStrokeId,
      color: _color,
      brushSize: _brushSize,
      points: chunk,
      strokeEnd: end,
    );
  }

  // ------- UI ---------------------------------------------------------------

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Tahtayı temizle?'),
        content: const Text('Herkesin çizimleri silinecek.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Evet, temizle'),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        _strokes.clear();
        _strokeOrder.clear();
        _repaint++;
      });
      _udp.sendClear(
        port: widget.settings.port,
        userId: widget.settings.userId,
        name: widget.settings.name,
      );
    }
  }

  Future<void> _openSettings() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(settings: widget.settings),
      ),
    );
    if (changed == true) {
      _color = widget.settings.color;
      await _sub?.cancel();
      await _udp.stop();
      _presenceTimer?.cancel();
      _cleanupTimer?.cancel();
      setState(() {
        _starting = true;
        _online.clear();
      });
      await _start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final strokeList = _strokeOrder
        .map((k) => _strokes[k])
        .whereType<Stroke>()
        .toList(growable: false);

    return Scaffold(
      backgroundColor: const Color(0xFFFDFCFA),
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              myName: widget.settings.name,
              myColor: _color,
              channel: widget.settings.channel,
              ownIp: _ownIp,
              online: _online.values.toList(),
              onSettings: _openSettings,
              onClear: _confirmClear,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('⚠ $_error',
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (_, c) {
                        _canvasSize = Size(c.maxWidth, c.maxHeight);
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanDown: _onPanDown,
                          onPanUpdate: _onPanUpdate,
                          onPanEnd: _onPanEnd,
                          onPanCancel: _onPanCancel,
                          child: CustomPaint(
                            painter: CanvasPainter(
                              strokes: strokeList,
                              repaintToken: _repaint,
                            ),
                            size: Size.infinite,
                          ),
                        );
                      },
                    ),
                  ),
                  if (_starting)
                    const Align(
                      alignment: Alignment.center,
                      child: CircularProgressIndicator(),
                    ),
                ],
              ),
            ),
            _BottomBar(
              selectedColor: _color,
              brushSize: _brushSize,
              onColor: (c) {
                setState(() => _color = c);
                widget.settings
                  ..color = c
                  ..save();
                _sendPresence();
              },
              onBrush: (b) => setState(() => _brushSize = b),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String myName;
  final int myColor;
  final String channel;
  final String? ownIp;
  final List<_Peer> online;
  final VoidCallback onSettings;
  final VoidCallback onClear;

  const _TopBar({
    required this.myName,
    required this.myColor,
    required this.channel,
    required this.ownIp,
    required this.online,
    required this.onSettings,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        children: [
          _Dot(color: Color(myColor)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  myName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  '# $channel  •  ${online.length + 1} ressam',
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
          if (online.isNotEmpty)
            SizedBox(
              height: 32,
              child: ListView.separated(
                shrinkWrap: true,
                scrollDirection: Axis.horizontal,
                itemCount: online.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final p = online[i];
                  return Tooltip(
                    message: p.name,
                    child: _Dot(color: Color(p.color), size: 26),
                  );
                },
              ),
            ),
          IconButton(
            tooltip: 'Temizle',
            icon: const Icon(Icons.delete_outline),
            onPressed: onClear,
          ),
          IconButton(
            tooltip: 'Ayarlar',
            icon: const Icon(Icons.settings),
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  final double size;
  const _Dot({required this.color, this.size = 20});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black12, width: 1),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final int selectedColor;
  final double brushSize;
  final ValueChanged<int> onColor;
  final ValueChanged<double> onBrush;

  const _BottomBar({
    required this.selectedColor,
    required this.brushSize,
    required this.onColor,
    required this.onBrush,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final c in Palette.colors) ...[
                  _ColorSwatch(
                    color: c,
                    selected: c == selectedColor,
                    onTap: () => onColor(c),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.brush, size: 18),
              Expanded(
                child: Slider(
                  value: brushSize,
                  min: Brushes.sizes.first,
                  max: Brushes.sizes.last,
                  divisions: Brushes.sizes.length - 1,
                  label: brushSize.toStringAsFixed(0),
                  onChanged: onBrush,
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  brushSize.toStringAsFixed(0),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  final int color;
  final bool selected;
  final VoidCallback onTap;
  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: selected ? 44 : 38,
        height: selected ? 44 : 38,
        decoration: BoxDecoration(
          color: Color(color),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.black : Colors.black26,
            width: selected ? 3 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Color(color).withValues(alpha: 0.5),
                    blurRadius: 10,
                  )
                ]
              : null,
        ),
      ),
    );
  }
}
