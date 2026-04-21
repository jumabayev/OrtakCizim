import 'dart:math';

/// Çocuklar için parlak ve ayırt edilebilir bir palet.
class Palette {
  /// ARGB formatında (üst 0xFF opak).
  static const List<int> colors = [
    0xFFE53935, // kırmızı
    0xFFFB8C00, // turuncu
    0xFFFDD835, // sarı
    0xFF43A047, // yeşil
    0xFF039BE5, // mavi
    0xFF3949AB, // koyu mavi
    0xFF8E24AA, // mor
    0xFFEC407A, // pembe
    0xFF6D4C41, // kahverengi
    0xFF212121, // siyah
    0xFF757575, // gri
    0xFFFFFFFF, // beyaz (silgi gibi)
  ];

  static int random() => colors[Random().nextInt(colors.length)];
}

/// Fırça kalınlığı seçenekleri (piksel).
class Brushes {
  static const List<double> sizes = [3, 6, 10, 16, 24, 36];
  static const double defaultSize = 6;
}
