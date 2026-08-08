import 'package:flutter/material.dart';

import '../../services/user_data.dart';
import '../tokens.dart';
import 'avatar.dart';
import 'common.dart';

/// Missed-call group card: a to-do item. Tinted (error) background, bold
/// caller name, count badge, last-attempt time and one-tap call-back.
class MissedCallGroupCard extends StatelessWidget {
  const MissedCallGroupCard({
    super.key,
    required this.caller,
    required this.count,
    required this.lastAttempt,
    required this.onCallBack,
    this.callBacking = false,
  });

  final String caller;
  final int count;
  final DateTime? lastAttempt;
  final VoidCallback onCallBack;
  final bool callBacking;

  static String? parseEpochMs(dynamic value) {
    if (value == null) return null;
    try {
      final ms = int.tryParse(value.toString());
      if (ms == null) return null;
      final t = DateTime.fromMillisecondsSinceEpoch(ms);
      return formatTime(t);
    } catch (_) {
      return null;
    }
  }

  static String formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay ? '$h:$m' : '${t.day}/${t.month} $h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final displayCaller = UserData.maskNumber(caller);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: cs.error.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: cs.error.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          AvatarBubble(
            name: displayCaller,
            size: AppSizes.avatarMd,
            iconColor: cs.error,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        displayCaller,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.body + 1,
                          fontWeight: FontWeight.w800,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    if (count > 1) ...[
                      const SizedBox(width: 8),
                      BadgePill(count),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  lastAttempt != null
                      ? 'Last: ${formatTime(lastAttempt!)}'
                      : 'Waiting on the line',
                  style: TextStyle(
                    fontSize: AppType.caption - 1,
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          PressableScale(
            onTap: callBacking ? () {} : onCallBack,
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.primary,
              ),
              alignment: Alignment.center,
              child: callBacking
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: cs.onPrimary,
                      ),
                    )
                  : Icon(Icons.call_rounded, size: 22, color: cs.onPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
