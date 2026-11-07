import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../cadence_engine.dart';
import 'toy_models.dart';

/// Central service for native Bluetooth novelty hardware discovery, pairing,
/// telemetry, and metronome cadence synchronization.
class ToyService extends ChangeNotifier {
  static final ToyService instance = ToyService._internal();
  ToyService._internal();

  // Connection and device state
  ToyConnectionState _state = ToyConnectionState.disconnected;
  ConnectedToyInfo? _connectedToy;
  final List<DiscoveredToy> _discoveredToys = [];
  ToyCadenceMode _cadenceMode = ToyCadenceMode.pulseOnBeat;
  int _manualIntensity = 12; // 1 to 20
  String? _statusMessage;

  // Active BLE device & characteristic handles
  BluetoothDevice? _activeDevice;
  BluetoothCharacteristic? _writeCharacteristic;
  BluetoothCharacteristic? _notifyCharacteristic;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _notifySubscription;

  // Pulse & safety timers
  Timer? _delayTimer;
  Timer? _pulseTimer;
  DateTime? _lastCommandTime;
  int _lastSentSpeed = -1;
  int _syncOffsetMs = 60;

  // Getters
  ToyConnectionState get state => _state;
  bool get isConnected => _state == ToyConnectionState.connected && _connectedToy != null;
  bool get isScanning => _state == ToyConnectionState.scanning;
  ConnectedToyInfo? get connectedToy => _connectedToy;
  List<DiscoveredToy> get discoveredToys => List.unmodifiable(_discoveredToys);
  ToyCadenceMode get cadenceMode => _cadenceMode;
  int get manualIntensity => _manualIntensity;
  int get syncOffsetMs => _syncOffsetMs;
  String? get statusMessage => _statusMessage;

  /// A ceiling on every speed sent, set while a partner is in control: the
  /// owner's "partners may go up to" limit. Null when nobody else is driving.
  int? _outputCap;
  int? get outputCap => _outputCap;
  set outputCap(int? cap) {
    _outputCap = cap?.clamp(0, 20);
    // A lower ceiling applies at once, not at the next command.
    if (_outputCap != null && _lastSentSpeed > _outputCap!) {
      final ceiling = _outputCap!;
      _lastSentSpeed = -1;
      setVibrateSpeed(ceiling);
    }
  }

  /// Beat-pulse strength for a metronome started by live control, in place of
  /// the owner's own manual intensity. Null to use the manual intensity.
  int? intensityOverride;

  /// The strength cadence pulses and steady buzz scale to.
  int get effectiveIntensity => (intensityOverride ?? _manualIntensity).clamp(1, 20);

  /// The speed last sent to the toy, 0 when still.
  int get currentSpeed => _lastSentSpeed < 0 ? 0 : _lastSentSpeed;

  /// Stands a toy in as connected, for tests: no Bluetooth involved.
  @visibleForTesting
  void debugSetConnected(ConnectedToyInfo? toy) {
    _connectedToy = toy;
    _state = toy == null ? ToyConnectionState.disconnected : ToyConnectionState.connected;
    _lastSentSpeed = -1;
    notifyListeners();
  }

  /// Initializes the service and attempts to auto-reconnect to the last paired toy.
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeIndex = prefs.getInt('setting_toy_cadence_mode');
      if (modeIndex != null && modeIndex >= 0 && modeIndex < ToyCadenceMode.values.length) {
        _cadenceMode = ToyCadenceMode.values[modeIndex];
      }
      _manualIntensity = prefs.getInt('setting_toy_manual_intensity') ?? 12;
      _syncOffsetMs = prefs.getInt('setting_toy_sync_offset_ms') ?? 60;

      // Auto-reconnect if last device ID is saved
      final lastId = prefs.getString('setting_last_toy_id');
      final lastName = prefs.getString('setting_last_toy_name');
      if (lastId != null && lastName != null) {
        autoReconnect(lastId, lastName);
      }
    } catch (_) {}
  }

  void setCadenceMode(ToyCadenceMode mode) {
    _cadenceMode = mode;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt('setting_toy_cadence_mode', mode.index);
    }).catchError((_) {});
    notifyListeners();
  }

  void setManualIntensity(int speed) {
    _manualIntensity = speed.clamp(1, 20);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt('setting_toy_manual_intensity', _manualIntensity);
    }).catchError((_) {});
    if (isConnected) {
      setVibrateSpeed(_manualIntensity);
    }
    notifyListeners();
  }

  void setSyncOffset(int ms) {
    _syncOffsetMs = ms.clamp(0, 300);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt('setting_toy_sync_offset_ms', _syncOffsetMs);
    }).catchError((_) {});
    notifyListeners();
  }

  /// Begins scanning for nearby Bluetooth novelty hardware.
  Future<void> startScan() async {
    try {
      if (_state == ToyConnectionState.scanning) return;

      // Check if Bluetooth is supported on this machine/device
      if (!await FlutterBluePlus.isSupported) {
        _statusMessage = 'Bluetooth is not supported on this platform';
        notifyListeners();
        return;
      }

      _discoveredToys.clear();
      _state = ToyConnectionState.scanning;
      _statusMessage = 'Searching for nearby toys...';
      notifyListeners();

      _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        bool changed = false;
        for (final r in results) {
          final advName = r.advertisementData.advName;
          final platformName = r.device.platformName;
          final name = advName.isNotEmpty
              ? advName
              : (platformName.isNotEmpty ? platformName : '');

          if (name.isEmpty) continue;


          final id = r.device.remoteId.str;
          final existingIdx = _discoveredToys.indexWhere((t) => t.id == id);
          if (existingIdx == -1) {
            // Include known toy brands first, but also include other named peripherals
            _discoveredToys.add(DiscoveredToy(id: id, name: name, rssi: r.rssi));
            changed = true;
          } else if (_discoveredToys[existingIdx].rssi != r.rssi) {
            _discoveredToys[existingIdx] = DiscoveredToy(id: id, name: name, rssi: r.rssi);
            changed = true;
          }
        }
        if (changed) {
          // Sort: Lovense and known toys at top, then by signal strength
          _discoveredToys.sort((a, b) {
            if (a.isLovense && !b.isLovense) return -1;
            if (!a.isLovense && b.isLovense) return 1;
            return b.rssi.compareTo(a.rssi);
          });
          notifyListeners();
        }
      });

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        androidUsesFineLocation: false,
      );

      // Once scan timer naturally completes
      Future.delayed(const Duration(seconds: 15), () {
        if (_state == ToyConnectionState.scanning) {
          _state = ToyConnectionState.disconnected;
          _statusMessage = _discoveredToys.isEmpty ? 'No toys discovered' : null;
          notifyListeners();
        }
      });
    } catch (e) {
      _state = ToyConnectionState.disconnected;
      _statusMessage = 'Bluetooth scan error: $e';
      notifyListeners();
    }
  }

  /// Cancels active Bluetooth scanning.
  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
      _scanSubscription?.cancel();
      _scanSubscription = null;
      if (_state == ToyConnectionState.scanning) {
        _state = isConnected ? ToyConnectionState.connected : ToyConnectionState.disconnected;
        _statusMessage = null;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Connects to a discovered Bluetooth toy.
  Future<bool> connect(DiscoveredToy toy) async {
    await stopScan();
    _state = ToyConnectionState.connecting;
    _statusMessage = 'Connecting to ${toy.name}...';
    notifyListeners();

    try {
      final device = BluetoothDevice.fromId(toy.id);
      _activeDevice = device;

      // Listen for connection lifecycle changes
      _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen((connState) {
        if (connState == BluetoothConnectionState.disconnected) {
          _handleDisconnected();
        }
      });

      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 12),
        autoConnect: false,
      );

      // Discover GATT services and resolve Lovense / UART characteristics
      final services = await device.discoverServices();
      BluetoothCharacteristic? writeChar;
      BluetoothCharacteristic? notifyChar;

      for (final service in services) {
        for (final char in service.characteristics) {
          final uuid = char.characteristicUuid.str.toLowerCase();
          final hasWrite = char.properties.write || char.properties.writeWithoutResponse;
          final hasNotify = char.properties.notify || char.properties.indicate;

          // Lovense custom characteristic: 0000fff2... or Nordic UART TX: 6e400002...
          if (hasWrite && (uuid.contains('fff2') || uuid.contains('6e400002') || writeChar == null)) {
            // Avoid standard generic access characteristics
            if (!uuid.contains('2a00') && !uuid.contains('2a01')) {
              writeChar = char;
            }
          }

          // Lovense notification characteristic: 0000fff1... or Nordic UART RX: 6e400003...
          if (hasNotify && (uuid.contains('fff1') || uuid.contains('6e400003') || notifyChar == null)) {
            notifyChar = char;
          }
        }
      }

      if (writeChar == null) {
        _statusMessage = 'Could not find writable command channel on ${toy.name}';
        await device.disconnect();
        _state = ToyConnectionState.disconnected;
        notifyListeners();
        return false;
      }

      _writeCharacteristic = writeChar;
      _notifyCharacteristic = notifyChar;

      _connectedToy = ConnectedToyInfo(
        id: toy.id,
        name: toy.name,
        isLovense: toy.isLovense,
      );
      _state = ToyConnectionState.connected;
      _statusMessage = 'Connected to ${toy.name}';

      // Save connection for auto-reconnect
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('setting_last_toy_id', toy.id);
      await prefs.setString('setting_last_toy_name', toy.name);

      // Set up notification listener for battery query responses
      if (_notifyCharacteristic != null) {
        try {
          await _notifyCharacteristic!.setNotifyValue(true);
          _notifySubscription = _notifyCharacteristic!.lastValueStream.listen((data) {
            _handleIncomingData(data);
          });
          // Query battery level
          await queryBattery();
        } catch (_) {}
      }

      // Small confirmation pulse
      testPulse();

      notifyListeners();
      return true;
    } catch (e) {
      _state = ToyConnectionState.disconnected;
      _statusMessage = 'Failed to connect: $e';
      notifyListeners();
      return false;
    }
  }

  /// Attempts a quiet background auto-reconnect to the last known device.
  Future<void> autoReconnect(String id, String name) async {
    if (isConnected || _state == ToyConnectionState.connecting) return;
    try {
      if (!await FlutterBluePlus.isSupported) return;
      connect(DiscoveredToy(id: id, name: name, rssi: -60));
    } catch (_) {}
  }

  /// Disconnects the active Bluetooth toy and resets vibration state.
  Future<void> disconnect() async {
    try {
      await stopVibration();
      _pulseTimer?.cancel();
      _pulseTimer = null;
      _notifySubscription?.cancel();
      _connectionSubscription?.cancel();
      await _activeDevice?.disconnect();
    } catch (_) {}
    _handleDisconnected();
  }

  void _handleDisconnected() {
    _lastSentSpeed = -1;
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _writeCharacteristic = null;
    _notifyCharacteristic = null;
    _activeDevice = null;
    _connectedToy = null;
    _state = ToyConnectionState.disconnected;
    _statusMessage = 'Disconnected';
    notifyListeners();
  }

  /// Sends a raw command string to the toy over BLE.
  Future<void> sendRawCommand(String cmd) async {
    if (_writeCharacteristic == null) return;
    try {
      final bytes = utf8.encode(cmd.endsWith(';') ? cmd : '$cmd;');
      await _writeCharacteristic!.write(
        bytes,
        withoutResponse: _writeCharacteristic!.properties.writeWithoutResponse,
      );
      _lastCommandTime = DateTime.now();
    } catch (_) {}
  }

  /// Queries the current battery percentage from the toy.
  Future<void> queryBattery() async {
    if (!isConnected) return;
    // Standard Lovense battery request
    await sendRawCommand('Battery;');
  }

  /// Sets continuous vibration speed (0 to 20 for Lovense).
  Future<void> setVibrateSpeed(int speed) async {
    final clamped = speed.clamp(0, _outputCap ?? 20);
    _trailingSpeedTimer?.cancel();
    _trailingSpeedTimer = null;
    if (clamped == _lastSentSpeed) return;

    // Throttle commands: Avoid sending faster than ~20Hz to prevent BLE buffer
    // congestion. A throttled speed is sent once the gap has passed rather
    // than dropped - otherwise the last position of a dragged slider could be
    // the one that never arrives.
    final now = DateTime.now();
    final sinceLast = _lastCommandTime == null ? null : now.difference(_lastCommandTime!).inMilliseconds;
    if (sinceLast != null && sinceLast < 40 && clamped != 0) {
      _trailingSpeedTimer = Timer(Duration(milliseconds: 40 - sinceLast), () {
        _trailingSpeedTimer = null;
        setVibrateSpeed(clamped);
      });
      return;
    }

    _lastSentSpeed = clamped;
    await sendRawCommand('Vibrate:$clamped;');
  }

  Timer? _trailingSpeedTimer;

  /// Immediately shuts down all vibration motors on the connected hardware.
  Future<void> stopVibration() async {
    _trailingSpeedTimer?.cancel();
    _trailingSpeedTimer = null;
    _delayTimer?.cancel();
    _delayTimer = null;
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _lastSentSpeed = 0;
    await sendRawCommand('Vibrate:0;');
  }

  /// Fires a quick single pulse to confirm connection.
  Future<void> testPulse({int speed = 14, int durationMs = 220}) async {
    if (!isConnected) return;
    await setVibrateSpeed(speed);
    _pulseTimer?.cancel();
    _pulseTimer = Timer(Duration(milliseconds: durationMs), () {
      stopVibration();
    });
  }

  /// Called directly by [CadenceEngine] on every metronome beat.
  void onCadenceTick(CadenceTick tick) {
    if (!isConnected) return;

    if (_syncOffsetMs <= 0) {
      _dispatchCadenceTick(tick);
    } else {
      _delayTimer?.cancel();
      _delayTimer = Timer(Duration(milliseconds: _syncOffsetMs), () {
        if (isConnected) {
          _dispatchCadenceTick(tick);
        }
      });
    }
  }

  void _dispatchCadenceTick(CadenceTick tick) {
    switch (_cadenceMode) {
      case ToyCadenceMode.pulseOnBeat:
        _handleBeatPulse(tick);
        break;

      case ToyCadenceMode.continuousIntensity:
        _handleContinuousCurve(tick);
        break;

      case ToyCadenceMode.hybrid:
        _handleHybridBeat(tick);
        break;
    }
  }

  /// Rhythmic pulse: fires a short 100-140ms tap on the beat, then stops.
  void _handleBeatPulse(CadenceTick tick) {
    final speed = effectiveIntensity;
    final pulseDurationMs = (60000 / tick.currentBpm * 0.28).clamp(70, 160).round();

    setVibrateSpeed(speed);
    _pulseTimer?.cancel();
    _pulseTimer = Timer(Duration(milliseconds: pulseDurationMs), () {
      stopVibration();
    });
  }

  /// Continuous curve: motor power smoothly rises and falls with tempo curves.
  void _handleContinuousCurve(CadenceTick tick) {
    // Map current BPM (between 30 and 150) to vibration power (1 to 20)
    final normalized = ((tick.currentBpm - 30) / (150 - 30)).clamp(0.0, 1.0);
    final speed = (1 + (normalized * 19)).round().clamp(1, 20);
    setVibrateSpeed(speed);
  }

  /// Hybrid: pulses on every beat, but pulse intensity rises with BPM/curve height.
  void _handleHybridBeat(CadenceTick tick) {
    final normalized = ((tick.currentBpm - 30) / (150 - 30)).clamp(0.0, 1.0);
    final speed = (6 + (normalized * 14)).round().clamp(6, 20);
    final pulseDurationMs = (60000 / tick.currentBpm * 0.28).clamp(70, 160).round();

    setVibrateSpeed(speed);
    _pulseTimer?.cancel();
    _pulseTimer = Timer(Duration(milliseconds: pulseDurationMs), () {
      stopVibration();
    });
  }

  void _handleIncomingData(List<int> bytes) {
    try {
      final text = utf8.decode(bytes).trim();
      // Parse battery response: e.g. "85;" or integer
      final clean = text.replaceAll(';', '').trim();
      final level = int.tryParse(clean);
      if (level != null && level >= 0 && level <= 100) {
        if (_connectedToy != null) {
          _connectedToy = _connectedToy!.copyWith(batteryLevel: level);
          notifyListeners();
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
