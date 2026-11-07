import 'package:flutter/material.dart';
import '../../services/toy/toy_models.dart';
import '../../services/toy/toy_service.dart';
import 'toy_control_view.dart';
import 'toy_partner_sections.dart';

/// Modal bottom sheet allowing players and directors to scan, pair,
/// test, and configure Bluetooth novelty hardware telemetry.
class ToyManagerSheet extends StatefulWidget {
  const ToyManagerSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ToyManagerSheet(),
    );
  }

  @override
  State<ToyManagerSheet> createState() => _ToyManagerSheetState();
}

class _ToyManagerSheetState extends State<ToyManagerSheet> {
  final ToyService _toyService = ToyService.instance;

  @override
  void initState() {
    super.initState();
    _toyService.addListener(_onServiceUpdate);
  }

  @override
  void dispose() {
    _toyService.removeListener(_onServiceUpdate);
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isConnected = _toyService.isConnected;
    final isScanning = _toyService.isScanning;

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withOpacity(0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),

            // Sheet Title Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.bluetooth_audio_rounded,
                      color: theme.colorScheme.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Bluetooth Toy Control',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          isConnected
                              ? 'Synced to Metronome & Cadence Engine'
                              : 'Connect Lovense & BLE Novelty Hardware',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            const Divider(height: 24),

            // Scrollable Content
            Flexible(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                shrinkWrap: true,
                children: [
                  // Active Connection Card
                  if (isConnected) ...[
                    _buildConnectedCard(theme),
                    const SizedBox(height: 16),
                  ] else ...[
                    _buildDisconnectedCard(theme, isScanning),
                    const SizedBox(height: 16),
                  ],

                  // Discovered Devices List
                  if (!isConnected && (_toyService.discoveredToys.isNotEmpty || isScanning)) ...[
                    _buildDiscoverySection(theme, isScanning),
                    const SizedBox(height: 16),
                  ],

                  // Live control: partners' toys, and who may control yours
                  const ToyPartnerSections(),
                  const SizedBox(height: 16),

                  // Cadence & Metronome Sync Settings
                  _buildCadenceSettings(theme),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectedCard(ThemeData theme) {
    final toy = _toyService.connectedToy!;

    return Card(
      elevation: 0,
      color: theme.colorScheme.primary.withOpacity(0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  color: theme.colorScheme.primary,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        toy.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        toy.isLovense ? 'Lovense Protocol' : 'Standard BLE Device',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                if (toy.batteryLevel >= 0) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          toy.batteryLevel > 20
                              ? Icons.battery_charging_full_rounded
                              : Icons.battery_alert_rounded,
                          size: 16,
                          color: toy.batteryLevel > 20
                              ? theme.colorScheme.primary
                              : Colors.redAccent,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${toy.batteryLevel}%',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('toy-open-control'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.tune_rounded),
                label: const Text('Control your toy'),
                onPressed: () => ToyControlView.openLocal(context),
              ),
            ),
            const SizedBox(height: 10),

            // Action Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: const Icon(Icons.vibration_rounded, size: 18),
                    label: const Text('Test Pulse'),
                    onPressed: () => _toyService.testPulse(speed: _toyService.manualIntensity),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: const Icon(Icons.bluetooth_disabled_rounded, size: 18),
                    label: const Text('Disconnect'),
                    onPressed: () => _toyService.disconnect(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDisconnectedCard(ThemeData theme, bool isScanning) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceVariant.withOpacity(0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  Icons.bluetooth_searching_rounded,
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'No Toy Connected',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        isScanning
                          ? 'Searching for nearby hardware...'
                          : 'Turn on your Lovense or BLE toy to connect',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: isScanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.search_rounded),
                label: Text(isScanning ? 'Scanning...' : 'Scan for Toys'),
                onPressed: isScanning
                    ? () => _toyService.stopScan()
                    : () => _toyService.startScan(),
              ),
            ),
            if (_toyService.statusMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                _toyService.statusMessage!,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoverySection(ThemeData theme, bool isScanning) {
    final toys = _toyService.discoveredToys;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'DISCOVERED TOYS (${toys.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
                color: theme.colorScheme.primary,
              ),
            ),
            const Spacer(),
            if (isScanning)
              TextButton(
                onPressed: () => _toyService.stopScan(),
                child: const Text('Stop Scan', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        ...toys.map((toy) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: Icon(
                  toy.isLovense ? Icons.favorite_rounded : Icons.bluetooth_rounded,
                  color: toy.isLovense ? Colors.pinkAccent : theme.colorScheme.primary,
                ),
                title: Text(
                  toy.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${toy.isLovense ? "Lovense • " : ""}Signal: ${toy.rssi} dBm',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
                trailing: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Connect'),
                  onPressed: () => _toyService.connect(toy),
                ),
              ),
            )),
      ],
    );
  }

  Widget _buildCadenceSettings(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'METRONOME SYNCHRONIZATION',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.1,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          elevation: 0,
          color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...ToyCadenceMode.values.map((mode) {
                  final isSelected = _toyService.cadenceMode == mode;
                  return RadioListTile<ToyCadenceMode>(
                    value: mode,
                    groupValue: _toyService.cadenceMode,
                    contentPadding: EdgeInsets.zero,
                    activeColor: theme.colorScheme.primary,
                    title: Text(
                      mode.displayName,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      mode.description,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                    onChanged: (val) {
                      if (val != null) _toyService.setCadenceMode(val);
                    },
                  );
                }),
                const Divider(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Pulse / Base Power',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${_toyService.manualIntensity} / 20',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _toyService.manualIntensity.toDouble(),
                  min: 1,
                  max: 20,
                  divisions: 19,
                  label: '${_toyService.manualIntensity}',
                  onChanged: (val) {
                    _toyService.setManualIntensity(val.round());
                  },
                ),
                const Divider(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Timing Sync Offset',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '+${_toyService.syncOffsetMs} ms',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Delays the pulse to compensate for Bluetooth vs audio buffer latency, ensuring pulses land in exact unison with the metronome beat.',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
                Slider(
                  value: _toyService.syncOffsetMs.toDouble().clamp(0.0, 200.0),
                  min: 0,
                  max: 200,
                  divisions: 40,
                  label: '+${_toyService.syncOffsetMs} ms',
                  onChanged: (val) {
                    _toyService.setSyncOffset(val.round());
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
