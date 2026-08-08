import 'package:flutter/material.dart';

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
  });

  final String phone;
  final DateTime? scheduledAt;
  final String? comment;
  final String? status;
  final String? callbackId;
  final VoidCallback? onCallBack;
  final bool completing;
  final bool overdue;

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
    final isDone = (status ?? '').toLowerCase().contains('complete') ||
        (status ?? '').toLowerCase().contains('done');

    if (isDone) {
      return Opacity(
        opacity: 0.45,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          leading: AvatarBubble(
            name: phone,
            size: AppSizes.avatarSm,
            iconColor: cs.onSurface.withValues(alpha: 0.4),
          ),
          title: Text(
            phone,
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

    final accentColor = overdue ? cs.error : cs.primary;

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 3,
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
      decoration: BoxDecoration(
        color: overdue
            ? cs.error.withValues(alpha: 0.06)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(
          color: overdue
              ? cs.error.withValues(alpha: 0.3)
              : cs.outline.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          AvatarBubble(
            name: phone,
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
                  phone,
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
                      overdue
                          ? Icons.warning_amber_rounded
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
                color: cs.primary,
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
