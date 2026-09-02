import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:orders_app/main.dart';
import 'package:orders_app/core/theme/theme_provider.dart';
import 'package:orders_app/core/security/security_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/storage_service.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/quest_service.dart';

void main() {
  testWidgets('OrdersApp startup smoke test', (WidgetTester tester) async {
    final themeProvider = ThemeProvider();
    final securityService = SecurityService();
    final storageService = StorageService();
    final orderEngine = OrderEngine(storage: storageService);
    final partnerService = PartnerService();
    final chatService = ChatService();
    final questService = QuestService();
    final syncService = SyncService(orderEngine);
    syncService.attachServices(partnerService, chatService, questService: questService);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: themeProvider),
          ChangeNotifierProvider.value(value: securityService),
          ChangeNotifierProvider.value(value: orderEngine),
          ChangeNotifierProvider.value(value: partnerService),
          ChangeNotifierProvider.value(value: chatService),
          ChangeNotifierProvider.value(value: questService),
          ChangeNotifierProvider.value(value: syncService),
        ],
        child: const OrdersApp(),
      ),
    );

    // Verify main HUD loaded
    expect(find.text('PLAYER'), findsOneWidget);
    expect(find.text('PULL NEW ORDER'), findsOneWidget);

    syncService.dispose();
  });
}
