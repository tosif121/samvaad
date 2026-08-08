import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/call_log_entry.dart';

/// Persists recent-call history (like the webphone) locally and exposes the
/// entries plus an "unseen missed" counter for the Recent tab badge.
class CallLogService {
  CallLogService._();

  static final CallLogService _instance = CallLogService._();

  factory CallLogService() => _instance;

  static CallLogService get instance => _instance;

  static const String _storageKey = 'call_log_entries_v1';
  static const String _missedSeenKey = 'call_log_missed_seen_at_v1';
  static const int maxEntries = 200;

  final ValueNotifier<List<CallLogEntry>> entries = ValueNotifier(
    const <CallLogEntry>[],
  );
  final ValueNotifier<int> unseenMissed = ValueNotifier(0);

  bool _loaded = false;
  DateTime _missedSeenAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final seenRaw = prefs.getString(_missedSeenKey);
      if (seenRaw != null) {
        _missedSeenAt = DateTime.parse(seenRaw);
      }
      final raw = prefs.getString(_storageKey);
      if (raw != null) {
        final decoded = jsonDecode(raw) as List;
        final list = decoded
            .map((e) => CallLogEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        entries.value = list;
      }
    } catch (e) {
      debugPrint('CallLogService.load error: $e');
    }
    _loaded = true;
    _recomputeUnseen();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _storageKey,
        jsonEncode(entries.value.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('CallLogService.persist error: $e');
    }
  }

  void _recomputeUnseen() {
    unseenMissed.value = entries.value
        .where((e) => e.isMissed && e.startedAt.isAfter(_missedSeenAt))
        .length;
  }

  Future<void> upsert(CallLogEntry entry) async {
    final list = List<CallLogEntry>.from(entries.value);
    final idx = list.indexWhere((e) => e.id == entry.id);
    if (idx >= 0) {
      list[idx] = entry;
    } else {
      list.insert(0, entry);
      if (list.length > maxEntries) {
        list.removeRange(maxEntries, list.length);
      }
    }
    entries.value = list;
    _recomputeUnseen();
    await _persist();
  }

  Future<void> remove(String id) async {
    entries.value = entries.value.where((e) => e.id != id).toList();
    _recomputeUnseen();
    await _persist();
  }

  Future<void> clear() async {
    entries.value = const <CallLogEntry>[];
    _recomputeUnseen();
    await _persist();
  }

  Future<void> markMissedSeen() async {
    _missedSeenAt = DateTime.now();
    _recomputeUnseen();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _missedSeenKey,
        _missedSeenAt.toUtc().toIso8601String(),
      );
    } catch (e) {
      debugPrint('CallLogService.markMissedSeen error: $e');
    }
  }
}
