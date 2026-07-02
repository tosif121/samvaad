import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DialButton extends StatefulWidget {
  final String digit;
  final VoidCallback onPressed;
  /// When true, uses a smaller 56dp size (for DTMF keypad inside active call)
  final bool compact;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final Color? letterColor;

  const DialButton({
    super.key,
    required this.digit,
    required this.onPressed,
    this.compact = false,
    this.backgroundColor,
    this.foregroundColor,
    this.letterColor,
  });

  @override
  State<DialButton> createState() => _DialButtonState();
}

class _DialButtonState extends State<DialButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 100));
    _scale = Tween<double>(begin: 1.0, end: 0.88)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String get _letters {
    switch (widget.digit) {
      case '2': return 'ABC';
      case '3': return 'DEF';
      case '4': return 'GHI';
      case '5': return 'JKL';
      case '6': return 'MNO';
      case '7': return 'PQRS';
      case '8': return 'TUV';
      case '9': return 'WXYZ';
      case '0': return '+';
      default:  return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final size   = widget.compact ? 56.0 : 72.0;
    final fs     = widget.compact ? 20.0 : 28.0;
    final subFs  = widget.compact ? 8.0  : 10.0;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bgColor = widget.backgroundColor ?? (isDark ? const Color(0xFF1C1E26) : const Color(0xFFF2F4F7));
    final fgColor = widget.foregroundColor ?? (isDark ? Colors.white : const Color(0xFF1a1a1a));
    final ltColor = widget.letterColor    ?? (isDark ? const Color(0xFF6B7280) : const Color(0xFF8B92A8));
    final borderColor = isDark ? const Color(0xFF2A2D36) : const Color(0xFFE5E8ED);

    return GestureDetector(
      onTapDown: (_) {
        HapticFeedback.lightImpact();
        _ctrl.forward();
      },
      onTapUp: (_) {
        _ctrl.reverse();
        widget.onPressed();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: bgColor,
            shape: BoxShape.circle,
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.digit,
                style: TextStyle(
                  fontSize: fs,
                  fontWeight: FontWeight.w400,
                  color: fgColor,
                  height: 1.1,
                ),
              ),
              if (_letters.isNotEmpty)
                Text(
                  _letters,
                  style: TextStyle(
                    fontSize: subFs,
                    color: ltColor,
                    letterSpacing: widget.compact ? 0.5 : 1.5,
                    fontWeight: FontWeight.w500,
                    height: 1.0,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
