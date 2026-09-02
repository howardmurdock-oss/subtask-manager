import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/partner_contact.dart';
import '../../services/partner_service.dart';
import '../../services/chat_service.dart';
import 'chat_conversation_view.dart';
import '../contacts/partner_directory_view.dart';

class MessengerInboxView extends StatefulWidget {
  const MessengerInboxView({super.key});

  @override
  State<MessengerInboxView> createState() => _MessengerInboxViewState();
}

class _MessengerInboxViewState extends State<MessengerInboxView> {
  String _filter = 'all'; // 'all', 'active', 'blocked'

  String _formatRelativeTime(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) {
      final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
      final min = dt.minute.toString().padLeft(2, '0');
      final p = dt.hour >= 12 ? 'PM' : 'AM';
      return '$hour:$min $p';
    }
    return '${dt.month}/${dt.day}';
  }

  @override
  Widget build(BuildContext context) {
    final partnerSvc = Provider.of<PartnerService>(context);
    final chat = Provider.of<ChatService>(context);
    final theme = Theme.of(context);

    var contacts = partnerSvc.contacts;
    if (_filter == 'active') {
      contacts = partnerSvc.unblockedContacts;
    } else if (_filter == 'blocked') {
      contacts = partnerSvc.blockedContacts;
    }

    final pendingCount = partnerSvc.pendingRequests.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Encrypted Direct Messenger'),
        actions: [
          IconButton(
            tooltip: 'Partner Contacts Directory',
            icon: pendingCount > 0
                ? Badge.count(
                    count: pendingCount,
                    backgroundColor: Colors.amber,
                    textColor: Colors.black,
                    child: const Icon(Icons.people_alt_outlined),
                  )
                : const Icon(Icons.people_alt_outlined),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PartnerDirectoryView()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Pending Connection Requests Notification Banner
          if (pendingCount > 0)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.person_add_alt_1_rounded, color: Colors.amber, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$pendingCount Pending Connection Request${pendingCount > 1 ? "s" : ""}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'A partner wants to pair and sync with you',
                          style: TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber,
                      foregroundColor: Colors.black,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const PartnerDirectoryView()),
                      );
                    },
                    child: const Text('VIEW', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ],
              ),
            ),

          // Filter Chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                ChoiceChip(
                  label: Text('All (${partnerSvc.contacts.length})'),
                  selected: _filter == 'all',
                  onSelected: (sel) => setState(() => _filter = 'all'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text('Active (${partnerSvc.unblockedContacts.length})'),
                  selected: _filter == 'active',
                  onSelected: (sel) => setState(() => _filter = 'active'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text('Blocked (${partnerSvc.blockedContacts.length})'),
                  selected: _filter == 'blocked',
                  onSelected: (sel) => setState(() => _filter = 'blocked'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Conversation List
          Expanded(
            child: contacts.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chat_bubble_outline_rounded, size: 64, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                        const SizedBox(height: 12),
                        Text(
                          _filter == 'blocked' ? 'No blocked contacts' : 'No Messenger Conversations',
                          style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _filter == 'blocked'
                              ? 'Blocked contacts will appear here'
                              : 'Add a partner in the contacts hub to begin',
                          style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                        ),
                        const SizedBox(height: 16),
                        if (_filter != 'blocked')
                          ElevatedButton.icon(
                            icon: const Icon(Icons.person_add_rounded, size: 18),
                            label: const Text('Add / Pair Partner'),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => const PartnerDirectoryView()),
                              );
                            },
                          ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: contacts.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 70),
                    itemBuilder: (context, index) {
                      final partner = contacts[index];
                      final lastMsg = chat.getLastMessage(partner.id);

                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        leading: Stack(
                          children: [
                            CircleAvatar(
                              radius: 24,
                              backgroundColor: partner.isBlocked
                                  ? Colors.redAccent.withOpacity(0.2)
                                  : theme.colorScheme.primary.withOpacity(0.2),
                              child: Icon(
                                partner.isBlocked
                                    ? Icons.block_rounded
                                    : (partner.role == PartnerRole.dominant ? Icons.lock_person_rounded : Icons.person_rounded),
                                color: partner.isBlocked ? Colors.redAccent : theme.colorScheme.primary,
                              ),
                            ),
                            if (partner.unreadCount > 0 && !partner.isBlocked)
                              Positioned(
                                right: 0,
                                top: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: const BoxDecoration(
                                    color: Colors.purpleAccent,
                                    shape: BoxShape.circle,
                                  ),
                                  constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                                  child: Text(
                                    '${partner.unreadCount}',
                                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                partner.displayName,
                                style: TextStyle(
                                  fontWeight: partner.unreadCount > 0 ? FontWeight.bold : FontWeight.w600,
                                  fontSize: 15,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (lastMsg != null)
                              Text(
                                _formatRelativeTime(lastMsg.timestamp),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: partner.unreadCount > 0 ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.5),
                                  fontWeight: partner.unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                          ],
                        ),
                        subtitle: Row(
                          children: [
                            if (partner.isBlocked)
                              Container(
                                margin: const EdgeInsets.only(right: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'BLOCKED',
                                  style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              )
                            else
                              Container(
                                margin: const EdgeInsets.only(right: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  partner.role.name.toUpperCase(),
                                  style: TextStyle(color: theme.colorScheme.primary, fontSize: 9, fontWeight: FontWeight.bold),
                                ),
                              ),
                            Expanded(
                              child: Text(
                                lastMsg != null
                                    ? (lastMsg.imageBase64 != null && lastMsg.text.isEmpty ? '📷 [Photo proof attachment]' : lastMsg.text)
                                    : 'Tap to start encrypted conversation',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: partner.unreadCount > 0
                                      ? theme.colorScheme.onSurface
                                      : theme.colorScheme.onSurface.withOpacity(0.6),
                                  fontWeight: partner.unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatConversationView(partner: partner),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_comment_rounded),
        label: const Text('New Chat / Contact'),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PartnerDirectoryView()),
          );
        },
      ),
    );
  }
}
