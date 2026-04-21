import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gal/gal.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/draw_object.dart';
import '../models/palette.dart';
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

enum Tool { brush, rect, ellipse, line, arrow, star, heart }

ShapeKind _toolToShape(Tool t) {
  switch (t) {
    case Tool.rect:
      return ShapeKind.rectangle;
    case Tool.ellipse:
      return ShapeKind.ellipse;
    case Tool.line:
      return ShapeKind.line;
    case Tool.arrow:
      return ShapeKind.arrow;
    case Tool.star:
      return ShapeKind.star;
    case Tool.heart:
      return ShapeKind.heart;
    case Tool.brush:
      throw StateError('brush is not a shape');
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
  final _canvasKey = GlobalKey();
  StreamSubscription<IncomingDrawEvent>? _sub;
  Timer? _presenceTimer;
  Timer? _cleanupTimer;
  Timer? _flushTimer;
  final _rng = Random();

  // Çizim durumu
  final Map<String, DrawObject> _objects = {}; // senderId#objectId → obj
  final List<String> _order = [];
  final List<int> _myUndoStack = []; // undo için kendi obje ID'leri
  final Map<String, _Peer> _online = {};

  // Araçlar / ayarlar
  Tool _tool = Tool.brush;
  bool _rainbow = false;
  bool _fill = false;
  double _brushSize = Brushes.defaultSize;
  late int _color;
  int _repaint = 0;

  // Aktif kendi çizim
  int _myObjectId = 0;
  String? _myStrokeKey; // stroke sırasında
  final List<DrawPoint> _pendingPoints = [];
  ShapeObject? _previewShape;

  Size _canvasSize = Size.zero;
  String? _ownIp;
  String? _error;
  bool _starting = true;

  static const int _maxObjects = 2000;
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
      _presenceTimer =
          Timer.periodic(_presenceInterval, (_) => _sendPresence());
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

  void _upsertOnline(String id, String name, int color) {
    final existed = _online.containsKey(id);
    _online[id] = _Peer(
      id: id,
      name: name,
      color: color,
      lastSeen: DateTime.now(),
    );
    if (!existed) _sendPresence();
  }

  void _onIncoming(IncomingDrawEvent e) {
    switch (e) {
      case IncomingPresence p:
        _upsertOnline(p.senderId, p.senderName, p.color);
        if (mounted) setState(() {});
        break;

      case IncomingClear _:
        setState(() {
          _objects.clear();
          _order.clear();
          _myUndoStack.clear();
          _repaint++;
        });
        break;

      case IncomingStrokeChunk c:
        _upsertOnline(c.senderId, c.senderName, c.color);
        final key = '${c.senderId}#${c.objectId}';
        final existing = _objects[key];
        if (existing is StrokeObject) {
          existing.points.addAll(c.points);
          if (c.strokeEnd) existing.finished = true;
        } else if (existing == null) {
          final s = StrokeObject(
            senderId: c.senderId,
            objectId: c.objectId,
            color: c.color,
            brushSize: c.brushSize,
            points: List.of(c.points),
            rainbow: c.rainbow,
            finished: c.strokeEnd,
          );
          _objects[key] = s;
          _order.add(key);
          _evictOld();
        }
        setState(() => _repaint++);
        break;

      case IncomingShape s:
        _upsertOnline(s.senderId, s.senderName, s.color);
        final key = '${s.senderId}#${s.objectId}';
        final obj = ShapeObject(
          senderId: s.senderId,
          objectId: s.objectId,
          color: s.color,
          fillColor: s.fillColor,
          brushSize: s.brushSize,
          kind: s.kind,
          p1: s.p1,
          p2: s.p2,
        );
        _objects[key] = obj;
        if (!_order.contains(key)) _order.add(key);
        _evictOld();
        setState(() => _repaint++);
        break;

      case IncomingDelete d:
        final key = '${d.senderId}#${d.objectId}';
        if (_objects.remove(key) != null) {
          _order.remove(key);
          setState(() => _repaint++);
        }
        break;
    }
  }

  void _evictOld() {
    while (_order.length > _maxObjects) {
      final old = _order.removeAt(0);
      _objects.remove(old);
    }
  }

  // --- Pan callbacks --------------------------------------------------------

  DrawPoint _normalize(Offset p) {
    final w = _canvasSize.width == 0 ? 1 : _canvasSize.width;
    final h = _canvasSize.height == 0 ? 1 : _canvasSize.height;
    return DrawPoint(
      (p.dx / w).clamp(0.0, 1.0),
      (p.dy / h).clamp(0.0, 1.0),
    );
  }

  void _onPanDown(DragDownDetails d) {
    if (_canvasSize == Size.zero) return;
    _myObjectId = _rng.nextInt(0xFFFFFFFF);
    if (_tool == Tool.brush) {
      final key = '${widget.settings.userId}#$_myObjectId';
      _myStrokeKey = key;
      final pt = _normalize(d.localPosition);
      final stroke = StrokeObject(
        senderId: widget.settings.userId,
        objectId: _myObjectId,
        color: _color,
        brushSize: _brushSize,
        points: [pt],
        rainbow: _rainbow,
      );
      _objects[key] = stroke;
      _order.add(key);
      _evictOld();
      _pendingPoints
        ..clear()
        ..add(pt);
      _flushTimer?.cancel();
      _flushTimer = Timer.periodic(_flushCadence, (_) => _flushStroke());
    } else {
      // Şekil: preview oluştur, henüz broadcast yok
      final p = _normalize(d.localPosition);
      _previewShape = ShapeObject(
        senderId: widget.settings.userId,
        objectId: _myObjectId,
        color: _color,
        fillColor: _fill ? _color : null,
        brushSize: _brushSize,
        kind: _toolToShape(_tool),
        p1: p,
        p2: p,
      );
    }
    setState(() => _repaint++);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final p = _normalize(d.localPosition);
    if (_tool == Tool.brush) {
      final key = _myStrokeKey;
      if (key == null) return;
      final s = _objects[key];
      if (s is! StrokeObject) return;
      s.points.add(p);
      _pendingPoints.add(p);
      if (_pendingPoints.length >= 20) _flushStroke();
    } else {
      final prev = _previewShape;
      if (prev == null) return;
      _previewShape = ShapeObject(
        senderId: prev.senderId,
        objectId: prev.objectId,
        color: prev.color,
        fillColor: prev.fillColor,
        brushSize: prev.brushSize,
        kind: prev.kind,
        p1: prev.p1,
        p2: p,
      );
    }
    setState(() => _repaint++);
  }

  void _onPanEnd(DragEndDetails _) => _finishDrag();
  void _onPanCancel() => _finishDrag();

  void _finishDrag() {
    if (_tool == Tool.brush) {
      _flushTimer?.cancel();
      _flushStroke(end: true);
      final key = _myStrokeKey;
      if (key != null) _myUndoStack.add(_myObjectId);
      _myStrokeKey = null;
    } else {
      final prev = _previewShape;
      if (prev != null) {
        // Preview'i kalıcı objeye çevir + broadcast
        final key = prev.key;
        _objects[key] = prev;
        if (!_order.contains(key)) _order.add(key);
        _myUndoStack.add(prev.objectId);
        _udp.sendShape(
          port: widget.settings.port,
          userId: widget.settings.userId,
          name: widget.settings.name,
          objectId: prev.objectId,
          kind: prev.kind,
          color: prev.color,
          fillColor: prev.fillColor,
          brushSize: prev.brushSize,
          p1: prev.p1,
          p2: prev.p2,
        );
      }
      _previewShape = null;
    }
    setState(() => _repaint++);
  }

  void _flushStroke({bool end = false}) {
    if (_pendingPoints.isEmpty && !end) return;
    final chunk = List<DrawPoint>.from(_pendingPoints);
    _pendingPoints.clear();
    _udp.sendStrokeChunk(
      port: widget.settings.port,
      userId: widget.settings.userId,
      name: widget.settings.name,
      objectId: _myObjectId,
      color: _color,
      brushSize: _brushSize,
      points: chunk,
      strokeEnd: end,
      rainbow: _rainbow,
    );
  }

  // --- Undo / Clear / Save --------------------------------------------------

  Future<void> _undo() async {
    if (_myUndoStack.isEmpty) return;
    final lastId = _myUndoStack.removeLast();
    final key = '${widget.settings.userId}#$lastId';
    if (_objects.remove(key) != null) {
      _order.remove(key);
      setState(() => _repaint++);
    }
    _udp.sendDelete(
      port: widget.settings.port,
      userId: widget.settings.userId,
      objectId: lastId,
    );
  }

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
        _objects.clear();
        _order.clear();
        _myUndoStack.clear();
        _repaint++;
      });
      _udp.sendClear(
        port: widget.settings.port,
        userId: widget.settings.userId,
        name: widget.settings.name,
      );
    }
  }

  Future<Uint8List?> _capturePng() async {
    final ro = _canvasKey.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return null;
    final image = await ro.toImage(pixelRatio: 3.0);
    final bd = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bd?.buffer.asUint8List();
  }

  Future<void> _savePng() async {
    final bytes = await _capturePng();
    if (bytes == null) return;
    try {
      final ok = await Gal.hasAccess(toAlbum: true);
      if (!ok) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) {
          _snack('Galeri izni verilmedi');
          return;
        }
      }
      final fname =
          'ortakcizim_${DateTime.now().millisecondsSinceEpoch}.png';
      await Gal.putImageBytes(bytes, name: fname);
      _snack('Kaydedildi: $fname');
    } catch (e) {
      _snack('Kaydedilemedi: $e');
    }
  }

  Future<void> _sharePng() async {
    final bytes = await _capturePng();
    if (bytes == null) return;
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/ortakcizim_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        text: 'OrtakÇizim çalışmam 🎨',
      );
    } catch (e) {
      _snack('Paylaşılamadı: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ),
    );
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

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final objectList = _order
        .map((k) => _objects[k])
        .whereType<DrawObject>()
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
              online: _online.values.toList(),
              canUndo: _myUndoStack.isNotEmpty,
              onUndo: _undo,
              onSave: _savePng,
              onShare: _sharePng,
              onClear: _confirmClear,
              onSettings: _openSettings,
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
                          child: RepaintBoundary(
                            key: _canvasKey,
                            child: Container(
                              color: const Color(0xFFFDFCFA),
                              child: CustomPaint(
                                painter: CanvasPainter(
                                  objects: objectList,
                                  preview: _previewShape,
                                  repaintToken: _repaint,
                                ),
                                size: Size.infinite,
                              ),
                            ),
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
              tool: _tool,
              onTool: (t) => setState(() => _tool = t),
              rainbow: _rainbow,
              onRainbow: (v) => setState(() => _rainbow = v),
              fill: _fill,
              onFill: (v) => setState(() => _fill = v),
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

// --- Widgets ---------------------------------------------------------------

class _TopBar extends StatelessWidget {
  final String myName;
  final int myColor;
  final String channel;
  final List<_Peer> online;
  final bool canUndo;
  final VoidCallback onUndo;
  final VoidCallback onSave;
  final VoidCallback onShare;
  final VoidCallback onClear;
  final VoidCallback onSettings;

  const _TopBar({
    required this.myName,
    required this.myColor,
    required this.channel,
    required this.online,
    required this.canUndo,
    required this.onUndo,
    required this.onSave,
    required this.onShare,
    required this.onClear,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
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
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  myName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
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
              height: 28,
              width: (online.length * 24.0).clamp(24.0, 120.0),
              child: ListView.separated(
                shrinkWrap: true,
                scrollDirection: Axis.horizontal,
                itemCount: online.length,
                separatorBuilder: (_, _) => const SizedBox(width: 4),
                itemBuilder: (_, i) => Tooltip(
                  message: online[i].name,
                  child: _Dot(color: Color(online[i].color), size: 22),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Geri al',
            icon: const Icon(Icons.undo),
            onPressed: canUndo ? onUndo : null,
          ),
          IconButton(
            tooltip: 'Kaydet',
            icon: const Icon(Icons.save_alt),
            onPressed: onSave,
          ),
          IconButton(
            tooltip: 'Paylaş',
            icon: const Icon(Icons.share),
            onPressed: onShare,
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
  final Tool tool;
  final ValueChanged<Tool> onTool;
  final bool rainbow;
  final ValueChanged<bool> onRainbow;
  final bool fill;
  final ValueChanged<bool> onFill;
  final int selectedColor;
  final double brushSize;
  final ValueChanged<int> onColor;
  final ValueChanged<double> onBrush;

  const _BottomBar({
    required this.tool,
    required this.onTool,
    required this.rainbow,
    required this.onRainbow,
    required this.fill,
    required this.onFill,
    required this.selectedColor,
    required this.brushSize,
    required this.onColor,
    required this.onBrush,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
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
                _ToolBtn(
                  icon: Icons.brush,
                  label: 'Fırça',
                  selected: tool == Tool.brush,
                  onTap: () => onTool(Tool.brush),
                ),
                _ToolBtn(
                  icon: Icons.crop_square,
                  label: 'Kare',
                  selected: tool == Tool.rect,
                  onTap: () => onTool(Tool.rect),
                ),
                _ToolBtn(
                  icon: Icons.circle_outlined,
                  label: 'Daire',
                  selected: tool == Tool.ellipse,
                  onTap: () => onTool(Tool.ellipse),
                ),
                _ToolBtn(
                  icon: Icons.remove,
                  label: 'Çizgi',
                  selected: tool == Tool.line,
                  onTap: () => onTool(Tool.line),
                ),
                _ToolBtn(
                  icon: Icons.arrow_right_alt,
                  label: 'Ok',
                  selected: tool == Tool.arrow,
                  onTap: () => onTool(Tool.arrow),
                ),
                _ToolBtn(
                  icon: Icons.star,
                  label: 'Yıldız',
                  selected: tool == Tool.star,
                  onTap: () => onTool(Tool.star),
                ),
                _ToolBtn(
                  icon: Icons.favorite,
                  label: 'Kalp',
                  selected: tool == Tool.heart,
                  onTap: () => onTool(Tool.heart),
                ),
                const SizedBox(width: 8),
                _Toggle(
                  icon: Icons.gradient,
                  label: 'Gökkuşağı',
                  on: rainbow,
                  enabled: tool == Tool.brush,
                  onTap: () => onRainbow(!rainbow),
                ),
                _Toggle(
                  icon: Icons.format_color_fill,
                  label: 'Dolgu',
                  on: fill,
                  enabled: tool != Tool.brush &&
                      tool != Tool.line &&
                      tool != Tool.arrow,
                  onTap: () => onFill(!fill),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
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
                width: 34,
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

class _ToolBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ToolBtn({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? Theme.of(context).colorScheme.primary : Colors.black87;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 60,
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: color,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool on;
  final bool enabled;
  final VoidCallback onTap;
  const _Toggle({
    required this.icon,
    required this.label,
    required this.on,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = on && enabled;
    final color = !enabled
        ? Colors.black26
        : active
            ? Theme.of(context).colorScheme.primary
            : Colors.black87;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          width: 68,
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: color,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
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
        width: selected ? 40 : 34,
        height: selected ? 40 : 34,
        decoration: BoxDecoration(
          color: Color(color),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.black : Colors.black26,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }
}
