import 'dart:ui';

/// Canvas’ta sıfırla bir noktası (normalize edilmiş 0..1 koordinat).
class DrawPoint {
  final double x;
  final double y;
  const DrawPoint(this.x, this.y);
}

/// Birden çok noktadan oluşan çizim hamlesi (parmağın basılı kaldığı süre).
class Stroke {
  final String senderId;
  final int strokeId; // gönderici başına benzersiz
  final int color; // ARGB
  final double brushSize; // piksel
  final List<DrawPoint> points;
  bool finished;

  Stroke({
    required this.senderId,
    required this.strokeId,
    required this.color,
    required this.brushSize,
    required this.points,
    this.finished = false,
  });

  String get key => '$senderId#$strokeId';

  Color get flutterColor => Color(color);
}
