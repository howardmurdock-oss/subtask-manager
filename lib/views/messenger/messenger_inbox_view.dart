import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/partner_contact.dart';
import '../../models/chastity_timer.dart';
import '../../services/partner_service.dart';
import '../../services/chat_service.dart';
import '../../services/chastity_timer_service.dart';
import 'chat_conversation_view.dart';
import 'profile_chat_conversation_view.dart';
import '../contacts/partner_directory_view.dart';
import '../chastity_timer/timer_profile_view.dart';

class MessengerInboxView extends StatefulWidget {
  const MessengerInboxView({super.key, this.embedded = false, this.onOpenPartners});

  /// When embedded, this is one tab of the Partners & Chat panel: the panel
  /// owns the scaffold, and anything that used to open the partner directory
  /// as a separate page switches to the sibling tab instead.
  final bool embedded;
  final VoidCallback? onOpenPartners;

  @override
  State<MessengerInboxView> createState() => _MessengerInboxViewState();
}

class _MessengerInboxViewState extends State<MessengerInboxView> {
  String _filter = 'all'; // 'all', 'partners', 'visitors', 'blocked'
  List<ProfileChatThread> _visitorThreads = [];

  ChastityTimerService? _getTimers(BuildContext context, {bool listen = false}) {
    try {
      return Provider.of<ChastityTimerService>(context, listen: listen);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadVisitorChats());
  }

  Future<void> _loadVisitorChats() async {
    final timers = _getTimers(context, listen: false);
    if (timers == null || timers.profile == null) return;
    final threads = await timers.fetchProfileChatThreads();
    if (mounted) {
      setState(() {
        _visitorThreads = threads;
      });
    }
  }

  void _openPartners() {
    if (widget.onOpenPartners != null) {
      widget.onOpenPartners!();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PartnerDirectoryView()),
    );
  }

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

  Widget _buildSectionHeader(String title, ThemeData theme, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      color: theme.colorScheme.surface,
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
          ],
          Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVisitorThreadTile(ProfileChatThread thread, ThemeData theme) {
    final timers = _getTimers(context, listen: false);
    final isBlocked = thread.isBlocked || (timers?.isVisitorBlocked(thread.visitorId) ?? false);
    final hasUnread = thread.hasUnread && !isBlocked;
    final timeStr = _formatRelativeTime(thread.lastMessageAt);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: isBlocked
                ? Colors.redAccent.withValues(alpha: 0.2)
                : (hasUnread
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest),
            child: Icon(
              isBlocked ? Icons.block_rounded : Icons.public_rounded,
              color: isBlocked
                  ? Colors.redAccent
                  : (hasUnread
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant),
            ),
          ),
          if (hasUnread)
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
                  '${thread.unreadCount}',
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
              thread.visitorName,
              style: TextStyle(
                fontWeight: hasUnread ? FontWeight.bold : FontWeight.w600,
                fontSize: 15,
                color: isBlocked ? Colors.redAccent : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (timeStr.isNotEmpty)
            Text(
              timeStr,
              style: TextStyle(
                fontSize: 11,
                color: hasUnread ? theme.colorScheme.primary : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
              ),
            ),
        ],
      ),
      subtitle: Row(
        children: [
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: isBlocked
                  ? Colors.redAccent.withValues(alpha: 0.15)
                  : theme.colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              isBlocked ? 'BLOCKED' : 'VISITOR',
              style: TextStyle(
                color: isBlocked ? Colors.redAccent : theme.colorScheme.primary,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text(
              thread.lastMessage.isNotEmpty ? thread.lastMessage : 'Tap to open chat',
              style: TextStyle(
                fontSize: 13,
                color: hasUnread
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontWeight: hasUnread ? FontWeight.w600 : FontWeight.normal,
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
            builder: (_) => ProfileChatConversationView(thread: thread),
          ),
        ).then((_) => _loadVisitorChats());
      },
    );
  }

  Widget _buildPartnerTile(PartnerContact partner, ChatService? chat, ThemeData theme) {
    final lastMsg = chat?.getLastMessage(partner.id);
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
                  ? (lastMsg.imageBase64 != null && lastMsg.text.isEmpty ? '📷 [Photo attachment]' : lastMsg.text)
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
  }

  @override
  Widget build(BuildContext context) {
    final partnerSvc = Provider.of<PartnerService>(context);
    ChatService? chat;
    try {
      chat = Provider.of<ChatService>(context);
    } catch (_) {}
    final timers = _getTimers(context, listen: true);
    final theme = Theme.of(context);

    final unblockedPartners = partnerSvc.unblockedContacts;
    final blockedPartners = partnerSvc.blockedContacts;
    final hasProfile = timers?.profile != null;
    final unblockedVisitors = timers == null
        ? _visitorThreads
        : _visitorThreads.where((t) => !timers.isVisitorBlocked(t.visitorId)).toList();
    final blockedVisitors = timers == null
        ? <ProfileChatThread>[]
        : _visitorThreads.where((t) => timers.isVisitorBlocked(t.visitorId)).toList();
    final totalVisitorUnread = unblockedVisitors.fold<int>(0, (sum, t) => sum + t.unreadCount);
    final allCount = unblockedPartners.length + unblockedVisitors.length;
    final blockedTotalCount = blockedPartners.length + blockedVisitors.length;
    final pendingCount = partnerSvc.pendingRequests.length;

    final body = Column(
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
                  onPressed: _openPartners,
                  child: const Text('VIEW', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            ),
          ),

        // Filter Chips
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: Text('All ($allCount)'),
                  selected: _filter == 'all',
                  onSelected: (sel) => setState(() => _filter = 'all'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text('Partners (${unblockedPartners.length})'),
                  selected: _filter == 'partners' || _filter == 'active',
                  onSelected: (sel) => setState(() => _filter = 'partners'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  avatar: totalVisitorUnread > 0
                      ? Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.purpleAccent,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '$totalVisitorUnread',
                            style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                          ),
                        )
                      : null,
                  label: Text('Visitors (${unblockedVisitors.length})'),
                  selected: _filter == 'visitors',
                  onSelected: (sel) => setState(() => _filter = 'visitors'),
                ),
                if (blockedTotalCount > 0 || _filter == 'blocked') ...[
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text('Blocked ($blockedTotalCount)'),
                    selected: _filter == 'blocked',
                    onSelected: (sel) => setState(() => _filter = 'blocked'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 1),

        // Conversation List
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadVisitorChats,
            child: Builder(
              builder: (context) {
                // Filter: Visitors only
                if (_filter == 'visitors') {
                  final allowMessages = timers?.profile?.acceptMessages ?? false;
                  return ListView(
                    padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 16),
                    children: [
                      if (hasProfile)
                        Card(
                          margin: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                          elevation: 0,
                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                            ),
                          ),
                          child: SwitchListTile(
                            secondary: Icon(
                              allowMessages ? Icons.mark_email_read_rounded : Icons.mark_email_unread_rounded,
                              color: allowMessages ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                            ),
                            value: allowMessages,
                            onChanged: (on) async {
                              await timers!.updateProfile(acceptMessages: on);
                            },
                            title: const Text('Allow visitor messages', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                            subtitle: Text(
                              allowMessages
                                  ? 'Visitors can chat with you on your public page'
                                  : 'Visitor messaging is currently turned off',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        )
                      else
                        Card(
                          margin: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.public_rounded, color: theme.colorScheme.primary),
                                    const SizedBox(width: 8),
                                    const Text('Public Profile Page', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  'Set up a public page to let visitors start conversations with you.',
                                  style: TextStyle(fontSize: 12),
                                ),
                                const SizedBox(height: 12),
                                FilledButton.tonalIcon(
                                  icon: const Icon(Icons.person_outline_rounded, size: 16),
                                  label: const Text('Set Up Public Page'),
                                  onPressed: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(builder: (_) => const TimerProfileView()),
                                    ).then((_) => _loadVisitorChats());
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (unblockedVisitors.isEmpty) ...[
                        SizedBox(height: MediaQuery.of(context).size.height * 0.12),
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                allowMessages ? Icons.forum_outlined : Icons.public_off_rounded,
                                size: 64,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No Visitor Chats Yet',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                allowMessages
                                    ? 'Visitors to your public profile will appear here'
                                    : 'Enable "Allow visitor messages" above to receive chats',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        ...unblockedVisitors.map((t) => Column(
                              children: [
                                _buildVisitorThreadTile(t, theme),
                                const Divider(height: 1, indent: 70),
                              ],
                            )),
                      ],
                    ],
                  );
                }

                // Filter: Blocked only
                if (_filter == 'blocked') {
                  if (blockedPartners.isEmpty && blockedVisitors.isEmpty) {
                    return ListView(
                      children: [
                        SizedBox(height: MediaQuery.of(context).size.height * 0.15),
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.block_rounded, size: 64, color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
                              const SizedBox(height: 12),
                              Text(
                                'No Blocked Contacts',
                                style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  }
                  return ListView(
                    padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 16),
                    children: [
                      if (blockedVisitors.isNotEmpty) ...[
                        _buildSectionHeader('BLOCKED VISITORS (${blockedVisitors.length})', theme, icon: Icons.public_off_rounded),
                        ...blockedVisitors.map((v) => Column(
                              children: [
                                _buildVisitorThreadTile(v, theme),
                                const Divider(height: 1, indent: 70),
                              ],
                            )),
                        const SizedBox(height: 8),
                      ],
                      if (blockedPartners.isNotEmpty) ...[
                        _buildSectionHeader('BLOCKED PARTNERS (${blockedPartners.length})', theme, icon: Icons.block_rounded),
                        ...blockedPartners.map((p) => Column(
                              children: [
                                _buildPartnerTile(p, chat, theme),
                                const Divider(height: 1, indent: 70),
                              ],
                            )),
                      ],
                    ],
                  );
                }

                // Filter: Partners only
                if (_filter == 'partners' || _filter == 'active') {
                  if (unblockedPartners.isEmpty) {
                    return ListView(
                      children: [
                        SizedBox(height: MediaQuery.of(context).size.height * 0.15),
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.people_outline_rounded, size: 64, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                              const SizedBox(height: 12),
                              Text(
                                'No Partner Conversations',
                                style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Pair with a partner in the contacts hub to begin',
                                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                              ),
                              const SizedBox(height: 16),
                              ElevatedButton.icon(
                                icon: const Icon(Icons.person_add_rounded, size: 18),
                                label: const Text('Add / Pair Partner'),
                                onPressed: _openPartners,
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  }
                  return ListView.separated(
                    padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 16),
                    itemCount: unblockedPartners.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 70),
                    itemBuilder: (_, i) => _buildPartnerTile(unblockedPartners[i], chat, theme),
                  );
                }

                // Filter: All
                if (unblockedVisitors.isEmpty && unblockedPartners.isEmpty) {
                  return ListView(
                    children: [
                      SizedBox(height: MediaQuery.of(context).size.height * 0.15),
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.chat_bubble_outline_rounded, size: 64, color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
                            const SizedBox(height: 12),
                            Text(
                              'No Active Conversations',
                              style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Pair with a partner or receive visitor chats on your public page',
                              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.person_add_rounded, size: 18),
                              label: const Text('Add / Pair Partner'),
                              onPressed: _openPartners,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }

                // If both types exist, section them
                if (unblockedVisitors.isNotEmpty && unblockedPartners.isNotEmpty) {
                  return ListView(
                    padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 16),
                    children: [
                      _buildSectionHeader('VISITOR CHATS (${unblockedVisitors.length})', theme, icon: Icons.public_rounded),
                      ...unblockedVisitors.map((t) => Column(
                            children: [
                              _buildVisitorThreadTile(t, theme),
                              const Divider(height: 1, indent: 70),
                            ],
                          )),
                      const SizedBox(height: 8),
                      _buildSectionHeader('PARTNER MESSAGES (${unblockedPartners.length})', theme, icon: Icons.group_rounded),
                      ...unblockedPartners.map((p) => Column(
                            children: [
                              _buildPartnerTile(p, chat, theme),
                              const Divider(height: 1, indent: 70),
                            ],
                          )),
                    ],
                  );
                }

                // Only visitor threads exist
                if (unblockedVisitors.isNotEmpty) {
                  return ListView(
                    padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 16),
                    children: [
                      _buildSectionHeader('VISITOR CHATS (${unblockedVisitors.length})', theme, icon: Icons.public_rounded),
                      ...unblockedVisitors.map((t) => Column(
                            children: [
                              _buildVisitorThreadTile(t, theme),
                              const Divider(height: 1, indent: 70),
                            ],
                          )),
                    ],
                  );
                }

                // Only partner contacts exist
                return ListView.separated(
                  padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 16),
                  itemCount: unblockedPartners.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 70),
                  itemBuilder: (_, i) => _buildPartnerTile(unblockedPartners[i], chat, theme),
                );
              },
            ),
          ),
        ),
      ],
    );

    if (widget.embedded) return body;

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
            onPressed: _openPartners,
          ),
        ],
      ),
      body: body,
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_comment_rounded),
        label: const Text('New Chat / Contact'),
        onPressed: _openPartners,
      ),
    );
  }
}
