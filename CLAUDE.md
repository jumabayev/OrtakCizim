# CLAUDE.md

Claude Code ile OrtakCizim repo'sunda çalışırken bu dosyayı önce okuyun.

## Tek satırda

Yerel ağ üzerinde gerçek zamanlı ortak çizim tahtası. İki/daha fazla telefon aynı Wi-Fi'da, biri çizdiğinde diğerlerinde anlık görünür. Hesap yok, sunucu yok, internet yok. Aynı altyapı modeliyle BBTalk'ın çizim kuzeni.

## Esas kararlar ve neden

- **UDP broadcast (subnet `.255`) — peer IP yok** — kullanıcı el ile IP girmek zorunda olmasın; aynı kanaldaki herkes otomatik görünür. iOS multicast entitlement gerektirdiği için multicast yerine subnet broadcast.
- **AES-256-GCM per-paket, anahtar = `SHA-256("<channel>|OrtakCizim-v1")`** — kanal adı = ortak parola. Yanlış kanaldan gelen paketler GCM tag barlamasından geçemediği için sessizce düşürülür → privacy + filtreleme tek adımda.
- **AAD = paket başlığı (magic+version+type+seq)** — başlık açık gider ama değiştirilirse tag tutmaz.
- **Magic `BBDR`, port 9101** (BBTalk magic `BBTK`, port 9001 ile çakışmasın diye farklı).
- **Anahtar suffix `|OrtakCizim-v1`** — BBTalk ile aynı kanal adı kullanılsa bile türetilmiş anahtar farklı, paketler birbirini bozmaz.
- **`reusePort: true` POSIX-de denenir, başarısız olursa fallback** — bazı Android çekirdekleri `reusePort` desteklemiyor (`not supported on this platform` hatası). `_bindWithFallback` önce dener, hata alırsa `reuseAddress` ile tek başına kurar.
- **Normalize 0..1 koordinat (u16 olarak 0..65535)** — farklı ekran boyutlarında aynı çizim aynı yere düşsün.
- **Protokol breaking, uyumluluk yok** — her major sürüm version byte'ını artırır; eski clientler yeni paketi sessizce düşürür. Herkesin APK güncellemesi şart.

## Mesaj/paket akışı

```
parmak → DragUpdate → DrawPoint(x,y) normalize 0..1
   ↓
biriken nokta listesi (≤50) → 40 ms timer ya da 20 nokta birikince flush
   ↓  AES-GCM encrypt + AAD=header
   ↓  UDP → x.x.x.255:9101
── WiFi ──
   ↓  UDP :9101
   ↓  decrypt (yanlış kanal → drop)
   ↓  selfUserId filter
   ↓  IncomingDrawEvent → StreamController
   ↓
draw_screen._onIncoming → _objects map güncelle → repaintToken++
```

## Protokol sürüm geçişleri (HEPSİ BREAKING)

- **v=1 (v0.1.0)** — stroke chunk + clear + presence
- **v=2 (v0.2.0)** — + shape upsert + delete; stroke flag bit1 = rainbow
- **v=3 (v0.2.1)** — + typeMove (5); delete paketleri **target senderId** taşır (başkasının objesini de silmek için)
- **v=4 (v0.3.0)** — presence +1 byte avatarIdx; stroke flag bit2 = confetti; shape plaintext sonuna UTF-8 extra alanı (stamp emoji); + typeReaction (6) ephemeral
- **v=5 — yok henüz**

Kanal anahtarı, magic, port — sürümler arası DEĞİŞMEZ. Şifreleme aynı.

## Paket yapısı (v=4)

Header (8 byte): `B B D R | version | type | seq_lo | seq_hi`
Sonra 12 byte nonce + AES-GCM(plaintext, AAD=header).

| type | adı           | plaintext yapısı                                                                |
|-----:|:--------------|:--------------------------------------------------------------------------------|
| 0    | stroke chunk  | senderId(16) + objectId(u32) + nameLen(1) + name + RGB(3) + brushSize(u8) + flags(u8) + N(u8) + N×(x_u16, y_u16) |
| 1    | clear         | senderId(16) + clearId(u32) + nameLen(1) + name                                 |
| 2    | presence      | senderId(16) + nameLen(1) + name + RGB(3) + avatarIdx(u8)                       |
| 3    | shape         | senderId(16) + objectId + nameLen + name + kind(u8) + RGB(3) + fillRGB(3) + brushSize + flags + p1(u32) + p2(u32) + extraLen(u8) + extra |
| 4    | delete        | deleter(16) + targetSender(16) + objectId(u32)                                  |
| 5    | move          | mover(16) + targetSender(16) + objectId + p1(u32) + p2(u32)                     |
| 6    | reaction      | sender(16) + targetUser(16) + reactionIdx(u8)  — ephemeral, kaydolmaz           |

Stroke flags: bit0=strokeEnd, bit1=rainbow, bit2=confetti.
Shape flags: bit0=hasFill.
ShapeKind enum: rectangle, ellipse, line, arrow, star, heart, **stamp** (extra=emoji).

## Obje modeli

`lib/models/draw_object.dart` altında sealed `DrawObject`:
- `StrokeObject` — points listesi, rainbow + confetti bayrakları, `finished` (alıcıda strokeEnd ile set)
- `ShapeObject` — kind + p1 + p2 + extra (stamp emoji için), opsiyonel fillColor

Her objenin `objectId` (u32 random per-stroke) + `senderId` var → key = `"senderId#objectId"`. `_order` listesi z-order'ı korur, `_objects` Map lookups'ı.

## UI/Çizim mantıkları

- **Smoothing (v0.3.3)** — `strokeEnd` geldiği anda Chaikin corner-cutting bir geçiş çalıştır (`_chaikin`). Her segment 1/4 ve 3/4 pozisyonlarındaki iki yeni noktayla bölünür → ~2× nokta sayısı, jagged çizgi pürüzsüz eğriye döner. Konfeti stroke'u atlanır (emoji yoğunluğu çift olmasın).
- **Render smoothing** — tek-renk stroke'larda CanvasPainter zaten midpoint-quadratic Bezier ile düzeltir; rainbow stroke'larda her segment ayrı paint ile çizilir (HSL hue cycling).
- **Şekil çizim** — preview ShapeObject sürükleme sırasında oluşur, broadcast YOK. `_finishDrag` release'de commit edip broadcastler. ≤6×6 px tap'ler atılır (boş şekil oluşmaz).
- **Seç / taşı / boyutlandır** — `Tool.select` aktifken `_hitTestShape` reverse-z, sonra `_hitTestHandle` (4 köşe, 28px tolerance). Drag body → p1+p2 aynı delta; drag handle → bounding rect math, %2 minimum collapse koruması. `sendMove` 40 ms throttle, `_onPanEnd` final authoritative broadcast.
- **Undo** — sadece kendi obje stack'i (`_myUndoStack`); `sendDelete` `targetSenderId = userId`. Üst barda kırmızı 🗑 butonu seçili objeyi siler (kimin olursa olsun) — `targetSenderId = obj.senderId`.

## Reaction sistemi (v0.3.0+)

- `_FloatingReaction` (List, global, Map değil) — `emoji + fromName + startTimeMs + xFraction(0..1)`.
- Spawn: `_spawnReaction(fromName, idx)` — yerel reaksiyon `fromName='Sen'`, alıcıdaki `_online[senderId]?.name ?? 'Biri'`.
- Animasyon: `_reactionTicker` 40 ms periodic, 2.5 sn'den eski reaksiyonları çıkarır, biter bitmez kendini durdurur.
- Render: tuval Stack'inde `Positioned.fill` overlay (v0.3.2'den itibaren — eskiden online şeride bağlıydı, kırpılıyordu). Büyük emoji + altında siyah isim chip'i, ease-out yukarı süzülme + sallanma + soluma.
- Online şerit YOK (v0.3.2 ile kaldırıldı). Top bar'da `Icons.people_alt + sayı` chip'i → bottomSheet (`_showOnlineSheet`) → her peer satırı: avatar + ad + 5 inline reaction emojisi. Tek dokunuş hem peer'i seçer hem reaksiyonu yollar.

## Önemli paketler

- `cryptography ^2.7.0` — pure Dart AES-256-GCM
- `network_info_plus ^6.0.0` — WiFi IP + submask → subnet broadcast hesabı
- `shared_preferences` — kanal/ad/renk/avatar/userId persist
- `wakelock_plus` — çizim aktifken ekran kapanmasın
- `gal ^2.3.1` — galeriye PNG kaydet
- `share_plus ^10.1.4` — `Share.shareXFiles` (10.x API; 11+ farklı)
- `path_provider` — paylaşım için geçici PNG dosyası
- `flutter_launcher_icons ^0.14.4` — özel app ikonu (palet+fırça teması, indigo bg)

## Adaptör/test komutları

```bash
flutter pub get
flutter analyze            # ÖNCE temiz olmalı
flutter run                # cihaz ya da emulator
flutter build apk --release
```

İkon yenilenmek istenirse:
```bash
dart run flutter_launcher_icons
```

## Sürüm yayın akışı (BBTalk ile aynı)

1. `pubspec.yaml` version bump
2. commit + `git push`
3. `flutter build apk --release`
4. `cp build/app/outputs/flutter-apk/app-release.apk /tmp/ortakcizim-vX.Y.Z.apk`
5. `git tag vX.Y.Z && git push origin vX.Y.Z`
6. `gh release create vX.Y.Z <apk> --title ... --notes ...` (Türkçe notlar)
7. Python `qrcode` paketiyle yeni QR PNG üret, eski sil
8. README.md'deki tüm `vX.Y.Z` referanslarını `replace_all` ile güncelle
9. `curl -sIL` ile anonim APK indirme HTTP:200 doğrula

## Seresap/dikkat

- **Nonce reuse = ölüm** — AES-GCM için 12 byte random nonce kullanıyoruz; 30+ pkt/s rate'de bile çakışma 2^48 paketten önce yok. Yeni mesaj tipi eklerken `Random.secure()` kullanılmalı.
- **Endian** — koordinat ve seq alanları her yerde **little-endian**. setRange ile yazarken explicit byte-byte yazıyoruz; Int16List view'i kullanma çünkü alignment problem çıkar.
- **`reusePort` fallback** — yeni socket bind kodu eklerken `_bindWithFallback` kullan, doğrudan `RawDatagramSocket.bind` çağırma.
- **Hot reload & state** — UDP soketi state içinde tutuluyor; hot reload reset etmiyor. Dispose path'i bozulursa eski socket leak olur.
- **Stroke chunk birleşmesi** — alıcıda aynı `senderId#objectId` için chunk'lar `points` listesine append edilir. Smoothing **sadece** `strokeEnd=true` gelince çalışır (yarım stroke smoothing yapılmaz).
- **Konfeti smoothing'den muaf** — `_smoothStrokeIfEligible` confetti bayrağını kontrol eder; doğal sıklığı bozulmasın.
- **Self-echo filter** — `_handle` içinde `senderId == _selfUserId` ise droplanır. Reaction paketinde de geçerli; kendi reaksiyonumuzu ağdan değil, lokal `_spawnReaction('Sen', ...)` çağrısıyla görüyoruz.
- **iOS Bonjour** — `Info.plist`'te `_ortakcizim._udp` Bonjour service deklare edildi. iOS local network izni için NSLocalNetworkUsageDescription şart.
- **Android storage** — gal modern Android'de mediastore üzerinden yazıyor; `WRITE_EXTERNAL_STORAGE` sadece SDK ≤28 için manifest'te `maxSdkVersion="28"` ile.

## Stil

- Türkçe yorum + Türkçe UI metni (çocuklar için).
- `flutter analyze` "No issues found" olmadan PR yok.
- Yeni özellik = yeni protokol bumpyıne ihtiyaç var mı kontrol et. Var ise version byte'ı artır + CLAUDE.md'deki "Sürüm geçişleri" bölümünü güncelle.
- Lazım olmayan kütüphane gurnanma. Yeni paket eklerken sebebini açıkla.

## Açık olan ileri özellikler

- Boya kovası ile mevcut şekli sonradan doldur (paint bucket)
- Stroke move/resize (şu an sadece şekiller)
- Yerel çizim geçmişi (SQLite) — yeni katılana son N hamle
- BBTalk yan yana — çizim yaparken sesli konuşma
- Renk damlatıcısı (uzun basınca serbest renk)
- v=5 protokol için neyin gerekeceğine karar ver
