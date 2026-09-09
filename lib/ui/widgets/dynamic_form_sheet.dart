import 'package:flutter/material.dart';

import '../../services/user_data.dart';
import '../tokens.dart';

/// Maps webphone `iconMap`-style hints to Material icons for field labels.
IconData _fieldIcon(String label, String name, String type) {
  final l = label.toLowerCase();
  final n = name.toLowerCase();
  if (l.contains('name') || n.contains('name')) {
    return l.contains('last') ? Icons.badge_rounded : Icons.person_rounded;
  }
  if (l.contains('email') || l.contains('mail')) {
    return Icons.mail_rounded;
  }
  if (l.contains('phone') ||
      l.contains('mobile') ||
      l.contains('contact') ||
      n.contains('phone')) {
    return Icons.phone_rounded;
  }
  if (l.contains('address') ||
      l.contains('city') ||
      l.contains('state') ||
      l.contains('district')) {
    return Icons.location_on_rounded;
  }
  if (l.contains('pincode') || l.contains('pin') || l.contains('postal')) {
    return Icons.mail_outline_rounded;
  }
  if (l.contains('date') || n.contains('date')) {
    return Icons.calendar_today_rounded;
  }
  if (l.contains('comment') ||
      l.contains('notes') ||
      l.contains('message') ||
      l.contains('remark')) {
    return Icons.message_rounded;
  }
  if (l.contains('select') ||
      l.contains('option') ||
      n.contains('select') ||
      n.contains('type')) {
    return Icons.list_rounded;
  }
  if (l.contains('amount') ||
      l.contains('number') ||
      n.contains('number') ||
      type == 'number') {
    return Icons.tag_rounded;
  }
  if (l.contains('medical') || l.contains('health') || l.contains('symptom')) {
    return Icons.health_and_safety_rounded;
  }
  return Icons.text_snippet_rounded;
}

/// Renders the campaign's dynamic lead form (webphone `DynamicForm.jsx`) as a
/// scrollable modal sheet: sectioned fields (text/textarea/select/radio/
/// checkbox/date/number/email/phone/rating), system fields (caller number,
/// caller name, alternate number), conditional visibility, cascading select
/// options and required/format validation. Submit goes through
/// `POST /addModifyContact` via the provided `onSubmit`.
///
/// Returns `true` when the form was successfully submitted.
Future<bool> showDynamicFormSheet(
  BuildContext context, {
  required Map<String, dynamic> formConfig,
  required String callType, // 'outgoing' | 'incoming'
  required String contactNumber,
  Map<String, dynamic>? initialData,
  required Future<bool> Function(Map<String, dynamic> payload) onSubmit,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (context) => PopScope(
      canPop: false,
      child: _DynamicFormSheet(
        formConfig: formConfig,
        callType: callType,
        contactNumber: contactNumber,
        initialData: initialData,
        onSubmit: onSubmit,
      ),
    ),
  ).then((v) => v ?? false);
}

class _DynamicFormSheet extends StatefulWidget {
  const _DynamicFormSheet({
    required this.formConfig,
    required this.callType,
    required this.contactNumber,
    this.initialData,
    required this.onSubmit,
  });

  final Map<String, dynamic> formConfig;
  final String callType;
  final String contactNumber;
  final Map<String, dynamic>? initialData;
  final Future<bool> Function(Map<String, dynamic> payload) onSubmit;

  @override
  State<_DynamicFormSheet> createState() => _DynamicFormSheetState();
}

class _DynamicFormSheetState extends State<_DynamicFormSheet> {
  final Map<String, dynamic> _values = {};
  final Map<String, String> _errors = {};
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // Pre-fill form values from existing contact data (mirrors web DynamicForm.jsx)
    final d = widget.initialData;
    if (d != null) {
      for (final field in _allFields) {
        if (field is! Map) continue;
        final name = _fieldName(field);
        if (name.isEmpty) continue;
        dynamic val = d[name];
        if (val == null || val.toString().trim().isEmpty) {
          final normalizedName = name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
          for (final entry in d.entries) {
            final k = entry.key.toString().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
            if (k == normalizedName) {
              val = entry.value;
              break;
            }
          }
        }
        if (val != null && val.toString().trim().isNotEmpty) {
          _values[name] = val;
        }
      }
    }
  }

  Map<String, dynamic> get _formConfig => widget.formConfig;

  List<dynamic> get _sections {
    final sections = (_formConfig['sections'] as List?) ?? const [];
    final sorted = List<dynamic>.from(sections)
      ..sort((a, b) {
        final an = (a is Map ? a['id'] : null)?.toString();
        final bn = (b is Map ? b['id'] : null)?.toString();
        return (int.tryParse('$an') ?? 0).compareTo(int.tryParse('$bn') ?? 0);
      });
    return sorted;
  }

  List<dynamic> get _allFields => [
    for (final s in _sections)
      for (final f in ((s is Map ? s['fields'] : null) as List?) ?? const []) f,
  ];

  String _fieldName(Map field) => (field['name'] ?? '').toString();

  String _labelOf(Map field) =>
      ((field['label'] ?? field['question'] ?? field['name']) ?? '').toString();

  String _fieldType(Map field) =>
      (field['type'] ?? 'text').toString().toLowerCase();

  /// Webphone `systemField` roles: callerNumber / callerName / alternateNumber.
  String _systemRole(Map field) {
    final sf = (field['systemField'] ?? '').toString().toLowerCase();
    if (sf.isNotEmpty) return sf;
    final name = _fieldName(field).toLowerCase();
    final label = _labelOf(field).toLowerCase();
    if (name.contains('callernumber') ||
        name.contains('contactnumber') ||
        name == 'number' ||
        label.contains('caller number') ||
        label.contains('contact number')) {
      return 'callerNumber';
    }
    if (name.contains('alternatenumber') ||
        label.contains('alternate number') ||
        label.contains('alt number')) {
      return 'alternateNumber';
    }
    if (name.contains('callername') || label.contains('caller name')) {
      return 'callerName';
    }
    return '';
  }

  bool _isVisible(Map field) {
    final parent = (field['parentField'] ?? '').toString();
    if (parent.isEmpty) return true;
    final parentValue = _values[parent]?.toString() ?? '';
    if (parentValue.isEmpty) return false;
    final visibilityValues = (field['visibilityValues'] as List?) ?? const [];
    if (visibilityValues.isEmpty) return true;
    return visibilityValues
        .map((v) => v.toString().trim())
        .where((v) => v.isNotEmpty)
        .contains(parentValue.trim());
  }

  /// Filters cascading select options by `option.parentValue`, matching the
  /// webphone's `getFilteredOptions`: no parentField -> all options, empty
  /// parent value -> no options, otherwise trimmed exact match on parentValue.
  List<Map<String, dynamic>> _filteredOptions(Map field) {
    final options = (field['options'] as List?) ?? const [];
    final parent = (field['parentField'] ?? '').toString();
    if (parent.isEmpty) {
      return options
          .whereType<Map>()
          .map((o) => Map<String, dynamic>.from(o))
          .toList();
    }
    final parentValue = _values[parent]?.toString().trim() ?? '';
    if (parentValue.isEmpty) return [];
    final hasCascade = options.any(
      (o) => o is Map && (o['parentValue']?.toString().trim() ?? '').isNotEmpty,
    );
    if (!hasCascade) {
      return options
          .whereType<Map>()
          .map((o) => Map<String, dynamic>.from(o))
          .toList();
    }
    return options
        .whereType<Map>()
        .map((o) => Map<String, dynamic>.from(o))
        .where((o) {
          final pv = (o['parentValue'] ?? '').toString().trim();
          return pv == parentValue;
        })
        .toList();
  }

  String? _optionLabel(Map option) {
    final raw = (option['label'] ?? option['value'])?.toString().trim();
    return (raw != null && raw.isNotEmpty) ? raw : null;
  }

  void _setValue(String name, dynamic value) {
    setState(() {
      _values[name] = value;
      _errors.remove(name);
    });
  }

  String? _validateField(Map field, dynamic value) {
    final type = _fieldType(field);
    final label = _labelOf(field);
    if (field['required'] == true) {
      // Matches the webphone: falsy values (null, '', false, 0, empty list)
      // mean the required field was not filled.
      final missing =
          value == null ||
          value == false ||
          value == 0 ||
          (value is String && value.trim().isEmpty) ||
          (value is List && value.isEmpty);
      if (missing) return '$label is required';
    }
    if (value == null || (value is String && value.isEmpty)) return null;
    if (type == 'email') {
      if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.toString())) {
        return 'Please enter a valid email address';
      }
    }
    if (type == 'phone') {
      final v = value.toString().replaceAll(' ', '');
      if (!RegExp(r'^\+?[1-9][0-9]{0,15}$').hasMatch(v)) {
        return 'Please enter a valid mobile number';
      }
    }
    if (type == 'number') {
      final v = num.tryParse(value.toString());
      if (v == null || v < 0) return 'Please enter a valid number';
    }
    return null;
  }

  Future<void> _submit() async {
    final errors = <String, String>{};
    for (final f in _allFields) {
      if (f is! Map) continue;
      if (!_isVisible(f)) continue;
      final role = _systemRole(f);
      if (role == 'callerNumber') continue;
      final name = _fieldName(f);
      final err = _validateField(f, _values[name]);
      if (err != null) errors[name] = err;
    }
    final callerNumber =
        (widget.contactNumber.isNotEmpty
                ? widget.contactNumber
                : _values['contactNumber'])
            ?.toString()
            .trim() ??
        '';
    if (callerNumber.isEmpty) {
      errors['contactNumber'] = 'Caller number is required';
    }
    setState(() => _errors.addAll(errors));
    if (errors.isNotEmpty) return;

    final payload = _buildPayload(callerNumber);
    setState(() => _submitting = true);
    final ok = await widget.onSubmit(payload);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to save the form. Please retry.')),
      );
    }
  }

  Map<String, dynamic> _buildPayload(String callerNumber) {
    final username = UserData.username();
    final campaign = UserData.campaign();

    final contactData = <String, dynamic>{};
    final conversationFields = <String, dynamic>{};

    for (final f in _allFields) {
      if (f is! Map) continue;
      final name = _fieldName(f);
      if (name.isEmpty) continue;
      if (!_values.containsKey(name)) continue;
      final value = _values[name];
      if (value == null) continue;
      if (value is String && value.trim().isEmpty) continue;
      if (value is List && value.isEmpty) continue;

      final role = _systemRole(f);
      if (role == 'callerNumber') continue;

      final storage = (f['storageTarget'] ?? '').toString().toLowerCase();
      final isConversation = storage == 'conversation';
      (isConversation ? conversationFields : contactData)[name] = value;
    }

    final formId = (_formConfig['formId'] ?? '').toString();
    final formTitle = (_formConfig['formTitle'] ?? 'Contact Form').toString();
    final formType = (_formConfig['formType'] ?? widget.callType).toString();

    return {
      'user': username,
      'formObject': {
        'contactNumber': callerNumber,
        'agentName': username,
        'campaignId': campaign,
        'formId': formId,
        'formTitle': formTitle,
        'formType': formType,
        'callType': widget.callType,
        'entryMode': 'call',
        'callReference': '',
        ...conversationFields,
      },
      'data': {
        ...contactData,
        'isSticky': false,
        'contactNumber': callerNumber,
        'agent': username,
        'agentName': username,
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = (_formConfig['formTitle'] ?? 'Contact Form').toString();

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      height: MediaQuery.of(context).size.height * 0.92,
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SafeArea(
        child: Column(
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
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.callType == 'incoming'
                  ? 'Incoming call form'
                  : 'Outgoing call form',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  if (widget.contactNumber.isNotEmpty)
                    _systemFieldRow(
                      icon: Icons.phone_rounded,
                      label: 'Caller Number',
                      value: widget.contactNumber,
                    ),
                  for (final s in _sections) ..._buildSection(s),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('Submit Form'),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _systemFieldRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: cs.primary,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSection(dynamic section) {
    final cs = Theme.of(context).colorScheme;
    if (section is! Map) return const [];
    final title = (section['title'] ?? '').toString();
    final fields = (section['fields'] as List?) ?? const [];
    final visibleFields = [
      for (final f in fields)
        if (f is Map) f,
    ].where(_isVisible).toList();

    if (title.isEmpty && visibleFields.isEmpty) return const [];

    return [
      if (title.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
            ),
          ),
        ),
      ],
      for (final f in visibleFields) _buildField(f),
      const SizedBox(height: 6),
    ];
  }

  Widget _buildField(Map field) {
    final role = _systemRole(field);
    if (role == 'callerNumber') return const SizedBox.shrink();
    if (role == 'callerName' || role == 'alternateNumber') {
      return _buildSystemInput(field, role);
    }

    final type = _fieldType(field);
    switch (type) {
      case 'textarea':
        return _buildTextArea(field);
      case 'select':
        return _buildSelect(field);
      case 'radio':
        return _buildRadio(field);
      case 'checkbox':
      case 'multiple-options':
        return _buildCheckboxGroup(field);
      case 'single-checkbox':
        return _buildSingleCheckbox(field);
      case 'date':
        return _buildDate(field);
      case 'rating':
        return _buildRating(field);
      case 'file':
        return const SizedBox.shrink();
      default:
        return _buildTextInput(field, type);
    }
  }

  Widget _fieldLabel(String text, {IconData? icon}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: cs.primary),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorText(String? err) {
    if (err == null || err.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        err,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }

  Widget _buildSystemInput(Map field, String role) {
    final name = _fieldName(field);
    final label = _labelOf(field);
    final icon = _fieldIcon(label, name, _fieldType(field));
    final controller = TextEditingController(
      text: _values[name]?.toString() ?? '',
    );
    final hint = role == 'callerName' ? 'Caller Name' : 'Alternate Number';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel(label, icon: icon),
          TextField(
            controller: controller,
            keyboardType: role == 'callerName'
                ? TextInputType.text
                : TextInputType.phone,
            onChanged: (v) => _setValue(name, v),
            decoration: InputDecoration(
              hintText: hint,
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.md),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextInput(Map field, String type) {
    final name = _fieldName(field);
    final label = _labelOf(field);
    final cs = Theme.of(context).colorScheme;
    final err = _errors[name];
    final controller = TextEditingController(
      text: _values[name]?.toString() ?? '',
    );
    final keyboardType = switch (type) {
      'email' => TextInputType.emailAddress,
      'phone' => TextInputType.phone,
      'number' => const TextInputType.numberWithOptions(decimal: true),
      _ => TextInputType.text,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel(
            field['required'] == true ? '$label *' : label,
            icon: _fieldIcon(label, name, type),
          ),
          TextField(
            controller: controller,
            keyboardType: keyboardType,
            onChanged: (v) => _setValue(name, v),
            decoration: InputDecoration(
              hintText: label,
              filled: true,
              fillColor: cs.surfaceContainerLow,
              errorText: err,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.md),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextArea(Map field) {
    final name = _fieldName(field);
    final label = _labelOf(field);
    final cs = Theme.of(context).colorScheme;
    final err = _errors[name];
    final controller = TextEditingController(
      text: _values[name]?.toString() ?? '',
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel(
            field['required'] == true ? '$label *' : label,
            icon: Icons.message_rounded,
          ),
          TextField(
            controller: controller,
            maxLines: 4,
            onChanged: (v) => _setValue(name, v),
            decoration: InputDecoration(
              hintText: label,
              filled: true,
              fillColor: cs.surfaceContainerLow,
              errorText: err,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.md),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelect(Map field) {
    final name = _fieldName(field);
    final label = _labelOf(field);
    final cs = Theme.of(context).colorScheme;
    final options = _filteredOptions(field);
    final err = _errors[name];

    final uniqueItems = <String>[];
    final seen = <String>{};
    for (final o in options) {
      final l = _optionLabel(o);
      if (l != null && seen.add(l)) {
        uniqueItems.add(l);
      }
    }

    final rawValue = _values[name]?.toString().trim();
    String? selectedValue;
    if (rawValue != null && rawValue.isNotEmpty) {
      if (seen.contains(rawValue)) {
        selectedValue = rawValue;
      } else {
        // If current value was previously selected or prefilled from lead data
        // but is absent in filtered options, preserve it in the list to prevent
        // Flutter's DropdownButton assertion error.
        uniqueItems.insert(0, rawValue);
        seen.add(rawValue);
        selectedValue = rawValue;
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel(
            field['required'] == true ? '$label *' : label,
            icon: _fieldIcon(label, name, 'select'),
          ),
          DropdownButtonFormField<String>(
            key: ValueKey('$name-$selectedValue-${uniqueItems.length}'),
            initialValue: selectedValue,
            isExpanded: true,
            hint: Text(label),
            items: uniqueItems
                .map((v) => DropdownMenuItem<String>(value: v, child: Text(v)))
                .toList(),
            onChanged: (v) {
              if (v != null) {
                _setValue(name, v);
              }
            },
            decoration: InputDecoration(
              filled: true,
              fillColor: cs.surfaceContainerLow,
              errorText: err,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.md),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRadio(Map field) {
    final name = _fieldName(field);
    final label = _labelOf(field);
    final options = _filteredOptions(field);
    final err = _errors[name];
    final selected = _values[name]?.toString();

    final uniqueOptions = <String>[];
    final seen = <String>{};
    for (final o in options) {
      final l = _optionLabel(o);
      if (l != null && seen.add(l)) {
        uniqueOptions.add(l);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel(
            field['required'] == true ? '$label *' : label,
            icon: _fieldIcon(label, name, 'radio'),
          ),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: RadioGroup<String>(
              groupValue: selected,
              onChanged: (v) {
                if (v != null) _setValue(name, v);
              },
              child: Column(
                children: [
                  for (final v in uniqueOptions)
                    RadioListTile<String>(
                      dense: true,
                      value: v,
                      title: Text(v),
                    ),
                ],
              ),
            ),
          ),
          _errorText(err),
        ],
      ),
    );
  }

  Widget _buildCheckboxGroup(Map field) {
    final name = _fieldName(field);
    final label = _labelOf(field);
    final options = _filteredOptions(field);
    final err = _errors[name];
    final selected = (_values[name] as List?) ?? <String>[];

    final uniqueOptions = <String>[];
    final seen = <String>{};
    for (final o in options) {
      final l = _optionLabel(o);
      if (l != null && seen.add(l)) {
        uniqueOptions.add(l);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel(
            field['required'] == true ? '$label *' : label,
            icon: _fieldIcon(label, name, 'checkbox'),
          ),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: Column(
              children: [
                for (final v in uniqueOptions)
                  CheckboxListTile(
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: selected.contains(v),
                    title: Text(v),
                    onChanged: (checked) {
                      final next = List<String>.from(selected);
                      if (checked == true) {
                        if (!next.contains(v)) next.add(v);
                      } else {
                        next.remove(v);
                      }
                      _setValue(name, next);
                    },
                  ),
              ],
            ),
          ),
          _errorText(err),
        ],
      ),
    );
  }

  Widget _buildSingleCheckbox(Map field) {
    final name = _fieldName(field);
    final label = _labelOf(field);
    final checked = _values[name] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: checked,
        title: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        onChanged: (v) => _setValue(name, v == true),
      ),
    );
  }

  Widget _buildDate(Map field) {
    final name = _fieldName(field);
    final label = _labelOf(field);
    final cs = Theme.of(context).colorScheme;
    final err = _errors[name];
    final value = _values[name]?.toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel(
            field['required'] == true ? '$label *' : label,
            icon: Icons.calendar_today_rounded,
          ),
          InkWell(
            onTap: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: _parseDate(value) ?? now,
                firstDate: DateTime(2000),
                lastDate: DateTime(now.year + 5),
              );
              if (picked != null) {
                _setValue(
                  name,
                  '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}',
                );
              }
            },
            borderRadius: BorderRadius.circular(AppRadii.md),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: err != null ? Border.all(color: cs.error) : null,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.calendar_today_rounded,
                    size: 16,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    value ?? 'Select date',
                    style: TextStyle(
                      fontSize: 14,
                      color: value == null
                          ? cs.onSurface.withValues(alpha: 0.4)
                          : cs.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
          _errorText(err),
        ],
      ),
    );
  }

  DateTime? _parseDate(String? s) {
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s);
  }

  Widget _buildRating(Map field) {
    final name = _fieldName(field);
    final label = _labelOf(field);
    final err = _errors[name];
    final value = (_values[name] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel(
            field['required'] == true ? '$label *' : label,
            icon: Icons.star_rounded,
          ),
          Row(
            children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  onPressed: () => _setValue(name, i),
                  icon: Icon(
                    i <= value
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    color: i <= value
                        ? Colors.amber
                        : Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.3),
                  ),
                ),
            ],
          ),
          _errorText(err),
        ],
      ),
    );
  }
}
