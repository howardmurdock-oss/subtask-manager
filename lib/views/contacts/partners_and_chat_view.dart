import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/partner_service.dart';
import '../messenger/messenger_inbox_view.dart';
import 'partner_directory_view.dart';

/// Partners and conversations in one panel.
///
/// These were two separate destinations for a director and one for a player,
/// which made the same two things look like different features depending on
/// which side you were on. They are the same subject: who you are connected
/// to, and what you are saying to them.
class PartnersAndChatView extends StatefulWidget {
  const PartnersAndChatView({super.key});

  @override
  State<PartnersAndChatView> createState() => _PartnersAndChatViewState();
}

class _PartnersAndChatViewState extends State<PartnersAndChatView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final partnerSvc = Provider.of<PartnerService>(context);
    final pending = partnerSvc.pendingRequests.length;
    final unread = partnerSvc.totalUnreadCount;

    Widget tab(String label, IconData icon, int count, Color badgeColor) => Tab(
          icon: count > 0
              ? Badge.count(
                  count: count,
                  backgroundColor: badgeColor,
                  textColor: badgeColor == Colors.amber ? Colors.black : null,
                  child: Icon(icon),
                )
              : Icon(icon),
          text: label,
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            tooltip: 'Add Partner',
            icon: const Icon(Icons.person_add_rounded),
            onPressed: () => PartnerDirectoryView.showAddPartner(context),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            tab('Partners', Icons.group_rounded, pending, Colors.amber),
            tab('Chat', Icons.forum_rounded, unread,
                Theme.of(context).colorScheme.primary),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          const PartnerDirectoryView(embedded: true),
          MessengerInboxView(
            embedded: true,
            // Anything that used to open the directory as its own page now
            // moves to the tab beside it.
            onOpenPartners: () => _tabs.animateTo(0),
          ),
        ],
      ),
    );
  }
}
