import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../models/reward_item.dart';
import '../../models/reward_pack.dart';
import '../../models/partner_contact.dart';
import '../../models/active_redemption.dart';
import '../../services/order_engine.dart';
import '../../services/sync_service.dart';
import '../../services/partner_service.dart';
import '../../core/security/encryption_helper.dart';
import 'reward_studio_view.dart';

class RewardManagerView extends StatelessWidget {
  const RewardManagerView({super.key});

  String _sanitizeFileName(String title) {
    return title.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
  }

  void _sendPackViaChat(BuildContext context, RewardPack pack) {
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);
    final contacts = partnerSvc.unblockedContacts;

    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No paired partners found to send reward pack.')),
      );
      return;
    }

    PartnerContact? selectedPartner = partnerSvc.activePartner ?? contacts.first;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.send_rounded, color: Colors.amber),
              const SizedBox(width: 10),
              Expanded(child: Text('Send "${pack.title}" in Chat', overflow: TextOverflow.ellipsis)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Send this reward pack (${pack.rewards.length} rewards) to:'),
              const SizedBox(height: 12),
              DropdownButtonFormField<PartnerContact>(
                value: selectedPartner,
                decoration: const InputDecoration(labelText: 'Recipient', border: OutlineInputBorder()),
                items: contacts.map((c) => DropdownMenuItem(value: c, child: Text('${c.displayName} (${c.pairingCode})'))).toList(),
                onChanged: (val) => setDialogState(() => selectedPartner = val),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton.icon(
              icon: const Icon(Icons.send_rounded, size: 16),
              label: const Text('Send Pack'),
              onPressed: selectedPartner == null ? null : () async {
                Navigator.pop(ctx);
                final rawJson = jsonEncode(pack.toJson());
                await sync.sendChatMessage(
                  selectedPartner!,
                  'Shared Reward Pack: "${pack.title}" (${pack.rewards.length} rewards)',
                  packType: 'rewardPack',
                  packTitle: pack.title,
                  packItemCount: pack.rewards.length,
                  packData: rawJson,
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Sent "${pack.title}" to ${selectedPartner!.displayName}!'), behavior: SnackBarBehavior.floating),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _exportPack(BuildContext context, RewardPack pack) {
    final rawJson = jsonEncode(pack.toJson());
    final passCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Export "${pack.title}"'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Export as a standalone .rewardpack file. You can optionally protect it with a password:'),
              const SizedBox(height: 14),
              Text(
                'Encryption Password (Optional)',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  hintText: 'Leave empty for unencrypted file',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Clipboard'),
              onPressed: () {
                String output = rawJson;
                if (passCtrl.text.trim().isNotEmpty) {
                  output = EncryptionHelper.encryptString(rawJson, passCtrl.text.trim());
                }
                Clipboard.setData(ClipboardData(text: output));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Reward Pack copied to clipboard!'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.save_alt_rounded, size: 18),
              label: const Text('Save to File'),
              onPressed: () async {
                String output = rawJson;
                if (passCtrl.text.trim().isNotEmpty) {
                  output = EncryptionHelper.encryptString(rawJson, passCtrl.text.trim());
                }

                Navigator.pop(ctx);

                try {
                  final defaultFileName = '${_sanitizeFileName(pack.title)}.rewardpack';
                  final savedUri = await FilePicker.saveFile(
                    dialogTitle: 'Save Reward Pack File',
                    fileName: defaultFileName,
                    bytes: utf8.encode(output),
                    type: FileType.custom,
                    allowedExtensions: ['rewardpack', 'json'],
                  );

                  if (savedUri != null) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Saved pack: $defaultFileName'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error saving file: $e')),
                    );
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }

  void _showImportDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Import Reward Pack',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(Icons.file_open_rounded, color: Colors.blueAccent),
                  title: const Text('Open .rewardpack or .json File'),
                  subtitle: const Text('Import from local storage or downloads'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _importFromFile(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.content_paste_rounded, color: Colors.greenAccent),
                  title: const Text('Paste from Clipboard'),
                  subtitle: const Text('Paste raw or encrypted JSON string'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _importFromClipboard(context);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _importFromFile(BuildContext context) async {
    final engine = Provider.of<OrderEngine>(context, listen: false);

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['rewardpack', 'json', 'txt'],
      );

      if (result != null && result.isNotEmpty && result.single.path != null) {
        final file = File(result.single.path!);
        final raw = await file.readAsString();

        if (context.mounted) {
          _processImportData(context, engine, raw);
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open file: $e')),
        );
      }
    }
  }

  void _importFromClipboard(BuildContext context) async {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim() ?? '';

    if (raw.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clipboard is empty.')),
        );
      }
      return;
    }

    if (context.mounted) {
      _processImportData(context, engine, raw);
    }
  }

  void _processImportData(BuildContext context, OrderEngine engine, String raw) {
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) {
        final pack = RewardPack.fromJson(parsed);
        engine.addRewardPack(pack);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imported "${pack.title}" (${pack.rewards.length} rewards)!'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
    } catch (_) {
      _promptPasswordForDecryption(context, engine, raw);
    }
  }

  void _promptPasswordForDecryption(BuildContext context, OrderEngine engine, String encryptedData) {
    final passCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Encrypted Reward Pack'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('This pack is encrypted. Enter the passphrase to unlock and import:'),
              const SizedBox(height: 12),
              TextField(
                controller: passCtrl,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Passphrase',
                  border: OutlineInputBorder(),
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
                final password = passCtrl.text.trim();
                Navigator.pop(ctx);
                try {
                  final decrypted = EncryptionHelper.decryptString(encryptedData, password);
                  final parsed = jsonDecode(decrypted) as Map<String, dynamic>;
                  final pack = RewardPack.fromJson(parsed);
                  engine.addRewardPack(pack);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Decrypted & imported "${pack.title}" (${pack.rewards.length} rewards)!'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Decryption failed. Incorrect passphrase or corrupt file.'),
                      backgroundColor: Colors.redAccent,
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              child: const Text('Unlock & Import'),
            ),
          ],
        );
      },
    );
  }

  void _showDeclineDialog(BuildContext context, ActiveRedemption redemption) {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final reasonController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Decline "${redemption.reward.title}"?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The ${redemption.reward.cost} tokens will be fully refunded to the submissive.',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Reason for declining (Optional)',
                  hintText: 'e.g. Schedule conflict, try again tomorrow...',
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
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                engine.rejectRedemption(
                  redemption.id,
                  reason: reasonController.text.trim().isEmpty ? 'Declined by Director' : reasonController.text.trim(),
                );
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Redemption request declined and tokens refunded.'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              child: const Text('Decline & Refund'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final engine = Provider.of<OrderEngine>(context);
    final theme = Theme.of(context);
    final pendingCount = engine.pendingRedemptions.length;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Reward Packs & Privileges'),
          bottom: TabBar(
            tabs: [
              const Tab(text: 'REWARD PACKS', icon: Icon(Icons.inventory_2_rounded, size: 20)),
              Tab(
                icon: Badge(
                  isLabelVisible: pendingCount > 0,
                  label: Text('$pendingCount'),
                  child: const Icon(Icons.approval_rounded, size: 20),
                ),
                text: 'REDEMPTIONS',
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // Tab 1: Reward Packs
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Top control banner
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.stars_rounded, color: Colors.amber, size: 28),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Privilege Packs & Economies',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  ),
                                  Text(
                                    '${engine.rewards.length} rewards active across ${engine.rewardPacks.where((p) => p.isEnabled).length} enabled packs',
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
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.add_rounded),
                                label: const Text('Create Pack'),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => const RewardStudioView()),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.download_rounded),
                              label: const Text('Import'),
                              onPressed: () => _showImportDialog(context),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Pack List
                ...engine.rewardPacks.map((pack) {
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ExpansionTile(
                      leading: CircleAvatar(
                        backgroundColor: pack.isEnabled
                            ? theme.colorScheme.primary.withOpacity(0.15)
                            : theme.colorScheme.onSurface.withOpacity(0.1),
                        child: Icon(
                          pack.isEnabled ? Icons.card_giftcard_rounded : Icons.lock_outline_rounded,
                          color: pack.isEnabled ? theme.colorScheme.primary : Colors.grey,
                        ),
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              pack.title,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: pack.isEnabled ? null : theme.colorScheme.onSurface.withOpacity(0.5),
                              ),
                            ),
                          ),
                          Switch(
                            value: pack.isEnabled,
                            onChanged: (val) => engine.toggleRewardPackEnabled(pack.id),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        '${pack.rewards.length} rewards • By ${pack.author}',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                      children: [
                        if (pack.description.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                pack.description,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                                ),
                              ),
                            ),
                          ),

                        // Action button toolbar
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton.icon(
                                icon: const Icon(Icons.send_rounded, size: 16, color: Colors.amber),
                                label: const Text('Send', style: TextStyle(fontSize: 12, color: Colors.amber)),
                                onPressed: () => _sendPackViaChat(context, pack),
                              ),
                              TextButton.icon(
                                icon: const Icon(Icons.edit_rounded, size: 16),
                                label: const Text('Edit', style: TextStyle(fontSize: 12)),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => RewardStudioView(existingPack: pack)),
                                  );
                                },
                              ),
                              TextButton.icon(
                                icon: const Icon(Icons.file_upload_outlined, size: 16),
                                label: const Text('Export', style: TextStyle(fontSize: 12)),
                                onPressed: () => _exportPack(context, pack),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Colors.redAccent),
                                tooltip: 'Delete Pack',
                                onPressed: () {
                                  showDialog(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: Text('Delete "${pack.title}"?'),
                                      content: const Text('This will permanently delete this reward pack.'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                                        ElevatedButton(
                                          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                                          onPressed: () {
                                            engine.deleteRewardPack(pack.id);
                                            Navigator.pop(ctx);
                                          },
                                          child: const Text('Delete'),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),

                        const Divider(height: 1),

                        // Rewards preview inside pack
                        ...pack.rewards.map((r) {
                          return ListTile(
                            dense: true,
                            leading: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.amber.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '${r.cost}T',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                  color: Colors.amber,
                                ),
                              ),
                            ),
                            title: Text(r.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                            subtitle: Text(
                              '${r.category} ${r.requiresDirectorApproval ? "• Needs Approval" : "• Instant"}',
                              style: const TextStyle(fontSize: 11),
                            ),
                          );
                        }),
                      ],
                    ),
                  );
                }),
              ],
            ),

            // Tab 2: Redemptions
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'PENDING APPROVALS (${engine.pendingRedemptions.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.0),
                ),
                const SizedBox(height: 8),
                if (engine.pendingRedemptions.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          'No pending redemption requests from your submissive.',
                          style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5)),
                        ),
                      ),
                    ),
                  )
                else
                  ...engine.pendingRedemptions.map((redemption) {
                    final dateStr = DateFormat('MMM d, h:mm a').format(redemption.requestedAt);
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    redemption.reward.title,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '${redemption.reward.cost} Tokens',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                      color: Colors.amber,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              redemption.reward.description,
                              style: TextStyle(
                                fontSize: 13,
                                color: theme.colorScheme.onSurface.withOpacity(0.7),
                              ),
                            ),
                            if (redemption.note != null && redemption.note!.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surface.withOpacity(0.5),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: theme.colorScheme.onSurface.withOpacity(0.1)),
                                ),
                                child: Text(
                                  'Note: "${redemption.note}"',
                                  style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            Text(
                              'Requested $dateStr',
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurface.withOpacity(0.4),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.redAccent,
                                  ),
                                  icon: const Icon(Icons.close_rounded, size: 16),
                                  label: const Text('Decline'),
                                  onPressed: () => _showDeclineDialog(context, redemption),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.greenAccent[700],
                                    foregroundColor: Colors.black,
                                  ),
                                  icon: const Icon(Icons.check_rounded, size: 16),
                                  label: const Text('Grant Privilege'),
                                  onPressed: () {
                                    engine.approveRedemption(redemption.id);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Granted "${redemption.reward.title}"!'),
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  }),

                const SizedBox(height: 24),
                Text(
                  'RECENT REDEMPTIONS HISTORY',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.0),
                ),
                const SizedBox(height: 8),
                if (engine.redemptions.where((r) => r.status != RedemptionStatus.pending).isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Center(
                        child: Text(
                          'No past redemption history.',
                          style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5)),
                        ),
                      ),
                    ),
                  )
                else
                  ...engine.redemptions
                      .where((r) => r.status != RedemptionStatus.pending)
                      .take(10)
                      .map((redemption) {
                    final isApproved = redemption.status == RedemptionStatus.approved;
                    final dateStr = redemption.resolvedAt != null
                        ? DateFormat('MMM d, h:mm a').format(redemption.resolvedAt!)
                        : '';
                    return Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        leading: Icon(
                          isApproved ? Icons.check_circle_rounded : Icons.cancel_rounded,
                          color: isApproved ? Colors.greenAccent : Colors.redAccent,
                        ),
                        title: Text(redemption.reward.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          '${isApproved ? "Granted" : "Declined"} • $dateStr',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: Text(
                          '${redemption.reward.cost} Tok',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withOpacity(0.7),
                          ),
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
