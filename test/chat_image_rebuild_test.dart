import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/chat_message.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/storage_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/views/messenger/chat_conversation_view.dart';

/// A 1x1 PNG.
const _photo =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OrderEngine engine;
  late PartnerService partnerService;
  late ChatService chatService;
  late QuestService questService;
  late SyncService syncService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    engine = OrderEngine(storage: StorageService());
    await engine.init();
    partnerService = PartnerService();
    await partnerService.init();
    chatService = ChatService();
    await chatService.init();
    questService = QuestService();
    syncService = SyncService(engine);
    syncService.attachServices(partnerService, chatService, questService: questService);
  });

  MemoryImage photoInChat(WidgetTester tester) {
    final image = tester.widget<Image>(find.byType(Image).first);
    return image.image as MemoryImage;
  }

  // A photo in the chat shrank to a sliver and sprang back over and over.
  // Every rebuild decoded it again into a new byte list, which Flutter treats
  // as a new image and loads from scratch, and while loading it has no height.
  testWidgets('a photo in the chat is not reloaded when the chat rebuilds', (tester) async {
    final partner = PartnerContact(
      id: 'partner_photo',
      displayName: 'PC 1',
      pairingCode: 'PHOTO123',
      pairingSecret: 'secret',
      role: PartnerRole.submissive,
    );
    await partnerService.addContact(partner);
    await chatService.addMessage(ChatMessage(
      partnerId: partner.id,
      senderId: 'me',
      imageBase64: _photo,
      isOutgoing: true,
    ));

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<PartnerService>.value(value: partnerService),
        ChangeNotifierProvider<ChatService>.value(value: chatService),
        ChangeNotifierProvider<SyncService>.value(value: syncService),
        ChangeNotifierProvider<OrderEngine>.value(value: engine),
        ChangeNotifierProvider<QuestService>.value(value: questService),
      ],
      child: MaterialApp(home: ChatConversationView(partner: partner)),
    ));
    await tester.pumpAndSettle();

    final before = photoInChat(tester);

    // Any change to the conversation rebuilds every bubble in it.
    await chatService.addMessage(ChatMessage(
      partnerId: partner.id,
      senderId: partner.id,
      text: 'Test 123',
    ));
    await tester.pump();

    final after = photoInChat(tester);
    expect(identical(after.bytes, before.bytes), isTrue,
        reason: 'the same photo must stay the same image across a rebuild');
    expect(after, equals(before));
    expect(tester.widget<Image>(find.byType(Image).first).gaplessPlayback, isTrue);
  });
}
