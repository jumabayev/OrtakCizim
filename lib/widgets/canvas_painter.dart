import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/draw_object.dart';

/// Tüm çizim nesnelerini canvas üzerine render eden painter.
///
/// - Stroke'larda ardışık noktalar arası midpoint-quadratic-bezier düğümleri
///   ile eğri yumuşatma.
/// - `rainbow` açıksa HSL rengi segmentler boyunca döner → renk karışımlı fırça.
/// - Şekiller için rect/ellipse/line/arrow/star/heart çizimleri.
class CanvasPainter extends CustomPainter {
  final List<DrawObject> objects;

  /// Aktif çizilmekte olan (sürükleme sırasında) şekil, henüz broadcast
  /// edilmemiş hali. Yerel preview olarak çizilir + kılavuz çizgiler.
  final DrawObject? preview;

  /// Seçili objenin key'i ("senderId#objectId"). Varsa çerçeve + köşe
  /// tutamakları çizilir.
  final String? selectedKey;

  final int repaintToken;
  CanvasPainter({
    required this.objects,
    required this.preview,
    required this.selectedKey,
    required this.repaintToken,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final obj in objects) {
      _drawObject(canvas, size, obj);
    }
    final p = preview;
    if (p != null) {
      _drawObject(canvas, size, p);
      _drawPreviewGuides(canvas, size, p);
    }
    final selKey = selectedKey;
    if (selKey != null) {
      for (final obj in objects) {
        if (obj.key == selKey && obj is ShapeObject) {
          _drawSelection(canvas, size, obj);
          break;
        }
      }
    }
  }

  void _drawObject(Canvas canvas, Size size, DrawObject obj) {
    if (obj is StrokeObject) {
      _drawStroke(canvas, size, obj);
    } else if (obj is ShapeObject) {
      _drawShape(canvas, size, obj);
    }
  }

  // --- STROKE ---------------------------------------------------------------

  void _drawStroke(Canvas canvas, Size size, StrokeObject s) {
    if (s.points.isEmpty) return;

    final basePaint = Paint()
      ..strokeWidth = s.brushSize
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke;

    final absPoints = s.points
        .map((p) => Offset(p.x * size.width, p.y * size.height))
        .toList(growable: false);

    if (absPoints.length == 1) {
      final p = absPoints.first;
      canvas.drawCircle(
        p,
        s.brushSize / 2,
        Paint()..color = _pickColor(s, 0, 1),
      );
      return;
    }

    if (s.rainbow) {
      // Her segmenti kendi HSL rengiyle çiz — karışık renkli fırça.
      for (int i = 1; i < absPoints.length; i++) {
        final t = i / (absPoints.length - 1);
        final paint = basePaint..color = _pickColor(s, i, absPoints.length);
        final prev = absPoints[i - 1];
        final curr = absPoints[i];
        if (i + 1 < absPoints.length) {
          // midpoint-bezier için sonraki midpoint’e doğru yumuşat
          final next = absPoints[i + 1];
          final mid1 = Offset((prev.dx + curr.dx) / 2, (prev.dy + curr.dy) / 2);
          final mid2 = Offset((curr.dx + next.dx) / 2, (curr.dy + next.dy) / 2);
          final path = Path()..moveTo(mid1.dx, mid1.dy);
          path.quadraticBezierTo(curr.dx, curr.dy, mid2.dx, mid2.dy);
          canvas.drawPath(path, paint);
        } else {
          canvas.drawLine(prev, curr, paint);
        }
        // ignore: unused_local_variable
        final _ = t; // future: per-segment width etc.
      }
      return;
    }

    // Tek renk stroke — düzleştirilmiş path
    final path = Path();
    path.moveTo(absPoints[0].dx, absPoints[0].dy);
    for (int i = 1; i < absPoints.length - 1; i++) {
      final curr = absPoints[i];
      final next = absPoints[i + 1];
      final mid = Offset((curr.dx + next.dx) / 2, (curr.dy + next.dy) / 2);
      path.quadraticBezierTo(curr.dx, curr.dy, mid.dx, mid.dy);
    }
    path.lineTo(absPoints.last.dx, absPoints.last.dy);
    canvas.drawPath(path, basePaint..color = s.flutterColor);
  }

  Color _pickColor(StrokeObject s, int index, int total) {
    if (!s.rainbow) return s.flutterColor;
    final hue = (index * 18.0) % 360;
    return HSLColor.fromAHSL(1, hue, 0.9, 0.55).toColor();
  }

  // --- SHAPES ---------------------------------------------------------------

  void _drawShape(Canvas canvas, Size size, ShapeObject s) {
    final rect = Rect.fromPoints(
      Offset(s.p1.x * size.width, s.p1.y * size.height),
      Offset(s.p2.x * size.width, s.p2.y * size.height),
    );
    final strokePaint = Paint()
      ..color = s.flutterColor
      ..strokeWidth = s.brushSize
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke;
    final fill = s.flutterFill;
    final fillPaint = fill == null
        ? null
        : (Paint()
            ..color = fill
            ..style = PaintingStyle.fill
            ..isAntiAlias = true);

    switch (s.kind) {
      case ShapeKind.rectangle:
        final r = RRect.fromRectAndRadius(rect, const Radius.circular(8));
        if (fillPaint != null) canvas.drawRRect(r, fillPaint);
        canvas.drawRRect(r, strokePaint);
        break;
      case ShapeKind.ellipse:
        if (fillPaint != null) canvas.drawOval(rect, fillPaint);
        canvas.drawOval(rect, strokePaint);
        break;
      case ShapeKind.line:
        canvas.drawLine(rect.topLeft, rect.bottomRight, strokePaint);
        break;
      case ShapeKind.arrow:
        _drawArrow(canvas, rect, strokePaint);
        break;
      case ShapeKind.star:
        final path = _starPath(rect, 5);
        if (fillPaint != null) canvas.drawPath(path, fillPaint);
        canvas.drawPath(path, strokePaint);
        break;
      case ShapeKind.heart:
        final path = _heartPath(rect);
        if (fillPaint != null) canvas.drawPath(path, fillPaint);
        canvas.drawPath(path, strokePaint);
        break;
    }
  }

  void _drawArrow(Canvas canvas, Rect rect, Paint paint) {
    final start = rect.topLeft;
    final end = rect.bottomRight;
    canvas.drawLine(start, end, paint);
    final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
    final headLen = math.min(
      math.sqrt(math.pow(rect.width, 2) + math.pow(rect.height, 2)) * 0.2,
      40,
    );
    final headAngle = math.pi / 6;
    final p1 = Offset(
      end.dx - headLen * math.cos(angle - headAngle),
      end.dy - headLen * math.sin(angle - headAngle),
    );
    final p2 = Offset(
      end.dx - headLen * math.cos(angle + headAngle),
      end.dy - headLen * math.sin(angle + headAngle),
    );
    canvas.drawLine(end, p1, paint);
    canvas.drawLine(end, p2, paint);
  }

  Path _starPath(Rect rect, int points) {
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    final rOuter = math.min(rect.width, rect.height) / 2;
    final rInner = rOuter * 0.45;
    final path = Path();
    for (int i = 0; i < points * 2; i++) {
      final r = (i.isEven) ? rOuter : rInner;
      final a = -math.pi / 2 + i * math.pi / points;
      final x = cx + r * math.cos(a);
      final y = cy + r * math.sin(a);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  Path _heartPath(Rect rect) {
    final path = Path();
    final w = rect.width;
    final h = rect.height;
    final l = rect.left;
    final t = rect.top;
    // Parametrik kalp şekli, rect içine uyacak şekilde ölçeklenmiş.
    path.moveTo(l + w / 2, t + h);
    path.cubicTo(
      l - w * 0.25,
      t + h * 0.55,
      l + w * 0.1,
      t - h * 0.1,
      l + w / 2,
      t + h * 0.3,
    );
    path.cubicTo(
      l + w * 0.9,
      t - h * 0.1,
      l + w * 1.25,
      t + h * 0.55,
      l + w / 2,
      t + h,
    );
    path.close();
    return path;
  }

  // --- PREVIEW GUIDES (şekil çizerken) --------------------------------------

  void _drawPreviewGuides(Canvas canvas, Size size, DrawObject obj) {
    if (obj is! ShapeObject) return;
    final a = Offset(obj.p1.x * size.width, obj.p1.y * size.height);
    final b = Offset(obj.p2.x * size.width, obj.p2.y * size.height);
    final rect = Rect.fromPoints(a, b);

    // Kesikli bounding rect (line/arrow için ayrıca yardımcı olur).
    final dashPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    _drawDashedRect(canvas, rect.inflate(2), dashPaint);

    // Başlangıç noktası (yeşil) ve bitiş (kırmızı) — yönü net gösterir.
    canvas.drawCircle(
      a,
      7,
      Paint()..color = const Color(0xFF43A047),
    );
    canvas.drawCircle(
      a,
      7,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
      b,
      7,
      Paint()..color = const Color(0xFFE53935),
    );
    canvas.drawCircle(
      b,
      7,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Ölçü bilgisi (örn: 120 × 80).
    final w = rect.width.round();
    final h = rect.height.round();
    final label = '$w×$h';
    _drawLabel(canvas, rect.bottomRight + const Offset(6, 6), label);
  }

  void _drawDashedRect(Canvas canvas, Rect r, Paint paint) {
    const dash = 6.0;
    const gap = 4.0;
    void dashedLine(Offset from, Offset to) {
      final dist = (to - from).distance;
      if (dist == 0) return;
      final dir = (to - from) / dist;
      double drawn = 0;
      while (drawn < dist) {
        final a = from + dir * drawn;
        final end = drawn + dash > dist ? dist : drawn + dash;
        final b = from + dir * end;
        canvas.drawLine(a, b, paint);
        drawn += dash + gap;
      }
    }

    dashedLine(r.topLeft, r.topRight);
    dashedLine(r.topRight, r.bottomRight);
    dashedLine(r.bottomRight, r.bottomLeft);
    dashedLine(r.bottomLeft, r.topLeft);
  }

  void _drawLabel(Canvas canvas, Offset at, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final pad = const EdgeInsets.symmetric(horizontal: 6, vertical: 3);
    final bg = Rect.fromLTWH(
      at.dx,
      at.dy,
      tp.width + pad.horizontal,
      tp.height + pad.vertical,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bg, const Radius.circular(4)),
      Paint()..color = Colors.black.withValues(alpha: 0.7),
    );
    tp.paint(canvas, Offset(at.dx + pad.left, at.dy + pad.top));
  }

  // --- SELECTION (Seç aracıyla seçilmiş şekil) ------------------------------

  void _drawSelection(Canvas canvas, Size size, ShapeObject s) {
    final rect = Rect.fromPoints(
      Offset(s.p1.x * size.width, s.p1.y * size.height),
      Offset(s.p2.x * size.width, s.p2.y * size.height),
    );
    final outline = Paint()
      ..color = const Color(0xFF1E88E5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    _drawDashedRect(canvas, rect.inflate(4), outline);

    // 4 köşe tutamağı
    final corners = [
      rect.topLeft,
      rect.topRight,
      rect.bottomRight,
      rect.bottomLeft,
    ];
    for (final c in corners) {
      canvas.drawCircle(
        c,
        10,
        Paint()..color = Colors.white,
      );
      canvas.drawCircle(
        c,
        10,
        Paint()
          ..color = const Color(0xFF1E88E5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CanvasPainter old) =>
      old.repaintToken != repaintToken;
}
