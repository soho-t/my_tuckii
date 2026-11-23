import 'dart:convert';
import 'package:drift/drift.dart' as drift;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../database/app_database.dart';

class AiTagResult {
  final List<String> tags;
  final String? suggestedCollection;

  const AiTagResult({
    required this.tags,
    this.suggestedCollection,
  });
}

class AiOrganizerService {
  static const String _apiKeyPref = 'ai_gemini_api_key';
  static const String _autoTagPref = 'ai_auto_tag_enabled';
  static const String _modelName = 'gemini-2.5-flash';

  static Future<String> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_apiKeyPref)?.trim() ?? '';
  }

  static Future<void> saveApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiKeyPref, key.trim());
  }

  static Future<bool> isAutoTagEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoTagPref) ?? false;
  }

  static Future<void> setAutoTagEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoTagPref, enabled);
  }

  /// 呼叫 Gemini API 產生 2~4 個繁體中文標籤與建議收藏夾
  static Future<AiTagResult?> suggestTags({
    required String title,
    String? url,
    String? note,
    required List<String> existingCollections,
  }) async {
    final apiKey = await getApiKey();
    if (apiKey.isEmpty) return null;

    final colList =
        existingCollections.isEmpty ? '（尚無自訂收藏夾）' : existingCollections.join('、');

    final prompt = '''
你是個人書籤與筆記整理助手。請根據以下收藏內容，產生 2 到 4 個簡短精準的臺灣繁體中文標籤（每個 2~5 字，不要加 # 符號）。
另外，若「現有收藏夾清單」中有高度符合的資料夾，請回傳完全一致的名稱；若都不符合則回傳 null。

現有收藏夾清單：$colList
標題：$title
網址：${url ?? '無'}
內容摘要：${(note ?? '無').length > 300 ? note!.substring(0, 300) : (note ?? '無')}

請只輸出 JSON，格式固定如下：
{"tags": ["標籤1", "標籤2"], "collection": null}
''';

    final endpoint = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$_modelName:generateContent?key=$apiKey',
    );

    final resp = await http
        .post(
          endpoint,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt}
                ]
              }
            ],
            'generationConfig': {
              'responseMimeType': 'application/json',
              'temperature': 0.2,
            },
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (resp.statusCode != 200) {
      throw Exception('Gemini API 回應錯誤 (${resp.statusCode})');
    }

    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    final text =
        decoded['candidates']?[0]?['content']?['parts']?[0]?['text']?.toString() ?? '';
    if (text.isEmpty) return null;

    final cleaned = text
        .replaceAll(RegExp(r'^```json\s*'), '')
        .replaceAll(RegExp(r'^```\s*'), '')
        .replaceAll(RegExp(r'\s*```$'), '')
        .trim();

    final parsed = jsonDecode(cleaned);
    final rawTags = (parsed['tags'] as List?) ?? [];
    final tags = rawTags
        .map((e) => e.toString().replaceAll('#', '').trim())
        .where((e) => e.isNotEmpty)
        .take(4)
        .toList();

    final colRaw = parsed['collection']?.toString().trim();
    final matchedCol = (colRaw != null &&
            colRaw.isNotEmpty &&
            colRaw != 'null' &&
            existingCollections.contains(colRaw))
        ? colRaw
        : null;

    return AiTagResult(tags: tags, suggestedCollection: matchedCol);
  }

  /// 背景整理單一項目（供新增收藏後自動呼叫）
  static Future<bool> organizeSingleItemById(AppDatabase db, int itemId) async {
    final apiKey = await getApiKey();
    if (apiKey.isEmpty) return false;

    final item = await (db.select(db.savedItems)
          ..where((t) => t.id.equals(itemId)))
        .getSingleOrNull();
    if (item == null || item.isDeleted) return false;

    final cols = await (db.select(db.collections)
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    final colNames = cols.map((c) => c.name).toList();

    final res = await suggestTags(
      title: item.title,
      url: item.url,
      note: item.note,
      existingCollections: colNames,
    );
    if (res == null || res.tags.isEmpty) return false;

    int? newColId = item.collectionId;
    if (newColId == null && res.suggestedCollection != null) {
      for (final c in cols) {
        if (c.name == res.suggestedCollection) {
          newColId = c.id;
          break;
        }
      }
    }

    await (db.update(db.savedItems)..where((t) => t.id.equals(item.id))).write(
      SavedItemsCompanion(
        tags: drift.Value(res.tags.join(', ')),
        collectionId: drift.Value(newColId),
        updatedAt: drift.Value(DateTime.now()),
      ),
    );
    return true;
  }

  /// 一鍵整理所有尚未加上標籤的收藏項目
  static Future<int> organizeUntaggedItems(
    AppDatabase db, {
    void Function(int current, int total)? onProgress,
  }) async {
    final apiKey = await getApiKey();
    if (apiKey.isEmpty) {
      throw Exception('請先填入 Gemini API Key');
    }

    final allItems = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    final targets = allItems
        .where((i) => (i.tags ?? '').trim().isEmpty)
        .toList();

    final cols = await (db.select(db.collections)
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    final colNames = cols.map((c) => c.name).toList();

    final total = targets.length;
    onProgress?.call(0, total);

    int successCount = 0;
    for (int i = 0; i < targets.length; i++) {
      final item = targets[i];
      try {
        final res = await suggestTags(
          title: item.title,
          url: item.url,
          note: item.note,
          existingCollections: colNames,
        );
        if (res != null && res.tags.isNotEmpty) {
          int? newColId = item.collectionId;
          if (newColId == null && res.suggestedCollection != null) {
            for (final c in cols) {
              if (c.name == res.suggestedCollection) {
                newColId = c.id;
                break;
              }
            }
          }
          await (db.update(db.savedItems)..where((t) => t.id.equals(item.id)))
              .write(
            SavedItemsCompanion(
              tags: drift.Value(res.tags.join(', ')),
              collectionId: drift.Value(newColId),
              updatedAt: drift.Value(DateTime.now()),
            ),
          );
          successCount++;
        }
      } catch (_) {}
      onProgress?.call(i + 1, total);
    }

    return successCount;
  }
}