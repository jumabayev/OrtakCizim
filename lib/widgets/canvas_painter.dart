import 'package:flutter/material.dart';

import '../models/stroke.dart';

/// Tüm çizim hamlelerini canvas üzerine poliline olarak çizer.
class CanvasPainter extends CustomPainter {
  final List<Stroke> strokes;
  final int repaintToken; // parent Listenable yerine küçük bir ipucu
  CanvasPainter({required this.strokes, required this.repaintToken});

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = stroke.flutterColor
        ..strokeWidth = stroke.brushSize
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke;

      if (stroke.points.length == 1) {
        // Tek nokta — küçük yuvarlak
        final p = stroke.points.first;
        canvas.drawCircle(
          Offset(p.x * size.width, p.y * size.height),
          stroke.brushSize / 2,
          Paint()..color = stroke.flutterColor,
        );
        continue;
      }

      final path = Path();
      final first = stroke.points.first;
      path.moveTo(first.x * size.width, first.y * size.height);
      for (int i = 1; i < stroke.points.length; i++) {
        final p = stroke.points[i];
        path.lineTo(p.x * size.width, p.y * size.height);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CanvasPainter old) =>
      old.repaintToken != repaintToken;
}
