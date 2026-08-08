import 'package:flutter/material.dart';

import '../tokens.dart';

/// Initials/icon avatar with optional accent gradient treatment.
class AvatarBubble extends StatelessWidget {
  const AvatarBubble({
    super.key,
    this.name,
    this.icon,
    this.size = AppSizes.avatarMd,
    this.accent = false,
    this.iconColor,
  });

  /// Used to derive initials; falls back to [icon] when empty.
  final String? name;

  final IconData? icon;
  final double size;
  final bool accent;
  final Color? iconColor;

  String get _initials {
    final n = (name ?? '').trim();
    if (n.isEmpty) return '';
    final parts = n.split(RegExp(r'[\s@._+()-]+')).where((p) => p.isNotEmpty);
    if (parts.length >= 2) {
      return (parts.first[0] + parts.last[0]).toUpperCase();
    }
    return n.length >= 2 ? n.substring(0, 2).toUpperCase() : n.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final initialText = _initials;
    final hasInitials = initialText.isNotEmpty;

    final fg = accent ? cs.onPrimary : (iconColor ?? cs.primary);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: accent ? cs.primary : cs.primary.withValues(alpha: 0.1),
      ),
      alignment: Alignment.center,
      child: hasInitials
          ? Text(
              initialText,
              style: TextStyle(
                fontSize: size * 0.34,
                fontWeight: FontWeight.w800,
                color: fg,
                letterSpacing: 0.5,
              ),
            )
          : Icon(
              icon ?? Icons.person_rounded,
              size: size * 0.46,
              color: fg,
            ),
    );
  }
}
