import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/partner_contact.dart';
import '../../services/partner_service.dart';
import '../../services/sync_service.dart';
import '../messenger/chat_conversation_view.dart';

class PartnerDirectoryView extends StatelessWidget {
  const PartnerDirectoryView({super.key});

  void _showAddEditPartnerDialog(BuildContext context, {PartnerContact? existing}) {
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);

    final nameCtrl = TextEditingController(text: existing?.displayName ?? '');
    final codeCtrl = TextEditingController(text: existing?.pairingCode ?? '');
    final secretCtrl = TextEditingController(text: existing?.pairingSecret ?? '');
    PartnerRole role = existing?.role ?? PartnerRole.submissive;
    bool obscureSecret = true;
    bool isManualMode = existing != null;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(existing != null ? 'Edit Partner Details' : 'Add / Connect Partner'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (existing == null) ...[
                      // Guidance banner
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.25)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '1-Step Quick Pairing:',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Enter your partner\'s 8-character Pairing Code (from their Settings tab). Sending a request automatically exchanges and creates the shared encryption key!',
                                    style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8)),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    Text(
                      'Partner\'s 8-Character Pairing Code',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: codeCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        hintText: 'e.g. K8M2-9X4L',
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Partner Nickname / Alias (Optional)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        hintText: 'e.g. Primary Submissive / Master Dan',
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Partner Role',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<PartnerRole>(
                      value: role,
                      decoration: const InputDecoration(),
                      items: const [
                        DropdownMenuItem(value: PartnerRole.submissive, child: Text('Submissive / Player')),
                        DropdownMenuItem(value: PartnerRole.dominant, child: Text('Dominant / Director')),
                        DropdownMenuItem(value: PartnerRole.peer, child: Text('Peer / Partner')),
                      ],
                      onChanged: (val) {
                        if (val != null) setDialogState(() => role = val);
                      },
                    ),
                    if (existing != null || isManualMode) ...[
                      const SizedBox(height: 14),
                      Text(
                        'E2EE Shared Passphrase',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: secretCtrl,
                        obscureText: obscureSecret,
                        decoration: InputDecoration(
                          hintText: 'Shared encryption password',
                          suffixIcon: IconButton(
                            icon: Icon(obscureSecret ? Icons.visibility : Icons.visibility_off),
                            onPressed: () => setDialogState(() => obscureSecret = !obscureSecret),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    final code = codeCtrl.text.trim().toUpperCase();
                    final secret = secretCtrl.text.trim();

                    if (code.isEmpty) return;

                    if (existing != null) {
                      final updated = existing.copyWith(
                        displayName: name.isNotEmpty ? name : existing.displayName,
                        pairingCode: code,
                        pairingSecret: secret.isNotEmpty ? secret : existing.pairingSecret,
                        role: role,
                      );
                      await partnerSvc.updateContact(updated);
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Updated partner "$name"')),
                      );
                    } else {
                      await sync.sendPairingRequest(
                        targetCode: code,
                        targetName: name,
                        targetRole: role,
                      );
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Sent pairing request to $code! Awaiting acceptance...'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                  child: Text(existing != null ? 'Save Changes' : 'Send Pairing Request'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final partnerSvc = Provider.of<PartnerService>(context);
    final sync = Provider.of<SyncService>(context);
    final theme = Theme.of(context);
    final contacts = partnerSvc.contacts;
    final activeId = partnerSvc.activePartnerId;
    final pendingRequests = partnerSvc.pendingRequests;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Partner Directory & Multi-Sync Hub'),
        actions: [
          IconButton(
            tooltip: 'Add Partner',
            icon: const Icon(Icons.person_add_rounded),
            onPressed: () => _showAddEditPartnerDialog(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Incoming Pairing Requests Alert Card
          if (pendingRequests.isNotEmpty) ...[
            Card(
              color: theme.colorScheme.primary.withOpacity(0.12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.3)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.person_add_alt_1_rounded, size: 20, color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Text(
                          'INCOMING PAIRING REQUESTS (${pendingRequests.length})',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: theme.colorScheme.primary,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ...pendingRequests.map((req) => Container(
                      margin: const EdgeInsets.only(top: 6),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  req.senderName.isNotEmpty ? req.senderName : 'Partner (${req.senderCode})',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                                Text(
                                  '${req.senderRole.name.toUpperCase()} • Code: ${req.senderCode}',
                                  style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () => sync.declinePairingRequest(req),
                            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                            child: const Text('Decline'),
                          ),
                          const SizedBox(width: 6),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.check_rounded, size: 16),
                            label: const Text('Accept & Pair'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: theme.colorScheme.primary,
                              foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                            ),
                            onPressed: () async {
                              await sync.acceptPairingRequest(req);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Accepted pairing from ${req.senderName}! You are now connected.')),
                              );
                            },
                          ),
                        ],
                      ),
                    )),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
          ],

          if (contacts.isEmpty && pendingRequests.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.people_outline_rounded, size: 64, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                    const SizedBox(height: 12),
                    const Text('No Partners Added Yet', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 6),
                    Text(
                      'Add multiple submissives or dominants to manage and message',
                      style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.person_add_rounded),
                      label: const Text('Connect with Partner'),
                      onPressed: () => _showAddEditPartnerDialog(context),
                    ),
                  ],
                ),
              ),
            )
          else
            ...contacts.map((partner) {
              final isActive = partner.id == activeId;

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: isActive
                        ? theme.colorScheme.primary.withOpacity(0.6)
                        : (partner.isBlocked ? Colors.redAccent.withOpacity(0.4) : Colors.transparent),
                    width: isActive ? 1.5 : 1.0,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 20,
                            backgroundColor: partner.isBlocked
                                ? Colors.redAccent.withOpacity(0.2)
                                : theme.colorScheme.primary.withOpacity(0.2),
                            child: Icon(
                              partner.isBlocked
                                  ? Icons.block_rounded
                                  : (partner.role == PartnerRole.dominant
                                      ? Icons.lock_person_rounded
                                      : Icons.person_rounded),
                              color: partner.isBlocked ? Colors.redAccent : theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      partner.displayName,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                    ),
                                    if (isActive) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.greenAccent.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          'ACTIVE SYNC',
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.greenAccent[400],
                                          ),
                                        ),
                                      ),
                                    ],
                                    if (partner.isBlocked) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.redAccent.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: const Text(
                                          'BLOCKED',
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.redAccent,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${partner.role.name.toUpperCase()} • Code: ${partner.pairingCode}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuButton<String>(
                            onSelected: (val) {
                              if (val == 'edit') {
                                _showAddEditPartnerDialog(context, existing: partner);
                              } else if (val == 'block') {
                                partnerSvc.toggleBlock(partner.id);
                              } else if (val == 'delete') {
                                partnerSvc.deleteContact(partner.id);
                              }
                            },
                            itemBuilder: (ctx) => [
                              const PopupMenuItem(value: 'edit', child: Text('Edit Partner Details')),
                              PopupMenuItem(
                                value: 'block',
                                child: Text(partner.isBlocked ? 'Unblock Contact' : 'Block Contact'),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete Contact', style: TextStyle(color: Colors.redAccent)),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          if (!isActive && !partner.isBlocked)
                            OutlinedButton.icon(
                              icon: const Icon(Icons.sync_alt_rounded, size: 16),
                              label: const Text('Switch Active Sync', style: TextStyle(fontSize: 12)),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              onPressed: () async {
                                await partnerSvc.setActivePartner(partner.id);
                                await sync.switchActivePartner(partner);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Switched active sync to ${partner.displayName}'),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              },
                            ),
                          const Spacer(),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                            label: const Text('Open Chat', style: TextStyle(fontSize: 12)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: theme.colorScheme.primary,
                              foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ChatConversationView(partner: partner),
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
        ],
      ),
    );
  }
}
