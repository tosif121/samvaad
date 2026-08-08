import 'dart:async';

import 'package:flutter/material.dart';

import '../tokens.dart';

/// Selectable disposition option tile for the fast-pick grid.
class DispositionOption extends StatelessWidget {
  const DispositionOption({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? cs.primary.withValues(alpha: 0.14)
          : cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color: selected
                  ? cs.primary.withValues(alpha: 0.6)
                  : cs.outline.withValues(alpha: 0.4),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 17,
                color: selected
                    ? cs.primary
                    : cs.onSurface.withValues(alpha: 0.3),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.body - 1,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? cs.primary : cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wraps disposition options in a fast-pick grid.
class DispositionGrid extends StatelessWidget {
  const DispositionGrid({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        mainAxisExtent: 48,
      ),
      itemCount: options.length,
      itemBuilder: (context, i) {
        final option = options[i];
        return DispositionOption(
          label: option,
          selected: option == selected,
          onTap: () => onSelect(option),
        );
      },
    );
  }
}

/// Circular auto-dispose countdown shown inside the disposition sheet.
class CountdownRing extends StatefulWidget {
  const CountdownRing({
    super.key,
    required this.seconds,
    required this.onComplete,
    this.label = 'Auto Disposed',
  });

  final int seconds;
  final VoidCallback onComplete;
  final String label;

  @override
  State<CountdownRing> createState() => _CountdownRingState();
}

class _CountdownRingState extends State<CountdownRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _timer;
  late int _remaining;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _remaining = widget.seconds;
    _controller = AnimationController(
      vsync: this,
      duration: Duration(seconds: widget.seconds),
    );
    _controller.forward();
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_remaining > 0) _remaining--;
    });
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_completed) {
        _completed = true;
        _timer?.cancel();
        widget.onComplete();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 74,
          height: 74,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 74,
                height: 74,
                child: CircularProgressIndicator(
                  value: _controller.value,
                  strokeWidth: 5,
                  strokeCap: StrokeCap.round,
                  color: cs.error.withValues(alpha: 0.7),
                  backgroundColor: cs.error.withValues(alpha: 0.12),
                ),
              ),
              Text(
                '$_remaining',
                style: TextStyle(
                  fontSize: AppType.heading,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'monospace',
                  color: cs.error,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.label,
          style: TextStyle(
            fontSize: AppType.overline,
            fontWeight: FontWeight.w700,
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }
}
