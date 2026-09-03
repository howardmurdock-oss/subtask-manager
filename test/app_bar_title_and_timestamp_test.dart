import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/core/security/security_service.dart';
import 'package:orders_app/core/theme/theme_provider.dart';
import 'package:orders_app/models/active_order.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/storage_service.dart';
import 'package:orders_app/views/home_screen.dart';
import 'package:orders_app/widgets/order_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ActiveOrder.formatAssignedTime Tests', () {
    test('formats today timestamps with Today, h:mm a', () {
      final now = DateTime.now();
      final formatted = ActiveOrder.formatAssignedTime(now);
      expect(formatted, startsWith('Today, '));
    });

    test('formats yesterday timestamps with Yesterday, h:mm a', () {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final formatted = ActiveOrder.formatAssignedTime(yesterday);
      expect(formatted, startsWith('Yesterday, '));
    });

    test('formats older dates with Month Day, h:mm a', () {
      final olderDate = DateTime(2026, 1, 15, 14, 30);
      final formatted = ActiveOrder.formatAssignedTime(olderDate);
      expect(formatted, 'Jan 15, 2:30 PM');
    });
  });

  group('OrderCard Assignment Timestamp Tests', () {
    testWidgets('OrderCard displays Assigned timestamp', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      final engine = OrderEngine(storage: storage);

      final orderItem = OrderItem(
        id: 'ord_1',
        title: 'Calisthenics Routine',
        description: 'Perform 20 pushups and 30 squats.',
        category: 'fitness',
        tier: 2,
        durationType: DurationType.instant,
        durationMinutes: 0,
        rewardTokens: 15,
        penaltyTokens: 5,
        verificationType: VerificationType.honorCheck,
      );

      final activeOrder = ActiveOrder(
        id: 'active_1',
        order: orderItem,
        assignedAt: DateTime(2026, 8, 20, 10, 15),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<OrderEngine>.value(
              value: engine,
              child: OrderCard(activeOrder: activeOrder),
            ),
          ),
        ),
      );

      expect(find.text('Calisthenics Routine'), findsOneWidget);
      expect(find.text('Assigned: Aug 20, 10:15 AM'), findsOneWidget);

      engine.dispose();
    });
  });

  group('HomeScreen AppBar Title Truncation Prevention Tests', () {
    testWidgets('HomeScreen renders responsive Directives title on compact phone width', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      final engine = OrderEngine(storage: storage);
      final partnerService = PartnerService();
      final chatService = ChatService();
      final questService = QuestService();
      final themeProvider = ThemeProvider();
      final securityService = SecurityService();
      final syncService = SyncService(engine);
      syncService.attachServices(partnerService, chatService, questService: questService);

      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
            ChangeNotifierProvider<SecurityService>.value(value: securityService),
            ChangeNotifierProvider<OrderEngine>.value(value: engine),
            ChangeNotifierProvider<PartnerService>.value(value: partnerService),
            ChangeNotifierProvider<SyncService>.value(value: syncService),
            ChangeNotifierProvider<ChatService>.value(value: chatService),
            ChangeNotifierProvider<QuestService>.value(value: questService),
          ],
          child: const MaterialApp(
            home: HomeScreen(),
          ),
        ),
      );

      await tester.pump();

      // In Player mode on compact width, 'Directives' is displayed without overflow
      expect(find.text('PLAYER'), findsOneWidget);
      expect(find.text('Directives'), findsOneWidget);

      syncService.dispose();
      engine.dispose();
    });
  });
}
