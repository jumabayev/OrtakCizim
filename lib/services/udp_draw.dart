import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../models/stroke.dart';
import 'channel_codec.dart';

/// Paket başlığı (sekiz byte) + 12 byte nonce + AES-GCM(cipher+tag).
class _Hdr {
  static const List<int> magic = [0x42, 0x42, 0x44, 0x52]; // 'BBDR'
  static const int version = 1;
  static const int size = 8;

  // Mesaj türleri
  static const int typeStroke = 0;
  static const int typeClear = 1;
  static const int typePresence = 2;
}

sealed class IncomingDrawEvent {
  final String senderId;
  const IncomingDrawEvent(this.senderId);
}

class IncomingStroke extends IncomingDrawEvent {
  final int strokeId;
  final String senderName;
  final int color;
  final double brushSize;
  final List<DrawPoint> points;
  final bool strokeEnd;
  IncomingStroke({
    required String senderId,
    required this.strokeId,
    required this.senderName,
    required this.color,
    required this.brushSize,
    required this.points,
    required this.strokeEnd,
  }) : super(senderId);
}

class IncomingClear extends IncomingDrawEvent {
  final String senderName;
  IncomingClear({required String senderId, required this.senderName})
      : super(senderId);
}

class IncomingPresence extends IncomingDrawEvent {
  final String senderName;
  final int color;
  IncomingPresence({
    required String senderId,
    required this.senderName,
    required this.color,
  }) : super(senderId);
}

/// UDP broadcast + AES-GCM taşıyıcısı. Stroke, clear ve presence paketlerini
/// yayar ve dinler. Kendi paketlerimizi senderId ile filtreliyoruz.
class UdpDraw {
  RawDatagramSocket? _socket;
  ChannelCodec? _codec;
  final _incoming = StreamController<IncomingDrawEvent>.broadcast();
  int _txSeq = 0;
  final _rng = Random.secure();

  String? _selfUserId;
  InternetAddress _broadcast = InternetAddress('255.255.255.255');

  Stream<IncomingDrawEvent> get incoming => _incoming.stream;
  bool get isBound => _socket != null;

  void setBroadcastAddress(String? addr) {
    if (addr == null || addr.isEmpty) {
      _broadcast = InternetAddress('255.255.255.255');
      return;
    }
    try {
      _broadcast = InternetAddress(addr);
    } catch (_) {
      _broadcast = InternetAddress('255.255.255.255');
    }
  }

  Future<void> start({
    required int port,
    required ChannelCodec codec,
    required String selfUserId,
    String? broadcastAddress,
  }) async {
    await stop();
    _codec = codec;
    _selfUserId = selfUserId;
    setBroadcastAddress(broadcastAddress);

    final s = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
      reusePort: _canReusePort(),
    );
    s.broadcastEnabled = true;
    s.readEventsEnabled = true;
    _socket = s;
    s.listen(_onEvent, onError: (_) {}, cancelOnError: false);
  }

  bool _canReusePort() =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isLinux;

  Future<void> stop() async {
    final s = _socket;
    _socket = null;
    s?.close();
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final s = _socket;
    if (s == null) return;
    while (true) {
      final pkt = s.receive();
      if (pkt == null) return;
      _handle(pkt);
    }
  }

  Future<void> _handle(Datagram dg) async {
    final data = dg.data;
    if (data.length < _Hdr.size + 12 + 16) return;
    if (data[0] != _Hdr.magic[0] ||
        data[1] != _Hdr.magic[1] ||
        data[2] != _Hdr.magic[2] ||
        data[3] != _Hdr.magic[3]) {
      return;
    }
    if (data[4] != _Hdr.version) return;
    final type = data[5];
    final header = data.sublist(0, _Hdr.size);
    final nonce = data.sublist(_Hdr.size, _Hdr.size + 12);
    final cipher = data.sublist(_Hdr.size + 12);

    final codec = _codec;
    if (codec == null) return;

    final pt = await codec.decrypt(
      cipherWithTag: cipher,
      aad: header,
      nonce: nonce,
    );
    if (pt == null) return;
    if (pt.length < 16) return;

    final senderId = _bytesToHex(pt.sublist(0, 16));
    if (senderId == _selfUserId) return;

    try {
      switch (type) {
        case _Hdr.typeStroke:
          _decodeStroke(senderId, pt);
          break;
        case _Hdr.typeClear:
          _decodeClear(senderId, pt);
          break;
        case _Hdr.typePresence:
          _decodePresence(senderId, pt);
          break;
      }
    } catch (_) {
      // Bozuk paket — sessizce bırak.
    }
  }

  // --- DECODE ----------------------------------------------------------------

  void _decodeStroke(String senderId, Uint8List pt) {
    if (pt.length < 16 + 4 + 1) return;
    final strokeId =
        pt[16] | (pt[17] << 8) | (pt[18] << 16) | (pt[19] << 24);
    final nameLen = pt[20];
    if (pt.length < 21 + nameLen + 1 + 3 + 1 + 1 + 1) return;
    final name = utf8.decode(pt.sublist(21, 21 + nameLen),
        allowMalformed: true);

    int cursor = 21 + nameLen;
    final color = 0xFF000000 |
        (pt[cursor] << 16) |
        (pt[cursor + 1] << 8) |
        pt[cursor + 2];
    cursor += 3;
    final brushSize = pt[cursor].toDouble();
    cursor += 1;
    final flags = pt[cursor];
    cursor += 1;
    final pointCount = pt[cursor];
    cursor += 1;
    final expected = cursor + pointCount * 4;
    if (pt.length < expected) return;

    final points = <DrawPoint>[];
    for (int i = 0; i < pointCount; i++) {
      final off = cursor + i * 4;
      final xi = pt[off] | (pt[off + 1] << 8);
      final yi = pt[off + 2] | (pt[off + 3] << 8);
      points.add(DrawPoint(xi / 65535.0, yi / 65535.0));
    }
    _incoming.add(IncomingStroke(
      senderId: senderId,
      strokeId: strokeId,
      senderName: name,
      color: color,
      brushSize: brushSize,
      points: points,
      strokeEnd: (flags & 0x01) != 0,
    ));
  }

  void _decodeClear(String senderId, Uint8List pt) {
    if (pt.length < 16 + 4 + 1) return;
    // pt[16..19] clearId (şimdilik göz ardı, sadece dedup için faydalı olabilir)
    final nameLen = pt[20];
    if (pt.length < 21 + nameLen) return;
    final name = utf8.decode(pt.sublist(21, 21 + nameLen),
        allowMalformed: true);
    _incoming.add(IncomingClear(senderId: senderId, senderName: name));
  }

  void _decodePresence(String senderId, Uint8List pt) {
    if (pt.length < 17) return;
    final nameLen = pt[16];
    if (pt.length < 17 + nameLen + 3) return;
    final name = utf8.decode(pt.sublist(17, 17 + nameLen),
        allowMalformed: true);
    final color = 0xFF000000 |
        (pt[17 + nameLen] << 16) |
        (pt[17 + nameLen + 1] << 8) |
        pt[17 + nameLen + 2];
    _incoming.add(IncomingPresence(
      senderId: senderId,
      senderName: name,
      color: color,
    ));
  }

  // --- SEND ------------------------------------------------------------------

  Future<void> sendStrokeChunk({
    required int port,
    required String userId,
    required String name,
    required int strokeId,
    required int color,
    required double brushSize,
    required List<DrawPoint> points,
    required bool strokeEnd,
  }) async {
    if (points.isEmpty && !strokeEnd) return;
    final userIdBytes = _hexToBytes(userId);
    if (userIdBytes.length != 16) return;

    final safeName = name.length > 63 ? name.substring(0, 63) : name;
    final nameBytes = utf8.encode(safeName);
    if (nameBytes.length > 255) return;

    final pointCount = points.length.clamp(0, 50);
    final plaintext = Uint8List(
      16 + 4 + 1 + nameBytes.length + 3 + 1 + 1 + 1 + pointCount * 4,
    );

    // senderId
    plaintext.setRange(0, 16, userIdBytes);
    // strokeId (u32 LE)
    plaintext[16] = strokeId & 0xFF;
    plaintext[17] = (strokeId >> 8) & 0xFF;
    plaintext[18] = (strokeId >> 16) & 0xFF;
    plaintext[19] = (strokeId >> 24) & 0xFF;
    plaintext[20] = nameBytes.length;
    plaintext.setRange(21, 21 + nameBytes.length, nameBytes);
    int cursor = 21 + nameBytes.length;
    plaintext[cursor++] = (color >> 16) & 0xFF; // R
    plaintext[cursor++] = (color >> 8) & 0xFF; // G
    plaintext[cursor++] = color & 0xFF; // B
    plaintext[cursor++] = brushSize.round().clamp(1, 255);
    plaintext[cursor++] = strokeEnd ? 0x01 : 0x00;
    plaintext[cursor++] = pointCount;
    for (int i = 0; i < pointCount; i++) {
      final p = points[i];
      final xi = (p.x.clamp(0.0, 1.0) * 65535).round();
      final yi = (p.y.clamp(0.0, 1.0) * 65535).round();
      plaintext[cursor++] = xi & 0xFF;
      plaintext[cursor++] = (xi >> 8) & 0xFF;
      plaintext[cursor++] = yi & 0xFF;
      plaintext[cursor++] = (yi >> 8) & 0xFF;
    }

    await _sendEncrypted(type: _Hdr.typeStroke, plaintext: plaintext, port: port);
  }

  Future<void> sendClear({
    required int port,
    required String userId,
    required String name,
  }) async {
    final userIdBytes = _hexToBytes(userId);
    if (userIdBytes.length != 16) return;
    final safeName = name.length > 63 ? name.substring(0, 63) : name;
    final nameBytes = utf8.encode(safeName);
    final clearId = _rng.nextInt(0xFFFFFFFF);

    final plaintext = Uint8List(16 + 4 + 1 + nameBytes.length);
    plaintext.setRange(0, 16, userIdBytes);
    plaintext[16] = clearId & 0xFF;
    plaintext[17] = (clearId >> 8) & 0xFF;
    plaintext[18] = (clearId >> 16) & 0xFF;
    plaintext[19] = (clearId >> 24) & 0xFF;
    plaintext[20] = nameBytes.length;
    plaintext.setRange(21, 21 + nameBytes.length, nameBytes);

    await _sendEncrypted(type: _Hdr.typeClear, plaintext: plaintext, port: port);
  }

  Future<void> sendPresence({
    required int port,
    required String userId,
    required String name,
    required int color,
  }) async {
    final userIdBytes = _hexToBytes(userId);
    if (userIdBytes.length != 16) return;
    final safeName = name.length > 63 ? name.substring(0, 63) : name;
    final nameBytes = utf8.encode(safeName);

    final plaintext = Uint8List(16 + 1 + nameBytes.length + 3);
    plaintext.setRange(0, 16, userIdBytes);
    plaintext[16] = nameBytes.length;
    plaintext.setRange(17, 17 + nameBytes.length, nameBytes);
    plaintext[17 + nameBytes.length] = (color >> 16) & 0xFF;
    plaintext[17 + nameBytes.length + 1] = (color >> 8) & 0xFF;
    plaintext[17 + nameBytes.length + 2] = color & 0xFF;

    await _sendEncrypted(
      type: _Hdr.typePresence,
      plaintext: plaintext,
      port: port,
    );
  }

  Future<void> _sendEncrypted({
    required int type,
    required Uint8List plaintext,
    required int port,
  }) async {
    final s = _socket;
    final codec = _codec;
    if (s == null || codec == null) return;

    final seq = (_txSeq++) & 0xFFFF;
    final header = Uint8List(_Hdr.size);
    header[0] = _Hdr.magic[0];
    header[1] = _Hdr.magic[1];
    header[2] = _Hdr.magic[2];
    header[3] = _Hdr.magic[3];
    header[4] = _Hdr.version;
    header[5] = type;
    header[6] = seq & 0xFF;
    header[7] = (seq >> 8) & 0xFF;

    final nonce = Uint8List.fromList(
      List<int>.generate(12, (_) => _rng.nextInt(256)),
    );

    final cipher = await codec.encrypt(
      plaintext: plaintext,
      aad: header,
      nonce: nonce,
    );

    final pkt = Uint8List(_Hdr.size + 12 + cipher.length);
    pkt.setRange(0, _Hdr.size, header);
    pkt.setRange(_Hdr.size, _Hdr.size + 12, nonce);
    pkt.setRange(_Hdr.size + 12, pkt.length, cipher);

    s.send(pkt, _broadcast, port);
  }

  Future<void> dispose() async {
    await stop();
    await _incoming.close();
  }

  // --- helpers ---------------------------------------------------------------

  static String _bytesToHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Uint8List _hexToBytes(String hex) {
    if (hex.length.isOdd) return Uint8List(0);
    final out = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
