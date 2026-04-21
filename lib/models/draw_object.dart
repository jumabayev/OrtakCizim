import 'dart:ui';

/// Canvas'ta normalize edilmiş tek bir nokta (0..1 aralığında).
class DrawPoint {
  final double x;
  final double y;
  const DrawPoint(this.x, this.y);
}

enum ShapeKind {
  rectangle,
  ellipse,
  line,
  arrow,
  star,
  heart,
  stamp; // extra alanı emoji metnini taşır

  static ShapeKind fromByte(int b) =>
      (b >= 0 && b < ShapeKind.values.length)
          ? ShapeKind.values[b]
          : ShapeKind.rectangle;
}

/// Tuvaldeki herhangi bir çizim nesnesi için ortak taban.
/// objectId: gönderici tarafından üretilen 32-bit rastgele sayı — taşıma,
/// silme ve gelecekte taşıma/boyutlandırma için kullanılır.
sealed class DrawObject {
  final String senderId;
  final int objectId;
  final int color; // stroke rengi (ARGB)
  final int? fillColor; // null = boş, aksi halde dolgu rengi ARGB
  final double brushSize;

  DrawObject({
    required this.senderId,
    required this.objectId,
    required this.color,
    required this.fillColor,
    required this.brushSize,
  });

  String get key => '$senderId#$objectId';

  Color get flutterColor => Color(color);
  Color? get flutterFill => fillColor == null ? null : Color(fillColor!);
}

class StrokeObject extends DrawObject {
  final List<DrawPoint> points;
  final bool rainbow;
  final bool confetti; // true → çizgi yerine her noktaya emoji basar
  bool finished;

  StrokeObject({
    required super.senderId,
    required super.objectId,
    required super.color,
    required super.brushSize,
    required this.points,
    this.rainbow = false,
    this.confetti = false,
    super.fillColor,
    this.finished = false,
  });
}

class ShapeObject extends DrawObject {
  final ShapeKind kind;
  final DrawPoint p1;
  final DrawPoint p2;
  /// stamp kind için emoji metni; diğer şekillerde boş.
  final String extra;

  ShapeObject({
    required super.senderId,
    required super.objectId,
    required super.color,
    required super.brushSize,
    required this.kind,
    required this.p1,
    required this.p2,
    this.extra = '',
    super.fillColor,
  });
}
