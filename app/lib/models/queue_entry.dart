class QueueEntry {
  const QueueEntry({
    required this.name,
    required this.assigned,
    this.mac,
    this.slotId,
  });

  final String name;
  final bool assigned;
  final String? mac;
  final String? slotId;

  factory QueueEntry.fromJson(Map<String, dynamic> json) => QueueEntry(
        name: json['name'] as String,
        assigned: json['assigned'] as bool? ?? false,
        mac: json['mac'] as String?,
        slotId: json['slot_id'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'assigned': assigned,
        if (mac != null) 'mac': mac,
        if (slotId != null) 'slot_id': slotId,
      };
}
