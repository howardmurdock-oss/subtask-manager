/// Data models representing Bluetooth novelty hardware and connection status.
enum ToyConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
}

enum ToyCadenceMode {
  pulseOnBeat,         // Rhythmic tap on every beat (follows BPM cadence)
  continuousIntensity, // Continuous vibration speed scaled to tempo/curve
  hybrid,              // Pulses on every beat with speed proportional to BPM
}

extension ToyCadenceModeExtension on ToyCadenceMode {
  String get displayName {
    switch (this) {
      case ToyCadenceMode.pulseOnBeat:
        return 'Pulse on Beat';
      case ToyCadenceMode.continuousIntensity:
        return 'Continuous Wave';
      case ToyCadenceMode.hybrid:
        return 'Hybrid (Pulse + Intensity)';
    }
  }

  String get description {
    switch (this) {
      case ToyCadenceMode.pulseOnBeat:
        return 'Sharp physical bursts on every metronome beat';
      case ToyCadenceMode.continuousIntensity:
        return 'Motor speed rises and falls smoothly with tempo curves';
      case ToyCadenceMode.hybrid:
        return 'Rhythmic beat pulses with power scaled by current BPM';
    }
  }
}

class DiscoveredToy {
  final String id;
  final String name;
  final int rssi;

  const DiscoveredToy({
    required this.id,
    required this.name,
    required this.rssi,
  });

  bool get isLovense =>
      name.toUpperCase().startsWith('LVS') || name.toUpperCase().contains('LOVENSE');
}

class ConnectedToyInfo {
  final String id;
  final String name;
  final int batteryLevel; // -1 if unknown, 0 to 100
  final bool isLovense;

  const ConnectedToyInfo({
    required this.id,
    required this.name,
    this.batteryLevel = -1,
    this.isLovense = false,
  });

  ConnectedToyInfo copyWith({
    String? id,
    String? name,
    int? batteryLevel,
    bool? isLovense,
  }) {
    return ConnectedToyInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      isLovense: isLovense ?? this.isLovense,
    );
  }
}
