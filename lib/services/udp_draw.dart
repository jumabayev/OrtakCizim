import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../models/draw_object.dart';
import 'channel_codec.dart';

class _Hdr {
  static const List<int> magic = [0x42, 0x42, 0x44, 0x52]; // 'BBDR'
  // v=3 (v0.2.1+): delete/move paketleri hedef sahibini ayrı taşır; böylece
  // başkasının objesi de taşınabilir/silinebilir. v=2 ile uyumlu değildir.
  static const int version = 3;
  static const int size = 8;

  static const int typeStroke = 0;
  static const int typeClear = 1;
  static const int typePresence = 2;
  static const int typeShape = 3;
  static const int typeDelete = 4;
  static const int typeMove = 5;
}

class _StrokeFlags {
  static const int strokeEnd = 0x01;
  static const int rainbow = 0x02;
}

class _ShapeFlags {
  static const int hasFill = 0x01;
}

sealed class IncomingDrawEvent {
  final String senderId;
  const IncomingDrawEvent(this.senderId);
}

class IncomingStrokeChunk extends IncomingDrawEvent {
  final int objectId;
  final String senderName;
  final int color;
  final double brushSize;
  final List<DrawPoint> points;
  final bool strokeEnd;
  final bool rainbow;
  IncomingStrokeChunk({
    required String senderId,
    required this.objectId,
    required this.senderName,
    required this.color,
    required this.brushSize,
    required this.points,
    required this.strokeEnd,
    required this.rainbow,
  }) : super(senderId);
}

class IncomingShape extends IncomingDrawEvent {
  final int objectId;
  final String senderName;
  final ShapeKind kind;
  final int color;
  final int? fillColor;
  final double brushSize;
  final DrawPoint p1;
  final DrawPoint p2;
  IncomingShape({
    required String senderId,
    required this.objectId,
    required this.senderName,
    required this.kind,
    required this.color,
    required this.fillColor,
    required this.brushSize,
    required this.p1,
    required this.p2,
  }) : super(senderId);
}

class IncomingDelete extends IncomingDrawEvent {
  /// Silinecek objenin SAHİBİ (bu bizim userId'miz ya da başkasınınki olabilir).
  final String targetSenderId;
  final int objectId;
  IncomingDelete({
    required String senderId,
    required this.targetSenderId,
    required this.objectId,
  }) : super(senderId);
}

class IncomingMove extends IncomingDrawEvent {
  final String targetSenderId;
  final int objectId;
  final DrawPoint p1;
  final DrawPoint p2;
  IncomingMove({
    required String senderId,
    required this.targetSenderId,
    required this.objectId,
    required this.p1,
    required this.p2,
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

/// UDP broadcast + AES-GCM taşıyıcısı. Stroke, shape, clear, delete ve
/// presence paketlerini yayar ve dinler.
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
        case _Hdr.typeShape:
          _decodeShape(senderId, pt);
          break;
        case _Hdr.typeDelete:
          _decodeDelete(senderId, pt);
          break;
        case _Hdr.typeMove:
          _decodeMove(senderId, pt);
          break;
      }
    } catch (_) {
      // Bozuk paket — sessizce bırak.
    }
  }

  // --- DECODE ---------------------------------------------------------------

  void _decodeStroke(String senderId, Uint8List pt) {
    if (pt.length < 16 + 4 + 1) return;
    final objectId =
        pt[16] | (pt[17] << 8) | (pt[18] << 16) | (pt[19] << 24);
    final nameLen = pt[20];
    if (pt.length < 21 + nameLen + 1 + 3 + 1 + 1 + 1) return;
    final name = utf8.decode(pt.sublist(21, 21 + nameLen),
        allowMalformed: true);

    int c = 21 + nameLen;
    final color =
        0xFF000000 | (pt[c] << 16) | (pt[c + 1] << 8) | pt[c + 2];
    c += 3;
    final brushSize = pt[c].toDouble();
    c += 1;
    final flags = pt[c];
    c += 1;
    final pointCount = pt[c];
    c += 1;
    if (pt.length < c + pointCount * 4) return;
    final points = <DrawPoint>[];
    for (int i = 0; i < pointCount; i++) {
      final off = c + i * 4;
      final xi = pt[off] | (pt[off + 1] << 8);
      final yi = pt[off + 2] | (pt[off + 3] << 8);
      points.add(DrawPoint(xi / 65535.0, yi / 65535.0));
    }

    _incoming.add(IncomingStrokeChunk(
      senderId: senderId,
      objectId: objectId,
      senderName: name,
      color: color,
      brushSize: brushSize,
      points: points,
      strokeEnd: (flags & _StrokeFlags.strokeEnd) != 0,
      rainbow: (flags & _StrokeFlags.rainbow) != 0,
    ));
  }

  void _decodeShape(String senderId, Uint8List pt) {
    // [16..19] objectId
    // [20] nameLen
    // [21..] name
    // [+0] kind, [+1..3] stroke RGB, [+4..6] fill RGB, [+7] brushSize,
    // [+8] flags, [+9..12] p1 x/y u16 LE, [+13..16] p2 x/y u16 LE
    if (pt.length < 16 + 4 + 1) return;
    final objectId =
        pt[16] | (pt[17] << 8) | (pt[18] << 16) | (pt[19] << 24);
    final nameLen = pt[20];
    if (pt.length < 21 + nameLen + 1 + 3 + 3 + 1 + 1 + 4 + 4) return;
    final name = utf8.decode(pt.sublist(21, 21 + nameLen),
        allowMalformed: true);

    int c = 21 + nameLen;
    final kind = ShapeKind.fromByte(pt[c]);
    c += 1;
    final color =
        0xFF000000 | (pt[c] << 16) | (pt[c + 1] << 8) | pt[c + 2];
    c += 3;
    final fillRaw =
        0xFF000000 | (pt[c] << 16) | (pt[c + 1] << 8) | pt[c + 2];
    c += 3;
    final brushSize = pt[c].toDouble();
    c += 1;
    final flags = pt[c];
    c += 1;
    final p1xi = pt[c] | (pt[c + 1] << 8);
    final p1yi = pt[c + 2] | (pt[c + 3] << 8);
    c += 4;
    final p2xi = pt[c] | (pt[c + 1] << 8);
    final p2yi = pt[c + 2] | (pt[c + 3] << 8);

    _incoming.add(IncomingShape(
      senderId: senderId,
      objectId: objectId,
      senderName: name,
      kind: kind,
      color: color,
      fillColor: (flags & _ShapeFlags.hasFill) != 0 ? fillRaw : null,
      brushSize: brushSize,
      p1: DrawPoint(p1xi / 65535.0, p1yi / 65535.0),
      p2: DrawPoint(p2xi / 65535.0, p2yi / 65535.0),
    ));
  }

  void _decodeDelete(String senderId, Uint8List pt) {
    // [0..15] deleter (senderId) — zaten parametre olarak geldi
    // [16..31] target sender
    // [32..35] target objectId
    if (pt.length < 16 + 16 + 4) return;
    final targetSenderId = _bytesToHex(pt.sublist(16, 32));
    final objectId =
        pt[32] | (pt[33] << 8) | (pt[34] << 16) | (pt[35] << 24);
    _incoming.add(IncomingDelete(
      senderId: senderId,
      targetSenderId: targetSenderId,
      objectId: objectId,
    ));
  }

  void _decodeMove(String senderId, Uint8List pt) {
    // [0..15] mover, [16..31] target sender, [32..35] target objectId,
    // [36..39] p1 (x u16, y u16), [40..43] p2 (x u16, y u16)
    if (pt.length < 16 + 16 + 4 + 4 + 4) return;
    final targetSenderId = _bytesToHex(pt.sublist(16, 32));
    final objectId =
        pt[32] | (pt[33] << 8) | (pt[34] << 16) | (pt[35] << 24);
    final p1xi = pt[36] | (pt[37] << 8);
    final p1yi = pt[38] | (pt[39] << 8);
    final p2xi = pt[40] | (pt[41] << 8);
    final p2yi = pt[42] | (pt[43] << 8);
    _incoming.add(IncomingMove(
      senderId: senderId,
      targetSenderId: targetSenderId,
      objectId: objectId,
      p1: DrawPoint(p1xi / 65535.0, p1yi / 65535.0),
      p2: DrawPoint(p2xi / 65535.0, p2yi / 65535.0),
    ));
  }

  void _decodeClear(String senderId, Uint8List pt) {
    if (pt.length < 16 + 4 + 1) return;
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

  // --- SEND -----------------------------------------------------------------

  Future<void> sendStrokeChunk({
    required int port,
    required String userId,
    required String name,
    required int objectId,
    required int color,
    required double brushSize,
    required List<DrawPoint> points,
    required bool strokeEnd,
    required bool rainbow,
  }) async {
    if (points.isEmpty && !strokeEnd) return;
    final userIdBytes = _hexToBytes(userId);
    if (userIdBytes.length != 16) return;
    final safeName = name.length > 63 ? name.substring(0, 63) : name;
    final nameBytes = utf8.encode(safeName);

    final pointCount = points.length.clamp(0, 50);
    final plaintext = Uint8List(
      16 + 4 + 1 + nameBytes.length + 3 + 1 + 1 + 1 + pointCount * 4,
    );

    plaintext.setRange(0, 16, userIdBytes);
    _u32(plaintext, 16, objectId);
    plaintext[20] = nameBytes.length;
    plaintext.setRange(21, 21 + nameBytes.length, nameBytes);
    int c = 21 + nameBytes.length;
    plaintext[c++] = (color >> 16) & 0xFF;
    plaintext[c++] = (color >> 8) & 0xFF;
    plaintext[c++] = color & 0xFF;
    plaintext[c++] = brushSize.round().clamp(1, 255);
    int flags = 0;
    if (strokeEnd) flags |= _StrokeFlags.strokeEnd;
    if (rainbow) flags |= _StrokeFlags.rainbow;
    plaintext[c++] = flags;
    plaintext[c++] = pointCount;
    for (int i = 0; i < pointCount; i++) {
      final p = points[i];
      final xi = (p.x.clamp(0.0, 1.0) * 65535).round();
      final yi = (p.y.clamp(0.0, 1.0) * 65535).round();
      plaintext[c++] = xi & 0xFF;
      plaintext[c++] = (xi >> 8) & 0xFF;
      plaintext[c++] = yi & 0xFF;
      plaintext[c++] = (yi >> 8) & 0xFF;
    }
    await _sendEncrypted(
      type: _Hdr.typeStroke,
      plaintext: plaintext,
      port: port,
    );
  }

  Future<void> sendShape({
    required int port,
    required String userId,
    required String name,
    required int objectId,
    required ShapeKind kind,
    required int color,
    required int? fillColor,
    required double brushSize,
    required DrawPoint p1,
    required DrawPoint p2,
  }) async {
    final userIdBytes = _hexToBytes(userId);
    if (userIdBytes.length != 16) return;
    final safeName = name.length > 63 ? name.substring(0, 63) : name;
    final nameBytes = utf8.encode(safeName);

    final plaintext =
        Uint8List(16 + 4 + 1 + nameBytes.length + 1 + 3 + 3 + 1 + 1 + 4 + 4);

    plaintext.setRange(0, 16, userIdBytes);
    _u32(plaintext, 16, objectId);
    plaintext[20] = nameBytes.length;
    plaintext.setRange(21, 21 + nameBytes.length, nameBytes);
    int c = 21 + nameBytes.length;
    plaintext[c++] = kind.index;
    plaintext[c++] = (color >> 16) & 0xFF;
    plaintext[c++] = (color >> 8) & 0xFF;
    plaintext[c++] = color & 0xFF;
    final fill = fillColor ?? 0;
    plaintext[c++] = (fill >> 16) & 0xFF;
    plaintext[c++] = (fill >> 8) & 0xFF;
    plaintext[c++] = fill & 0xFF;
    plaintext[c++] = brushSize.round().clamp(1, 255);
    plaintext[c++] = fillColor == null ? 0 : _ShapeFlags.hasFill;
    final p1xi = (p1.x.clamp(0.0, 1.0) * 65535).round();
    final p1yi = (p1.y.clamp(0.0, 1.0) * 65535).round();
    final p2xi = (p2.x.clamp(0.0, 1.0) * 65535).round();
    final p2yi = (p2.y.clamp(0.0, 1.0) * 65535).round();
    plaintext[c++] = p1xi & 0xFF;
    plaintext[c++] = (p1xi >> 8) & 0xFF;
    plaintext[c++] = p1yi & 0xFF;
    plaintext[c++] = (p1yi >> 8) & 0xFF;
    plaintext[c++] = p2xi & 0xFF;
    plaintext[c++] = (p2xi >> 8) & 0xFF;
    plaintext[c++] = p2yi & 0xFF;
    plaintext[c++] = (p2yi >> 8) & 0xFF;

    await _sendEncrypted(type: _Hdr.typeShape, plaintext: plaintext, port: port);
  }

  Future<void> sendDelete({
    required int port,
    required String userId,
    required String targetSenderId,
    required int objectId,
  }) async {
    final userIdBytes = _hexToBytes(userId);
    final targetBytes = _hexToBytes(targetSenderId);
    if (userIdBytes.length != 16 || targetBytes.length != 16) return;
    final plaintext = Uint8List(16 + 16 + 4);
    plaintext.setRange(0, 16, userIdBytes);
    plaintext.setRange(16, 32, targetBytes);
    _u32(plaintext, 32, objectId);
    await _sendEncrypted(
      type: _Hdr.typeDelete,
      plaintext: plaintext,
      port: port,
    );
  }

  Future<void> sendMove({
    required int port,
    required String userId,
    required String targetSenderId,
    required int objectId,
    required DrawPoint p1,
    required DrawPoint p2,
  }) async {
    final userIdBytes = _hexToBytes(userId);
    final targetBytes = _hexToBytes(targetSenderId);
    if (userIdBytes.length != 16 || targetBytes.length != 16) return;
    final plaintext = Uint8List(16 + 16 + 4 + 4 + 4);
    plaintext.setRange(0, 16, userIdBytes);
    plaintext.setRange(16, 32, targetBytes);
    _u32(plaintext, 32, objectId);
    final p1xi = (p1.x.clamp(0.0, 1.0) * 65535).round();
    final p1yi = (p1.y.clamp(0.0, 1.0) * 65535).round();
    final p2xi = (p2.x.clamp(0.0, 1.0) * 65535).round();
    final p2yi = (p2.y.clamp(0.0, 1.0) * 65535).round();
    plaintext[36] = p1xi & 0xFF;
    plaintext[37] = (p1xi >> 8) & 0xFF;
    plaintext[38] = p1yi & 0xFF;
    plaintext[39] = (p1yi >> 8) & 0xFF;
    plaintext[40] = p2xi & 0xFF;
    plaintext[41] = (p2xi >> 8) & 0xFF;
    plaintext[42] = p2yi & 0xFF;
    plaintext[43] = (p2yi >> 8) & 0xFF;
    await _sendEncrypted(
      type: _Hdr.typeMove,
      plaintext: plaintext,
      port: port,
    );
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
    _u32(plaintext, 16, clearId);
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

  // --- helpers --------------------------------------------------------------

  static void _u32(Uint8List out, int offset, int v) {
    out[offset] = v & 0xFF;
    out[offset + 1] = (v >> 8) & 0xFF;
    out[offset + 2] = (v >> 16) & 0xFF;
    out[offset + 3] = (v >> 24) & 0xFF;
  }

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
