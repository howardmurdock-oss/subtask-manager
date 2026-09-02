import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/quest_service.dart';

class QuestGateView extends StatefulWidget {
  const QuestGateView({super.key});

  @override
  State<QuestGateView> createState() => _QuestGateViewState();
}

class _QuestGateViewState extends State<QuestGateView> {
  final TextEditingController _codeCtrl = TextEditingController();
  String? _errorMsg;
  bool _isLoading = false;

  void _verifyCode() {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      setState(() => _errorMsg = 'Please enter an access code');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    final questService = Provider.of<QuestService>(context, listen: false);
    final success = questService.unlockWithPasscode(code);

    setState(() {
      _isLoading = false;
      if (!success) {
        _errorMsg = 'Invalid Patreon access code. Check Patreon posts for the current build code.';
      }
    });

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.stars_rounded, color: Colors.amber),
              SizedBox(width: 10),
              Text('Quests & Chained Directives Unlocked!'),
            ],
          ),
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Patreon Exclusive: Quests'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Glowing Lock / Quest Emblem
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.12),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.primary.withOpacity(0.4),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    Icons.auto_stories_rounded,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 20),

                // Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.amber, width: 1),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.workspace_premium_rounded, size: 16, color: Colors.amber),
                      SizedBox(width: 6),
                      Text(
                        'PATREON SUPPORTER FEATURE',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                          color: Colors.amber,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                Text(
                  'Sequential Directive Quests',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),

                Text(
                  'String directives into multi-step interactive playlists, gauntlets, and obedience storylines. Progress step-by-step with mystery reveals and bonus payouts.',
                  style: TextStyle(
                    fontSize: 14,
                    color: theme.colorScheme.onSurface.withOpacity(0.7),
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),

                // Card with Input & Unlock Button
                Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'ENTER PATREON ACCESS CODE',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _codeCtrl,
                          textCapitalization: TextCapitalization.characters,
                          decoration: InputDecoration(
                            hintText: 'e.g. PATREON-VIP',
                            prefixIcon: const Icon(Icons.key_rounded),
                            errorText: _errorMsg,
                            border: const OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _verifyCode(),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          icon: _isLoading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.lock_open_rounded),
                          label: const Text('Unlock Quests Access'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: theme.colorScheme.brightness == Brightness.dark
                                ? Colors.black
                                : Colors.white,
                          ),
                          onPressed: _isLoading ? null : _verifyCode,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                Text(
                  'Active for current build (v${QuestService.appCurrentBuildVersion}). Codes are distributed on the official Patreon creator page.',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
