import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Kanal adından türetilen AES-256-GCM anahtar ile paketleri şifreleyen /
/// çözen sınıf. Farklı kanaldan gelen paketler tag doğrulamasında düşer.
class ChannelCodec {
  final AesGcm _aes;
  final SecretKey _key;

  ChannelCodec._(this._aes, this._key);

  static Future<ChannelCodec> fromChannel(String channel) async {
    final data = utf8.encode('$channel|OrtakCizim-v1');
    final hash = await Sha256().hash(data);
    return ChannelCodec._(AesGcm.with256bits(), SecretKey(hash.bytes));
  }

  /// cipher + 16 byte GCM tag birleşik çıktı verir.
  Future<Uint8List> encrypt({
    required List<int> plaintext,
    required List<int> aad,
    required List<int> nonce,
  }) async {
    final box = await _aes.encrypt(
      plaintext,
      secretKey: _key,
      nonce: nonce,
      aad: aad,
    );
    final out = Uint8List(box.cipherText.length + box.mac.bytes.length);
    out.setRange(0, box.cipherText.length, box.cipherText);
    out.setRange(box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  /// cipher + tag alır; yanlış kanal veya bozuk paketlerde null döner.
  Future<Uint8List?> decrypt({
    required Uint8List cipherWithTag,
    required List<int> aad,
    required List<int> nonce,
  }) async {
    if (cipherWithTag.length < 16) return null;
    final cipher = cipherWithTag.sublist(0, cipherWithTag.length - 16);
    final tag = cipherWithTag.sublist(cipherWithTag.length - 16);
    try {
      final box = SecretBox(cipher, nonce: nonce, mac: Mac(tag));
      final pt = await _aes.decrypt(box, secretKey: _key, aad: aad);
      return Uint8List.fromList(pt);
    } catch (_) {
      return null;
    }
  }
}
