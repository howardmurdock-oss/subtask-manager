import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import '../../models/order_item.dart';
import '../../models/scheduled_order_rule.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static final StreamController<String> _notificationClickController = StreamController<String>.broadcast();
  static Stream<String> get onNotificationClicked => _notificationClickController.stream;

  static const String _channelId = 'orders_dispatch_channel_v3';
  static const String _channelName = 'Directives & Orders Alert';
  static const String _channelDesc = 'Critical heads-up alerts for incoming directives, tasks, and verifications';

  static const String _alarmChannelId = 'scheduled_orders_alarm_channel_v1';
  static const String _alarmChannelName = 'Scheduled Orders & Alarms';
  static const String _alarmChannelDesc = 'High-priority alerts for scheduled orders, directives, and window triggers';

  static Future<void> _initTimeZone() async {
    try {
      tz.initializeTimeZones();
      if (!kIsWeb && !Platform.isWindows) {
        String? timeZoneName;
        try {
          final timeZoneInfo = await FlutterTimezone.getLocalTimezone();
          timeZoneName = timeZoneInfo.identifier;
        } catch (_) {}

        if (timeZoneName != null && timeZoneName.isNotEmpty) {
          try {
            tz.setLocalLocation(tz.getLocation(timeZoneName));
            return;
          } catch (_) {}
        }

        // Fallback: match device UTC offset against known timezone locations
        final offset = DateTime.now().timeZoneOffset;
        for (final loc in tz.timeZoneDatabase.locations.values) {
          final nowInLoc = tz.TZDateTime.now(loc);
          if (nowInLoc.timeZoneOffset == offset) {
            tz.setLocalLocation(loc);
            return;
          }
        }
      }
    } catch (tzErr) {
      if (kDebugMode) print('Timezone initialization fallback: $tzErr');
    }
  }

  static Future<void> init() async {
    if (_initialized) return;

    try {
      // 1. Initialize timezone database for exact background alarms with robust fallback
      await _initTimeZone();

      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwinSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      const linuxSettings = LinuxInitializationSettings(defaultActionName: 'Open');

      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
        macOS: darwinSettings,
        linux: linuxSettings,
      );

      if (!kIsWeb && !Platform.isWindows) {
        await _plugin.initialize(
          initSettings,
          onDidReceiveNotificationResponse: (details) {
            if (kDebugMode) print('Notification clicked: ${details.payload}');
            if (details.payload != null && details.payload!.isNotEmpty) {
              _notificationClickController.add(details.payload!);
            }
          },
        );

        if (Platform.isAndroid) {
          final androidImpl = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
          if (androidImpl != null) {
            // Explicitly register notification channels with Android NotificationManager
            try {
              const alarmChannel = AndroidNotificationChannel(
                _alarmChannelId,
                _alarmChannelName,
                description: _alarmChannelDesc,
                importance: Importance.max,
                playSound: true,
                enableVibration: true,
                showBadge: true,
              );
              const dispatchChannel = AndroidNotificationChannel(
                _channelId,
                _channelName,
                description: _channelDesc,
                importance: Importance.max,
                playSound: true,
                enableVibration: true,
                showBadge: true,
              );
              await androidImpl.createNotificationChannel(alarmChannel);
              await androidImpl.createNotificationChannel(dispatchChannel);
            } catch (e) {
              if (kDebugMode) print('Error creating notification channels: $e');
            }

            // Run permission verification asynchronously so Android system prompts or channel IPC
            // never block the startup execution flow or postpone runApp()
            Future.microtask(() async {
              try {
                await androidImpl.requestNotificationsPermission();
                final canExact = await androidImpl.canScheduleExactNotifications() ?? false;
                if (!canExact) {
                  await androidImpl.requestExactAlarmsPermission();
                }
              } catch (_) {}
            });
          }
        }
      }

      _initialized = true;
    } catch (e) {
      if (kDebugMode) print('NotificationService initialization error: $e');
    }
  }

  static void _showWindowsToast(String title, String body) {
    if (!Platform.isWindows) return;
    try {
      final safeTitle = title.replaceAll('"', '`"').replaceAll("'", "`'");
      final safeBody = body.replaceAll('"', '`"').replaceAll("'", "`'");
      final script = '''
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > \$null
\$template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
\$xml = \$template.GetXml()
\$textNodes = \$template.GetElementsByTagName("text")
\$textNodes.Item(0).AppendChild(\$template.CreateTextNode("$safeTitle")) > \$null
\$textNodes.Item(1).AppendChild(\$template.CreateTextNode("$safeBody")) > \$null
\$toast = [Windows.UI.Notifications.ToastNotification]::new(\$template)
\$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("OrdersApp")
\$notifier.Show(\$toast)
''';
      Process.run('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script]);
    } catch (_) {}
  }

  static Future<void> showOrderDispatchedNotification({
    required String title,
    required String description,
    String? assignerName,
    int? rewardTokens,
  }) async {
    try {
      final assigner = assignerName != null && assignerName.isNotEmpty ? assignerName : 'Director';
      final notificationTitle = '⚡ New Directive from $assigner';
      final rewardInfo = rewardTokens != null && rewardTokens > 0 ? ' (+$rewardTokens tokens)' : '';
      final body = '$title$rewardInfo\n$description';

      if (Platform.isWindows) {
        _showWindowsToast(notificationTitle, body);
        return;
      }

      final androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.max,
        priority: Priority.max,
        ticker: 'New Order Received',
        playSound: true,
        enableVibration: true,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.alarm,
        visibility: NotificationVisibility.public,
        styleInformation: BigTextStyleInformation(
          body,
          contentTitle: notificationTitle,
          summaryText: 'Directive Assignment',
        ),
      );

      const darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
      );

      final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _plugin.show(id, notificationTitle, body, details);
    } catch (e) {
      if (kDebugMode) print('Failed to show order notification: $e');
    }
  }

  static Future<void> showProofReviewedNotification({
    required String title,
    required bool approved,
    String? reviewerName,
    int? tokensAwarded,
  }) async {
    try {
      final reviewer = reviewerName != null && reviewerName.isNotEmpty ? reviewerName : 'Director';
      final statusStr = approved ? 'Verified & Approved' : 'Rejected / Revision Requested';
      final notificationTitle = approved ? '✅ Directive Approved ($reviewer)' : '❌ Directive Rejected ($reviewer)';
      final tokenStr = approved && tokensAwarded != null ? ' (+$tokensAwarded tokens)' : '';
      final body = '"$title" has been $statusStr$tokenStr.';

      if (Platform.isWindows) {
        _showWindowsToast(notificationTitle, body);
        return;
      }

      final androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(
          body,
          contentTitle: notificationTitle,
        ),
      );

      const darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
      );

      final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _plugin.show(id, notificationTitle, body, details);
    } catch (e) {
      if (kDebugMode) print('Failed to show proof review notification: $e');
    }
  }

  static Future<void> showPairingRequestNotification({
    required String senderName,
    required String senderCode,
  }) async {
    try {
      final notificationTitle = '🔗 Partner Pairing Request';
      final body = '$senderName ($senderCode) wants to connect and sync directives with you.';

      if (Platform.isWindows) {
        _showWindowsToast(notificationTitle, body);
        return;
      }

      final androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
      );

      const darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
      );

      final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _plugin.show(id, notificationTitle, body, details);
    } catch (e) {
      if (kDebugMode) print('Failed to show pairing request notification: $e');
    }
  }

  static Future<void> showProofSubmittedNotification({
    required String title,
    String? senderName,
    bool isIncompleteTimer = false,
    int? secondsRemaining,
  }) async {
    try {
      final sender = senderName != null && senderName.isNotEmpty ? senderName : 'Player';
      final warningHeader = isIncompleteTimer ? '⚠️ [EARLY SUBMISSION] ' : '📥 ';
      final notificationTitle = '$warningHeader Proof from $sender';
      final timerWarning = isIncompleteTimer && secondsRemaining != null
          ? '\n⚠️ Incomplete Action Timer: ${OrderItem.formatSecondsHuman(secondsRemaining)} left on timer!'
          : '';
      final body = 'Submitted verification proof for "$title"$timerWarning';

      if (Platform.isWindows) {
        _showWindowsToast(notificationTitle, body);
        return;
      }

      final androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.max,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(
          body,
          contentTitle: notificationTitle,
        ),
      );

      const darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
      );

      final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _plugin.show(id, notificationTitle, body, details);
    } catch (e) {
      if (kDebugMode) print('Failed to show proof submitted notification: $e');
    }
  }

  static Future<void> showChatMessageNotification({
    required String senderName,
    required String messageText,
  }) async {
    try {
      final notificationTitle = '💬 Message from $senderName';
      final body = messageText;

      if (Platform.isWindows) {
        _showWindowsToast(notificationTitle, body);
        return;
      }

      final androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
      );

      const darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
      );

      final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _plugin.show(id, notificationTitle, body, details);
    } catch (e) {
      if (kDebugMode) print('Failed to show chat notification: $e');
    }
  }

  static Future<void> showOrderFailedNotification({
    required String title,
    String? playerName,
    String? reason,
  }) async {
    try {
      final player = playerName != null && playerName.isNotEmpty ? playerName : 'Player';
      final notificationTitle = '❌ Directive Failed ($player)';
      final reasonStr = reason != null && reason.isNotEmpty ? '\nReason: $reason' : '';
      final body = '"$title" failed or was forfeited by $player.$reasonStr';

      if (Platform.isWindows) {
        _showWindowsToast(notificationTitle, body);
        return;
      }

      final androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(
          body,
          contentTitle: notificationTitle,
        ),
      );

      const darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
      );

      final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _plugin.show(id, notificationTitle, body, details);
    } catch (e) {
      if (kDebugMode) print('Failed to show order failed notification: $e');
    }
  }

  static Future<void> showGenericNotification({
    required String title,
    required String body,
  }) async {
    try {
      if (Platform.isWindows) {
        _showWindowsToast(title, body);
        return;
      }

      final androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
      );

      const darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
      );

      final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _plugin.show(id, title, body, details);
    } catch (e) {
      if (kDebugMode) print('Failed to show generic notification: $e');
    }
  }

  static Future<void> showCustomNotification({
    required String title,
    required String body,
  }) => showGenericNotification(title: title, body: body);

  /// How many future occurrences of a rule are armed with the OS at once.
  ///
  /// An armed alarm is the only part of the scheduling pipeline that survives
  /// the app process being killed. The alarm chain is normally advanced by
  /// whichever isolate executes the rule — but if Android has killed both the
  /// app and the foreground service, arming only the next occurrence means a
  /// recurring rule announces itself once and then goes silent until the user
  /// happens to open the app. Arming a run of them keeps a daily rule notifying
  /// through five days of total inactivity, and every app open tops the window
  /// back up.
  static const int preArmedOccurrences = 5;

  /// Pre-arms exact OS alarm notifications for a scheduled rule.
  /// Fires even when the app is in deep background, closed, or Doze mode.
  static Future<void> scheduleOrderNotification(ScheduledOrderRule rule) async {
    if (!rule.isEnabled) {
      await cancelOrderNotification(rule.id);
      return;
    }

    final baseId = notificationIdForRule(rule.id);
    final isDirector = rule.targetType == ScheduleTargetType.directorDispatch;
    final staged = rule.stagedOrder ?? rule.specificOrder;
    final orderTitle = staged != null ? staged.title : rule.title;
    final tokenInfo = (staged != null && staged.rewardTokens > 0) ? ' (+${staged.rewardTokens} tokens)' : '';

    final specificTitle = isDirector
        ? '⚡ Scheduled Directive: $orderTitle$tokenInfo'
        : '⚡ Scheduled Task: $orderTitle$tokenInfo';
    final specificBody = (staged != null && staged.description.isNotEmpty)
        ? staged.description
        : (isDirector
            ? 'Directive "${rule.title}" has been dispatched. Open (sub)Task Manager to view.'
            : 'A surprise order is ready for you to complete! Open (sub)Task Manager now.');

    // Only the imminent occurrence knows which task it will deliver: a random
    // draw is re-staged each time the rule executes. Naming this task on a
    // notification days out would promise something the dashboard then
    // contradicts, so later occurrences stay deliberately generic — unless the
    // rule always dispatches one fixed order, where the task cannot change.
    final laterKeepsTask = rule.isSpecificOrder && rule.specificOrder != null;
    final laterTitle = isDirector
        ? '⚡ Scheduled Directive: ${rule.title}'
        : '⚡ Scheduled Task Ready';
    final laterBody = isDirector
        ? 'Directive "${rule.title}" has been dispatched. Open (sub)Task Manager to view.'
        : 'A surprise order is ready for you to complete! Open (sub)Task Manager now.';

    final triggers = rule.upcomingTriggers(preArmedOccurrences);

    for (var slot = 0; slot < triggers.length; slot++) {
      final isImminent = slot == 0 || laterKeepsTask;
      await scheduleExactNotification(
        id: (baseId + slot) & 0x7FFFFFFF,
        title: isImminent ? specificTitle : laterTitle,
        body: isImminent ? specificBody : laterBody,
        scheduledDate: triggers[slot],
        payload: 'rule:${rule.id}',
      );
    }

    // Drop slots left armed by a previous, longer run — a rule switched to
    // one-shot, or edited to stop recurring, must not keep firing.
    for (var stale = triggers.length; stale < preArmedOccurrences; stale++) {
      await cancelNotification((baseId + stale) & 0x7FFFFFFF);
    }
  }

  /// Stable notification id for a rule.
  ///
  /// Uses an explicit FNV-1a hash rather than `String.hashCode`, whose value is
  /// only guaranteed within a single run. An id that shifted between launches
  /// would leave the previous alarm uncancellable, so re-arming a rule would
  /// stack a duplicate alarm instead of replacing the old one.
  static int notificationIdForRule(String ruleId) {
    var hash = 0x811c9dc5;
    for (final unit in ruleId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
  }

  /// Cancels every armed OS alarm for a rule, across the whole pre-armed window.
  static Future<void> cancelOrderNotification(String ruleId) async {
    final baseId = notificationIdForRule(ruleId);
    for (var slot = 0; slot < preArmedOccurrences; slot++) {
      await cancelNotification((baseId + slot) & 0x7FFFFFFF);
    }
  }

  /// Schedules an exact OS alarm notification using flutter_local_notifications
  static Future<void> scheduleExactNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    String? payload,
  }) async {
    try {
      if (kIsWeb || Platform.isWindows) return;

      await init();

      if (scheduledDate.isBefore(DateTime.now())) return;

      final androidDetails = AndroidNotificationDetails(
        _alarmChannelId,
        _alarmChannelName,
        channelDescription: _alarmChannelDesc,
        importance: Importance.max,
        priority: Priority.max,
        ticker: 'Scheduled Directive Ready',
        playSound: true,
        enableVibration: true,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.alarm,
        visibility: NotificationVisibility.public,
        styleInformation: BigTextStyleInformation(
          body,
          contentTitle: title,
          summaryText: 'Scheduled Directive',
        ),
      );

      const darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
      );

      final tzScheduled = tz.TZDateTime.from(scheduledDate, tz.local);

      if (Platform.isAndroid) {
        bool scheduled = false;

        // 1. Try alarmClock mode (highest priority, wakes phone from deep Doze mode, backed by AlarmManager.setAlarmClock)
        try {
          await _plugin.zonedSchedule(
            id,
            title,
            body,
            tzScheduled,
            details,
            androidScheduleMode: AndroidScheduleMode.alarmClock,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
            payload: payload,
          );
          scheduled = true;
        } catch (clockErr) {
          if (kDebugMode) print('alarmClock schedule attempt: $clockErr - falling back to exactAllowWhileIdle');
        }

        // 2. Try exactAllowWhileIdle if alarmClock failed
        if (!scheduled) {
          try {
            await _plugin.zonedSchedule(
              id,
              title,
              body,
              tzScheduled,
              details,
              androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
              uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
              payload: payload,
            );
            scheduled = true;
          } catch (exactErr) {
            if (kDebugMode) print('exactAllowWhileIdle schedule attempt: $exactErr - falling back to inexactAllowWhileIdle');
          }
        }

        // 3. Fallback to inexactAllowWhileIdle if exact modes failed
        if (!scheduled) {
          await _plugin.zonedSchedule(
            id,
            title,
            body,
            tzScheduled,
            details,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
            payload: payload,
          );
        }
      } else {
        await _plugin.zonedSchedule(
          id,
          title,
          body,
          tzScheduled,
          details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          payload: payload,
        );
      }
    } catch (e) {
      if (kDebugMode) print('Failed to schedule exact notification: $e');
    }
  }

  /// Cancels an individual notification by ID
  static Future<void> cancelNotification(int id) async {
    try {
      if (kIsWeb || Platform.isWindows) return;
      await _plugin.cancel(id);
    } catch (e) {
      if (kDebugMode) print('Failed to cancel notification: $e');
    }
  }
}
