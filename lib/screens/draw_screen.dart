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

import '../models/avatars.dart';
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

enum Tool { select, brush, rect, ellipse, line, arrow, star, heart, stamp }

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
    case Tool.stamp:
      return ShapeKind.stamp;
    case Tool.brush:
    case Tool.select:
      throw StateError('not a shape tool');
  }
}

/// Seçili şekil üzerindeki 4 köşe tutamağı (yeniden boyutlandırma için).
enum _Handle { topLeft, topRight, bottomRight, bottomLeft }

class _Peer {
  final String id;
  String name;
  int color;
  int avatarIdx;
  DateTime lastSeen;
  _Peer({
    required this.id,
    required this.name,
    required this.color,
    required this.avatarIdx,
    required this.lastSeen,
  });
}

/// Kısa ömürlü floating reaction — tuval üzerinde yukarı süzülür.
class _FloatingReaction {
  final String emoji;
  final String fromName; // gösterilecek kaynak adı ("Sen" veya peer adı)
  final double startTimeMs;
  final double xFraction; // 0..1 — tuval genişliğine göre konum
  _FloatingReaction({
    required this.emoji,
    required this.fromName,
    required this.startTimeMs,
    required this.xFraction,
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
  Timer? _reactionTicker;
  final _rng = Random();

  // Çizim durumu
  final Map<String, DrawObject> _objects = {}; // senderId#objectId → obj
  final List<String> _order = [];
  final List<int> _myUndoStack = []; // undo için kendi obje ID'leri
  final Map<String, _Peer> _online = {};

  // Araçlar / ayarlar
  Tool _tool = Tool.brush;
  bool _rainbow = false;
  bool _confetti = false;
  bool _fill = false;
  int _stampIdx = Stamps.defaultIdx;
  double _brushSize = Brushes.defaultSize;
  late int _color;
  int _repaint = 0;

  // Ephemeral reaksiyonlar — tuval üstünde global floating overlay.
  final List<_FloatingReaction> _activeReactions = [];

  // Aktif kendi çizim
  int _myObjectId = 0;
  String? _myStrokeKey; // stroke sırasında
  final List<DrawPoint> _pendingPoints = [];
  ShapeObject? _previewShape;

  // Seçim (Tool.select)
  String? _selectedKey;
  _Handle? _activeHandle; // null = gövdeyi taşı
  DrawPoint? _dragInitialP1;
  DrawPoint? _dragInitialP2;
  Offset? _dragStartLocal;
  DateTime _lastMoveBroadcast = DateTime.fromMillisecondsSinceEpoch(0);
  static const _moveBroadcastInterval = Duration(milliseconds: 40);

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
    _reactionTicker?.cancel();
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
      avatarIdx: widget.settings.avatarIdx,
    );
  }

  void _upsertOnline(String id, String name, int color, int avatarIdx) {
    final existed = _online.containsKey(id);
    _online[id] = _Peer(
      id: id,
      name: name,
      color: color,
      avatarIdx: avatarIdx,
      lastSeen: DateTime.now(),
    );
    if (!existed) _sendPresence();
  }

  void _onIncoming(IncomingDrawEvent e) {
    switch (e) {
      case IncomingPresence p:
        _upsertOnline(p.senderId, p.senderName, p.color, p.avatarIdx);
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
        _upsertOnline(
          c.senderId,
          c.senderName,
          c.color,
          _online[c.senderId]?.avatarIdx ?? 0,
        );
        final key = '${c.senderId}#${c.objectId}';
        final existing = _objects[key];
        StrokeObject? target;
        if (existing is StrokeObject) {
          existing.points.addAll(c.points);
          if (c.strokeEnd) existing.finished = true;
          target = existing;
        } else if (existing == null) {
          final s = StrokeObject(
            senderId: c.senderId,
            objectId: c.objectId,
            color: c.color,
            brushSize: c.brushSize,
            points: List.of(c.points),
            rainbow: c.rainbow,
            confetti: c.confetti,
            finished: c.strokeEnd,
          );
          _objects[key] = s;
          _order.add(key);
          _evictOld();
          target = s;
        }
        // Gönderen parmağı kaldırdığında Chaikin ile yumuşat.
        if (c.strokeEnd && target != null) {
          _smoothStrokeIfEligible(target);
        }
        setState(() => _repaint++);
        break;

      case IncomingShape s:
        _upsertOnline(
          s.senderId,
          s.senderName,
          s.color,
          _online[s.senderId]?.avatarIdx ?? 0,
        );
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
          extra: s.extra,
        );
        _objects[key] = obj;
        if (!_order.contains(key)) _order.add(key);
        _evictOld();
        setState(() => _repaint++);
        break;

      case IncomingDelete d:
        final key = '${d.targetSenderId}#${d.objectId}';
        if (_objects.remove(key) != null) {
          _order.remove(key);
          if (_selectedKey == key) _selectedKey = null;
          setState(() => _repaint++);
        }
        break;

      case IncomingMove m:
        final key = '${m.targetSenderId}#${m.objectId}';
        final existing = _objects[key];
        if (existing is ShapeObject) {
          _objects[key] = ShapeObject(
            senderId: existing.senderId,
            objectId: existing.objectId,
            color: existing.color,
            fillColor: existing.fillColor,
            brushSize: existing.brushSize,
            kind: existing.kind,
            p1: m.p1,
            p2: m.p2,
            extra: existing.extra,
          );
          setState(() => _repaint++);
        }
        break;

      case IncomingReaction r:
        // Gönderen peer adını bul; bilinmeyen ise kısa kimlik göster.
        final fromName =
            _online[r.senderId]?.name ?? 'Biri';
        _spawnReaction(fromName, r.reactionIdx);
        break;
    }
  }

  /// Yeni bir reaksiyonu tuval overlay listesine ekler.
  void _spawnReaction(String fromName, int reactionIdx) {
    if (reactionIdx < 0 || reactionIdx >= Reactions.count) return;
    final emoji = Reactions.list[reactionIdx];
    final now = DateTime.now().millisecondsSinceEpoch.toDouble();
    _activeReactions.add(_FloatingReaction(
      emoji: emoji,
      fromName: fromName,
      startTimeMs: now,
      xFraction: 0.15 + _rng.nextDouble() * 0.7, // orta şeritte rastgele
    ));
    _ensureReactionTicker();
    if (mounted) setState(() {});
  }

  /// Reaksiyonlar aktif oldukça ~40 ms aralıkla ekranı yeniler; biter bitmez
  /// kendini durdurur — boşuna CPU harcama.
  void _ensureReactionTicker() {
    if (_reactionTicker != null) return;
    _reactionTicker = Timer.periodic(const Duration(milliseconds: 40), (_) {
      final now = DateTime.now().millisecondsSinceEpoch.toDouble();
      final cutoff = now - 2500;
      _activeReactions.removeWhere((r) => r.startTimeMs < cutoff);
      if (_activeReactions.isEmpty) {
        _reactionTicker?.cancel();
        _reactionTicker = null;
      }
      if (mounted) setState(() {});
    });
  }

  void _sendReactionTo(String targetUserId, int reactionIdx) {
    // Hem yerel tetikle (ben kendim gördüm) hem de ağa yay.
    _spawnReaction('Sen', reactionIdx);
    _udp.sendReaction(
      port: widget.settings.port,
      userId: widget.settings.userId,
      targetUserId: targetUserId,
      reactionIdx: reactionIdx,
    );
  }

  void _evictOld() {
    while (_order.length > _maxObjects) {
      final old = _order.removeAt(0);
      _objects.remove(old);
    }
  }

  /// Chaikin corner-cutting — jagged çizgiyi yumuşatır, 1 iterasyon.
  /// Her segment iki yeni ¼-¾ noktasıyla değiştirilir. Konfeti fırçasında
  /// emoji yoğunluğu iki katına çıkacağından atlanır.
  static List<DrawPoint> _chaikin(List<DrawPoint> pts) {
    if (pts.length < 3) return pts;
    final out = <DrawPoint>[pts.first];
    for (int i = 0; i < pts.length - 1; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      out.add(DrawPoint(a.x * 0.75 + b.x * 0.25, a.y * 0.75 + b.y * 0.25));
      out.add(DrawPoint(a.x * 0.25 + b.x * 0.75, a.y * 0.25 + b.y * 0.75));
    }
    out.add(pts.last);
    return out;
  }

  /// Bitmiş bir stroke'un yerel `points` listesini yumuşat. Broadcast
  /// edilmemesi, alıcılar aynı algoritmayı kendi tarafında uygular.
  void _smoothStrokeIfEligible(StrokeObject s) {
    if (s.confetti) return; // emoji sıklığı bozulmasın
    if (s.points.length < 3) return;
    final smoothed = _chaikin(s.points);
    s.points
      ..clear()
      ..addAll(smoothed);
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

  // ---- Hit-test yardımcıları ---------------------------------------------

  /// Verilen local ofseti içeren en üstteki şekli bul (reverse z-order).
  String? _hitTestShape(Offset local) {
    for (int i = _order.length - 1; i >= 0; i--) {
      final key = _order[i];
      final obj = _objects[key];
      if (obj is! ShapeObject) continue;
      final r = Rect.fromPoints(
        Offset(obj.p1.x * _canvasSize.width, obj.p1.y * _canvasSize.height),
        Offset(obj.p2.x * _canvasSize.width, obj.p2.y * _canvasSize.height),
      ).inflate(8);
      if (r.contains(local)) return key;
    }
    return null;
  }

  /// Seçili şeklin köşe tutamağına mı bastı?
  _Handle? _hitTestHandle(Offset local) {
    final key = _selectedKey;
    if (key == null) return null;
    final obj = _objects[key];
    if (obj is! ShapeObject) return null;
    final r = Rect.fromPoints(
      Offset(obj.p1.x * _canvasSize.width, obj.p1.y * _canvasSize.height),
      Offset(obj.p2.x * _canvasSize.width, obj.p2.y * _canvasSize.height),
    );
    const tol = 28.0;
    final corners = <_Handle, Offset>{
      _Handle.topLeft: r.topLeft,
      _Handle.topRight: r.topRight,
      _Handle.bottomRight: r.bottomRight,
      _Handle.bottomLeft: r.bottomLeft,
    };
    for (final e in corners.entries) {
      if ((e.value - local).distance < tol) return e.key;
    }
    return null;
  }

  void _onPanDown(DragDownDetails d) {
    if (_canvasSize == Size.zero) return;

    // --- Seçim aracı ---
    if (_tool == Tool.select) {
      // Önce mevcut seçimin tutamağına mı bastık?
      final handle = _hitTestHandle(d.localPosition);
      if (handle != null && _selectedKey != null) {
        final obj = _objects[_selectedKey!];
        if (obj is ShapeObject) {
          _activeHandle = handle;
          _dragStartLocal = d.localPosition;
          _dragInitialP1 = obj.p1;
          _dragInitialP2 = obj.p2;
          return;
        }
      }
      // Aksi halde şekil seçmeye dene
      final newSel = _hitTestShape(d.localPosition);
      if (newSel != null) {
        final obj = _objects[newSel];
        if (obj is ShapeObject) {
          _selectedKey = newSel;
          _activeHandle = null;
          _dragStartLocal = d.localPosition;
          _dragInitialP1 = obj.p1;
          _dragInitialP2 = obj.p2;
        }
      } else {
        // Boşluğa basıldı → seçimi kaldır
        _selectedKey = null;
      }
      setState(() => _repaint++);
      return;
    }

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
        confetti: _confetti,
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
        extra: _tool == Tool.stamp ? Stamps.list[_stampIdx] : '',
      );
    }
    setState(() => _repaint++);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    // --- Seçim aracı: taşı veya boyutlandır ---
    if (_tool == Tool.select) {
      final key = _selectedKey;
      final start = _dragStartLocal;
      final initP1 = _dragInitialP1;
      final initP2 = _dragInitialP2;
      if (key == null || start == null || initP1 == null || initP2 == null) {
        return;
      }
      final obj = _objects[key];
      if (obj is! ShapeObject) return;
      final delta = d.localPosition - start;
      final dx = delta.dx / _canvasSize.width;
      final dy = delta.dy / _canvasSize.height;

      DrawPoint newP1;
      DrawPoint newP2;
      if (_activeHandle == null) {
        // Gövde taşı: p1 ve p2'yi aynı oranda kaydır
        newP1 = DrawPoint(
          (initP1.x + dx).clamp(0.0, 1.0),
          (initP1.y + dy).clamp(0.0, 1.0),
        );
        newP2 = DrawPoint(
          (initP2.x + dx).clamp(0.0, 1.0),
          (initP2.y + dy).clamp(0.0, 1.0),
        );
      } else {
        // Köşe tutamağı: bounding rect'in ilgili köşesini kaydır.
        double left = initP1.x < initP2.x ? initP1.x : initP2.x;
        double top = initP1.y < initP2.y ? initP1.y : initP2.y;
        double right = initP1.x > initP2.x ? initP1.x : initP2.x;
        double bottom = initP1.y > initP2.y ? initP1.y : initP2.y;
        switch (_activeHandle!) {
          case _Handle.topLeft:
            left = (left + dx).clamp(0.0, right - 0.02);
            top = (top + dy).clamp(0.0, bottom - 0.02);
            break;
          case _Handle.topRight:
            right = (right + dx).clamp(left + 0.02, 1.0);
            top = (top + dy).clamp(0.0, bottom - 0.02);
            break;
          case _Handle.bottomRight:
            right = (right + dx).clamp(left + 0.02, 1.0);
            bottom = (bottom + dy).clamp(top + 0.02, 1.0);
            break;
          case _Handle.bottomLeft:
            left = (left + dx).clamp(0.0, right - 0.02);
            bottom = (bottom + dy).clamp(top + 0.02, 1.0);
            break;
        }
        newP1 = DrawPoint(left, top);
        newP2 = DrawPoint(right, bottom);
      }

      _objects[key] = ShapeObject(
        senderId: obj.senderId,
        objectId: obj.objectId,
        color: obj.color,
        fillColor: obj.fillColor,
        brushSize: obj.brushSize,
        kind: obj.kind,
        p1: newP1,
        p2: newP2,
        extra: obj.extra,
      );

      final now = DateTime.now();
      if (now.difference(_lastMoveBroadcast) >= _moveBroadcastInterval) {
        _lastMoveBroadcast = now;
        _udp.sendMove(
          port: widget.settings.port,
          userId: widget.settings.userId,
          targetSenderId: obj.senderId,
          objectId: obj.objectId,
          p1: newP1,
          p2: newP2,
        );
      }
      setState(() => _repaint++);
      return;
    }

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
        extra: prev.extra,
      );
    }
    setState(() => _repaint++);
  }

  void _onPanEnd(DragEndDetails _) => _finishDrag();
  void _onPanCancel() => _finishDrag();

  void _finishDrag() {
    // --- Seçim aracı ---
    if (_tool == Tool.select) {
      final key = _selectedKey;
      if (key != null) {
        final obj = _objects[key];
        if (obj is ShapeObject &&
            (_dragInitialP1 != null || _dragInitialP2 != null)) {
          _udp.sendMove(
            port: widget.settings.port,
            userId: widget.settings.userId,
            targetSenderId: obj.senderId,
            objectId: obj.objectId,
            p1: obj.p1,
            p2: obj.p2,
          );
        }
      }
      _activeHandle = null;
      _dragStartLocal = null;
      _dragInitialP1 = null;
      _dragInitialP2 = null;
      setState(() => _repaint++);
      return;
    }

    if (_tool == Tool.brush) {
      _flushTimer?.cancel();
      _flushStroke(end: true);
      final key = _myStrokeKey;
      if (key != null) {
        _myUndoStack.add(_myObjectId);
        // Parmak kalktığında kendi stroke'umuzu yumuşat — jagged çizgiyi
        // düzgün bir eğriye çevirir. Broadcast'e gerek yok: alıcılar hem
        // aynı algoritmayı hem de strokeEnd bayrağını kendi tarafında alıp
        // aynı sonucu üretiyor.
        final s = _objects[key];
        if (s is StrokeObject) _smoothStrokeIfEligible(s);
      }
      _myStrokeKey = null;
    } else {
      final prev = _previewShape;
      if (prev != null) {
        // Küçücük (sadece tap) şekilleri eleyelim — boş kalma.
        final dx = (prev.p2.x - prev.p1.x).abs() * _canvasSize.width;
        final dy = (prev.p2.y - prev.p1.y).abs() * _canvasSize.height;
        final tooSmall = dx < 6 && dy < 6;
        if (tooSmall) {
          _previewShape = null;
          setState(() => _repaint++);
          return;
        }
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
          extra: prev.extra,
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
      confetti: _confetti,
    );
  }

  // --- Undo / Clear / Save --------------------------------------------------

  Future<void> _undo() async {
    if (_myUndoStack.isEmpty) return;
    final lastId = _myUndoStack.removeLast();
    final key = '${widget.settings.userId}#$lastId';
    if (_objects.remove(key) != null) {
      _order.remove(key);
      if (_selectedKey == key) _selectedKey = null;
      setState(() => _repaint++);
    }
    _udp.sendDelete(
      port: widget.settings.port,
      userId: widget.settings.userId,
      targetSenderId: widget.settings.userId,
      objectId: lastId,
    );
  }

  Future<void> _deleteSelected() async {
    final key = _selectedKey;
    if (key == null) return;
    final obj = _objects[key];
    if (obj == null) return;
    _objects.remove(key);
    _order.remove(key);
    _selectedKey = null;
    setState(() => _repaint++);
    _udp.sendDelete(
      port: widget.settings.port,
      userId: widget.settings.userId,
      targetSenderId: obj.senderId,
      objectId: obj.objectId,
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
              channel: widget.settings.channel,
              onlineCount: _online.length + 1,
              canUndo: _myUndoStack.isNotEmpty,
              hasSelection: _selectedKey != null,
              onDeleteSelected: _deleteSelected,
              onOnlineTap: _online.isEmpty
                  ? null
                  : () => _showOnlineSheet(context),
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
                                  selectedKey: _selectedKey,
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
                  // Floating reaksiyon overlay — tuval üstünde, parmak
                  // hareketini engellemez (IgnorePointer her widget içinde).
                  if (_activeReactions.isNotEmpty)
                    Positioned.fill(
                      child: LayoutBuilder(
                        builder: (_, c) {
                          final nowMs =
                              DateTime.now().millisecondsSinceEpoch.toDouble();
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              for (final r in _activeReactions)
                                _FloatingReactionWidget(
                                  reaction: r,
                                  nowMs: nowMs,
                                  areaWidth: c.maxWidth,
                                  areaHeight: c.maxHeight,
                                ),
                            ],
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
              onTool: (t) => setState(() {
                _tool = t;
                // Gökkuşağı ve confetti sadece fırçada anlamlı.
                if (t != Tool.brush) {
                  _rainbow = false;
                  _confetti = false;
                }
              }),
              rainbow: _rainbow,
              onRainbow: (v) => setState(() {
                _rainbow = v;
                if (v) _confetti = false; // karşılıklı dışlayıcı
              }),
              confetti: _confetti,
              onConfetti: (v) => setState(() {
                _confetti = v;
                if (v) _rainbow = false;
              }),
              fill: _fill,
              onFill: (v) => setState(() => _fill = v),
              stampIdx: _stampIdx,
              onStampIdx: (i) => setState(() => _stampIdx = i),
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
  final String channel;
  final int onlineCount;
  final bool canUndo;
  final bool hasSelection;
  final VoidCallback onDeleteSelected;
  final VoidCallback? onOnlineTap; // null → kanalda başka kimse yok
  final VoidCallback onUndo;
  final VoidCallback onSave;
  final VoidCallback onShare;
  final VoidCallback onClear;
  final VoidCallback onSettings;

  const _TopBar({
    required this.myName,
    required this.channel,
    required this.onlineCount,
    required this.canUndo,
    required this.hasSelection,
    required this.onDeleteSelected,
    required this.onOnlineTap,
    required this.onUndo,
    required this.onSave,
    required this.onShare,
    required this.onClear,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        children: [
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
                  '# $channel  •  $onlineCount ressam',
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
          // Online chip — kişi ikonu + toplam sayı. Tıklama bottomSheet açar.
          Tooltip(
            message: 'Kanaldaki ressamlar',
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: onOnlineTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: onOnlineTap == null
                      ? Colors.black.withValues(alpha: 0.04)
                      : const Color(0xFF3949AB).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.people_alt,
                      size: 18,
                      color: onOnlineTap == null
                          ? Colors.black45
                          : const Color(0xFF3949AB),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$onlineCount',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: onOnlineTap == null
                            ? Colors.black54
                            : const Color(0xFF3949AB),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (hasSelection)
            IconButton(
              tooltip: 'Seçileni sil',
              icon: const Icon(Icons.delete_sweep, color: Color(0xFFE53935)),
              onPressed: onDeleteSelected,
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

/// Online kullanıcıları gösteren bottom-sheet. Her satır: avatar + ad +
/// inline 5 reaksiyon butonu. Butona basılınca reaksiyon atılır + sheet kapanır.
Future<void> _showOnlineSheet(BuildContext context) async {
  final state = context.findAncestorStateOfType<_DrawScreenState>();
  if (state == null) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final peers = state._online.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${peers.length + 1} ressam online',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.black54,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 12),
              // Kendim (pasif satır — kendime reaksiyon yok)
              _OnlinePeerRow(
                name: '${state.widget.settings.name} (sen)',
                emoji: Avatars.get(state.widget.settings.avatarIdx).emoji,
                color: Color(state._color),
                onReaction: null,
              ),
              if (peers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'Aynı kanalda başka ressam yok. Bir arkadaşının telefonuna aynı kanalı gir!',
                    style: TextStyle(color: Colors.black54),
                  ),
                )
              else
                for (final peer in peers)
                  _OnlinePeerRow(
                    name: peer.name,
                    emoji: Avatars.get(peer.avatarIdx).emoji,
                    color: Color(peer.color),
                    onReaction: (idx) {
                      Navigator.of(ctx).pop();
                      state._sendReactionTo(peer.id, idx);
                    },
                  ),
            ],
          ),
        ),
      );
    },
  );
}

class _OnlinePeerRow extends StatelessWidget {
  final String name;
  final String emoji;
  final Color color;
  final void Function(int reactionIdx)? onReaction;
  const _OnlinePeerRow({
    required this.name,
    required this.emoji,
    required this.color,
    required this.onReaction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 4,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(emoji, style: const TextStyle(fontSize: 24)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onReaction != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (int i = 0; i < Reactions.list.length; i++)
                  InkResponse(
                    onTap: () => onReaction!(i),
                    radius: 22,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        Reactions.list[i],
                        style: const TextStyle(fontSize: 24),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Tuval üstünde yükselen reaksiyon — alttan görünür, üste çıkar, soluk.
/// Altında küçük bir isim etiketi: kim attı?
class _FloatingReactionWidget extends StatelessWidget {
  final _FloatingReaction reaction;
  final double nowMs;

  /// İçinde yaşadığı Stack'in yüksekliği (tuval yüksekliği).
  final double areaHeight;
  final double areaWidth;

  const _FloatingReactionWidget({
    required this.reaction,
    required this.nowMs,
    required this.areaHeight,
    required this.areaWidth,
  });

  @override
  Widget build(BuildContext context) {
    final t = ((nowMs - reaction.startTimeMs) / 2500).clamp(0.0, 1.0);
    final easedT = 1 - (1 - t) * (1 - t);
    // Canvas yüksekliğinin ~%55'i kadar yüksel.
    final riseY = easedT * (areaHeight * 0.55);
    // Hafif yan salınım
    final wobble = 16 * (easedT * 6).clamp(0.0, 100.0);
    final sway = (wobble % 32) - 16;
    final opacity = (1 - t * t).clamp(0.0, 1.0);
    final scale = 0.7 + 0.6 * (1 - (t - 0.25).abs()).clamp(0.0, 1.0);

    final leftCenter = reaction.xFraction * areaWidth;

    return Positioned(
      bottom: riseY + 12,
      left: leftCenter - 40,
      width: 80,
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(sway, 0),
            child: Transform.scale(
              scale: scale,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    reaction.emoji,
                    style: const TextStyle(fontSize: 44),
                    textAlign: TextAlign.center,
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      reaction.fromName,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StampBtn extends StatelessWidget {
  final String emoji;
  final bool selected;
  final VoidCallback onTap;
  const _StampBtn({
    required this.emoji,
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
          shape: BoxShape.circle,
          color: selected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.14)
              : Colors.black.withValues(alpha: 0.04),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
        ),
        alignment: Alignment.center,
        child: Text(emoji, style: TextStyle(fontSize: selected ? 26 : 22)),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final Tool tool;
  final ValueChanged<Tool> onTool;
  final bool rainbow;
  final ValueChanged<bool> onRainbow;
  final bool confetti;
  final ValueChanged<bool> onConfetti;
  final bool fill;
  final ValueChanged<bool> onFill;
  final int stampIdx;
  final ValueChanged<int> onStampIdx;
  final int selectedColor;
  final double brushSize;
  final ValueChanged<int> onColor;
  final ValueChanged<double> onBrush;

  const _BottomBar({
    required this.tool,
    required this.onTool,
    required this.rainbow,
    required this.onRainbow,
    required this.confetti,
    required this.onConfetti,
    required this.fill,
    required this.onFill,
    required this.stampIdx,
    required this.onStampIdx,
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
                  icon: Icons.pan_tool_alt,
                  label: 'Seç',
                  selected: tool == Tool.select,
                  onTap: () => onTool(Tool.select),
                ),
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
                  icon: Icons.emoji_emotions,
                  label: 'Damga',
                  selected: tool == Tool.stamp,
                  onTap: () => onTool(Tool.stamp),
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
                  icon: Icons.celebration,
                  label: 'Konfeti',
                  on: confetti,
                  enabled: tool == Tool.brush,
                  onTap: () => onConfetti(!confetti),
                ),
                _Toggle(
                  icon: Icons.format_color_fill,
                  label: 'Dolgu',
                  on: fill,
                  // Sadece kapalı alanı olan şekillerde anlamlı.
                  enabled: tool == Tool.rect ||
                      tool == Tool.ellipse ||
                      tool == Tool.star ||
                      tool == Tool.heart,
                  onTap: () => onFill(!fill),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          if (tool == Tool.stamp)
            SizedBox(
              height: 46,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (int i = 0; i < Stamps.list.length; i++) ...[
                      _StampBtn(
                        emoji: Stamps.list[i],
                        selected: i == stampIdx,
                        onTap: () => onStampIdx(i),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ],
                ),
              ),
            )
          else
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
