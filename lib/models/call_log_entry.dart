enum CallLogDirection { incoming, outgoing, missed }

enum CallLogType { audio, video }

class CallLogEntry {
  const CallLogEntry({
    required this.id,
    required this.number,
    required this.direction,
    this.type = CallLogType.audio,
    this.source = 'Manual',
    required this.startedAt,
    this.endedAt,
    this.durationSec = 0,
    this.bridgeId,
  });

  final String id;
  final String number;
  final CallLogDirection direction;
  final CallLogType type;
  final String source;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int durationSec;
  final String? bridgeId;

  bool get isMissed => direction == CallLogDirection.missed;

  CallLogEntry copyWith({
    CallLogDirection? direction,
    CallLogType? type,
    String? source,
    DateTime? endedAt,
    int? durationSec,
    String? bridgeId,
  }) {
    return CallLogEntry(
      id: id,
      number: number,
      direction: direction ?? this.direction,
      type: type ?? this.type,
      source: source ?? this.source,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      durationSec: durationSec ?? this.durationSec,
      bridgeId: bridgeId ?? this.bridgeId,
    );
  }

  factory CallLogEntry.fromJson(Map<String, dynamic> json) {
    return CallLogEntry(
      id: json['id'] as String,
      number: json['number'] as String,
      direction: CallLogDirection.values.byName(json['direction'] as String),
      type: CallLogType.values.byName(json['type'] as String),
      source: json['source'] as String? ?? 'Manual',
      startedAt: DateTime.parse(json['startedAt'] as String).toLocal(),
      endedAt: json['endedAt'] != null
          ? DateTime.parse(json['endedAt'] as String).toLocal()
          : null,
      durationSec: json['durationSec'] as int? ?? 0,
      bridgeId: json['bridgeId'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'number': number,
      'direction': direction.name,
      'type': type.name,
      'source': source,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'endedAt': endedAt?.toUtc().toIso8601String(),
      'durationSec': durationSec,
      'bridgeId': bridgeId,
    };
  }
}
