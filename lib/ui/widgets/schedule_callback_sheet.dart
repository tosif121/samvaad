import 'package:flutter/material.dart';

import '../tokens.dart';

String _formatDate(DateTime d) {
  final y = d.year.toString();
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

String _formatTime(DateTime t) {
  int h = t.hour;
  final m = t.minute.toString().padLeft(2, '0');
  final ampm = h >= 12 ? 'PM' : 'AM';
  h = h % 12;
  h = h == 0 ? 12 : h;
  return '${h.toString().padLeft(2, '0')}:$m $ampm';
}

/// "Schedule Callback" modal (webphone `Callback.jsx`): follow-up date + time
/// + comment. Returns `{date: 'YYYY-MM-DD', time: 'hh:mm AM/PM', details}` or
/// null when cancelled.
Future<Map<String, dynamic>?> showScheduleCallbackSheet(
  BuildContext context, {
  String? number,
}) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => _ScheduleCallbackSheet(number: number),
  );
}

class _ScheduleCallbackSheet extends StatefulWidget {
  const _ScheduleCallbackSheet({this.number});

  final String? number;

  @override
  State<_ScheduleCallbackSheet> createState() => _ScheduleCallbackSheetState();
}

class _ScheduleCallbackSheetState extends State<_ScheduleCallbackSheet> {
  DateTime? _date;
  DateTime _time = DateTime.now();
  final _detailsController = TextEditingController();

  bool get _isToday {
    final now = DateTime.now();
    final d = _date;
    return d != null &&
        d.year == now.year &&
        d.month == now.month &&
        d.day == now.day;
  }

  @override
  void dispose() {
    _detailsController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() {
        _date = picked;
        if (_isToday && _time.isBefore(now)) _time = now;
      });
    }
  }

  Future<void> _pickTime() async {
    final now = DateTime.now();
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_time),
    );
    if (picked != null) {
      var merged = DateTime(
        _date?.year ?? now.year,
        _date?.month ?? now.month,
        _date?.day ?? now.day,
        picked.hour,
        picked.minute,
      );
      if (_isToday && merged.isBefore(now)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Follow-up time cannot be in the past'),
            ),
          );
        }
        return;
      }
      setState(() => _time = merged);
    }
  }

  void _submit() {
    final date = _date;
    if (date == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a follow-up date')),
      );
      return;
    }
    final details = _detailsController.text.trim();
    if (details.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please provide callback details')),
      );
      return;
    }
    final now = DateTime.now();
    final scheduled = DateTime(
      date.year,
      date.month,
      date.day,
      _time.hour,
      _time.minute,
    );
    if (scheduled.isBefore(now)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Follow-up date and time cannot be in the past'),
        ),
      );
      return;
    }
    Navigator.of(context).pop({
      'date': _formatDate(date),
      'time': _formatTime(_time),
      'details': details,
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Schedule Callback',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              if (widget.number != null && widget.number!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  widget.number!,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _fieldButton(
                      context,
                      icon: Icons.calendar_today_rounded,
                      label: 'Follow-up Date',
                      value: _date == null
                          ? 'Select a date'
                          : '${_date!.day} ${_monthName(_date!.month)} ${_date!.year}',
                      onTap: _pickDate,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _fieldButton(
                      context,
                      icon: Icons.access_time_rounded,
                      label: 'Follow-up Time',
                      value: _formatTime(_time),
                      onTap: _pickTime,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Comment',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _detailsController,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText:
                      'Enter callback details, customer preferences, or specific topics to discuss...',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.4),
                  ),
                  filled: true,
                  fillColor: cs.surfaceContainerLow,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('Cancel'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _submit,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('Schedule Callback'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fieldButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _monthName(int m) {
    const names = [
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
    return names[m - 1];
  }
}
