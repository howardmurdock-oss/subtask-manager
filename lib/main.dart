import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/theme/theme_provider.dart';
import 'core/security/security_service.dart';
import 'core/sound/sound_service.dart';
import 'core/notifications/notification_service.dart';
import 'services/order_engine.dart';
import 'services/sync_service.dart';
import 'services/storage_service.dart';
import 'services/partner_service.dart';
import 'services/chat_service.dart';
import 'services/quest_service.dart';
import 'services/schedule_service.dart';
import 'services/background_link_service.dart';
import 'services/push_service.dart';
import 'views/home_screen.dart';
import 'views/disguise/panic_decoy_view.dart';
import 'views/security/pin_lock_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final themeProvider = ThemeProvider();
  await themeProvider.init();

  final securityService = SecurityService();
  await securityService.init();

  await SoundService.init();
  await NotificationService.init();

  final storageService = StorageService();
  final orderEngine = OrderEngine(storage: storageService);
  await orderEngine.init();

  final partnerService = PartnerService();
  await partnerService.init();

  final chatService = ChatService();
  await chatService.init();

  final questService = QuestService();

  final syncService = SyncService(orderEngine);
  syncService.attachServices(partnerService, chatService, questService: questService);
  final isPinLocked = securityService.isPinRequired && !securityService.isUnlocked;
  await syncService.init(deferNetwork: isPinLocked);

  // Register for push once the pairing code is loaded, so the Worker learns
  // which topic this device answers to. The topic is the same hashed code the
  // relay uses, so no raw pairing code ever leaves the device.
  if (syncService.pairingCode.isNotEmpty) {
    PushService.init(topic: SyncService.getHashedTopic(syncService.pairingCode));
  }

  final scheduleService = ScheduleService();
  await scheduleService.init();
  // Claim scheduled-rule execution for this isolate before attaching, so the
  // background isolate stands down instead of racing the startup catch-up.
  await scheduleService.markForegroundAlive();
  scheduleService.attachDependencies(
    orderEngine: orderEngine,
    syncService: syncService,
    partnerService: partnerService,
  );

  // Initialize background foreground task service asynchronously after the first frame,
  // preventing Android IPC platform channel calls from blocking app launch.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    BackgroundLinkService.init();
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: themeProvider),
        ChangeNotifierProvider.value(value: securityService),
        ChangeNotifierProvider.value(value: orderEngine),
        ChangeNotifierProvider.value(value: partnerService),
        ChangeNotifierProvider.value(value: chatService),
        ChangeNotifierProvider.value(value: questService),
        ChangeNotifierProvider.value(value: scheduleService),
        ChangeNotifierProvider.value(value: syncService),
      ],
      child: const OrdersApp(),
    ),
  );
}

class OrdersApp extends StatefulWidget {
  const OrdersApp({super.key});

  @override
  State<OrdersApp> createState() => _OrdersAppState();
}

class _OrdersAppState extends State<OrdersApp> with WidgetsBindingObserver {
  bool _wasLocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final security = Provider.of<SecurityService>(context, listen: false);
    _wasLocked = security.isPinRequired && !security.isUnlocked;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final security = Provider.of<SecurityService>(context, listen: false);
      final isLocked = security.isPinRequired && !security.isUnlocked;
      final engine = Provider.of<OrderEngine>(context, listen: false);
      engine.onAppResumed();

      // If user is currently looking at PIN lock screen, do NOT choke the event queue
      // with network requests and SharedPreferences decodes.
      if (!isLocked) {
        final sync = Provider.of<SyncService>(context, listen: false);
        sync.onAppResumed();
        final schedule = Provider.of<ScheduleService>(context, listen: false);
        // Resync rather than a plain check: while this isolate was frozen the
        // background isolate may have advanced rules and delivered orders, and
        // acting on the stale in-memory snapshot would re-fire them and then
        // persist the rollback.
        schedule.markForegroundAlive();
        schedule.resyncFromStorage();
        // Android can drop pending alarms across a long idle stretch; re-arming
        // on resume is the only thing that re-establishes them short of a full
        // cold start.
        schedule.rearmAllAlarms();
      }
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      final engine = Provider.of<OrderEngine>(context, listen: false);
      engine.onAppPaused();
      // Hand scheduled-rule execution back to the background isolate.
      final schedule = Provider.of<ScheduleService>(context, listen: false);
      schedule.markForegroundStopped();
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final security = Provider.of<SecurityService>(context);

    final isLocked = security.isPinRequired && !security.isUnlocked;
    if (_wasLocked && !isLocked) {
      _wasLocked = false;
      // Post-unlock deferred sync: give the UI 300ms to smoothly complete the
      // transition from PIN pad to HomeScreen before starting network sync
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          final sync = Provider.of<SyncService>(context, listen: false);
          sync.startForegroundSync();
          final schedule = Provider.of<ScheduleService>(context, listen: false);
          schedule.markForegroundAlive();
          schedule.resyncFromStorage();
        }
      });
    } else if (isLocked) {
      _wasLocked = true;
    }

    Widget rootScreen;
    if (security.isPanicModeActive) {
      rootScreen = const PanicDecoyView();
    } else if (isLocked) {
      rootScreen = const PinLockScreen();
    } else {
      rootScreen = const HomeScreen();
    }

    return MaterialApp(
      title: '(sub)Task Manager',
      debugShowCheckedModeBanner: false,
      theme: themeProvider.themeData,
      home: rootScreen,
    );
  }
}
