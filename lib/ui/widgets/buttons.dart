import 'dart:async';

import 'package:flutter/material.dart';

import '../haptics.dart';
import '../tokens.dart';
import 'common.dart';

/// Circular call button with the accent (primary->secondary) gradient.
/// Reserved for call-action buttons (dial, accept, connect).
class GradientCallButton extends StatelessWidget {
  const GradientCallButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = AppSizes.callAction,
    this.iconSize = 30,
    this.label,
    this.processing = false,
    this.disabled = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final double iconSize;
  final String? label;
  final bool processing;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Opacity(
      opacity: disabled ? 0.45 : 1.0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PressableScale(
            onTap: disabled ? () {} : onTap,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.primary,
                boxShadow: [
                  BoxShadow(
                    color: cs.primary.withValues(alpha: 0.35),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: processing
                  ? SizedBox(
                      width: size * 0.34,
                      height: size * 0.34,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: cs.onPrimary,
                      ),
                    )
                  : Icon(icon, size: iconSize, color: cs.onPrimary),
            ),
          ),
          if (label != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              label!,
              style: TextStyle(
                fontSize: AppType.caption,
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Circular toggle control for in-call actions (Mute, Speaker, Hold, ...).
/// Fills with the primary color when active.
class CallActionButton extends StatefulWidget {
  const CallActionButton({
    super.key,
    required this.icon,
    required this.label,
    this.isActive = false,
    this.disabled = false,
    this.isOnDark = false,
    this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool isActive;
  final bool disabled;
  final bool isOnDark;
  final FutureOr<void> Function()? onPressed;

  @override
  State<CallActionButton> createState() => _CallActionButtonState();
}

class _CallActionButtonState extends State<CallActionButton> {
  bool _processing = false;

  Future<void> _handleTap() async {
    if (_processing || widget.disabled || widget.onPressed == null) return;
    Haptics.tap();
    setState(() => _processing = true);
    try {
      final result = widget.onPressed!();
      if (result is Future) await result;
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = widget.isActive;
    final disabled = widget.disabled || _processing;
    final onDark = widget.isOnDark;

    final bg = active
        ? cs.primary
        : onDark
            ? Colors.white.withValues(alpha: 0.16)
            : cs.surfaceContainerHigh;
    final fg = active
        ? cs.onPrimary
        : onDark
            ? Colors.white
            : cs.onSurface.withValues(alpha: 0.85);
    final labelColor = active
        ? cs.primary
        : onDark
            ? Colors.white.withValues(alpha: 0.75)
            : cs.onSurface.withValues(alpha: 0.6);

    return Opacity(
      opacity: disabled && !_processing ? 0.4 : 1.0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PressableScale(
            onTap: disabled ? () {} : _handleTap,
            child: AnimatedContainer(
              duration: AppMotion.normal,
              curve: AppMotion.easeOut,
              width: AppSizes.callControl,
              height: AppSizes.callControl,
              decoration: BoxDecoration(
                color: bg,
                shape: BoxShape.circle,
                border: onDark && !active
                    ? Border.all(color: Colors.white.withValues(alpha: 0.18))
                    : null,
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: cs.primary.withValues(alpha: 0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              alignment: Alignment.center,
              child: _processing
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: fg,
                      ),
                    )
                  : Icon(widget.icon, size: 24, color: fg),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            widget.label,
            style: TextStyle(
              fontSize: AppType.overline,
              fontWeight: active ? FontWeight.w800 : FontWeight.w600,
              color: labelColor,
            ),
          ),
        ],
      ),
    );
  }
}
