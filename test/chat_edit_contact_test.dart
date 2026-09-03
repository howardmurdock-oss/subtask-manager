import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/storage_service.dart';
import 'package:orders_app/views/messenger/chat_conversation_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storage;
  late OrderEngine engine;
  late PartnerService partnerService;
  late ChatService chatService;
  late QuestService questService;
  late SyncService syncService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    engine = OrderEngine(storage: storage);
    await engine.init();

    partnerService = PartnerService();
    await partnerService.init();

    chatService = ChatService();
    await chatService.init();

    questService = QuestService();
    syncService = SyncService(engine);
    syncService.attachServices(partnerService, chatService, questService: questService);
  });

  Widget createChatWidget(PartnerContact partner) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<PartnerService>.value(value: partnerService),
        ChangeNotifierProvider<ChatService>.value(value: chatService),
        ChangeNotifierProvider<SyncService>.value(value: syncService),
        ChangeNotifierProvider<OrderEngine>.value(value: engine),
        ChangeNotifierProvider<QuestService>.value(value: questService),
      ],
      child: MaterialApp(
        home: ChatConversationView(partner: partner),
      ),
    );
  }

  testWidgets('Chat popup menu contains Edit Contact Info option and opens edit dialog', (tester) async {
    final contact = PartnerContact(
      id: 'partner_test_1',
      displayName: 'Alice Sub',
      pairingCode: 'CODE1234',
      pairingSecret: 'mysecret',
      role: PartnerRole.submissive,
      notes: 'Initial test notes',
    );
    await partnerService.addContact(contact);

    await tester.pumpWidget(createChatWidget(contact));
    await tester.pumpAndSettle();

    // Verify initial contact name is visible
    expect(find.text('Alice Sub'), findsOneWidget);

    // Open popup menu in AppBar
    final popupMenuBtn = find.byType(PopupMenuButton<String>);
    expect(popupMenuBtn, findsOneWidget);
    await tester.tap(popupMenuBtn);
    await tester.pumpAndSettle();

    // Verify 'Edit Contact Info' option exists in the menu
    expect(find.text('Edit Contact Info'), findsOneWidget);
    expect(find.widgetWithText(PopupMenuItem<String>, 'Edit Contact Info'), findsOneWidget);

    // Tap 'Edit Contact Info'
    await tester.tap(find.text('Edit Contact Info'));
    await tester.pumpAndSettle();

    // Verify the edit dialog opens
    expect(find.text('Edit Contact Info'), findsOneWidget);
    expect(find.text('Display Name / Alias'), findsOneWidget);
    expect(find.text('Save Changes'), findsOneWidget);

    // Enter a new display name
    final nameField = find.widgetWithText(TextField, 'Alice Sub');
    expect(nameField, findsOneWidget);
    await tester.enterText(nameField, 'Alice Sub Prime');
    await tester.pumpAndSettle();

    // Tap Save Changes
    await tester.tap(find.text('Save Changes'));
    await tester.pumpAndSettle();

    // Verify PartnerService contact was updated
    final updatedContact = partnerService.findContactById('partner_test_1');
    expect(updatedContact, isNotNull);
    expect(updatedContact!.displayName, equals('Alice Sub Prime'));

    // Verify the AppBar dynamically updated
    expect(find.text('Alice Sub Prime'), findsOneWidget);
  });

  testWidgets('Tapping contact header in chat AppBar also opens edit contact dialog', (tester) async {
    final contact = PartnerContact(
      id: 'partner_test_2',
      displayName: 'Bob Dominant',
      pairingCode: 'BOB5678',
      pairingSecret: 'bobsecret',
      role: PartnerRole.dominant,
    );
    await partnerService.addContact(contact);

    await tester.pumpWidget(createChatWidget(contact));
    await tester.pumpAndSettle();

    // Tap the contact title in the AppBar
    await tester.tap(find.text('Bob Dominant'));
    await tester.pumpAndSettle();

    // Verify dialog opened
    expect(find.text('Edit Contact Info'), findsOneWidget);
    expect(find.text('Save Changes'), findsOneWidget);

    // Tap Cancel
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Dialog closed
    expect(find.text('Save Changes'), findsNothing);
  });
}
