import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import '../database/app_database.dart';

class LinkHealthResult {
  final int checked;
  final int broken;
  final bool skippedNoWifi;

  const LinkHealthResult({
    required this.checked,
    required this.broken,
    this.skippedNoWifi = false,
  });
}

class ReminderService {
  static const int persistentClipNotifId = 888;

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static void Function(String payload)? _onNotificationTap;

  static Future<void> init({void Function(String payload)? onTap}) async {
    if (onTap != null) {
      _onNotificationTap = onTap;
    }
    if (_initialized) return;

    tz.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('Asia/Taipei'));
    } catch (_) {}

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (details) {
        final payload = details.payload;
        if (payload != null && payload.isNotEmpty) {
          _onNotificationTap?.call(payload);
        }
      },
    );
    _initialized = true;
  }

  static Future<String?> getLaunchPayload() async {
    await init();
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details != null && details.didNotificationLaunchApp) {
      return details.notificationResponse?.payload;
    }
    return null;
  }

  static Future<bool> isPermissionGranted() async {
    await init();
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl == null) return true;
    return await androidImpl.areNotificationsEnabled() ?? false;
  }

  static Future<bool> requestPermission() async {
    await init();
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl == null) return true;
    final granted = await androidImpl.requestNotificationsPermission();
    return granted ?? false;
  }

  /// 開啟或關閉通知欄「存剪貼簿」常駐通知 (ID: 888)
  static Future<void> setPersistentClipboardNotification(bool enabled) async {
    await init();
    if (!enabled) {
      await _plugin.cancel(persistentClipNotifId);
      return;
    }

    final granted = await isPermissionGranted();
    if (!granted) return;

    await _plugin.show(
      persistentClipNotifId,
      '隨手存 · 存剪貼簿',
      '複製抖音、小紅書或網頁連結後，點這裡一鍵收藏',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'persistent_clip_channel',
          '剪貼簿快速收錄常駐列',
          channelDescription: '在通知欄常駐一鍵存入剪貼簿的快捷按鈕',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          playSound: false,
          enableVibration: false,
          onlyAlertOnce: true,
        ),
      ),
      payload: 'quick_clip_save',
    );
  }

  /// 重新排程所有本機通知（並自動保留已開啟的剪貼簿常駐通知）
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
    final persistentClip = prefs.getBool('setting_persistent_clip_notif') ?? false;

    final allItems = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    final unreadItems = allItems.where((i) => !i.isRead).toList();

    // 1. 每日回顧：預排未來 14 天獨立推播 (ID: 201~214)
    if (dailyEnabled) {
      final baseTime = _nextTimeOfDay(dailyHour, dailyMinute);
      final random = Random();

      for (int dayOffset = 0; dayOffset < 14; dayOffset++) {
        String body = '打開隨手存，花 1 分鐘回顧你的待讀靈感吧！';
        if (unreadItems.isNotEmpty) {
          final shuffled = List.of(unreadItems)..shuffle(random);
          final pickCount = min(3, shuffled.length);
          final picks =
              shuffled.take(pickCount).map((e) => '• ${e.title}').join('\n');
          body = '為你挑選 $pickCount 則待讀收藏：\n$picks';
        }

        await _plugin.zonedSchedule(
          201 + dayOffset,
          '隨手存 · 每日回顧',
          body,
          baseTime.add(Duration(days: dayOffset)),
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
          payload: 'daily_review',
        );
      }
    }

    // 2. 久未看提醒：每週日 20:00
    if (staleEnabled) {
      await _plugin.zonedSchedule(
        102,
        '隨手存 · 久未看提醒',
        '看看有沒有放超過 $staleDays 天還沒讀的收藏，抽空滑卡片整理一下吧！',
        _nextWeekdayTime(DateTime.sunday, 20, 0),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'stale_reminder_channel',
            '久未看提醒',
            channelDescription: '每週提醒整理放太久未看的收藏',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        payload: 'stale_review',
      );
    }

    // 3. 清單週末提醒：每週五 19:00
    if (weekendEnabled) {
      await _plugin.zonedSchedule(
        103,
        '隨手存 · 週末清單提醒',
        '週末到了！打開隨手存看看清單裡想去的店、想做的菜或待讀靈感吧！',
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
        payload: 'weekend_review',
      );
    }

    // 4. 若已啟用剪貼簿常駐通知，重新補回
    if (persistentClip) {
      await setPersistentClipboardNotification(true);
    }
  }

  static Future<void> sendInstantReviewPreview(AppDatabase db) async {
    await init();
    final allItems = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(false) & t.isRead.equals(false)))
        .get();

    String body = '目前沒有未讀收藏，快去新增幾筆連結或截圖吧！';
    if (allItems.isNotEmpty) {
      final shuffled = List.of(allItems)..shuffle(Random());
      final pickCount = min(3, shuffled.length);
      final picks =
          shuffled.take(pickCount).map((e) => '• ${e.title}').join('\n');
      body = '為你挑選 $pickCount 則待讀收藏：\n$picks';
    }

    await _plugin.show(
      999,
      '隨手存 · 每日回顧（點擊進入複習）',
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
      payload: 'daily_review',
    );
  }

  static Future<LinkHealthResult> runLinkHealthCheck(
    AppDatabase db, {
    bool requireWifi = false,
    void Function(int current, int total)? onProgress,
  }) async {
    if (requireWifi) {
      try {
        final results = await Connectivity().checkConnectivity();
        if (!results.contains(ConnectivityResult.wifi)) {
          return const LinkHealthResult(
            checked: 0,
            broken: 0,
            skippedNoWifi: true,
          );
        }
      } catch (_) {}
    }

    final allLinks = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(false) & t.itemType.equals('link')))
        .get();

    final targets = allLinks.where((item) {
      final rawUrl = item.url?.trim() ?? '';
      if (rawUrl.isEmpty || Uri.tryParse(rawUrl) == null) return false;
      if ((item.tags ?? '').contains('失效連結')) return false;
      return true;
    }).toList();

    final total = targets.length;
    onProgress?.call(0, total);

    int checked = 0;
    int broken = 0;
    const batchSize = 5;

    for (int i = 0; i < targets.length; i += batchSize) {
      final batch = targets.sublist(i, min(i + batchSize, targets.length));
      final results = await Future.wait(
        batch.map((item) => _checkSingleLink(db, item)),
      );
      checked += batch.length;
      broken += results.where((isDead) => isDead).length;
      onProgress?.call(checked, total);
    }

    if (broken > 0 && await isPermissionGranted()) {
      await _plugin.show(
        104,
        '隨手存 · 連結健康檢查結果',
        '共掃描 $checked 個連結，新發現 $broken 個失效連結（點擊檢視 #失效連結）。',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'link_health_channel',
            '連結健康檢查',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: 'link_health',
      );
    }

    return LinkHealthResult(checked: checked, broken: broken);
  }

  static Future<bool> _checkSingleLink(AppDatabase db, SavedItem item) async {
    final rawUrl = item.url!.trim();
    final uri = Uri.parse(rawUrl);
    bool isDead = false;

    try {
      if (rawUrl.contains('youtube.com/watch') ||
          rawUrl.contains('youtu.be/') ||
          rawUrl.contains('youtube.com/shorts/')) {
        final oembed = Uri.parse(
            'https://www.youtube.com/oembed?url=${Uri.encodeComponent(rawUrl)}&format=json');
        final resp = await http.get(oembed).timeout(const Duration(seconds: 6));
        if (resp.statusCode == 404 ||
            resp.statusCode == 401 ||
            resp.statusCode == 403) {
          isDead = true;
        }
      } else if (rawUrl.contains('open.spotify.com/')) {
        final oembed = Uri.parse(
            'https://open.spotify.com/oembed?url=${Uri.encodeComponent(rawUrl)}');
        final resp = await http.get(oembed).timeout(const Duration(seconds: 6));
        if (resp.statusCode == 404 || resp.statusCode == 410) {
          isDead = true;
        }
      } else if ((rawUrl.contains('x.com/') ||
              rawUrl.contains('twitter.com/')) &&
          rawUrl.contains('/status/')) {
        final oembed = Uri.parse(
            'https://publish.twitter.com/oembed?url=${Uri.encodeComponent(rawUrl)}');
        final resp = await http.get(oembed).timeout(const Duration(seconds: 6));
        if (resp.statusCode == 404 || resp.statusCode == 403) {
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
    } catch (_) {}

    if (isDead) {
      final currentTags = item.tags ?? '';
      final updatedTags = currentTags.isEmpty ? '失效連結' : '$currentTags, 失效連結';
      await (db.update(db.savedItems)..where((t) => t.id.equals(item.id)))
          .write(
        SavedItemsCompanion(
          tags: drift.Value(updatedTags),
          updatedAt: drift.Value(DateTime.now()),
        ),
      );
    }

    return isDead;
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