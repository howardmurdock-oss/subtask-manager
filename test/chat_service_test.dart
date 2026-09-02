import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/chat_message.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatMessage Model & ChatService Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('ChatMessage serialization and deserialization round-trip', () {
      final msg = ChatMessage(
        id: 'msg_1',
        partnerId: 'partner_abc',
        senderId: 'device_xyz',
        senderName: 'Director',
        text: 'Reviewing your submission now.',
        imageBase64: 'base64sampledata',
        isOutgoing: true,
        isRead: false,
      );

      final json = msg.toJson();
      final recovered = ChatMessage.fromJson(json);

      expect(recovered.id, 'msg_1');
      expect(recovered.partnerId, 'partner_abc');
      expect(recovered.senderId, 'device_xyz');
      expect(recovered.senderName, 'Director');
      expect(recovered.text, 'Reviewing your submission now.');
      expect(recovered.imageBase64, 'base64sampledata');
      expect(recovered.isOutgoing, true);
      expect(recovered.isRead, false);
    });

    test('ChatService stores, retrieves, and marks messages as read', () async {
      final service = ChatService();
      await service.init();

      expect(service.getMessages('p1').length, 0);

      final m1 = ChatMessage(
        id: 'm1',
        partnerId: 'p1',
        senderId: 'p1',
        text: 'Hello Director',
        isOutgoing: false,
        isRead: false,
      );
      final m2 = ChatMessage(
        id: 'm2',
        partnerId: 'p1',
        senderId: 'local',
        text: 'Awaiting your report',
        isOutgoing: true,
        isRead: true,
      );

      await service.addMessage(m1);
      await service.addMessage(m2);

      final list = service.getMessages('p1');
      expect(list.length, 2);
      expect(list[0].text, 'Hello Director');
      expect(list[0].isRead, false);

      expect(service.getLastMessage('p1')?.text, 'Awaiting your report');

      // Mark conversation as read
      await service.markAsRead('p1');
      final updatedList = service.getMessages('p1');
      expect(updatedList[0].isRead, true);

      // Clear conversation
      await service.clearChat('p1');
      expect(service.getMessages('p1').length, 0);
    });

    test('ChatService edits and deletes individual messages', () async {
      final service = ChatService();
      await service.init();

      final m1 = ChatMessage(
        id: 'msg_edit_1',
        partnerId: 'p1',
        senderId: 'local',
        text: 'Initial text before editing',
        isOutgoing: true,
      );

      await service.addMessage(m1);
      expect(service.getMessages('p1').first.isEdited, false);

      final editedTime = DateTime.now();
      await service.editMessage('p1', 'msg_edit_1', 'Updated text after editing', editedTime: editedTime);

      final updated = service.getMessages('p1').first;
      expect(updated.text, 'Updated text after editing');
      expect(updated.isEdited, true);
      expect(updated.editedTimestamp, isNotNull);

      // Test delete
      await service.deleteMessage('p1', 'msg_edit_1');
      expect(service.getMessages('p1').length, 0);
    });

    test('SyncService rejects self-sent chat echoes from being processed as incoming', () async {
      final engine = OrderEngine();
      final chatService = ChatService();
      await chatService.init();

      final partnerService = PartnerService();
      await partnerService.init();

      final partner = PartnerContact(
        id: 'contact_pc2',
        displayName: 'PC 2 Director',
        pairingCode: 'CODE-PC2',
        pairingSecret: 'sec_pc2',
      );
      await partnerService.addContact(partner);

      final sync = SyncService(engine, partnerService: partnerService);
      sync.attachChatService(chatService);

      // Simulate sending outgoing message
      final msgId = 'outgoing_123';
      final outgoingMsg = ChatMessage(
        id: msgId,
        partnerId: partner.id,
        senderId: sync.deviceId,
        senderName: 'Phone',
        text: 'Test message from phone',
        isOutgoing: true,
        isRead: true,
      );
      await chatService.addMessage(outgoingMsg);

      expect(chatService.getMessages(partner.id).length, 1);
      expect(chatService.getMessages(partner.id).first.isOutgoing, isTrue);

      // Simulate incoming echo from relay with own deviceId
      final echoMsg1 = SyncMessage(
        id: msgId,
        type: SyncMessageType.chatMessage,
        senderId: sync.deviceId,
        payload: {
          'messageId': msgId,
          'senderId': sync.deviceId,
          'senderCode': sync.pairingCode,
          'senderName': 'Phone',
          'text': 'Test message from phone',
        },
      );

      await sync.handleIncomingSyncMessage(echoMsg1);

      // Ensure message was NOT duplicated or marked incoming
      final messagesAfterEcho1 = chatService.getMessages(partner.id);
      expect(messagesAfterEcho1.length, 1);
      expect(messagesAfterEcho1.first.isOutgoing, isTrue);

      // Simulate echo matching own pairingCode
      final echoMsg2 = SyncMessage(
        id: 'different_id_same_code',
        type: SyncMessageType.chatMessage,
        senderId: 'unknown_sender',
        payload: {
          'messageId': 'different_id_same_code',
          'senderId': 'unknown_sender',
          'senderCode': sync.pairingCode,
          'senderName': 'Phone',
          'text': 'Test message from phone',
        },
      );

      await sync.handleIncomingSyncMessage(echoMsg2);

      final messagesAfterEcho2 = chatService.getMessages(partner.id);
      expect(messagesAfterEcho2.length, 1);
      expect(messagesAfterEcho2.first.isOutgoing, isTrue);
    });

    test('Incoming chat message when activeChatPartnerId is viewing conversation is marked read with 0 unread badge', () async {
      final engine = OrderEngine();
      final chatService = ChatService();
      await chatService.init();

      final partnerService = PartnerService();
      await partnerService.init();

      final partner = PartnerContact(
        id: 'partner_phone',
        displayName: 'Phone Submissive',
        pairingCode: 'CODE-PHONE',
        pairingSecret: 'sec_phone',
      );
      await partnerService.addContact(partner);

      final sync = SyncService(engine, partnerService: partnerService);
      sync.attachChatService(chatService);

      // Case 1: User NOT currently in chat -> unread increments
      final incoming1 = SyncMessage(
        id: 'in_1',
        type: SyncMessageType.chatMessage,
        senderId: 'device_phone',
        payload: {
          'messageId': 'in_1',
          'senderId': 'device_phone',
          'senderCode': 'CODE-PHONE',
          'senderName': 'Phone Submissive',
          'text': 'Message while away',
        },
      );

      await sync.handleIncomingSyncMessage(incoming1);
      expect(partnerService.unreadCount(partner.id), 1);
      expect(chatService.getMessages(partner.id).last.isRead, isFalse);

      // User opens conversation
      chatService.setActiveChatPartnerId(partner.id);
      partnerService.resetUnread(partner.id);
      expect(partnerService.unreadCount(partner.id), 0);

      // Case 2: User IS currently in chat -> message arrives as read, unread stays 0
      final incoming2 = SyncMessage(
        id: 'in_2',
        type: SyncMessageType.chatMessage,
        senderId: 'device_phone',
        payload: {
          'messageId': 'in_2',
          'senderId': 'device_phone',
          'senderCode': 'CODE-PHONE',
          'senderName': 'Phone Submissive',
          'text': 'Message while in chat',
        },
      );

      await sync.handleIncomingSyncMessage(incoming2);
      expect(partnerService.unreadCount(partner.id), 0);
      expect(chatService.getMessages(partner.id).last.isRead, isTrue);
    });
  });
}
