import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../../models/order_item.dart';
import '../../models/order_pack.dart';
import '../../models/partner_contact.dart';
import '../../services/order_engine.dart';
import '../../services/sync_service.dart';
import '../../services/partner_service.dart';
import '../../core/security/encryption_helper.dart';
import 'pack_studio_view.dart';
import 'order_dispatch_dialog.dart';

class PackManagerView extends StatelessWidget {
  const PackManagerView({super.key});

  String _sanitizeFileName(String title) {
    return title.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
  }

  void _exportPack(BuildContext context, OrderPack pack) {
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
              const Text('Export as a standalone .orderpack file. You can optionally protect it with a password:'),
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
                    content: Text('Pack copied to clipboard!'),
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
                  final defaultFileName = '${_sanitizeFileName(pack.title)}.orderpack';
                  final savedUri = await FilePicker.saveFile(
                    dialogTitle: 'Save Order Pack File',
                    fileName: defaultFileName,
                    bytes: utf8.encode(output),
                    type: FileType.custom,
                    allowedExtensions: ['orderpack', 'json'],
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

  void _importFromFile(BuildContext context) async {
    final engine = Provider.of<OrderEngine>(context, listen: false);

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['orderpack', 'json', 'txt'],
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

  void _processImportData(BuildContext context, OrderEngine engine, String raw) {
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) {
        final pack = OrderPack.fromJson(parsed);
        engine.addPack(pack);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imported "${pack.title}" (${pack.orders.length} orders)!'),
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
          title: const Text('Encrypted Pack'),
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
                  final pack = OrderPack.fromJson(parsed);
                  engine.addPack(pack);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Decrypted & imported "${pack.title}" (${pack.orders.length} orders)!'),
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
              child: const Text('Decrypt & Import'),
            ),
          ],
        );
      },
    );
  }

  void _showImportDialog(BuildContext context) {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final dataCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Import Order Pack'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.file_open_rounded),
                  label: const Text('Pick .orderpack / .json File'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 44),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _importFromFile(context);
                  },
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        'OR PASTE RAW DATA',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'Paste Pack Data / JSON',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: dataCtrl,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'Paste copied JSON or encrypted text string...',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final raw = dataCtrl.text.trim();
                if (raw.isEmpty) return;
                Navigator.pop(ctx);
                _processImportData(context, engine, raw);
              },
              child: const Text('Import Text'),
            ),
          ],
        );
      },
    );
  }

  void _dispatchOrder(BuildContext context, OrderItem order) {
    final sync = Provider.of<SyncService>(context, listen: false);
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);

    final target = partnerSvc.activePartner ??
        (partnerSvc.unblockedContacts.isNotEmpty ? partnerSvc.unblockedContacts.first : null);

    sync.dispatchOrderToPlayer(order, targetPartner: target);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(target != null
            ? 'Dispatched "${order.title}" to ${target.displayName}!'
            : 'Dispatched "${order.title}"!'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _sendPackViaChat(BuildContext context, OrderPack pack) {
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);
    final contacts = partnerSvc.unblockedContacts;

    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No paired partners found to send pack.')),
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
              const Icon(Icons.send_rounded, color: Colors.cyanAccent),
              const SizedBox(width: 10),
              Expanded(child: Text('Send "${pack.title}" in Chat', overflow: TextOverflow.ellipsis)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Send this order pack (${pack.orders.length} directives) to:'),
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
                  'Shared Order Pack: "${pack.title}" (${pack.orders.length} directives)',
                  packType: 'orderPack',
                  packTitle: pack.title,
                  packItemCount: pack.orders.length,
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

  @override
  Widget build(BuildContext context) {
    final engine = Provider.of<OrderEngine>(context);
    final packs = engine.packs;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Order Packs & Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.send_rounded),
            tooltip: 'Dispatch Tasks Hub',
            onPressed: () => OrderDispatchDialog.show(context),
          ),
          IconButton(
            icon: const Icon(Icons.file_open_outlined),
            tooltip: 'Import from File (.orderpack)',
            onPressed: () => _importFromFile(context),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Create Pack',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PackStudioView()),
              );
            },
          ),
        ],
      ),
      body: packs.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_open_rounded, size: 64, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                  const SizedBox(height: 12),
                  const Text('No Order Packs Installed'),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: packs.length,
              itemBuilder: (context, index) {
                final pack = packs[index];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: ExpansionTile(
                    shape: const Border(),
                    collapsedShape: const Border(),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    title: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                pack.title,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'By ${pack.author} • ${pack.orders.length} Directives',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: pack.isEnabled,
                          onChanged: (_) => engine.togglePackEnabled(pack.id),
                        ),
                      ],
                    ),
                    subtitle: pack.description.isNotEmpty
                        ? Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              pack.description,
                              style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.8)),
                            ),
                          )
                        : null,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Action toolbar for pack
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'DIRECTIVES IN THIS PACK (${pack.orders.length})',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.1,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                                Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.send_rounded, size: 18, color: Colors.cyanAccent),
                                      tooltip: 'Send Pack via Chat',
                                      onPressed: () => _sendPackViaChat(context, pack),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.file_download_outlined, size: 20),
                                      tooltip: 'Export to File (.orderpack)',
                                      onPressed: () => _exportPack(context, pack),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.edit_outlined, size: 20),
                                      tooltip: 'Edit Pack in Studio',
                                      onPressed: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => PackStudioView(existingPack: pack),
                                          ),
                                        );
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                                      tooltip: 'Delete Pack',
                                      onPressed: () => engine.deletePack(pack.id),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const Divider(height: 16),

                            // List of directives inside pack
                            ...pack.orders.map((order) {
                              return Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: order.allowRandomDraw
                                      ? theme.colorScheme.surfaceVariant.withOpacity(0.2)
                                      : theme.colorScheme.surfaceVariant.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: order.allowRandomDraw
                                        ? theme.colorScheme.outlineVariant.withOpacity(0.2)
                                        : theme.colorScheme.outlineVariant.withOpacity(0.1),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.amber.withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'T${order.tier}',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.amber,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            order.title,
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13,
                                              color: order.allowRandomDraw ? null : theme.colorScheme.onSurface.withOpacity(0.6),
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Wrap(
                                            crossAxisAlignment: WrapCrossAlignment.center,
                                            spacing: 6,
                                            children: [
                                              Text(
                                                '${order.formattedTiming} • +${order.rewardTokens} / -${order.penaltyTokens} Tok',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                                                ),
                                              ),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                decoration: BoxDecoration(
                                                  color: order.allowRandomDraw
                                                      ? Colors.cyanAccent.withOpacity(0.15)
                                                      : Colors.grey.withOpacity(0.15),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      order.allowRandomDraw ? Icons.casino_rounded : Icons.lock_clock_rounded,
                                                      size: 10,
                                                      color: order.allowRandomDraw ? Colors.cyanAccent : Colors.grey,
                                                    ),
                                                    const SizedBox(width: 3),
                                                    Text(
                                                      order.allowRandomDraw ? 'Random Pool' : 'Manual Only',
                                                      style: TextStyle(
                                                        fontSize: 9,
                                                        fontWeight: FontWeight.bold,
                                                        color: order.allowRandomDraw ? Colors.cyanAccent : Colors.grey,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Tooltip(
                                      message: order.allowRandomDraw
                                          ? 'Random Draw: Enabled (Tap to exclude from random draws)'
                                          : 'Random Draw: Disabled (Tap to include in random draws)',
                                      child: Switch(
                                        value: order.allowRandomDraw,
                                        activeColor: Colors.cyanAccent,
                                        onChanged: (_) {
                                          engine.toggleOrderRandomDraw(pack.id, order.id);
                                        },
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.edit_note_rounded, size: 20),
                                      tooltip: 'Customize & Dispatch',
                                      onPressed: () => OrderDispatchDialog.show(context, initialOrder: order),
                                    ),
                                    ElevatedButton.icon(
                                      icon: const Icon(Icons.send_rounded, size: 14),
                                      label: const Text('Dispatch', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: theme.colorScheme.primary,
                                        foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        minimumSize: Size.zero,
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      onPressed: () => _dispatchOrder(context, order),
                                    ),
                                  ],
                                ),
                              );
                            }),
                            const SizedBox(height: 6),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
