import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/chastity_timer.dart';
import '../../services/chastity_timer_service.dart';

/// Full conversation view for the profile owner talking to a public page visitor.
class ProfileChatConversationView extends StatefulWidget {
  const ProfileChatConversationView({
    super.key,
    required this.thread,
    this.timers,
  });

  final ProfileChatThread thread;
  final ChastityTimerService? timers;

  @override
  State<ProfileChatConversationView> createState() => _ProfileChatConversationViewState();
}

class _ProfileChatConversationViewState extends State<ProfileChatConversationView> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  List<ProfileChatMessage> _messages = const [];
  bool _loading = true;
  bool _sending = false;
  Timer? _poll;

  ChastityTimerService get _timers =>
      widget.timers ?? Provider.of<ChastityTimerService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _refreshQuietly();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final msgs = await _timers.fetchProfileChatMessages(widget.thread.visitorId);
    if (!mounted) return;
    setState(() {
      _messages = msgs;
      _loading = false;
    });
    _scrollToBottom();
  }

  Future<void> _refreshQuietly() async {
    final msgs = await _timers.fetchProfileChatMessages(widget.thread.visitorId);
    if (!mounted) return;
    if (msgs.length != _messages.length ||
        (msgs.isNotEmpty && _messages.isNotEmpty && msgs.last.id != _messages.last.id)) {
      setState(() => _messages = msgs);
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final error = await _timers.sendProfileChatReply(widget.thread.visitorId, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (error == null) {
      _textController.clear();
      await _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send: $error')),
      );
    }
  }

  Future<void> _confirmDelete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: Text('Delete all messages with ${widget.thread.visitorName}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _timers.deleteProfileChatThread(widget.thread.visitorId);
      if (mounted) Navigator.pop(context, true);
    }
  }

  Future<void> _toggleBlock() async {
    final currentlyBlocked = _timers.isVisitorBlocked(widget.thread.visitorId);
    if (!currentlyBlocked) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Block user?'),
          content: Text(
            'Block ${widget.thread.visitorName}? They will no longer be able to message you or send orders from your public page.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Block'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }
    final nowBlocked = await _timers.toggleBlockVisitor(widget.thread.visitorId);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(nowBlocked
            ? 'Blocked ${widget.thread.visitorName}'
            : 'Unblocked ${widget.thread.visitorName}'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isBlocked = _timers.isVisitorBlocked(widget.thread.visitorId);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.thread.visitorName),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: isBlocked
                        ? Colors.redAccent.withValues(alpha: 0.15)
                        : theme.colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    isBlocked ? 'BLOCKED' : 'VISITOR',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: isBlocked ? Colors.redAccent : theme.colorScheme.primary,
                    ),
                  ),
                ),
                Text(
                  'Public Page Chat',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu_rounded),
            tooltip: 'Menu',
            onSelected: (val) {
              if (val == 'delete') {
                _confirmDelete();
              } else if (val == 'block') {
                _toggleBlock();
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline_rounded, size: 18, color: theme.colorScheme.error),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Delete chat',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'block',
                child: Row(
                  children: [
                    Icon(
                      isBlocked ? Icons.lock_open_rounded : Icons.block_rounded,
                      size: 18,
                      color: isBlocked ? Colors.greenAccent : Colors.redAccent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isBlocked ? 'Unblock user' : 'Block user',
                        style: TextStyle(
                          color: isBlocked ? Colors.greenAccent : Colors.redAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (isBlocked)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: Colors.redAccent.withValues(alpha: 0.15),
                child: Row(
                  children: [
                    const Icon(Icons.block_rounded, color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'This user is blocked. New messages from them are suppressed.',
                        style: TextStyle(fontSize: 12, color: Colors.redAccent),
                      ),
                    ),
                    TextButton(
                      onPressed: _toggleBlock,
                      child: const Text('UNBLOCK', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _messages.isEmpty
                      ? const Center(child: Text('No messages yet in this conversation.'))
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          itemCount: _messages.length,
                          itemBuilder: (context, i) {
                            final m = _messages[i];
                            final isYou = m.isFromPlayer;
                            final timeStr = DateFormat.jm().format(m.createdAt);
                            return Align(
                              alignment: isYou ? Alignment.centerRight : Alignment.centerLeft,
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isYou
                                      ? theme.colorScheme.primaryContainer
                                      : theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(16),
                                    topRight: const Radius.circular(16),
                                    bottomLeft: Radius.circular(isYou ? 16 : 3),
                                    bottomRight: Radius.circular(isYou ? 3 : 16),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: isYou ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          isYou ? 'You' : m.senderName,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: isYou
                                                ? theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.8)
                                                : theme.colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          timeStr,
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: isYou
                                                ? theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.6)
                                                : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    SelectableText(
                                      m.text,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: isYou
                                            ? theme.colorScheme.onPrimaryContainer
                                            : theme.colorScheme.onSurface,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
            if (isBlocked)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3))),
                ),
                child: Center(
                  child: Text(
                    'User is blocked. Unblock from the menu to send a reply.',
                    style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                  ),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        textCapitalization: TextCapitalization.sentences,
                        maxLines: 4,
                        minLines: 1,
                        decoration: const InputDecoration(
                          hintText: 'Type a reply…',
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    IconButton(
                      icon: _sending
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send_rounded),
                      color: theme.colorScheme.primary,
                      onPressed: _sending ? null : _send,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
