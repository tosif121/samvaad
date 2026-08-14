import 'package:flutter/material.dart';

import '../../services/user_data.dart';
import '../tokens.dart';
import 'common.dart';

/// Follow-up / callback task row: contact, scheduled time (relative +
/// absolute), disposition reason, overdue escalation and a call action with
/// an optimistic "completing..." state.
class FollowUpTile extends StatelessWidget {
  const FollowUpTile({
    super.key,
    required this.phone,
    required this.scheduledAt,
    this.comment,
    this.user,
    this.status,
    this.callbackId,
    this.onCallBack,
    this.onDone,
    this.completing = false,
    this.overdue = false,
    this.isAlert = false,
    this.isActive = false,
  });

  final String phone;
  final DateTime? scheduledAt;
  final String? comment;
  final String? user;
  final String? status;
  final String? callbackId;
  final VoidCallback? onCallBack;
  final VoidCallback? onDone;
  final bool completing;
  final bool overdue;
  final bool isAlert;
  final bool isActive;

  static String relativeTime(DateTime time) {
    final now = DateTime.now();
    final diff = time.difference(now);
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return 'in ${diff.inMinutes}m';
    if (diff.inHours < 24) return 'in ${diff.inHours}h';
    if (diff.inDays < 7) return 'in ${diff.inDays}d';
    return time.toString().substring(0, 10);
  }

  static String absoluteTime(DateTime time) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final ampm = time.hour >= 12 ? 'PM' : 'AM';
    var h = time.hour % 12;
    h = h == 0 ? 12 : h;
    final m = time.minute.toString().padLeft(2, '0');
    return '${time.day} ${months[time.month - 1]} ${time.year} • '
        '${h.toString().padLeft(2, '0')}:$m $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDone =
        (status ?? '').toLowerCase().contains('complete') ||
        (status ?? '').toLowerCase().contains('done');

    if (isDone) {
      return Opacity(
        opacity: 0.45,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          leading: const Icon(Icons.check_circle_rounded),
          title: Text(
            comment != null && comment!.isNotEmpty ? comment! : 'Follow-up Call',
            style: const TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            displayPhone(),
            style: TextStyle(
              fontSize: AppType.caption - 1,
              color: cs.onSurface.withValues(alpha: 0.4),
            ),
          ),
          trailing: Icon(Icons.check_circle_rounded, color: cs.secondary),
        ),
      );
    }

    final Color accentColor;
    if (isAlert) {
      accentColor = Colors.green;
    } else if (overdue) {
      accentColor = cs.error;
    } else {
      accentColor = cs.primary;
    }

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 3,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        color: isAlert
            ? Colors.green.withValues(alpha: 0.06)
            : overdue
            ? cs.error.withValues(alpha: 0.06)
            : isActive
            ? cs.primary.withValues(alpha: 0.06)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(
          color: isAlert
              ? Colors.green.withValues(alpha: 0.5)
              : overdue
              ? cs.error.withValues(alpha: 0.3)
              : isActive
              ? cs.primary.withValues(alpha: 0.4)
              : cs.outline.withValues(alpha: 0.4),
          width: isAlert ? 1.5 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comment != null && comment!.isNotEmpty
                      ? comment!
                      : 'Follow-up Call',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.body + 1,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(
                      isAlert
                          ? Icons.notifications_active_rounded
                          : overdue
                          ? Icons.warning_amber_rounded
                          : Icons.schedule_rounded,
                      size: 13,
                      color: accentColor,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        scheduledAt != null
                            ? '${relativeTime(scheduledAt!)} · ${absoluteTime(scheduledAt!)}'
                            : 'Unscheduled',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.overline,
                          fontWeight: FontWeight.w700,
                          color: accentColor,
                        ),
                      ),
                    ),
                  ],
                ),
                if (user != null && user!.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    'By: $user',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.caption - 1,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    border: Border.all(
                      color: cs.primary.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.phone_rounded,
                          size: 13, color: cs.primary),
                      const SizedBox(width: 4),
                      Text(
                        displayPhone(),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: AppType.caption - 1,
                          fontWeight: FontWeight.w600,
                          color: cs.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onDone != null) ...[
                OutlinedButton(
                  onPressed: completing ? null : onDone,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(64, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: completing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Done'),
                ),
                const SizedBox(height: 6),
              ],
              PressableScale(
                onTap: completing ? () {} : (onCallBack ?? () {}),
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isAlert ? Colors.green : accentColor,
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.call_rounded,
                      size: 20, color: cs.onPrimary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String displayPhone() => UserData.maskNumber(phone);
}
