import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../services/sync_service.dart';
import '../../models/sync_message.dart';

class PairingView extends StatefulWidget {
  const PairingView({super.key});

  @override
  State<PairingView> createState() => _PairingViewState();
}

class _PairingViewState extends State<PairingView> {
  ConnectionTransport _selectedTransport = ConnectionTransport.cloudRelay;
  final _codeController = TextEditingController();
  final _secretController = TextEditingController();
  final _ipController = TextEditingController();
  final _brokerController = TextEditingController();
  String _localIp = 'Fetching...';
  bool _obscureSecret = true;

  @override
  void initState() {
    super.initState();
    _fetchLocalIp();
    final sync = Provider.of<SyncService>(context, listen: false);
    _codeController.text = sync.pairingCode;
    _secretController.text = sync.pairingSecret;
    _brokerController.text = sync.customRelayHost;
  }

  Future<void> _fetchLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        setState(() {
          _localIp = interfaces.first.addresses.first.address;
        });
      } else {
        setState(() {
          _localIp = '127.0.0.1';
        });
      }
    } catch (_) {
      setState(() {
        _localIp = '127.0.0.1';
      });
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _secretController.dispose();
    _ipController.dispose();
    _brokerController.dispose();
    super.dispose();
  }

  void _copyPairingCode(String code, String password) {
    Clipboard.setData(ClipboardData(
      text: 'ORDERS APP PAIRING\nCode: $code\nPassword: $password\nRelay: Internet Cloud Link',
    ));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Pairing details copied to clipboard!'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sync = Provider.of<SyncService>(context);
    final theme = Theme.of(context);
    final isConnected = sync.status == ConnectionStatus.connected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Remote Pairing & Network Sync'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Connection Status Hero Card
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: isConnected
                    ? Colors.greenAccent.withOpacity(0.5)
                    : (sync.status == ConnectionStatus.connecting
                        ? Colors.amber.withOpacity(0.5)
                        : Colors.transparent),
                width: 1.5,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: isConnected
                            ? Colors.greenAccent.withOpacity(0.2)
                            : (sync.status == ConnectionStatus.connecting
                                ? Colors.amber.withOpacity(0.2)
                                : theme.colorScheme.surface),
                        child: Icon(
                          isConnected
                              ? Icons.public_rounded
                              : (sync.status == ConnectionStatus.connecting
                                  ? Icons.sync_rounded
                                  : Icons.public_off_rounded),
                          color: isConnected
                              ? Colors.greenAccent[400]
                              : (sync.status == ConnectionStatus.connecting
                                  ? Colors.amber
                                  : theme.colorScheme.onSurface.withOpacity(0.4)),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isConnected
                                  ? 'LINK ACTIVE • 100% E2EE ENCRYPTED'
                                  : (sync.status == ConnectionStatus.connecting
                                      ? 'ESTABLISHING SECURE CONNECTION...'
                                      : 'DISCONNECTED'),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                                color: isConnected
                                    ? Colors.greenAccent[400]
                                    : (sync.status == ConnectionStatus.connecting
                                        ? Colors.amber
                                        : theme.colorScheme.onSurface.withOpacity(0.5)),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              isConnected
                                  ? 'Connected as ${sync.role.name.toUpperCase()} (${sync.transport == ConnectionTransport.cloudRelay ? "Internet Relay" : "Direct Link"})'
                                  : sync.statusMessage,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (isConnected) ...[
                    const SizedBox(height: 14),
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: () {
                            sync.sendMessage(SyncMessage(
                              type: SyncMessageType.ping,
                              senderId: sync.deviceId,
                            ));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Ping packet sent to peer.'),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                          icon: const Icon(Icons.network_ping_rounded, size: 16),
                          label: const Text('Test Ping'),
                        ),
                        const Spacer(),
                        ElevatedButton.icon(
                          onPressed: () => sync.disconnect(),
                          icon: const Icon(Icons.link_off_rounded, size: 16),
                          label: const Text('Disconnect'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent.withOpacity(0.2),
                            foregroundColor: Colors.redAccent,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Transport Mode Selector
          Text(
            'CONNECTION TRANSPORT',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<ConnectionTransport>(
            segments: const [
              ButtonSegment(
                value: ConnectionTransport.cloudRelay,
                icon: Icon(Icons.cloud_sync_rounded),
                label: Text('Internet Relay'),
              ),
              ButtonSegment(
                value: ConnectionTransport.localWifi,
                icon: Icon(Icons.wifi_rounded),
                label: Text('Local Wi-Fi'),
              ),
              ButtonSegment(
                value: ConnectionTransport.directIp,
                icon: Icon(Icons.lan_rounded),
                label: Text('Direct IP'),
              ),
            ],
            selected: {_selectedTransport},
            onSelectionChanged: (set) {
              setState(() => _selectedTransport = set.first);
            },
          ),
          const SizedBox(height: 20),

          // 1. GLOBAL CLOUD RELAY TAB (Internet / Worldwide / Cellular)
          if (_selectedTransport == ConnectionTransport.cloudRelay) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.public_rounded, color: Colors.cyanAccent),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Global Internet Link (E2EE)',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Generate New Code',
                          icon: const Icon(Icons.refresh_rounded),
                          onPressed: () async {
                            await sync.regeneratePersonalIdentity();
                            setState(() {
                              _codeController.text = sync.pairingCode;
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Zero router setup required. Connects securely across mobile data (5G) or separate Wi-Fi networks worldwide.',
                      style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                    ),
                    const SizedBox(height: 16),

                    // Pairing Code Field (Read-Only to prevent code theft/hijacking)
                    Text(
                      'Pairing Code (Auto-Generated Unique ID)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _codeController,
                      readOnly: true,
                      style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2.0),
                      decoration: InputDecoration(
                        hintText: 'e.g. ALPHA7',
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.copy_rounded, size: 18),
                          onPressed: () => _copyPairingCode(_codeController.text.trim(), _secretController.text.trim()),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Shared Passphrase Field
                    Text(
                      'Shared Secret Passphrase (E2EE Key)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _secretController,
                      obscureText: _obscureSecret,
                      decoration: InputDecoration(
                        hintText: 'Enter shared password',
                        suffixIcon: IconButton(
                          icon: Icon(_obscureSecret ? Icons.visibility_rounded : Icons.visibility_off_rounded, size: 18),
                          onPressed: () => setState(() => _obscureSecret = !_obscureSecret),
                        ),
                      ),
                      onChanged: (val) => sync.setPairingSecret(val),
                    ),
                    const SizedBox(height: 20),

                    // Connect Buttons
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: isConnected
                                ? null
                                : () async {
                                    final code = _codeController.text.trim();
                                    final pass = _secretController.text.trim();
                                    if (code.isEmpty || pass.isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Please enter both pairing code and password.')),
                                      );
                                      return;
                                    }
                                    final ok = await sync.connectViaCloudRelay(
                                      asRole: ConnectionRole.director,
                                      code: code,
                                      password: pass,
                                    );
                                    if (ok && mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Connected via Internet Cloud Relay!')),
                                      );
                                    }
                                  },
                            icon: const Icon(Icons.lock_person_rounded, size: 16),
                            label: const Text('Connect as Director'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              backgroundColor: Colors.purpleAccent,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: isConnected
                                ? null
                                : () async {
                                    final code = _codeController.text.trim();
                                    final pass = _secretController.text.trim();
                                    if (code.isEmpty || pass.isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Please enter both pairing code and password.')),
                                      );
                                      return;
                                    }
                                    final ok = await sync.connectViaCloudRelay(
                                      asRole: ConnectionRole.player,
                                      code: code,
                                      password: pass,
                                    );
                                    if (ok && mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Connected via Internet Cloud Relay!')),
                                      );
                                    }
                                  },
                            icon: const Icon(Icons.person_rounded, size: 16),
                            label: const Text('Connect as Player'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              backgroundColor: theme.colorScheme.primary,
                              foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],

          // 2. LOCAL WI-FI TAB
          if (_selectedTransport == ConnectionTransport.localWifi) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.wifi_rounded, color: Colors.cyanAccent),
                        SizedBox(width: 10),
                        Text(
                          'Local Wi-Fi Network',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Both devices must be connected to the same Wi-Fi router.',
                      style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Your Device IP: $_localIp (Port ${sync.port})',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: sync.status == ConnectionStatus.listening
                            ? null
                            : () async {
                                final ok = await sync.startPlayerHost();
                                if (ok && mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Listening for Director on local network...')),
                                  );
                                }
                              },
                        icon: const Icon(Icons.wifi_tethering_rounded),
                        label: Text(sync.status == ConnectionStatus.listening
                            ? 'Listening for Director...'
                            : 'Host as Player'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // 3. DIRECT IP TAB
          if (_selectedTransport == ConnectionTransport.directIp) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.lan_rounded, color: Colors.purpleAccent),
                        SizedBox(width: 10),
                        Text(
                          'Direct IP / Port Forwarding / VPN',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Host IP or Dynamic DNS Domain',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _ipController,
                      decoration: const InputDecoration(
                        hintText: 'e.g. 192.168.1.50 or myhost.ddns.net',
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final host = _ipController.text.trim();
                          if (host.isEmpty) return;
                          final ok = await sync.connectAsDirector(host);
                          if (ok && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Connected directly to Host!')),
                            );
                          }
                        },
                        icon: const Icon(Icons.link_rounded),
                        label: const Text('Connect as Director'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
