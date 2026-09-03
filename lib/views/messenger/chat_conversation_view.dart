import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/partner_contact.dart';
import '../../models/chat_message.dart';
import '../../models/order_pack.dart';
import '../../models/reward_pack.dart';
import '../../models/quest_pack.dart';
import '../../models/quest_item.dart';
import '../../services/chat_service.dart';
import '../../services/partner_service.dart';
import '../../services/sync_service.dart';
import '../../services/order_engine.dart';
import '../../services/quest_service.dart';
import '../../core/security/encryption_helper.dart';
import '../../core/utils/image_compressor.dart';
import '../../widgets/draggable_dialog.dart';
import '../../widgets/linkable_text.dart';

class ChatConversationView extends StatefulWidget {
  final PartnerContact partner;

  const ChatConversationView({super.key, required this.partner});

  @override
  State<ChatConversationView> createState() => _ChatConversationViewState();
}

class _ChatConversationViewState extends State<ChatConversationView> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  final ImagePicker _picker = ImagePicker();
  String? _pendingImageBase64;
  bool _isSending = false;
  ChatService? _chatServiceRef;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _chatServiceRef = Provider.of<ChatService>(context, listen: false);
    _chatServiceRef?.setActiveChatPartnerId(widget.partner.id);
  }

  @override
  void initState() {
    super.initState();
    _markRead();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    if (_chatServiceRef?.activeChatPartnerId == widget.partner.id) {
      _chatServiceRef?.setActiveChatPartnerId(null);
    }
    super.dispose();
  }

  void _markRead() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final chat = Provider.of<ChatService>(context, listen: false);
      final partnerSvc = Provider.of<PartnerService>(context, listen: false);
      chat.setActiveChatPartnerId(widget.partner.id);
      chat.markAsRead(widget.partner.id);
      partnerSvc.resetUnread(widget.partner.id);
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? file = await _picker.pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 80,
      );

      if (file != null) {
        final bytes = await file.readAsBytes();
        final compressed = ImageCompressor.compressAndEncode(bytes, maxDimension: 800, quality: 65);
        setState(() {
          _pendingImageBase64 = compressed;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not pick image: $e')),
        );
      }
    }
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty && _pendingImageBase64 == null) return;

    setState(() => _isSending = true);

    final sync = Provider.of<SyncService>(context, listen: false);
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);

    // Get current partner state in case it was updated
    final currentPartner = partnerSvc.findContactById(widget.partner.id) ?? widget.partner;

    if (currentPartner.isBlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot send messages to a blocked contact.')),
      );
      setState(() => _isSending = false);
      return;
    }

    final sent = await sync.sendChatMessage(
      currentPartner,
      text,
      imageBase64: _pendingImageBase64,
    );

    if (mounted) {
      _textController.clear();
      setState(() {
        _pendingImageBase64 = null;
        _isSending = false;
      });

      // Scroll to bottom
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });

      if (!sent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Saved locally. Message will sync once partner is online.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _showExpandedImage(String base64Image) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
            Flexible(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 4.0,
                  child: Image.memory(base64Decode(base64Image), fit: BoxFit.contain),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    final partnerSvc = Provider.of<PartnerService>(context);
    final chat = Provider.of<ChatService>(context);
    final theme = Theme.of(context);

    final currentPartner = partnerSvc.findContactById(widget.partner.id) ?? widget.partner;
    final messages = chat.getMessages(currentPartner.id);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _showEditContactDialog(context, currentPartner),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: currentPartner.isBlocked
                      ? Colors.redAccent.withOpacity(0.2)
                      : theme.colorScheme.primary.withOpacity(0.2),
                  child: Icon(
                    currentPartner.isBlocked ? Icons.block_rounded : Icons.person_rounded,
                    color: currentPartner.isBlocked ? Colors.redAccent : theme.colorScheme.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              currentPartner.displayName,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.edit_note_rounded, size: 14, color: theme.colorScheme.primary.withOpacity(0.6)),
                        ],
                      ),
                      Text(
                        currentPartner.isBlocked
                            ? 'BLOCKED'
                            : 'Encrypted • Code: ${currentPartner.pairingCode}',
                        style: TextStyle(
                          fontSize: 11,
                          color: currentPartner.isBlocked
                              ? Colors.redAccent
                              : theme.colorScheme.onSurface.withOpacity(0.6),
                          fontWeight: currentPartner.isBlocked ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (val) {
              if (val == 'edit_contact') {
                _showEditContactDialog(context, currentPartner);
              } else if (val == 'clear') {
                chat.clearChat(currentPartner.id);
              } else if (val == 'block') {
                partnerSvc.toggleBlock(currentPartner.id);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(currentPartner.isBlocked ? 'Blocked ${currentPartner.displayName}' : 'Unblocked ${currentPartner.displayName}'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'edit_contact',
                child: Row(
                  children: [
                    Icon(Icons.edit_note_rounded, size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Edit Contact Info')),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.delete_sweep_rounded, size: 18),
                    SizedBox(width: 8),
                    Expanded(child: Text('Clear Chat History')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'block',
                child: Row(
                  children: [
                    Icon(
                      currentPartner.isBlocked ? Icons.lock_open_rounded : Icons.block_rounded,
                      size: 18,
                      color: currentPartner.isBlocked ? Colors.greenAccent : Colors.redAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        currentPartner.isBlocked ? 'Unblock Contact' : 'Block Contact',
                        style: TextStyle(
                          color: currentPartner.isBlocked ? Colors.greenAccent : Colors.redAccent,
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
      body: Column(
        children: [
          // Blocked Alert Banner
          if (currentPartner.isBlocked)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.redAccent.withOpacity(0.15),
              child: Row(
                children: [
                  const Icon(Icons.block_rounded, color: Colors.redAccent, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'This contact is blocked. Messages and task dispatches are suppressed.',
                      style: TextStyle(fontSize: 12, color: Colors.redAccent),
                    ),
                  ),
                  TextButton(
                    onPressed: () => partnerSvc.setBlocked(currentPartner.id, false),
                    child: const Text('UNBLOCK', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ],
              ),
            ),

          // Messages List
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.mark_chat_read_rounded, size: 54, color: theme.colorScheme.onSurface.withOpacity(0.25)),
                        const SizedBox(height: 12),
                        Text(
                          'No messages yet',
                          style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'End-to-end encrypted direct communication',
                          style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      return _buildMessageBubble(msg, currentPartner, theme);
                    },
                  ),
          ),

          // Pending Image Preview Thumbnail
          if (_pendingImageBase64 != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      base64Decode(_pendingImageBase64!),
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Attached photo ready to send', style: TextStyle(fontSize: 12)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => setState(() => _pendingImageBase64 = null),
                  ),
                ],
              ),
            ),

          // Input Bar
          if (!currentPartner.isBlocked)
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(
                    top: BorderSide(color: theme.colorScheme.outlineVariant.withOpacity(0.3)),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.purpleAccent),
                      tooltip: 'Share Pack or Media',
                      onPressed: _showAttachmentMenu,
                    ),
                    Expanded(
                      child: Focus(
                        onKeyEvent: (node, event) {
                          if (event is KeyDownEvent &&
                              event.logicalKey == LogicalKeyboardKey.enter &&
                              !HardwareKeyboard.instance.isShiftPressed) {
                            _sendMessage();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: TextField(
                          controller: _textController,
                          focusNode: _inputFocusNode,
                          maxLines: 4,
                          minLines: 1,
                          textInputAction: TextInputAction.send,
                          decoration: const InputDecoration(
                            hintText: 'Type to message',
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                          ),
                          onSubmitted: (_) => _sendMessage(),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: _isSending
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send_rounded, color: Colors.purpleAccent),
                      onPressed: _isSending ? null : _sendMessage,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showMessageContextMenu(
    BuildContext context,
    Offset globalPos,
    ChatMessage msg,
    PartnerContact currentPartner,
  ) {
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromLTWH(globalPos.dx, globalPos.dy, 0, 0),
      Offset.zero & overlay.size,
    );

    showMenu<String>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        if (msg.isOutgoing && msg.text.isNotEmpty)
          const PopupMenuItem(
            value: 'edit',
            child: Row(
              children: [
                Icon(Icons.edit_rounded, size: 18),
                SizedBox(width: 10),
                Text('Edit Message'),
              ],
            ),
          ),
        if (msg.text.isNotEmpty)
          const PopupMenuItem(
            value: 'copy',
            child: Row(
              children: [
                Icon(Icons.copy_rounded, size: 18),
                SizedBox(width: 10),
                Text('Copy Text'),
              ],
            ),
          ),
        if (msg.isOutgoing)
          const PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
                SizedBox(width: 10),
                Text('Delete Message', style: TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
      ],
    ).then((choice) {
      if (choice == 'copy') {
        Clipboard.setData(ClipboardData(text: msg.text));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message copied to clipboard'), duration: Duration(seconds: 1)),
        );
      } else if (choice == 'edit') {
        _showEditMessageDialog(context, msg, currentPartner);
      } else if (choice == 'delete') {
        _showDeleteMessageConfirm(context, msg, currentPartner);
      }
    });
  }

  void _showEditMessageDialog(
    BuildContext context,
    ChatMessage msg,
    PartnerContact currentPartner,
  ) {
    final sync = Provider.of<SyncService>(context, listen: false);
    final editController = TextEditingController(text: msg.text);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Message'),
        content: TextField(
          controller: editController,
          maxLines: 4,
          minLines: 1,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Edit your message...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newText = editController.text.trim();
              if (newText.isNotEmpty && newText != msg.text) {
                await sync.sendEditChatMessage(currentPartner, msg.id, newText);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showDeleteMessageConfirm(
    BuildContext context,
    ChatMessage msg,
    PartnerContact currentPartner,
  ) {
    final sync = Provider.of<SyncService>(context, listen: false);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Message'),
        content: const Text('Are you sure you want to delete this message for both participants?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () async {
              await sync.sendDeleteChatMessage(currentPartner, msg.id);
              Navigator.pop(ctx);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showEditContactDialog(BuildContext context, PartnerContact contact) {
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);

    final nameCtrl = TextEditingController(text: contact.displayName);
    final codeCtrl = TextEditingController(text: contact.pairingCode);
    final secretCtrl = TextEditingController(text: contact.pairingSecret);
    final relayCtrl = TextEditingController(text: contact.customRelayHost);
    final notesCtrl = TextEditingController(text: contact.notes ?? '');
    PartnerRole role = contact.role;
    bool obscureSecret = true;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          final theme = Theme.of(dialogCtx);

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            title: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
                  child: Icon(
                    role == PartnerRole.dominant
                        ? Icons.lock_person_rounded
                        : (role == PartnerRole.submissive
                            ? Icons.person_rounded
                            : Icons.people_rounded),
                    color: theme.colorScheme.primary,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Edit Contact Info',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Display Name / Alias',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      hintText: 'e.g. Primary Submissive / Master Dan',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Partner Role',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<PartnerRole>(
                    value: role,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: PartnerRole.submissive,
                        child: Text('Submissive / Player'),
                      ),
                      DropdownMenuItem(
                        value: PartnerRole.dominant,
                        child: Text('Dominant / Director'),
                      ),
                      DropdownMenuItem(
                        value: PartnerRole.peer,
                        child: Text('Peer / Partner'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) setDialogState(() => role = val);
                    },
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Pairing Code',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: codeCtrl,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      hintText: 'e.g. K8M2-9X4L',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'E2EE Shared Passphrase',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: secretCtrl,
                    obscureText: obscureSecret,
                    decoration: InputDecoration(
                      hintText: 'Shared encryption password',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: IconButton(
                        icon: Icon(obscureSecret ? Icons.visibility : Icons.visibility_off, size: 20),
                        onPressed: () => setDialogState(() => obscureSecret = !obscureSecret),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Custom Relay Host (Optional)',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: relayCtrl,
                    decoration: const InputDecoration(
                      hintText: 'ntfy.envs.net',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Private Notes (Only visible to you)',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: notesCtrl,
                    maxLines: 3,
                    minLines: 1,
                    decoration: const InputDecoration(
                      hintText: 'Boundaries, agreements, or notes...',
                      border: OutlineInputBorder(),
                      isDense: true,
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
              ElevatedButton.icon(
                icon: const Icon(Icons.check_rounded, size: 16),
                label: const Text('Save Changes'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                ),
                onPressed: () async {
                  final newName = nameCtrl.text.trim();
                  final newCode = codeCtrl.text.trim().toUpperCase();
                  final newSecret = secretCtrl.text.trim();
                  final newRelay = relayCtrl.text.trim();
                  final newNotes = notesCtrl.text.trim();

                  if (newCode.isEmpty && !contact.isSelf) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Pairing Code cannot be empty')),
                    );
                    return;
                  }

                  final updated = contact.copyWith(
                    displayName: newName.isNotEmpty ? newName : contact.displayName,
                    pairingCode: newCode,
                    pairingSecret: newSecret.isNotEmpty ? newSecret : contact.pairingSecret,
                    role: role,
                    customRelayHost: newRelay.isNotEmpty ? newRelay : contact.customRelayHost,
                    notes: newNotes.isNotEmpty ? newNotes : null,
                  );

                  await partnerSvc.updateContact(updated);

                  // If this contact is the active partner, update sync relay host if changed
                  if (partnerSvc.activePartnerId == updated.id && updated.customRelayHost.isNotEmpty) {
                    sync.setCustomRelay(updated.customRelayHost);
                  }

                  if (context.mounted) {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Updated contact details for "${updated.displayName}"'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                },
              ),
            ],
          );
        },
      ),
    );
  }

  void _showAttachmentMenu() {
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Text(
                    'Share or Attach Content',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.1,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
                    child: Icon(Icons.inventory_2_rounded, color: theme.colorScheme.primary),
                  ),
                  title: const Text('Share Order Pack', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Send an entire bundle of custom or preset directives'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showSendOrderPackPicker();
                  },
                ),
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.amber.withOpacity(0.15),
                    child: const Icon(Icons.card_giftcard_rounded, color: Colors.amber),
                  ),
                  title: const Text('Share Reward Pack', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Send a catalog of unlockable privileges & rewards'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showSendRewardPackPicker();
                  },
                ),
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.purpleAccent.withOpacity(0.15),
                    child: const Icon(Icons.auto_stories_rounded, color: Colors.purpleAccent),
                  ),
                  title: const Text('Share Quest / Quest Pack', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Send chained directive playlists & gauntlets'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showSendQuestPackPicker();
                  },
                ),
                const Divider(height: 16),
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.blueAccent.withOpacity(0.15),
                    child: const Icon(Icons.photo_camera_rounded, color: Colors.blueAccent),
                  ),
                  title: const Text('Take Photo'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickImage(ImageSource.camera);
                  },
                ),
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.greenAccent.withOpacity(0.15),
                    child: const Icon(Icons.image_rounded, color: Colors.greenAccent),
                  ),
                  title: const Text('Photo Gallery'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickImage(ImageSource.gallery);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSendOrderPackPicker() {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);
    final currentPartner = partnerSvc.findContactById(widget.partner.id) ?? widget.partner;
    final packs = engine.packs;

    if (packs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No order packs available to share.')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.inventory_2_rounded, color: Colors.cyanAccent),
            SizedBox(width: 10),
            Text('Share Order Pack'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: packs.length,
            itemBuilder: (context, idx) {
              final pack = packs[idx];
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  title: Text(pack.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('${pack.orders.length} Directives • by ${pack.author}'),
                  trailing: const Icon(Icons.send_rounded, size: 18),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final rawJson = jsonEncode(pack.toJson());
                    await sync.sendChatMessage(
                      currentPartner,
                      'Shared Order Pack: "${pack.title}" (${pack.orders.length} directives)',
                      packType: 'orderPack',
                      packTitle: pack.title,
                      packItemCount: pack.orders.length,
                      packData: rawJson,
                    );
                  },
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ],
      ),
    );
  }

  void _showSendRewardPackPicker() {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);
    final currentPartner = partnerSvc.findContactById(widget.partner.id) ?? widget.partner;
    final packs = engine.rewardPacks;

    if (packs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No reward packs available to share.')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.card_giftcard_rounded, color: Colors.amber),
            SizedBox(width: 10),
            Text('Share Reward Pack'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: packs.length,
            itemBuilder: (context, idx) {
              final pack = packs[idx];
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  title: Text(pack.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('${pack.rewards.length} Privileges & Rewards • by ${pack.author}'),
                  trailing: const Icon(Icons.send_rounded, size: 18),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final rawJson = jsonEncode(pack.toJson());
                    await sync.sendChatMessage(
                      currentPartner,
                      'Shared Reward Pack: "${pack.title}" (${pack.rewards.length} rewards)',
                      packType: 'rewardPack',
                      packTitle: pack.title,
                      packItemCount: pack.rewards.length,
                      packData: rawJson,
                    );
                  },
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ],
      ),
    );
  }

  void _showSendQuestPackPicker() {
    final questSvc = Provider.of<QuestService>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);
    final currentPartner = partnerSvc.findContactById(widget.partner.id) ?? widget.partner;
    final allQuests = questSvc.allQuests;
    final questPacks = questSvc.questPacks;

    if (allQuests.isEmpty && questPacks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No quests or quest packs available to share.')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.auto_stories_rounded, color: Colors.purpleAccent),
            SizedBox(width: 10),
            Text('Share Quest or Quest Pack'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: DefaultTabController(
            length: 2,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'Individual Quests'),
                    Tab(text: 'Quest Packs'),
                  ],
                ),
                SizedBox(
                  height: 320,
                  child: TabBarView(
                    children: [
                      // Individual Quests
                      allQuests.isEmpty
                          ? const Center(child: Text('No quests found.'))
                          : ListView.builder(
                              itemCount: allQuests.length,
                              itemBuilder: (context, idx) {
                                final q = allQuests[idx];
                                return Card(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  child: ListTile(
                                    title: Text(q.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                                    subtitle: Text('${q.steps.length} Steps • ${q.category}'),
                                    trailing: const Icon(Icons.send_rounded, size: 18),
                                    onTap: () async {
                                      Navigator.pop(ctx);
                                      final rawJson = jsonEncode(q.toJson());
                                      await sync.sendChatMessage(
                                        currentPartner,
                                        'Shared Quest: "${q.title}" (${q.steps.length} steps)',
                                        packType: 'quest',
                                        packTitle: q.title,
                                        packItemCount: q.steps.length,
                                        packData: rawJson,
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                      // Quest Packs
                      questPacks.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('No crafted quest packs yet.'),
                                  const SizedBox(height: 8),
                                  Text(
                                    'You can package single quests or create packs in the Quest Studio.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              itemCount: questPacks.length,
                              itemBuilder: (context, idx) {
                                final p = questPacks[idx];
                                return Card(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  child: ListTile(
                                    title: Text(p.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                                    subtitle: Text('${p.quests.length} Quests • by ${p.author}'),
                                    trailing: const Icon(Icons.send_rounded, size: 18),
                                    onTap: () async {
                                      Navigator.pop(ctx);
                                      final rawJson = jsonEncode(p.toJson());
                                      await sync.sendChatMessage(
                                        currentPartner,
                                        'Shared Quest Pack: "${p.title}" (${p.quests.length} quests)',
                                        packType: 'questPack',
                                        packTitle: p.title,
                                        packItemCount: p.quests.length,
                                        packData: rawJson,
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ],
      ),
    );
  }

  void _showPackPreviewDialog(ChatMessage msg) {
    if (msg.packData == null) return;
    final theme = Theme.of(context);
    final packType = msg.packType ?? 'orderPack';

    try {
      final Map<String, dynamic> decoded = jsonDecode(msg.packData!);

      showDialog(
        context: context,
        builder: (ctx) {
          if (packType == 'orderPack') {
            final pack = OrderPack.fromJson(decoded);
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.inventory_2_rounded, color: Colors.cyanAccent),
                  const SizedBox(width: 10),
                  Expanded(child: Text(pack.title, overflow: TextOverflow.ellipsis)),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (pack.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(pack.description, style: const TextStyle(fontSize: 13)),
                      ),
                    Text('Directives (${pack.orders.length}):', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 6),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: pack.orders.length,
                        itemBuilder: (context, i) {
                          final o = pack.orders[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            child: ListTile(
                              dense: true,
                              title: Text(o.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text('${o.category} • ${o.formattedTiming} • +${o.rewardTokens} / -${o.penaltyTokens}'),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                ElevatedButton.icon(
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: const Text('Import Pack'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _importPackFromMessage(msg);
                  },
                ),
              ],
            );
          } else if (packType == 'rewardPack') {
            final pack = RewardPack.fromJson(decoded);
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.card_giftcard_rounded, color: Colors.amber),
                  const SizedBox(width: 10),
                  Expanded(child: Text(pack.title, overflow: TextOverflow.ellipsis)),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (pack.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(pack.description, style: const TextStyle(fontSize: 13)),
                      ),
                    Text('Rewards & Privileges (${pack.rewards.length}):', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 6),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: pack.rewards.length,
                        itemBuilder: (context, i) {
                          final r = pack.rewards[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            child: ListTile(
                              dense: true,
                              title: Text(r.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text('${r.cost} Tokens • ${r.category}'),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                ElevatedButton.icon(
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: const Text('Import Pack'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _importPackFromMessage(msg);
                  },
                ),
              ],
            );
          } else if (packType == 'questPack') {
            final pack = QuestPack.fromJson(decoded);
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.auto_stories_rounded, color: Colors.purpleAccent),
                  const SizedBox(width: 10),
                  Expanded(child: Text(pack.title, overflow: TextOverflow.ellipsis)),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (pack.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(pack.description, style: const TextStyle(fontSize: 13)),
                      ),
                    Text('Quests (${pack.quests.length}):', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 6),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: pack.quests.length,
                        itemBuilder: (context, i) {
                          final q = pack.quests[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            child: ListTile(
                              dense: true,
                              title: Text(q.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text('${q.steps.length} Steps • +${q.totalPotentialTokens} Tokens'),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                ElevatedButton.icon(
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: const Text('Import Pack'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _importPackFromMessage(msg);
                  },
                ),
              ],
            );
          } else {
            final quest = Quest.fromJson(decoded);
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.hub_rounded, color: Colors.purpleAccent),
                  const SizedBox(width: 10),
                  Expanded(child: Text(quest.title, overflow: TextOverflow.ellipsis)),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (quest.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(quest.description, style: const TextStyle(fontSize: 13)),
                      ),
                    Text('Steps (${quest.steps.length}):', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 6),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: quest.steps.length,
                        itemBuilder: (context, i) {
                          final s = quest.steps[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            child: ListTile(
                              dense: true,
                              title: Text('${s.orderIndex}. ${s.title}', style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text('+${s.rewardTokens} Tokens • ${s.durationType.displayName}'),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                ElevatedButton.icon(
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: const Text('Import Quest'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _importPackFromMessage(msg);
                  },
                ),
              ],
            );
          }
        },
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not preview pack: $e')),
      );
    }
  }

  Future<void> _importPackFromMessage(ChatMessage msg) async {
    if (msg.packData == null) return;
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final questSvc = Provider.of<QuestService>(context, listen: false);
    final packType = msg.packType ?? 'orderPack';

    try {
      if (packType == 'orderPack') {
        final pack = engine.importOrderPackFromJson(msg.packData!);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully imported Order Pack "${pack.title}" (${pack.orders.length} directives)!'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else if (packType == 'rewardPack') {
        final pack = engine.importRewardPackFromJson(msg.packData!);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully imported Reward Pack "${pack.title}" (${pack.rewards.length} rewards)!'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else if (packType == 'questPack') {
        final pack = await questSvc.importQuestPack(msg.packData!);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully imported Quest Pack "${pack.title}" (${pack.quests.length} quests)!'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else if (packType == 'quest') {
        final quest = await questSvc.importQuestFromJson(msg.packData!);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully imported Quest "${quest.title}" (${quest.steps.length} steps)!'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      setState(() {});
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
  }

  Widget _buildPackCard(ChatMessage msg, PartnerContact currentPartner, ThemeData theme) {
    final engine = Provider.of<OrderEngine>(context);
    final questSvc = Provider.of<QuestService>(context);
    final packType = msg.packType ?? 'orderPack';

    Color cardColor = theme.colorScheme.primary;
    IconData cardIcon = Icons.inventory_2_rounded;
    String typeLabel = 'ORDER PACK';
    bool isInstalled = false;

    if (packType == 'orderPack') {
      cardColor = Colors.cyanAccent;
      cardIcon = Icons.inventory_2_rounded;
      typeLabel = 'ORDER PACK';
      isInstalled = engine.isOrderPackInstalled('', title: msg.packTitle);
    } else if (packType == 'rewardPack') {
      cardColor = Colors.amberAccent;
      cardIcon = Icons.card_giftcard_rounded;
      typeLabel = 'REWARD PACK';
      isInstalled = engine.isRewardPackInstalled('', title: msg.packTitle);
    } else if (packType == 'questPack') {
      cardColor = Colors.purpleAccent;
      cardIcon = Icons.auto_stories_rounded;
      typeLabel = 'QUEST PACK';
      isInstalled = questSvc.questPacks.any((p) => p.title.toLowerCase() == (msg.packTitle ?? '').toLowerCase());
    } else if (packType == 'quest') {
      cardColor = Colors.purpleAccent;
      cardIcon = Icons.hub_rounded;
      typeLabel = 'QUEST PLAYLIST';
      isInstalled = questSvc.allQuests.any((q) => q.title.toLowerCase() == (msg.packTitle ?? '').toLowerCase());
    }

    return Container(
      width: 260,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withOpacity(0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardColor.withOpacity(0.5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(cardIcon, size: 20, color: cardColor),
              const SizedBox(width: 8),
              Text(
                typeLabel,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: cardColor,
                ),
              ),
              const Spacer(),
              if (isInstalled)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.greenAccent.withOpacity(0.5)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_rounded, size: 10, color: Colors.greenAccent),
                      SizedBox(width: 2),
                      Text('INSTALLED', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            msg.packTitle ?? 'Shared Pack',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 2),
          Text(
            packType == 'orderPack'
                ? '${msg.packItemCount ?? 0} Directives Included'
                : packType == 'rewardPack'
                    ? '${msg.packItemCount ?? 0} Rewards Included'
                    : packType == 'questPack'
                        ? '${msg.packItemCount ?? 0} Quests in Pack'
                        : '${msg.packItemCount ?? 0} Chained Steps',
            style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.7)),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                  ),
                  onPressed: () => _showPackPreviewDialog(msg),
                  child: const Text('Preview', style: TextStyle(fontSize: 11)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: isInstalled ? theme.colorScheme.surfaceVariant : cardColor.withOpacity(0.85),
                    foregroundColor: isInstalled ? theme.colorScheme.onSurface : Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                  ),
                  onPressed: () => _importPackFromMessage(msg),
                  child: Text(isInstalled ? 'Reinstall' : 'Import', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, PartnerContact currentPartner, ThemeData theme) {
    final isOut = msg.isOutgoing;

    return Align(
      alignment: isOut ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onSecondaryTapDown: (details) => _showMessageContextMenu(context, details.globalPosition, msg, currentPartner),
        onLongPressStart: (details) => _showMessageContextMenu(context, details.globalPosition, msg, currentPartner),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isOut
                ? theme.colorScheme.primary.withOpacity(0.25)
                : theme.colorScheme.surfaceVariant.withOpacity(0.6),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isOut ? 16 : 4),
              bottomRight: Radius.circular(isOut ? 4 : 16),
            ),
            border: Border.all(
              color: isOut
                  ? theme.colorScheme.primary.withOpacity(0.3)
                  : theme.colorScheme.outlineVariant.withOpacity(0.3),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (msg.isPackTransfer)
                _buildPackCard(msg, currentPartner, theme),
              if (msg.imageBase64 != null) ...[
                GestureDetector(
                  onTap: () => _showExpandedImage(msg.imageBase64!),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.memory(
                      base64Decode(msg.imageBase64!),
                      width: 200,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                if (msg.text.isNotEmpty) const SizedBox(height: 6),
              ],
              if (msg.text.isNotEmpty && !msg.isPackTransfer)
                LinkableText(
                  text: msg.text,
                  style: const TextStyle(fontSize: 14),
                  linkStyle: TextStyle(
                    fontSize: 14,
                    color: isOut
                        ? (theme.brightness == Brightness.dark ? Colors.lightBlueAccent : Colors.blue.shade900)
                        : theme.colorScheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: isOut
                        ? (theme.brightness == Brightness.dark ? Colors.lightBlueAccent : Colors.blue.shade900)
                        : theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (msg.isEdited && msg.editedTimestamp != null) ...[
                    Text(
                      'Edited • ${_formatTime(msg.editedTimestamp!)}  ·  Sent • ${_formatTime(msg.timestamp)}',
                      style: TextStyle(
                        fontSize: 10,
                        fontStyle: FontStyle.italic,
                        color: theme.colorScheme.onSurface.withOpacity(0.55),
                      ),
                    ),
                  ] else ...[
                    Text(
                      _formatTime(msg.timestamp),
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurface.withOpacity(0.5),
                      ),
                    ),
                  ],
                  if (isOut) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.done_all_rounded,
                      size: 12,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
