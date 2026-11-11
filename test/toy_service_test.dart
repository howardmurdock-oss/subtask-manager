import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/models/cadence_config.dart';
import 'package:orders_app/services/cadence_engine.dart';
import 'package:orders_app/services/toy/toy_models.dart';
import 'package:orders_app/services/toy/toy_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Toy Models & Enums Tests', () {
    test('ToyCadenceMode display names and descriptions are descriptive', () {
      expect(ToyCadenceMode.pulseOnBeat.displayName, 'Pulse on Beat');
      expect(ToyCadenceMode.continuousIntensity.displayName, 'Continuous Wave');
      expect(ToyCadenceMode.hybrid.displayName, 'Hybrid (Pulse + Intensity)');

      expect(ToyCadenceMode.pulseOnBeat.description.isNotEmpty, isTrue);
      expect(ToyCadenceMode.continuousIntensity.description.isNotEmpty, isTrue);
      expect(ToyCadenceMode.hybrid.description.isNotEmpty, isTrue);
    });

    test('DiscoveredToy model holds valid device identity', () {
      final toy = DiscoveredToy(
        id: 'LOVENSE-LUSH-01',
        name: 'LVS-Lush3',
        rssi: -58,
      );

      expect(toy.id, 'LOVENSE-LUSH-01');
      expect(toy.name, 'LVS-Lush3');
      expect(toy.rssi, -58);
      expect(toy.isLovense, isTrue);
    });

    test('ConnectedToyInfo copyWith and properties work correctly', () {
      final info = ConnectedToyInfo(
        id: 'BT-DEV-99',
        name: 'Lovense Max',
        isLovense: true,
        batteryLevel: 85,
      );

      expect(info.id, 'BT-DEV-99');
      expect(info.batteryLevel, 85);
      expect(info.isLovense, isTrue);

      final updated = info.copyWith(
        batteryLevel: 90,
      );

      expect(updated.batteryLevel, 90);
      expect(updated.id, 'BT-DEV-99');
      expect(updated.name, 'Lovense Max');
    });
  });

  group('ToyService Integration Tests', () {
    late ToyService service;

    setUp(() {
      service = ToyService.instance;
    });

    test('ToyService is singleton and initializes in disconnected state', () {
      expect(service, isNotNull);
      expect(ToyService.instance, same(service));
      expect(service.state, ToyConnectionState.disconnected);
      expect(service.connectedToy, isNull);
      expect(service.isConnected, isFalse);
      expect(service.isScanning, isFalse);
    });

    test('ToyCadenceMode updates cleanly', () {
      service.setCadenceMode(ToyCadenceMode.continuousIntensity);
      expect(service.cadenceMode, ToyCadenceMode.continuousIntensity);

      service.setCadenceMode(ToyCadenceMode.hybrid);
      expect(service.cadenceMode, ToyCadenceMode.hybrid);

      service.setCadenceMode(ToyCadenceMode.pulseOnBeat);
      expect(service.cadenceMode, ToyCadenceMode.pulseOnBeat);
    });

    test('Manual intensity clamping preserves valid range [1..20]', () {
      service.setManualIntensity(25);
      expect(service.manualIntensity, 20);

      service.setManualIntensity(0);
      expect(service.manualIntensity, 1);

      service.setManualIntensity(16);
      expect(service.manualIntensity, 16);
    });

    test('Sync timing offset clamping preserves valid range [0..400]', () {
      service.setSyncOffset(600);
      expect(service.syncOffsetMs, 400);

      service.setSyncOffset(-50);
      expect(service.syncOffsetMs, 0);

      service.setSyncOffset(75);
      expect(service.syncOffsetMs, 75);
    });

    test('Cadence tick is safely handled when disconnected without exceptions', () {
      const tick = CadenceTick(
        beatNumber: 1,
        currentBpm: 80,
        progress: 0.5,
        elapsedSeconds: 30,
        totalDurationSeconds: 60,
        mode: CadenceMode.fixed,
        trend: TempoTrend.steady,
      );

      // Should not throw or crash when disconnected
      expect(() => service.onCadenceTick(tick), returnsNormally);
      expect(() => service.stopVibration(), returnsNormally);
    });
  });
}
