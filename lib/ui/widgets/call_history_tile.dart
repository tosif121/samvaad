import 'package:flutter/material.dart';

import '../../models/call_log_entry.dart';
import '../../services/user_data.dart';
import '../haptics.dart';
import '../tokens.dart';
import 'avatar.dart';

/// Dense, scannable call-history row with swipe-to-delete.
class CallHistoryTile extends StatelessWidget {
  const CallHistoryTile({
    super.key,
    required this.entry,
    required this.onTap,
    this.onDelete,
    this.onCallBack,
    this.count,
  });

  final CallLogEntry entry;
  final VoidCallback onTap;
  final Future<void> Function()? onDelete;
  final VoidCallback? onCallBack;

  /// Number of times this caller was missed (shown as a badge when > 1).
  final int? count;

  static String formatDuration(int seconds) {
    if (seconds <= 0) return '';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m == 0) return '${s}s';
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }

  static String timeLabel(DateTime time) {
    final hour12 = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final ampm = time.hour < 12 ? 'AM' : 'PM';
    final h = hour12.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        time.year == now.year && time.month == now.month && time.day == now.day;
    return sameDay ? '$h:$m $ampm' : '${time.day}/${time.month} $h:$m $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final displayNumber = UserData.maskNumber(entry.number);
    final (icon, color) = switch (entry.direction) {
      CallLogDirection.incoming => (Icons.call_received_rounded, cs.secondary),
      CallLogDirection.outgoing => (Icons.call_made_rounded, cs.primary),
      CallLogDirection.missed => (Icons.call_missed_rounded, cs.error),
    };
    final duration = formatDuration(entry.durationSec);
    final time = timeLabel(entry.startedAt);

    final tile = ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 2,
      ),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          AvatarBubble(
            name: displayNumber,
            size: AppSizes.avatarSm,
            iconColor: color,
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: cs.surface,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 13, color: color),
            ),
          ),
          if (count != null && count! > 1)
            Positioned(
              left: -6,
              top: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: cs.error,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: cs.onError,
                  ),
                ),
              ),
            ),
        ],
      ),
      title: Text(
        displayNumber,
        style: TextStyle(
          fontSize: AppType.body,
          fontWeight: entry.isMissed ? FontWeight.w800 : FontWeight.w600,
          color: entry.isMissed ? cs.error : cs.onSurface,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          [
            time,
            if (duration.isNotEmpty) duration,
            if (entry.type == CallLogType.video) 'Video',
          ].join('  ·  '),
          style: TextStyle(
            fontSize: AppType.caption - 1,
            color: cs.onSurface.withValues(alpha: 0.45),
          ),
        ),
      ),
      trailing: onCallBack == null
          ? null
          : IconButton(
              icon: Icon(Icons.call_rounded, color: cs.secondary, size: 22),
              tooltip: 'Call back',
              onPressed: onCallBack,
            ),
    );

    if (onDelete == null) {
      return tile;
    }

    return Dismissible(
      key: ValueKey(entry.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        Haptics.light();
        return true;
      },
      onDismissed: (_) => onDelete!(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: AppSpacing.lg),
        decoration: BoxDecoration(
          color: cs.error.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadii.lg),
        ),
        child: Icon(Icons.delete_outline_rounded, color: cs.error),
      ),
      child: tile,
    );
  }
}
