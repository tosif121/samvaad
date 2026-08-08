import 'dart:async';

import 'package:flutter/material.dart';

import '../tokens.dart';

enum SipStatus { connected, connecting, failed }

/// SIP registration chip used in both the dashboard shell and settings.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.status,
    this.label,
    this.compact = false,
  });

  final SipStatus status;
  final String? label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (color, dot) = switch (status) {
      SipStatus.connected => (cs.primary, cs.primary),
      SipStatus.connecting => (cs.tertiary, cs.tertiary),
      SipStatus.failed => (cs.error, cs.error),
    };
    final text =
        label ??
        switch (status) {
          SipStatus.connected => 'Connected',
          SipStatus.connecting => 'Connecting',
          SipStatus.failed => 'Failed',
        };

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? AppSpacing.sm : AppSpacing.md,
        vertical: compact ? 5 : 7,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: dot,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: dot.withValues(alpha: 0.6), blurRadius: 6),
              ],
            ),
          ),
          const SizedBox(width: 7),
          Text(
            text,
            style: TextStyle(
              fontSize: compact ? AppType.overline : AppType.caption,
              fontWeight: FontWeight.w800,
              color: color,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Live elapsed-time chip shown while the agent is on break.
/// Ticks every second; shows "MM:SS" in monospace tabular figures.
class BreakTimerChip extends StatefulWidget {
  const BreakTimerChip({
    super.key,
    required this.startedAt,
    required this.breakLabel,
    this.onTap,
  });

  final DateTime startedAt;
  final String breakLabel;
  final VoidCallback? onTap;

  @override
  State<BreakTimerChip> createState() => _BreakTimerChipState();
}

class _BreakTimerChipState extends State<BreakTimerChip> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _elapsed() {
    final diff = DateTime.now().difference(widget.startedAt).inSeconds;
    final m = (diff ~/ 60).toString().padLeft(2, '0');
    final s = (diff % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.tertiary.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.pill),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.free_breakfast_rounded, size: 15, color: cs.tertiary),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 96),
                child: Text(
                  widget.breakLabel,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.caption - 1,
                    fontWeight: FontWeight.w700,
                    color: cs.tertiary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                width: 1,
                height: 12,
                color: cs.tertiary.withValues(alpha: 0.3),
              ),
              const SizedBox(width: 6),
              Text(
                _elapsed(),
                style: TextStyle(
                  fontSize: AppType.caption,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'monospace',
                  color: cs.tertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small informational pill (e.g. auto-answer hint on the dialer).
class InfoChip extends StatelessWidget {
  const InfoChip({
    super.key,
    required this.icon,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = color ?? cs.primary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: c.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: c),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: AppType.overline,
              fontWeight: FontWeight.w700,
              color: c,
            ),
          ),
        ],
      ),
    );
  }
}
