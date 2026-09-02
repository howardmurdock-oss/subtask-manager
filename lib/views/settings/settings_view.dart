import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../core/theme/theme_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/security/security_service.dart';
import '../../core/sound/sound_service.dart';
import '../../core/sound/sound_generator.dart';
import '../../models/order_item.dart';
import '../../services/order_engine.dart';
import '../../services/sync_service.dart';
import '../../services/background_link_service.dart';
import '../../core/notifications/notification_service.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  AlarmSoundPreset _selectedSound = SoundService.currentPreset;
  bool _useCustomSound = SoundService.useCustomSound;
  String? _customSoundName = SoundService.customSoundName;
  bool _audioAlertsEnabled = SoundService.audioAlertsEnabled;
  bool _obscureMySecret = true;
  bool _isBatterySaver = BackgroundLinkService.isBatterySaver;

  @override
  void initState() {
    super.initState();
    _refreshSoundState();
    _isBatterySaver = BackgroundLinkService.isBatterySaver;
  }

  void _refreshSoundState() {
    setState(() {
      _selectedSound = SoundService.currentPreset;
      _useCustomSound = SoundService.useCustomSound;
      _customSoundName = SoundService.customSoundName;
      _audioAlertsEnabled = SoundService.audioAlertsEnabled;
    });
  }

  Future<void> _pickAndSetCustomSound() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'wav', 'm4a', 'ogg', 'flac', 'aac'],
        allowMultiple: false,
      );

      if (result != null && result.isNotEmpty && result.single.path != null) {
        final originalFile = File(result.single.path!);
        final ext = p.extension(originalFile.path);
        final fileName = result.single.name;

        // Save persistently into app documents directory
        final appDir = await getApplicationDocumentsDirectory();
        final soundDir = Directory(p.join(appDir.path, 'custom_sounds'));
        if (!soundDir.existsSync()) {
          soundDir.createSync(recursive: true);
        }

        final targetPath = p.join(soundDir.path, 'alarm_sound$ext');
        await originalFile.copy(targetPath);

        await SoundService.setCustomSound(targetPath, fileName);
        _refreshSoundState();

        // Immediate audio preview confirmation
        await SoundService.playCustomSound(targetPath);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Custom alarm sound "$fileName" loaded & activated!'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not load sound file: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _showPinSetupDialog(BuildContext context) {
    final security = Provider.of<SecurityService>(context, listen: false);
    final pinController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Configure Security PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter a 4-8 digit numeric PIN. Leaving this blank disables PIN protection.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pinController,
                keyboardType: TextInputType.number,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Security PIN',
                  hintText: 'e.g. 1234',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                security.setPin(pinController.text.trim());
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      pinController.text.trim().isEmpty
                          ? 'PIN lock disabled'
                          : 'PIN lock enabled successfully',
                    ),
                  ),
                );
              },
              child: const Text('Save PIN'),
            ),
          ],
        );
      },
    );
  }

  void _showEditNicknameDialog(BuildContext context, SyncService sync) {
    final nameCtrl = TextEditingController(text: sync.nickname);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Your Display Nickname'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This nickname will auto-populate on your partners\' devices when you connect. Partners can also edit or customize your nickname on their end.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Your Nickname / Alias',
                hintText: 'e.g. Master Jack / Dan / Kitten',
                prefixIcon: Icon(Icons.badge_rounded, size: 20),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              sync.setNickname(nameCtrl.text.trim());
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(nameCtrl.text.trim().isNotEmpty
                      ? 'Nickname updated to "${nameCtrl.text.trim()}"'
                      : 'Nickname cleared (will use default role)'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            child: const Text('Save Nickname'),
          ),
        ],
      ),
    );
  }

  void _showEditPasswordDialog(BuildContext context, SyncService sync) {
    final nameCtrl = TextEditingController(text: sync.nickname);
    final secretCtrl = TextEditingController(text: sync.pairingSecret);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Password & Nickname'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Customize your personal nickname and E2EE encryption password.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Personal Nickname / Alias',
                hintText: 'e.g. Master Jack / Dan / Kitten',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: secretCtrl,
              decoration: const InputDecoration(
                labelText: 'E2EE Passphrase / Password (AES-256)',
                hintText: 'Custom encryption password',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newName = nameCtrl.text.trim();
              final newSecret = secretCtrl.text.trim();
              if (newSecret.isNotEmpty || newName.isNotEmpty) {
                await sync.updatePersonalIdentity(
                  newSecret: newSecret.isNotEmpty ? newSecret : null,
                  newNickname: newName.isNotEmpty ? newName : null,
                );
              }
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Updated password & synced with contacts!'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            child: const Text('Save Changes'),
          ),
        ],
      ),
    );
  }

  Widget _buildPersonalIdentitySection(BuildContext context, SyncService sync, ThemeData theme) {
    final code = sync.pairingCode;
    final secret = sync.pairingSecret;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'MY PERSONAL PAIRING IDENTITY',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
                      child: Icon(Icons.fingerprint_rounded, color: theme.colorScheme.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Personal Pairing Identity & Profile',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          Text(
                            'Share your code with partners so they can connect with you.',
                            style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                // Display Nickname Row
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'MY DISPLAY NICKNAME',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                              color: theme.colorScheme.onSurface.withOpacity(0.6),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            sync.nickname.isNotEmpty ? sync.nickname : 'Not set (auto-defaults to role)',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: sync.nickname.isNotEmpty ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.6),
                              fontStyle: sync.nickname.isNotEmpty ? FontStyle.normal : FontStyle.italic,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Auto-populates as your name when sending pairing requests or messages.',
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurface.withOpacity(0.55),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Edit Nickname',
                      icon: const Icon(Icons.edit_rounded, size: 18),
                      onPressed: () => _showEditNicknameDialog(context, sync),
                    ),
                  ],
                ),
                const Divider(height: 20),
                // Pairing Code Row
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'YOUR PAIRING CODE',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                              color: theme.colorScheme.onSurface.withOpacity(0.6),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            code,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2.0,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Copy Code',
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: code));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Copied pairing code "$code" to clipboard')),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // E2EE Passphrase Row
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'E2EE ENCRYPTION PASSPHRASE',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                              color: theme.colorScheme.onSurface.withOpacity(0.6),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _obscureMySecret ? '••••••••••••' : secret,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: _obscureMySecret ? 'Reveal Passphrase' : 'Hide Passphrase',
                      icon: Icon(_obscureMySecret ? Icons.visibility_rounded : Icons.visibility_off_rounded, size: 20),
                      onPressed: () => setState(() => _obscureMySecret = !_obscureMySecret),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Copy Passphrase',
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: secret));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copied E2EE passphrase to clipboard')),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Quick Action Buttons
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.share_rounded, size: 16),
                      label: const Text('Copy All Shareable Info'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                      ),
                      onPressed: () {
                        final invite = 'Orders App Pairing Credentials:\nPairing Code: $code\nE2EE Passphrase: $secret';
                        Clipboard.setData(ClipboardData(text: invite));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Copied complete pairing credentials to clipboard!'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.autorenew_rounded, size: 16),
                      label: const Text('Generate New Code'),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Generate New Unique Identity?'),
                            content: const Text(
                              'An automatic migration update will be sent to all existing contacts.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('Cancel'),
                              ),
                              ElevatedButton(
                                onPressed: () async {
                                  await sync.regeneratePersonalIdentity();
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Generated fresh identity & notified existing contacts!'),
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  }
                                },
                                child: const Text('Generate & Sync'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.password_rounded, size: 16),
                      label: const Text('Edit Password'),
                      onPressed: () => _showEditPasswordDialog(context, sync),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.verified_user_rounded, size: 16, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '1.1+ Trillion unique combinations (Crockford Base32) with AES-256 encryption.',
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurface.withOpacity(0.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  String _getSoundPresetName(AlarmSoundPreset preset) {
    switch (preset) {
      case AlarmSoundPreset.melodicChime:
        return 'Warm Cathedral Chime';
      case AlarmSoundPreset.zenBell:
        return 'Deep Tibetan Singing Bowl';
      case AlarmSoundPreset.cyberPulse:
        return 'Ambient Synth Swell';
      case AlarmSoundPreset.digitalBeep:
        return 'Minimalist Acoustic Ding';
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final security = Provider.of<SecurityService>(context);
    final sync = Provider.of<SyncService>(context);
    final theme = Theme.of(context);

    final List<Color> customColors = [
      const Color(0xFF00F0FF), // Electric Cyan
      const Color(0xFFBD00FF), // Neon Purple
      const Color(0xFFE11D48), // Rose Crimson
      const Color(0xFF10B981), // Emerald
      const Color(0xFFF59E0B), // Amber Gold
      const Color(0xFF38BDF8), // Sky Blue
      const Color(0xFFFAFAFA), // Crisp White
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Preferences & Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Personal Pairing Identity Section
          _buildPersonalIdentitySection(context, sync, theme),

          // Background Connection & Battery Optimization Section
          Text(
            'BACKGROUND LINK & BATTERY SAVER',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            margin: const EdgeInsets.only(bottom: 20),
            child: Column(
              children: [
                SwitchListTile(
                  secondary: CircleAvatar(
                    backgroundColor: _isBatterySaver
                        ? Colors.amber.withOpacity(0.2)
                        : theme.colorScheme.primary.withOpacity(0.2),
                    child: Icon(
                      _isBatterySaver ? Icons.battery_saver_rounded : Icons.cell_tower_rounded,
                      color: _isBatterySaver ? Colors.amber : theme.colorScheme.primary,
                    ),
                  ),
                  title: Text(
                    _isBatterySaver ? 'Battery Saver Mode (Active)' : 'Keep Connected in Background',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    _isBatterySaver
                        ? 'Background service stopped to conserve battery. Orders & messages will catch up automatically whenever you open the app.'
                        : 'Background service active. Orders, directives, and approvals will trigger notifications & alerts even when the app is completely closed.',
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.65)),
                  ),
                  value: !_isBatterySaver,
                  onChanged: (keepConnected) async {
                    final batterySaver = !keepConnected;
                    await BackgroundLinkService.setBatterySaver(batterySaver);
                    setState(() {
                      _isBatterySaver = batterySaver;
                    });
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(batterySaver
                              ? '🔋 Battery Saver ON: Background service stopped.'
                              : '📡 Background Link ACTIVE: Directives arrive in real-time when app is closed.'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
                if (!_isBatterySaver && Platform.isAndroid) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.bug_report_rounded, size: 16, color: theme.colorScheme.primary),
                            const SizedBox(width: 6),
                            Text(
                              'BACKGROUND SERVICE DIAGNOSTICS',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.0,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        FutureBuilder<Map<String, String>>(
                          future: BackgroundLinkService.getDiagnostics(),
                          builder: (ctx, snap) {
                            if (!snap.hasData) {
                              return const Text('Loading…', style: TextStyle(fontSize: 12));
                            }
                            final d = snap.data!;
                            final isRunning = d['isRunning'] == 'true';
                            final isSocketLive = d['socketLive'] == 'true';
                            final state = d['state'] ?? 'Unknown';
                            final host = d['host'] ?? 'ntfy.envs.net';
                            final msgCount = d['msgCount'] ?? '0';
                            final lastMsg = d['lastMsg'] ?? 'None';
                            final lastError = d['lastError'] ?? 'None';

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      isRunning ? Icons.check_circle_rounded : Icons.cancel_rounded,
                                      size: 14,
                                      color: isRunning ? Colors.green : Colors.red,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      isRunning ? 'Service RUNNING' : 'Service NOT RUNNING',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: isRunning ? Colors.green : Colors.red,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text('Link Status: $state', style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                                Text('Relay Server: $host', style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                                Text('Real-time Stream: ${isSocketLive ? "🟢 Active (0 polling load)" : "🟡 Reconnecting"}',
                                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                                Text('Messages Processed: $msgCount (Last: $lastMsg)',
                                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                                if (lastError != 'None' && lastError.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      'Notice: $lastError',
                                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.orange),
                                    ),
                                  ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.refresh_rounded, size: 16),
                                      label: const Text('Refresh'),
                                      onPressed: () => setState(() {}),
                                    ),
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.notifications_active_rounded, size: 16),
                                      label: const Text('Test Alert'),
                                      onPressed: () async {
                                        await NotificationService.showOrderDispatchedNotification(
                                          title: 'Test Directive Alert',
                                          description: 'Verifying notification sound, vibration, and banner delivery.',
                                          assignerName: 'Director (Test)',
                                          rewardTokens: 5,
                                        );
                                      },
                                    ),
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.assignment_turned_in_rounded, size: 16),
                                      label: const Text('Simulate Order'),
                                      onPressed: () {
                                        final engine = Provider.of<OrderEngine>(context, listen: false);
                                        final testOrder = OrderItem(
                                          id: 'diag-test-${DateTime.now().millisecondsSinceEpoch}',
                                          title: 'Diagnostic Test Directive',
                                          description: 'Verifying that incoming orders properly insert into your Active Directives list.',
                                          tier: 1,
                                          rewardTokens: 10,
                                          verificationType: VerificationType.honorCheck,
                                        );
                                        engine.assignOrder(
                                          testOrder,
                                          assignedByDirector: true,
                                          assignedByPartnerName: 'Self-Test',
                                        );
                                        NotificationService.showOrderDispatchedNotification(
                                          title: testOrder.title,
                                          description: testOrder.description,
                                          assignerName: 'Self-Test',
                                          rewardTokens: testOrder.rewardTokens,
                                        );
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            content: Text('Simulated order assigned to your Active Directives!'),
                                            behavior: SnackBarBehavior.floating,
                                          ),
                                        );
                                      },
                                    ),
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.restart_alt_rounded, size: 16),
                                      label: const Text('Restart Service'),
                                      onPressed: () async {
                                        await BackgroundLinkService.stopService();
                                        await Future.delayed(const Duration(milliseconds: 500));
                                        await BackgroundLinkService.startService();
                                        if (mounted) {
                                          setState(() {});
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Text('Background service restarted.'),
                                              behavior: SnackBarBehavior.floating,
                                            ),
                                          );
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Audio & Alarm Sound Effects Section
          Text(
            'AUDIO & CHIME ALERTS',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),

          // Master Audio Alert Switch
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: SwitchListTile(
              secondary: CircleAvatar(
                backgroundColor: _audioAlertsEnabled
                    ? theme.colorScheme.primary.withOpacity(0.2)
                    : theme.colorScheme.surface,
                child: Icon(
                  _audioAlertsEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                  color: _audioAlertsEnabled
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
              title: const Text('Audible Chime Alerts', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                _audioAlertsEnabled
                    ? 'Audible sound alert plays for incoming directives and timer completions.'
                    : 'Muted. Directives arrive silently with visual & system notifications only. (Default: Off)',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6)),
              ),
              value: _audioAlertsEnabled,
              onChanged: (val) async {
                await SoundService.setAudioAlertsEnabled(val);
                _refreshSoundState();
              },
            ),
          ),

          // Custom Sound File Card
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: _useCustomSound
                            ? theme.colorScheme.primary.withOpacity(0.2)
                            : theme.colorScheme.surface,
                        child: Icon(
                          Icons.audio_file_rounded,
                          color: _useCustomSound
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Custom Sound File',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            Text(
                              _customSoundName ?? 'Upload any MP3, WAV, M4A, OGG, FLAC, or AAC',
                              style: TextStyle(
                                fontSize: 12,
                                color: _customSoundName != null
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurface.withOpacity(0.6),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (_customSoundName != null) ...[
                        IconButton(
                          tooltip: 'Preview Custom Sound',
                          icon: const Icon(Icons.play_circle_outline_rounded, size: 24),
                          onPressed: () => SoundService.playCustomSound(),
                        ),
                        Radio<bool>(
                          value: true,
                          groupValue: _useCustomSound,
                          onChanged: (val) {
                            if (_customSoundName != null) {
                              SoundService.setCustomSound(
                                SoundService.customSoundPath!,
                                _customSoundName!,
                              );
                              _refreshSoundState();
                              SoundService.playCustomSound();
                            }
                          },
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (_customSoundName != null) ...[
                        TextButton.icon(
                          onPressed: () async {
                            await SoundService.clearCustomSound();
                            _refreshSoundState();
                          },
                          icon: const Icon(Icons.delete_outline_rounded, size: 16),
                          label: const Text('Remove'),
                          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                        ),
                        const SizedBox(width: 8),
                      ],
                      ElevatedButton.icon(
                        onPressed: _pickAndSetCustomSound,
                        icon: const Icon(Icons.upload_file_rounded, size: 16),
                        label: Text(_customSoundName != null ? 'Change Sound' : 'Upload Audio File'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: theme.colorScheme.surface,
                          foregroundColor: theme.colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Built-in Synthesizer Presets
          Card(
            child: Column(
              children: AlarmSoundPreset.values.map((preset) {
                final isSelected = !_useCustomSound && _selectedSound == preset;
                return Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        isSelected ? Icons.volume_up_rounded : Icons.music_note_rounded,
                        color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.5),
                      ),
                      title: Text(
                        _getSoundPresetName(preset),
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Preview / Test Sound',
                            icon: const Icon(Icons.play_circle_outline_rounded, size: 24),
                            onPressed: () {
                              SoundService.playPreset(preset);
                            },
                          ),
                          Radio<AlarmSoundPreset>(
                            value: preset,
                            groupValue: _useCustomSound ? null : _selectedSound,
                            onChanged: (val) {
                              if (val != null) {
                                SoundService.selectPreset(val);
                                _refreshSoundState();
                                SoundService.playPreset(val);
                              }
                            },
                          ),
                        ],
                      ),
                      onTap: () {
                        SoundService.selectPreset(preset);
                        _refreshSoundState();
                        SoundService.playPreset(preset);
                      },
                    ),
                    if (preset != AlarmSoundPreset.values.last) const Divider(height: 1),
                  ],
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 24),

          // Theme Presets Header
          Text(
            'THEME PRESETS',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 12),

          // Theme cards
          ...AppThemes.all.map((config) {
            final isSelected = themeProvider.currentPreset == config.preset;
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: isSelected ? theme.colorScheme.primary : Colors.transparent,
                  width: 2,
                ),
              ),
              child: ListTile(
                onTap: () => themeProvider.setPreset(config.preset),
                leading: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: config.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: config.secondary, width: 2),
                  ),
                ),
                title: Text(
                  config.displayName,
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                trailing: isSelected
                    ? Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary)
                    : null,
              ),
            );
          }),
          const SizedBox(height: 24),

          // Custom Accent Selector
          Text(
            'ACCENT COLOR OVERRIDE',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              ...customColors.map((color) {
                final isSelected = themeProvider.customAccent == color;
                return GestureDetector(
                  onTap: () => themeProvider.setCustomAccent(color),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? Colors.white : Colors.transparent,
                        width: 3,
                      ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: color.withOpacity(0.6),
                                blurRadius: 10,
                                spreadRadius: 2,
                              ),
                            ]
                          : [],
                    ),
                  ),
                );
              }),
              GestureDetector(
                onTap: () => themeProvider.setCustomAccent(null),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: themeProvider.customAccent == null
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface.withOpacity(0.3),
                      width: 2,
                    ),
                  ),
                  child: const Icon(Icons.refresh_rounded, size: 20),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),

          // Security & Disguise section
          Text(
            'SECURITY & DISGUISE',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.pin_rounded),
                  title: const Text('App Launch PIN Lock'),
                  subtitle: Text(
                    security.isPinRequired ? 'Enabled' : 'Disabled (Open on launch)',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _showPinSetupDialog(context),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.visibility_off_rounded, color: Colors.amber),
                  title: const Text('Test Panic / Disguise Mode'),
                  subtitle: const Text('Instantly masks the app with a functioning calculator'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    security.triggerPanic();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Tip: While disguised as a calculator, type "7777=" or long-press the top header to return.',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5)),
            ),
          ),
        ],
      ),
    );
  }
}
