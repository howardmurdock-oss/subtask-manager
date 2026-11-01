import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chastity_timer.dart';
import '../../services/public_visitor_service.dart';

/// A full two-way chat view for a visitor talking to a profile owner in-app.
class VisitorProfileChatView extends StatefulWidget {
  const VisitorProfileChatView({
    super.key,
    required this.publicId,
    this.profileName,
  });

  final String publicId;
  final String? profileName;

  @override
  State<VisitorProfileChatView> createState() => _VisitorProfileChatViewState();
}

class _VisitorProfileChatViewState extends State<VisitorProfileChatView> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _nickController = TextEditingController();

  List<ProfileChatMessage> _messages = const [];
  bool _loading = true;
  bool _sending = false;
  Timer? _poll;
  bool _editingNick = false;

  PublicVisitorService get _visitor => Provider.of<PublicVisitorService>(context, listen: false);

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
    _nickController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final msgs = await _visitor.fetchProfileChatMessages(widget.publicId);
    if (!mounted) return;
    setState(() {
      _messages = msgs;
      _loading = false;
    });
    _scrollToBottom();
  }

  Future<void> _refreshQuietly() async {
    final msgs = await _visitor.fetchProfileChatMessages(widget.publicId);
    if (!mounted) return;
    if (msgs.length != _messages.length || (msgs.isNotEmpty && _messages.isNotEmpty && msgs.last.id != _messages.last.id)) {
      setState(() => _messages = msgs);
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _sending) return;

    final nick = _visitor.chatNickname?.trim();
    if (nick == null || nick.isEmpty) {
      setState(() => _editingNick = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please choose a nickname to chat.')),
      );
      return;
    }

    setState(() => _sending = true);
    final response = await _visitor.sendProfileChatMessage(
      widget.publicId,
      text: text,
      senderName: nick,
    );
    if (!mounted) return;
    setState(() => _sending = false);

    if (response.ok) {
      _textController.clear();
      await _load();
    } else {
      final err = response.error ?? 'Failed to send message';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err == 'messages-off' ? 'This profile is not accepting messages.' : 'Could not send: $err')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visitor = Provider.of<PublicVisitorService>(context);
    final currentNick = visitor.chatNickname ?? '';
    final hasNick = currentNick.isNotEmpty;
    final title = widget.profileName != null ? 'Chat with ${widget.profileName}' : 'Profile Chat';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Nickname banner / editor
            if (!hasNick || _editingNick)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _nickController..text = _editingNick ? _nickController.text : currentNick,
                        decoration: const InputDecoration(
                          labelText: 'Your nickname',
                          hintText: 'e.g. SecretAdmirer',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        maxLength: 30,
                        buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                        onSubmitted: (val) async {
                          if (val.trim().isNotEmpty) {
                            await visitor.setChatNickname(val.trim());
                            if (mounted) setState(() => _editingNick = false);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () async {
                        final val = _nickController.text.trim();
                        if (val.isNotEmpty) {
                          await visitor.setChatNickname(val);
                          if (mounted) setState(() => _editingNick = false);
                        }
                      },
                      child: const Text('Save'),
                    ),
                    if (_editingNick && hasNick) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() => _editingNick = false),
                      ),
                    ],
                  ],
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                child: Row(
                  children: [
                    Icon(Icons.person_rounded, size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      'Chatting as ',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    Text(
                      currentNick,
                      style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () {
                        _nickController.text = currentNick;
                        setState(() => _editingNick = true);
                      },
                      child: const Text('Change'),
                    ),
                  ],
                ),
              ),

            // Chat messages
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _messages.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.chat_bubble_outline_rounded,
                                  size: 48, color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
                              const SizedBox(height: 12),
                              Text(
                                'No messages yet.',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Say hello to ${widget.profileName ?? 'them'}!',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          itemCount: _messages.length,
                          itemBuilder: (context, i) {
                            final m = _messages[i];
                            final isYou = m.isFromVisitor;
                            final timeStr =
                                '${m.createdAt.hour.toString().padLeft(2, '0')}:${m.createdAt.minute.toString().padLeft(2, '0')}';
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
                                          isYou
                                              ? (m.senderName.isNotEmpty ? m.senderName : 'You')
                                              : (m.senderName.isNotEmpty
                                                  ? m.senderName
                                                  : (widget.profileName ?? 'Host')),
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
                                    Text(
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

            // Bottom Input bar
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
                      decoration: const InputDecoration(
                        hintText: 'Type a message…',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      maxLines: 4,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton.filled(
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send_rounded, size: 20),
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
