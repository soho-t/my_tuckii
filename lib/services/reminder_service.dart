import 'dart:math';
import 'package:drift/drift.dart' as drift;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import '../database/app_database.dart';

class ReminderService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    tz.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('Asia/Taipei'));
    } catch (_) {}

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(initSettings);
    _initialized = true;
  }

  /// 檢查目前是否已允許通知權限
  static Future<bool> isPermissionGranted() async {
    await init();
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl == null) return true;
    return await androidImpl.areNotificationsEnabled() ?? false;
  }

  /// 請求 Android 13+ 通知權限
  static Future<bool> requestPermission() async {
    await init();
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl == null) return true;
    final granted = await androidImpl.requestNotificationsPermission();
    return granted ?? false;
  }

  /// 根據最新設定與資料庫內容，重新排程所有本機定時通知
  static Future<void> rescheduleAll(AppDatabase db) async {
    await init();
    await _plugin.cancelAll();

    final granted = await isPermissionGranted();
    if (!granted) return;

    final prefs = await SharedPreferences.getInstance();
    final dailyEnabled = prefs.getBool('rem_daily_enabled') ?? true;
    final dailyHour = prefs.getInt('rem_daily_hour') ?? 21;
    final dailyMinute = prefs.getInt('rem_daily_minute') ?? 0;

    final staleEnabled = prefs.getBool('rem_stale_enabled') ?? true;
    final staleDays = prefs.getInt('rem_stale_days') ?? 30;

    final weekendEnabled = prefs.getBool('rem_weekend_enabled') ?? false;

    final allItems = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    final unreadItems = allItems.where((i) => !i.isRead).toList();

    // 1. 每日回顧排程 (ID: 101)
    if (dailyEnabled) {
      String body = '打開隨手存，回顧你收藏的精彩內容吧！';
      if (unreadItems.isNotEmpty) {
        final shuffled = List.of(unreadItems)..shuffle(Random());
        final picks = shuffled.take(min(3, shuffled.length)).map((e) => '• ${e.title}').join('\n');
        body = '為你挑選 ${min(3, shuffled.length)} 則待讀收藏：\n$picks';
      }

      await _plugin.zonedSchedule(
        101,
        '隨手存 · 每日回顧',
        body,
        _nextTimeOfDay(dailyHour, dailyMinute),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'daily_review_channel',
            '每日回顧提醒',
            channelDescription: '每天定時挑選 1-3 則舊收藏提醒回顧',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            styleInformation: BigTextStyleInformation(''),
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    }

    // 2. 久未看提醒：每週日 20:00 統計超過 N 天未讀項目 (ID: 102)
    if (staleEnabled) {
      final cutoff = DateTime.now().subtract(Duration(days: staleDays));
      final staleCount =
          unreadItems.where((i) => i.createdAt.isBefore(cutoff)).length;
      final body = staleCount > 0
          ? '目前有 $staleCount 則收藏超過 $staleDays 天還沒看，抽空滑卡片清理一下吧！'
          : '太棒了！目前沒有超過 $staleDays 天未看的積壓收藏。';

      await _plugin.zonedSchedule(
        102,
        '隨手存 · 久未看提醒',
        body,
        _nextWeekdayTime(DateTime.sunday, 20, 0),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'stale_reminder_channel',
            '久未看提醒',
            channelDescription: '每週統計超過指定天數未看的收藏',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
      );
    }

    // 3. 清單週末提醒：每週五 19:00 提醒 (ID: 103)
    if (weekendEnabled) {
      final count = unreadItems.length;
      final body = count > 0
          ? '週末到了！清單裡還有 $count 則未讀收藏（想去的店、想看的文章），趁週末來看看吧！'
          : '週末愉快！打開隨手存整理這週的新靈感吧。';

      await _plugin.zonedSchedule(
        103,
        '隨手存 · 週末清單提醒',
        body,
        _nextWeekdayTime(DateTime.friday, 19, 0),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'weekend_reminder_channel',
            '清單週末提醒',
            channelDescription: '每週五 19:00 提醒查看週末清單',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
      );
    }
  }

  /// 立即發送一則每日回顧測試通知
  static Future<void> sendInstantReviewPreview(AppDatabase db) async {
    await init();
    final allItems = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(false) & t.isRead.equals(false)))
        .get();

    String body = '目前沒有未讀收藏，快去新增幾筆連結或截圖吧！';
    if (allItems.isNotEmpty) {
      final shuffled = List.of(allItems)..shuffle(Random());
      final picks = shuffled
          .take(min(3, shuffled.length))
          .map((e) => '• ${e.title}')
          .join('\n');
      body = '為你挑選 ${min(3, shuffled.length)} 則待讀收藏：\n$picks';
    }

    await _plugin.show(
      999,
      '隨手存 · 每日回顧（立即預覽）',
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'daily_review_channel',
          '每日回顧提醒',
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: BigTextStyleInformation(''),
        ),
      ),
    );
  }

  /// 掃描所有連結項目是否失效（404 / 410），並自動標記 #失效連結
  static Future> runLinkHealthCheck(AppDatabase db) async {
    final linkItems = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(false) & t.itemType.equals('link')))
        .get();

    int checked = 0;
    int broken = 0;

    for (final item in linkItems) {
      final rawUrl = item.url?.trim();
      if (rawUrl == null || rawUrl.isEmpty) continue;
      final uri = Uri.tryParse(rawUrl);
      if (uri == null) continue;

      checked++;
      bool isDead = false;

      try {
        // 針對 YouTube 影片使用 oEmbed 檢查是否已被下架或設為私人
        if (rawUrl.contains('youtube.com/watch') || rawUrl.contains('youtu.be/')) {
          final oembed = Uri.parse(
              'https://www.youtube.com/oembed?url=${Uri.encodeComponent(rawUrl)}&format=json');
          final resp = await http.get(oembed).timeout(const Duration(seconds: 6));
          if (resp.statusCode == 404 || resp.statusCode == 401 || resp.statusCode == 403) {
            isDead = true;
          }
        } else {
          final resp = await http.head(uri, headers: {
            'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
          }).timeout(const Duration(seconds: 6));
          if (resp.statusCode == 404 || resp.statusCode == 410) {
            isDead = true;
          }
        }
      } catch (_) {
        // 逾時或防爬蟲不誤判為失效
      }

      if (isDead) {
        broken++;
        final currentTags = item.tags ?? '';
        if (!currentTags.contains('失效連結')) {
          final updatedTags =
              currentTags.isEmpty ? '失效連結' : '$currentTags, 失效連結';
          await (db.update(db.savedItems)..where((t) => t.id.equals(item.id)))
              .write(
            SavedItemsCompanion(
              tags: drift.Value(updatedTags),
              updatedAt: drift.Value(DateTime.now()),
            ),
          );
        }
      }
    }

    if (broken > 0 && await isPermissionGranted()) {
      await _plugin.show(
        104,
        '隨手存 · 連結健康檢查結果',
        '共檢查 $checked 個連結，發現 $broken 個原作連結已失效（已自動標記 #失效連結）。',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'link_health_channel',
            '連結健康檢查',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    }

    return {'checked': checked, 'broken': broken};
  }

  static tz.TZDateTime _nextTimeOfDay(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }

  static tz.TZDateTime _nextWeekdayTime(int weekday, int hour, int minute) {
    var scheduled = _nextTimeOfDay(hour, minute);
    while (scheduled.weekday != weekday) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }
}