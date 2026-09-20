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
import '../../services/push_service.dart';
import '../../services/worker_socket_service.dart';
import '../../services/debug_settings.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/update_service.dart';
import '../player/stats_view.dart';
import '../../services/schedule_service.dart';
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

  /// Diagnostics are for working out why something did not arrive. They are
  /// noise the rest of the time, so the panel starts closed.
  bool _showDebugPanel = false;

  /// Result of the last explicit check, so the card can report back.
  AppUpdate? _update;
  bool _checkingForUpdate = false;
  String? _updateCheckMessage;

  Future<void> _checkForUpdateNow() async {
    setState(() {
      _checkingForUpdate = true;
      _updateCheckMessage = null;
    });
    final update = await UpdateService.check(force: true);
    if (!mounted) return;
    setState(() {
      _checkingForUpdate = false;
      _update = update;
      _updateCheckMessage =
          update == null ? 'You are on the latest version.' : null;
    });
  }

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

          // Stats live here rather than in the navigation bar: the record is
          // something you go and look at now and then, and the bar had more
          // destinations than fit a phone.
          Card(
            margin: const EdgeInsets.only(bottom: 20),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primary.withOpacity(0.18),
                child: Icon(Icons.bar_chart_rounded, color: theme.colorScheme.primary),
              ),
              title: const Text('Statistics & Record',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                'Tokens, streaks, completion history and your discipline log.',
                style:
                    TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.65)),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const StatsView()),
              ),
            ),
          ),

          // Version & updates. The app is distributed outside any store, so
          // nothing else would tell someone they are running an old build.
          if (UpdateService.isSupported) ...[
            Text(
              'APP VERSION',
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
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: _update != null
                      ? theme.colorScheme.primary.withOpacity(0.2)
                      : theme.colorScheme.onSurface.withOpacity(0.08),
                  child: Icon(
                    _update != null ? Icons.system_update_rounded : Icons.verified_rounded,
                    color: _update != null
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
                title: Text(
                  _update != null
                      ? 'Version ${_update!.version} available'
                      : 'Version ${UpdateService.currentVersion}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  _update != null
                      ? 'You are on ${UpdateService.currentVersion}.'
                          '${_update!.sizeLabel != null ? ' Download is ${_update!.sizeLabel}.' : ''}'
                      : (_updateCheckMessage ?? 'Checked against subtaskmanager.com.'),
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.65)),
                ),
                trailing: _checkingForUpdate
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : (_update != null
                        ? FilledButton(
                            onPressed: () {
                              final target = _update!.downloadUrl ?? _update!.notesUrl;
                              if (target != null) {
                                launchUrl(Uri.parse(target),
                                    mode: LaunchMode.externalApplication);
                              }
                            },
                            child: Text(_update!.downloadUrl != null ? 'Download' : 'Details'),
                          )
                        : TextButton(
                            onPressed: _checkForUpdateNow,
                            child: const Text('Check now'),
                          )),
              ),
            ),
          ],

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
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.bug_report_rounded,
                      color: theme.colorScheme.onSurface.withOpacity(0.7)),
                  title: const Text('Debug & Diagnostics',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    _showDebugPanel
                        ? 'Delivery, background service and alarm state.'
                        : 'Open if something did not arrive, or to turn on extra controls.',
                    style: TextStyle(
                        fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.65)),
                  ),
                  trailing: Icon(
                      _showDebugPanel ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                  onTap: () => setState(() => _showDebugPanel = !_showDebugPanel),
                ),
                if (_showDebugPanel) ...[
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: Icon(Icons.build_rounded,
                        color: theme.colorScheme.onSurface.withOpacity(0.7)),
                    title: const Text('Show override controls on Orders',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      'Adds Dismiss and Clean / Override Tasks to your dashboard. These clear a '
                      'directive without completing or forfeiting it. Your director is told it was '
                      'emergency-cleared, but no tokens are deducted and it is not logged as a '
                      'failure.',
                      style: TextStyle(
                          fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.65)),
                    ),
                    value: DebugSettings.instance.showPlayerOverrides,
                    onChanged: (on) async {
                      await DebugSettings.instance.setShowPlayerOverrides(on);
                      if (mounted) setState(() {});
                    },
                  ),
                ],
                // Shown on every platform. The panel was Android-only, which left
                // the director device — where dispatches originate — with no way
                // to see that its own sends were failing.
                if (!_isBatterySaver && _showDebugPanel) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Version badge: confirms at a glance which build is
                        // actually installed. Diagnosing across two devices is
                        // guesswork when you cannot tell what each is running.
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: theme.colorScheme.primary.withValues(alpha: 0.4),
                                ),
                              ),
                              child: Text(
                                'v${ScheduleService.appCurrentBuildVersion}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace',
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              Platform.isAndroid
                                  ? 'Android'
                                  : (Platform.isWindows ? 'Windows' : 'Desktop'),
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // Push registration. Without this, a device that failed
                        // to register its token looks identical to one sitting
                        // quietly with nothing to receive.
                        FutureBuilder<String>(
                          future: PushService.lastStatus(),
                          builder: (pctx, psnap) {
                            final st = psnap.data ?? 'checking...';
                            final bad = st.contains('failed') || st.contains('error');
                            return Text(
                                'Push: $st'
                                '${PushService.isSupported ? '' : ' (send-only platform)'}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: bad ? Colors.red : null,
                                ));
                          },
                        ),
                        // Desktop's live link to the Worker. Android has push;
                        // without this line a PC that had silently fallen back
                        // to the relay looked identical to a healthy one.
                        if (WorkerSocketService.isSupported) ...[
                          FutureBuilder<String>(
                            future: WorkerSocketService.lastStatus(),
                            builder: (wctx, wsnap) {
                              final st = wsnap.data ?? 'checking...';
                              return Text('Worker link: $st',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                    color: st.contains('disconnected') ? Colors.red : null,
                                  ));
                            },
                          ),
                          const SizedBox(height: 10),
                        ],
                        const SizedBox(height: 10),
                        // End-to-end evidence for scheduled pushes: what the
                        // server did, and what this device received. When a
                        // scheduled directive goes missing, these two lists
                        // say which link broke.
                        _PushDeliveryEvidence(
                          topic: sync.pairingCode.isEmpty
                              ? ''
                              : SyncService.getHashedTopic(sync.pairingCode),
                        ),
                        const SizedBox(height: 10),
                        // Outbound send status lives outside the background
                        // service section on purpose: it is the only signal the
                        // dispatching device has, and on desktop there is no
                        // background service for it to hang off.
                        FutureBuilder<String>(
                          future: SyncService.lastRelaySendStatus(),
                          builder: (sctx, ssnap) {
                            final st = ssnap.data ?? 'checking...';
                            return Text('Outbound send: $st',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: st.contains('FAILED') ? Colors.red : null,
                                ));
                          },
                        ),
                        const SizedBox(height: 10),
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
                            if (snap.hasError) {
                              return Text(
                                  'Diagnostics unavailable: ${snap.error}',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                      color: Colors.orange));
                            }
                            if (!snap.hasData) {
                              return const Text('Loading…',
                                  style: TextStyle(fontSize: 12));
                            }
                            final d = snap.data!;
                            // The foreground service is an Android concept. On
                            // desktop there is nothing to report, and a red
                            // "NOT RUNNING" badge would be a false alarm.
                            final serviceSupported = d['supported'] == 'true';
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
                                      !serviceSupported
                                          ? Icons.desktop_windows_rounded
                                          : (isRunning
                                              ? Icons.check_circle_rounded
                                              : Icons.cancel_rounded),
                                      size: 14,
                                      color: !serviceSupported
                                          ? theme.colorScheme.onSurface
                                              .withValues(alpha: 0.6)
                                          : (isRunning ? Colors.green : Colors.red),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        !serviceSupported
                                            ? 'No background service on this platform'
                                            : (isRunning
                                                ? 'Service RUNNING'
                                                : 'Service NOT RUNNING'),
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          color: !serviceSupported
                                              ? theme.colorScheme.onSurface
                                                  .withValues(alpha: 0.7)
                                              : (isRunning ? Colors.green : Colors.red),
                                        ),
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
                                // Whether the service is *ticking*, not merely
                                // registered. A stale tick with a RUNNING badge
                                // means the process is alive but frozen.
                                Text('Relay status: ${d['relayStatus'] ?? 'No errors'}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                      color: (d['relayStatus'] ?? '').contains('429')
                                          ? Colors.red
                                          : null,
                                    )),
                                Builder(builder: (_) {
                                  // A RUNNING badge beside a tick from hours
                                  // ago means the process is alive but frozen,
                                  // and it read as healthy until now.
                                  final tick = DateTime.tryParse(d['lastTick'] ?? '');
                                  final age = tick == null ? null : DateTime.now().difference(tick);
                                  final stale = age == null || age > const Duration(minutes: 5);
                                  final ageText = age == null
                                      ? ''
                                      : ' - ${age.inHours}h ${age.inMinutes % 60}m ago${stale ? ', NOT TICKING' : ''}';
                                  return Text(
                                      'Last service tick: ${d['lastTick'] ?? 'Never'} (${d['tickCount'] ?? '0'} ticks)$ageText',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontFamily: 'monospace',
                                        color: stale ? Colors.red : null,
                                      ));
                                }),
                                if (d['batteryExempt'] != null)
                                  Text(
                                      'Battery optimisation: ${d['batteryExempt'] == 'true' ? 'exempt' : 'NOT EXEMPT'}'
                                      ' | Restricted: ${d['bgRestricted']}'
                                      ' | Bucket: ${d['standbyBucket']}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontFamily: 'monospace',
                                        color: (d['batteryExempt'] != 'true' ||
                                                d['bgRestricted'] == 'true' ||
                                                d['standbyBucket'] == 'RESTRICTED')
                                            ? Colors.red
                                            : null,
                                      )),
                                if (d['device'] != null)
                                  Text('Device: ${d['device']}',
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
                                // Scheduled alarm arming. A scheduled task that
                                // never notified leaves no trace otherwise: the
                                // OS holds the alarm, and every failure to arm
                                // one is a caught exception.
                                FutureBuilder<Map<String, String>>(
                                  future: NotificationService.getAlarmDiagnostics(),
                                  builder: (actx, asnap) {
                                    if (!asnap.hasData) {
                                      return const Text('Scheduled alarms: loading…',
                                          style: TextStyle(fontSize: 12, fontFamily: 'monospace'));
                                    }
                                    final a = asnap.data!;
                                    final armed = int.tryParse(a['armed'] ?? '0') ?? 0;
                                    final pendingRaw = a['pending'] ?? '0';
                                    final pending = int.tryParse(pendingRaw);
                                    final pendingError = a['pendingError'] ?? '';
                                    final lastMissed = a['lastMissed'] ?? '';
                                    final canExact = a['canScheduleExact'] ?? 'unknown';
                                    final lastResult = a['lastResult'] ?? 'Never';
                                    final armError = a['lastError'] ?? '';

                                    // Only a genuine zero counts as a mismatch:
                                    // an unreadable store tells us nothing about
                                    // what the OS actually holds.
                                    final mismatch = armed > 0 && pending == 0;

                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Divider(height: 14),
                                        Text(
                                          'SCHEDULED ALARMS',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 1.0,
                                            color: theme.colorScheme.primary,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text('Exact alarms allowed: $canExact',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontFamily: 'monospace',
                                              color: canExact == 'false' ? Colors.red : null,
                                            )),
                                        Text('Armed by app: $armed   Held by OS: $pendingRaw',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontFamily: 'monospace',
                                              color: mismatch ? Colors.red : null,
                                            )),
                                        if (lastMissed.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 4),
                                            child: Text(
                                              'Alarm missed: $lastMissed',
                                              style: const TextStyle(
                                                  fontSize: 11, fontFamily: 'monospace', color: Colors.red),
                                            ),
                                          ),
                                        if (pendingError.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 4),
                                            child: Text(
                                              'Alarm store unreadable: $pendingError',
                                              style: const TextStyle(
                                                  fontSize: 11, fontFamily: 'monospace', color: Colors.orange),
                                            ),
                                          ),
                                        Text('Next armed: ${a['nextArmed'] ?? 'None'}',
                                            style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                                        Text('Last arm attempt: $lastResult',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontFamily: 'monospace',
                                              color: lastResult.contains('FAILED') || lastResult.contains('DEGRADED')
                                                  ? Colors.orange
                                                  : null,
                                            )),
                                        if (armError.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 4),
                                            child: Text(
                                              'Arm error: $armError',
                                              style: const TextStyle(
                                                  fontSize: 11, fontFamily: 'monospace', color: Colors.orange),
                                            ),
                                          ),
                                        if (mismatch)
                                          const Padding(
                                            padding: EdgeInsets.only(top: 4),
                                            child: Text(
                                              'The system is not holding these alarms. If this device shows '
                                              'an "Alarms & reminders" entry under its app settings, make sure it '
                                              'is allowed, and turn off battery optimisation for this app.',
                                              style: TextStyle(
                                                  fontSize: 11, fontFamily: 'monospace', color: Colors.red),
                                            ),
                                          ),
                                      ],
                                    );
                                  },
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
                                      icon: const Icon(Icons.alarm_add_rounded, size: 16),
                                      label: const Text('Test Alarm (2 min)'),
                                      onPressed: () async {
                                        // Goes through the same arming path as a
                                        // scheduled rule, so the result proves
                                        // whether alarms work on this device.
                                        final when = DateTime.now().add(const Duration(minutes: 2));
                                        await NotificationService.scheduleExactNotification(
                                          id: 987654321,
                                          title: '⏰ Alarm Test',
                                          body: 'If you are seeing this, scheduled alarms fire correctly '
                                              'on this device. Close the app and wait 2 minutes to test '
                                              'the background case.',
                                          scheduledDate: when,
                                        );
                                        if (!ctx.mounted) return;
                                        setState(() {});
                                        ScaffoldMessenger.of(ctx).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                                'Alarm armed for ${when.hour.toString().padLeft(2, '0')}:'
                                                '${when.minute.toString().padLeft(2, '0')}. '
                                                'Close the app fully and wait.'),
                                          ),
                                        );
                                      },
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


/// Server and device records of scheduled push delivery, side by side.
class _PushDeliveryEvidence extends StatelessWidget {
  const _PushDeliveryEvidence({required this.topic});

  final String topic;

  static const _mono = TextStyle(fontSize: 12, fontFamily: 'monospace');

  static String _hm(Object? ms) {
    if (ms is! num) return '?';
    final t = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    return '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
  }

  static String _hmIso(Object? iso) {
    final t = DateTime.tryParse('${iso ?? ''}');
    return t == null ? '?' : _hm(t.millisecondsSinceEpoch);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Object>>(
      future: Future.wait<Object>([
        PushService.fetchServerDiag(topic),
        PushService.recentReceipts(),
      ]),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Text('Push delivery: checking...', style: _mono);
        }
        final server = snap.data![0] as Map<String, dynamic>;
        final receipts = snap.data![1] as List<Map<String, dynamic>>;
        final lines = <Widget>[];

        if (server['error'] != null) {
          lines.add(Text('Server: unavailable (${server['error']})',
              style: _mono.copyWith(color: Colors.orange)));
        } else {
          final devices = (server['devices'] as List?) ?? const [];
          lines.add(Text(
              devices.isEmpty
                  ? 'Server: NO DEVICE REGISTERED for this code'
                  : 'Server: ${devices.length} device(s) registered, last ${_hm((devices.first as Map)['updated_at'])}',
              style: _mono.copyWith(color: devices.isEmpty ? Colors.red : null)));
          lines.add(Text(
              'Staged: ${server['staged']}'
              '${server['nextDue'] != null ? ', next ${_hm(server['nextDue'])}' : ''}',
              style: _mono));
          final deliveries = (server['deliveries'] as List?) ?? const [];
          if (deliveries.isEmpty) {
            lines.add(const Text('Server sends: none recorded yet', style: _mono));
          }
          for (final raw in deliveries.take(6)) {
            final d = raw as Map;
            final ok = (d['sent'] as num? ?? 0) > 0 ||
                '${d['detail'] ?? ''}'.startsWith('superseded');
            lines.add(Text(
                'Sent ${_hm(d['fired_at'])} (due ${_hm(d['due_at'])}) '
                '${d['sent']}/${d['devices']}'
                '${d['detail'] != null ? ' ${d['detail']}' : ''}',
                style: _mono.copyWith(color: ok ? null : Colors.red)));
          }
        }

        if (receipts.isEmpty) {
          lines.add(const Text('Received: none recorded yet', style: _mono));
        }
        for (final r in receipts.take(6)) {
          final received = DateTime.tryParse('${r['r'] ?? ''}');
          final sent = DateTime.tryParse('${r['s'] ?? ''}');
          final delay = (received != null && sent != null) ? received.difference(sent) : null;
          final late = delay != null && delay > const Duration(minutes: 2);
          lines.add(Text(
              'Received ${_hmIso(r['r'])} ${r['k']}${r['bg'] == true ? ' [bg]' : ''}'
              '${delay != null ? ' +${delay.inMinutes >= 1 ? '${delay.inMinutes}m' : '${delay.inSeconds}s'}' : ''}',
              style: _mono.copyWith(color: late ? Colors.red : null)));
        }

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines);
      },
    );
  }
}
