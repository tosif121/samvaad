import 'package:flutter/material.dart';

class DialButton extends StatelessWidget {
  final String digit;
  final VoidCallback onPressed;

  const DialButton({super.key, required this.digit, required this.onPressed});

  String get _letters {
    switch (digit) {
      case '2':
        return 'ABC';
      case '3':
        return 'DEF';
      case '4':
        return 'GHI';
      case '5':
        return 'JKL';
      case '6':
        return 'MNO';
      case '7':
        return 'PQRS';
      case '8':
        return 'TUV';
      case '9':
        return 'WXYZ';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(32),
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.grey[200]!, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                digit,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1a1a1a),
                ),
              ),
              if (_letters.isNotEmpty)
                Text(
                  _letters,
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.grey[600],
                    letterSpacing: 1,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
