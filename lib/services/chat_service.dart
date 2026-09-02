import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_message.dart';

class ChatService extends ChangeNotifier {
  final Map<String, List<ChatMessage>> _conversations = {};
  bool _initialized = false;
  String? _activeChatPartnerId;

  Map<String, List<ChatMessage>> get conversations => Map.unmodifiable(_conversations);
  String? get activeChatPartnerId => _activeChatPartnerId;

  void setActiveChatPartnerId(String? partnerId) {
    _activeChatPartnerId = partnerId;
    if (partnerId != null) {
      markAsRead(partnerId);
    }
  }

  List<ChatMessage> getMessages(String partnerId) {
    return List.unmodifiable(_conversations[partnerId] ?? []);
  }

  ChatMessage? getLastMessage(String partnerId) {
    final list = _conversations[partnerId];
    if (list == null || list.isEmpty) return null;
    return list.last;
  }

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedJson = prefs.getString('chat_conversations_store');
      if (savedJson != null && savedJson.isNotEmpty) {
        final Map<String, dynamic> decoded = jsonDecode(savedJson);
        _conversations.clear();
        decoded.forEach((partnerId, messagesRaw) {
          if (messagesRaw is List) {
            _conversations[partnerId] = messagesRaw
                .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
                .toList();
          }
        });
      }
      _initialized = true;
      notifyListeners();
    } catch (e) {
      if (kDebugMode) print('Error initializing ChatService: $e');
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final Map<String, dynamic> exportMap = {};
      _conversations.forEach((partnerId, msgList) {
        exportMap[partnerId] = msgList.map((m) => m.toJson()).toList();
      });
      await prefs.setString('chat_conversations_store', jsonEncode(exportMap));
    } catch (e) {
      if (kDebugMode) print('Error saving ChatService: $e');
    }
  }

  Future<void> addMessage(ChatMessage message) async {
    final partnerId = message.partnerId;
    if (!_conversations.containsKey(partnerId)) {
      _conversations[partnerId] = [];
    }

    // Deduplicate by message ID
    final existingIdx = _conversations[partnerId]!.indexWhere((m) => m.id == message.id);
    if (existingIdx >= 0) {
      _conversations[partnerId]![existingIdx] = message;
    } else {
      _conversations[partnerId]!.add(message);
    }

    // Sort by timestamp
    _conversations[partnerId]!.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    await _save();
    notifyListeners();
  }

  Future<void> markAsRead(String partnerId) async {
    final list = _conversations[partnerId];
    if (list != null && list.isNotEmpty) {
      bool changed = false;
      for (int i = 0; i < list.length; i++) {
        if (!list[i].isOutgoing && !list[i].isRead) {
          list[i] = list[i].copyWith(isRead: true);
          changed = true;
        }
      }
      if (changed) {
        await _save();
        notifyListeners();
      }
    }
  }

  Future<void> clearChat(String partnerId) async {
    if (_conversations.containsKey(partnerId)) {
      _conversations[partnerId]!.clear();
      await _save();
      notifyListeners();
    }
  }

  Future<void> deleteMessage(String partnerId, String messageId) async {
    final list = _conversations[partnerId];
    if (list != null) {
      list.removeWhere((m) => m.id == messageId);
      await _save();
      notifyListeners();
    }
  }

  Future<void> editMessage(String partnerId, String messageId, String newText, {DateTime? editedTime}) async {
    final list = _conversations[partnerId];
    if (list != null) {
      final idx = list.indexWhere((m) => m.id == messageId);
      if (idx >= 0) {
        list[idx] = list[idx].copyWith(
          text: newText,
          isEdited: true,
          editedTimestamp: editedTime ?? DateTime.now(),
        );
        await _save();
        notifyListeners();
      }
    }
  }
}
