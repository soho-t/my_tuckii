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

  /// 瑼Ｘ?桀??臬撌脣?閮梢甈?
  static Future<bool> isPermissionGranted() async {
    await init();
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl == null) return true;
    return await androidImpl.areNotificationsEnabled() ?? false;
  }

  /// 隢? Android 13+ ?甈?
  static Future<bool> requestPermission() async {
    await init();
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl == null) return true;
    final granted = await androidImpl.requestNotificationsPermission();
    return granted ?? false;
  }

  /// ?寞???啗身摰?鞈?摨怠摰對??????璈??
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

    // 1. 瘥?“?? (ID: 101)
    if (dailyEnabled) {
      String body = '???冽?摮??“雿??蝎曉蔗?批捆?改?';
      if (unreadItems.isNotEmpty) {
        final shuffled = List.of(unreadItems)..shuffle(Random());
        final picks = shuffled.take(min(3, shuffled.length)).map((e) => '??${e.title}').join('\n');
        body = '?箔?? ${min(3, shuffled.length)} ??霈?嗉?嚗n$picks';
      }

      await _plugin.zonedSchedule(
        101,
        '?冽?摮?繚 瘥?“',
        body,
        _nextTimeOfDay(dailyHour, dailyMinute),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'daily_review_channel',
            '瘥?“??',
            channelDescription: '瘥予摰?? 1-3 ???嗉????“',
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

    // 2. 銋????瘥望 20:00 蝯梯?頞? N 憭拇霈? (ID: 102)
    if (staleEnabled) {
      final cutoff = DateTime.now().subtract(Duration(days: staleDays));
      final staleCount =
          unreadItems.where((i) => i.createdAt.isBefore(cutoff)).length;
      final body = staleCount > 0
          ? '?桀???$staleCount ?????$staleDays 憭拚?瘝?嚗蝛箸??∠?皜?銝銝嚗?
          : '憭芣?鈭??桀?瘝?頞? $staleDays 憭拇??蝛??嗉???;

      await _plugin.zonedSchedule(
        102,
        '?冽?摮?繚 銋????,
        body,
        _nextWeekdayTime(DateTime.sunday, 20, 0),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'stale_reminder_channel',
            '銋????,
            channelDescription: '瘥梁絞閮???摰予?豢???嗉?',
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

    // 3. 皜?望??嚗??曹? 19:00 ?? (ID: 103)
    if (weekendEnabled) {
      final count = unreadItems.length;
      final body = count > 0
          ? '?望?唬?嚗??株ㄐ?? $count ?霈?嗉?嚗?餌?摨????嚗?頞望靘??嚗?
          : '?望?翰嚗?????渡??梁??圈????;

      await _plugin.zonedSchedule(
        103,
        '?冽?摮?繚 ?望皜??',
        body,
        _nextWeekdayTime(DateTime.friday, 19, 0),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'weekend_reminder_channel',
            '皜?望??',
            channelDescription: '瘥曹? 19:00 ???亦??望皜',
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

  /// 蝡?潮????亙?憿扳葫閰阡
  static Future<void> sendInstantReviewPreview(AppDatabase db) async {
    await init();
    final allItems = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(false) & t.isRead.equals(false)))
        .get();

    String body = '?桀?瘝??芾??嗉?嚗翰?餅憓嗾蝑????嚗?;
    if (allItems.isNotEmpty) {
      final shuffled = List.of(allItems)..shuffle(Random());
      final picks = shuffled
          .take(min(3, shuffled.length))
          .map((e) => '??${e.title}')
          .join('\n');
      body = '?箔?? ${min(3, shuffled.length)} ??霈?嗉?嚗n$picks';
    }

    await _plugin.show(
      999,
      '?冽?摮?繚 瘥?“嚗??喲?閬踝?',
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'daily_review_channel',
          '瘥?“??',
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: BigTextStyleInformation(''),
        ),
      ),
    );
  }

  /// ????????臬憭望?嚗?04 / 410嚗?銝西??閮?#憭望????
  static Future<Map<String, int>> runLinkHealthCheck(AppDatabase db) async {
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
        // ?? YouTube 敶梁?雿輻 oEmbed 瑼Ｘ?臬撌脰◤銝?身?箇?鈭?
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
        // ?暹???祈銝炊?斤憭望?
      }

      if (isDead) {
        broken++;
        final currentTags = item.tags ?? '';
        if (!currentTags.contains('憭望????')) {
          final updatedTags =
              currentTags.isEmpty ? '憭望????' : '$currentTags, 憭望????';
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
        '?冽?摮?繚 ????亙熒瑼Ｘ蝯?',
        '?望炎??$checked ???嚗??$broken ??雿??撌脣仃??撌脰??閮?#憭望????嚗?,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'link_health_channel',
            '????亙熒瑼Ｘ',
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

