import 'package:flutter/material.dart';

import '../../services/user_data.dart';
import '../tokens.dart';
import 'avatar.dart';
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
    this.status,
    this.callbackId,
    this.onCallBack,
    this.completing = false,
    this.overdue = false,
    this.isAlert = false,
    this.isActive = false,
  });

  final String phone;
  final DateTime? scheduledAt;
  final String? comment;
  final String? status;
  final String? callbackId;
  final VoidCallback? onCallBack;
  final bool completing;
  final bool overdue;
  final bool isAlert;
  final bool isActive;

  static String relativeTime(DateTime time) {
    final now = DateTime.now();
    final diff = time.difference(now);
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 1 && diff.inSeconds > 0) return 'now';
    if (diff.inMinutes < 60) return 'in ${diff.inMinutes}m';
    if (diff.inHours < 24) return 'in ${diff.inHours}h';
    if (diff.inDays < 7) return 'in ${diff.inDays}d';
    return time.toString().substring(0, 10);
  }

  static String absoluteTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final displayPhone = UserData.maskNumber(phone);
    final isDone =
        (status ?? '').toLowerCase().contains('complete') ||
        (status ?? '').toLowerCase().contains('done');

    if (isDone) {
      return Opacity(
        opacity: 0.45,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          leading: AvatarBubble(
            name: displayPhone,
            size: AppSizes.avatarSm,
            iconColor: cs.onSurface.withValues(alpha: 0.4),
          ),
          title: Text(
            displayPhone,
            style: const TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            'Completed',
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
    } else if (isActive) {
      accentColor = cs.primary;
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
        vertical: 10,
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
        children: [
          AvatarBubble(
            name: displayPhone,
            size: AppSizes.avatarMd,
            iconColor: accentColor,
            accent: overdue,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayPhone,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.body + 1,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                if (comment != null && comment!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    comment!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.caption - 1,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(
                      isAlert
                          ? Icons.notifications_active_rounded
                          : overdue
                          ? Icons.warning_amber_rounded
                          : isActive
                          ? Icons.call_made_rounded
                          : Icons.schedule_rounded,
                      size: 13,
                      color: accentColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      scheduledAt != null
                          ? '${relativeTime(scheduledAt!)} · ${absoluteTime(scheduledAt!)}'
                          : 'Unscheduled',
                      style: TextStyle(
                        fontSize: AppType.overline,
                        fontWeight: FontWeight.w700,
                        color: accentColor,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          PressableScale(
            onTap: completing ? () {} : (onCallBack ?? () {}),
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accentColor,
              ),
              alignment: Alignment.center,
              child: completing
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
