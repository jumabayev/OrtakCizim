import 'dart:math';

/// Her kullanıcı kendine bir avatar + renk seçer. Online çubuğunda ve
/// reaksiyonlarda bu emoji gözükür.
class Avatar {
  final String emoji;
  final int color; // ARGB
  const Avatar({required this.emoji, required this.color});
}

class Avatars {
  static const list = <Avatar>[
    Avatar(emoji: '🦸', color: 0xFFE53935),
    Avatar(emoji: '🦹', color: 0xFF8E24AA),
    Avatar(emoji: '🥷', color: 0xFF37474F),
    Avatar(emoji: '🧙', color: 0xFF3949AB),
    Avatar(emoji: '🧝', color: 0xFF00897B),
    Avatar(emoji: '🤖', color: 0xFF607D8B),
    Avatar(emoji: '👽', color: 0xFF43A047),
    Avatar(emoji: '👾', color: 0xFF7CB342),
    Avatar(emoji: '🦊', color: 0xFFF57C00),
    Avatar(emoji: '🐯', color: 0xFFFBC02D),
    Avatar(emoji: '🦁', color: 0xFFFFB300),
    Avatar(emoji: '🐻', color: 0xFF6D4C41),
    Avatar(emoji: '🐼', color: 0xFF455A64),
    Avatar(emoji: '🐸', color: 0xFF558B2F),
    Avatar(emoji: '🐵', color: 0xFF8D6E63),
    Avatar(emoji: '🦖', color: 0xFF2E7D32),
    Avatar(emoji: '🐉', color: 0xFFB71C1C),
    Avatar(emoji: '🦄', color: 0xFFEC407A),
    Avatar(emoji: '⚡', color: 0xFFFDD835),
    Avatar(emoji: '🔥', color: 0xFFFF6F00),
    Avatar(emoji: '🚀', color: 0xFF5E35B1),
    Avatar(emoji: '👻', color: 0xFF9E9E9E),
    Avatar(emoji: '🎃', color: 0xFFFB8C00),
    Avatar(emoji: '❄️', color: 0xFF039BE5),
  ];

  static Avatar get(int idx) => list[idx.abs() % list.length];
  static int random() => Random().nextInt(list.length);
}

/// Canvas'a basılan damgalar (stamp tool).
class Stamps {
  static const list = <String>[
    '⭐', '❤️', '🌈', '🌸', '🌟', '🦕', '🐶', '🐱',
    '🐸', '🦋', '🐠', '🦄', '🚀', '🎈', '🎨', '🎁',
    '🍎', '🍕', '🏀', '⚽',
  ];
  static const int defaultIdx = 0;
}

/// Ressamların birbirine göndereceği reaksiyon emojileri.
class Reactions {
  static const list = <String>['❤️', '⭐', '👏', '🎉', '🔥'];
  static int get count => list.length;
}
