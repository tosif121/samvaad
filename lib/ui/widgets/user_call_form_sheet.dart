import 'package:flutter/material.dart';

import '../../services/user_data.dart';
import '../tokens.dart';

/// Strips the Indian country prefix the same way the webphone's
/// `normalizePhone` util does (`^\+91`), falling back to the app's
/// `_stripCountryCode` behaviour for `0091` prefixed numbers.
String _normalizeContactNumber(String value) {
  var n = value.trim();
  if (n.startsWith('+91')) n = n.substring(3);
  if (n.startsWith('0091')) n = n.substring(4);
  return n;
}

/// `showUserCallFormSheet` shows the static UserCall contact form that the
/// webphone renders when campaign webforms are enabled but no dynamic form
/// resolves (no forms configured, no matching call type, or config fetch
/// failure).
///
/// All fields are optional (matching `UserCall.jsx` — no required validation),
/// the contact number is locked to the current call, and the sheet is
/// non-dismissible. Returns `true` only after a successful submit.
Future<bool> showUserCallFormSheet(
  BuildContext context, {
  required String callType,
  required String contactNumber,
  Map<String, dynamic>? initialData,
  required Future<bool> Function(Map<String, dynamic> payload) onSubmit,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (context) => PopScope(
      canPop: false,
      child: _UserCallFormSheet(
        callType: callType,
        contactNumber: _normalizeContactNumber(contactNumber),
        initialData: initialData,
        onSubmit: onSubmit,
      ),
    ),
  ).then((v) => v ?? false);
}

class _UserCallFormSheet extends StatefulWidget {
  const _UserCallFormSheet({
    required this.callType,
    required this.contactNumber,
    this.initialData,
    required this.onSubmit,
  });

  final String callType;
  final String contactNumber;
  final Map<String, dynamic>? initialData;
  final Future<bool> Function(Map<String, dynamic> payload) onSubmit;

  @override
  State<_UserCallFormSheet> createState() => _UserCallFormSheetState();
}

class _UserCallFormSheetState extends State<_UserCallFormSheet> {
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _emailId = TextEditingController();
  final _alternateNumber = TextEditingController();
  final _comment = TextEditingController();
  final _address = TextEditingController();
  final _district = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _pincode = TextEditingController();
  late final TextEditingController _contactNumber;

  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _contactNumber = TextEditingController(text: widget.contactNumber);

    // Pre-fill from existing contact data (mirrors web UserCall.jsx)
    final d = widget.initialData;
    if (d != null) {
      var first = (d['firstName'] ?? d['first_name'] ?? '').toString().trim();
      var last = (d['lastName'] ?? d['last_name'] ?? '').toString().trim();
      if (first.isEmpty && last.isEmpty && (d['Name'] ?? d['name']) != null) {
        final fullName = (d['Name'] ?? d['name']).toString().trim();
        final parts = fullName.split(' ');
        if (parts.length > 1) {
          first = parts.first;
          last = parts.sublist(1).join(' ');
        } else {
          first = fullName;
        }
      }
      _firstName.text = first;
      _lastName.text = last;
      _emailId.text =
          (d['emailId'] ?? d['Email'] ?? d['email'] ?? d['EmailId'] ?? '')
              .toString()
              .trim();
      _alternateNumber.text = _normalizeContactNumber(
          (d['alternateNumber'] ?? d['AlternateNumber'] ?? d['alternate_number'] ?? '')
              .toString());
      _comment.text =
          (d['comment'] ?? d['Remarks'] ?? d['remarks'] ?? d['comments'] ?? '')
              .toString()
              .trim();
      _address.text =
          (d['Contactaddress'] ?? d['address'] ?? d['Address'] ?? '')
              .toString()
              .trim();
      _district.text =
          (d['ContactDistrict'] ?? d['district'] ?? d['District'] ?? '')
              .toString()
              .trim();
      _city.text =
          (d['ContactCity'] ?? d['city'] ?? d['CIty'] ?? d['City'] ?? '')
              .toString()
              .trim();
      _state.text =
          (d['ContactState'] ?? d['state'] ?? d['State'] ?? '')
              .toString()
              .trim();
      _pincode.text = (d['ContactPincode'] ??
              d['postalCode'] ??
              d['Pincode '] ??
              d['pincode'] ??
              d['Pincode'] ??
              '')
          .toString()
          .trim();
    }
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _emailId.dispose();
    _alternateNumber.dispose();
    _comment.dispose();
    _address.dispose();
    _district.dispose();
    _city.dispose();
    _state.dispose();
    _pincode.dispose();
    _contactNumber.dispose();
    super.dispose();
  }

  Map<String, dynamic> _buildPayload() {
    final username = UserData.username();
    final campaign = UserData.campaign();
    final contactNumber = widget.contactNumber;
    return {
      'user': username,
      'formObject': {
        'contactNumber': contactNumber,
        'agentName': username,
        'campaignId': campaign,
        'formId': 'contact-form',
        'formTitle': 'Contact Form',
        'formType': widget.callType,
        'callType': widget.callType,
        'entryMode': 'call',
        'callReference': '',
      },
      'data': {
        'firstName': _firstName.text.trim(),
        'lastName': _lastName.text.trim(),
        'emailId': _emailId.text.trim(),
        'contactNumber': contactNumber,
        'alternateNumber': _alternateNumber.text.trim(),
        'comment': _comment.text.trim(),
        'Contactaddress': _address.text.trim(),
        'ContactDistrict': _district.text.trim(),
        'ContactCity': _city.text.trim(),
        'ContactState': _state.text.trim(),
        'ContactPincode': _pincode.text.trim(),
        'isSticky': false,
        'agent': username,
        'agentName': username,
      },
    };
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final ok = await widget.onSubmit(_buildPayload());
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

  Widget _textField({
    required TextEditingController controller,
    required String label,
    TextInputType keyboardType = TextInputType.text,
    bool multiline = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: multiline ? 3 : 1,
      style: const TextStyle(fontSize: AppType.body),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: AppType.body),
        filled: true,
        fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 40,
              height: 4,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Contact Form',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppType.title,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Save contact details for this call',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppType.body,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _textField(
                            controller: _firstName,
                            label: 'First Name',
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: _textField(
                            controller: _lastName,
                            label: 'Last Name',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _textField(
                      controller: _emailId,
                      label: 'Email ID',
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: _contactNumber,
                      enabled: false,
                      style: const TextStyle(fontSize: AppType.body),
                      decoration: InputDecoration(
                        labelText: 'Contact Number',
                        labelStyle: const TextStyle(fontSize: AppType.body),
                        filled: true,
                        fillColor: cs.surfaceContainerHighest.withValues(
                          alpha: 0.2,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: cs.outlineVariant),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: cs.outlineVariant),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _textField(
                      controller: _alternateNumber,
                      label: 'Alternate Number',
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _textField(
                      controller: _comment,
                      label: 'Comment / Remarks',
                      multiline: true,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _textField(controller: _address, label: 'Address'),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        Expanded(
                          child: _textField(
                            controller: _district,
                            label: 'District',
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: _textField(controller: _city, label: 'City'),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        Expanded(
                          child: _textField(controller: _state, label: 'State'),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: _textField(
                            controller: _pincode,
                            label: 'Pincode',
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      'Save Data',
                      style: TextStyle(
                        fontSize: AppType.body,
                        fontWeight: FontWeight.w600,
                        color: cs.onPrimary,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
