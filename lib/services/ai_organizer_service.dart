import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' as drift;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../database/app_database.dart';

typedef JsonMap = Map<String, dynamic>;

class AiTagResult {
  final List<String> tags;
  final String? suggestedCollection;
  final String? suggestedTitle;
  final String? summary;

  const AiTagResult({
    required this.tags,
    this.suggestedCollection,
    this.suggestedTitle,
    this.summary,
  });
}

class AiSearchResult {
  final String answer;
  final List<SavedItem> matchedItems;

  const AiSearchResult({
    required this.answer,
    required this.matchedItems,
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

  static String _detectMimeType(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    if (ext == '.png') return 'image/png';
    if (ext == '.webp') return 'image/webp';
    if (ext == '.gif') return 'image/gif';
    return 'image/jpeg';
  }

  static Future<JsonMap?> _buildImagePart(String? imagePath) async {
    if (imagePath == null || imagePath.trim().isEmpty) return null;
    final file = File(imagePath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > 15 * 1024 * 1024) return null;
    return {
      'inline_data': {
        'mime_type': _detectMimeType(imagePath),
        'data': base64Encode(bytes),
      },
    };
  }

  static Future<String> _callGemini({
    required List<JsonMap> parts,
    bool jsonOutput = false,
    double temperature = 0.2,
  }) async {
    final apiKey = await getApiKey();
    if (apiKey.isEmpty) {
      throw Exception('請先填入 Gemini API Key');
    }

    final endpoint = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$_modelName:generateContent?key=$apiKey',
    );

    final JsonMap generationConfig = {
      'temperature': temperature,
    };
    if (jsonOutput) {
      generationConfig['responseMimeType'] = 'application/json';
    }

    final resp = await http
        .post(
          endpoint,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {'parts': parts}
            ],
            'generationConfig': generationConfig,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (resp.statusCode != 200) {
      throw Exception('Gemini API 回應錯誤 (${resp.statusCode})');
    }

    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    final text =
        decoded['candidates']?[0]?['content']?['parts']?[0]?['text']?.toString() ?? '';
    return text.trim();
  }

  static String _stripCodeFence(String text) {
    return text
        .replaceAll(RegExp(r'^```json\s*'), '')
        .replaceAll(RegExp(r'^```\s*'), '')
        .replaceAll(RegExp(r'\s*```$'), '')
        .trim();
  }

  static bool _isGenericImageTitle(String title) {
    final lower = title.toLowerCase();
    return lower.startsWith('截圖') ||
        lower.startsWith('screenshot') ||
        lower.startsWith('img_') ||
        lower.startsWith('pxl_') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp');
  }

  /// 呼叫 Gemini API 產生 2~4 個繁體中文標籤、建議收藏夾，若為截圖則同步識圖產出標題與摘要
  static Future<AiTagResult?> suggestTags({
    required String title,
    String? url,
    String? note,
    String? imagePath,
    required List<String> existingCollections,
  }) async {
    final apiKey = await getApiKey();
    if (apiKey.isEmpty) return null;

    final colList =
        existingCollections.isEmpty ? '（尚無自訂收藏夾）' : existingCollections.join('、');
    final imagePart = await _buildImagePart(imagePath);
    final hasImage = imagePart != null;

    final prompt = '''
你是個人書籤、截圖與筆記整理助手。請使用臺灣繁體中文回覆。
請根據以下收藏內容${hasImage ? '（包含附圖畫面中的文字與資訊）' : ''}，完成以下項目：
1. tags：產生 2 到 4 個簡短精準的標籤（每個 2~5 字，不要加 # 符號）。
2. collection：若「現有收藏夾清單」中有高度符合的資料夾，回傳完全一致的名稱；若都不符合則回傳 null。
3. title：${hasImage ? '根據圖片內容給一個簡短好找的標題（15 字以內，例如「板橋早午餐菜單」、「高鐵訂票明細」）。' : '回傳 null。'}
4. summary：${hasImage ? '擷取圖片中的關鍵文字、店名、日期、金額或重點摘要（100 字以內，方便日後關鍵字搜尋）。' : '回傳 null。'}

現有收藏夾清單：$colList
目前標題：$title
網址：${url ?? '無'}
備註內容：${(note ?? '無').length > 300 ? note!.substring(0, 300) : (note ?? '無')}

請只輸出 JSON，格式固定如下：
{"tags": ["標籤1", "標籤2"], "collection": null, "title": null, "summary": null}
''';

    final List<JsonMap> parts = [
      {'text': prompt},
      if (imagePart != null) imagePart,
    ];

    final text = await _callGemini(parts: parts, jsonOutput: true);
    if (text.isEmpty) return null;

    final parsed = jsonDecode(_stripCodeFence(text));
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

    final titleRaw = parsed['title']?.toString().trim();
    final suggestedTitle =
        (titleRaw != null && titleRaw.isNotEmpty && titleRaw != 'null')
            ? titleRaw
            : null;

    final summaryRaw = parsed['summary']?.toString().trim();
    final summary =
        (summaryRaw != null && summaryRaw.isNotEmpty && summaryRaw != 'null')
            ? summaryRaw
            : null;

    return AiTagResult(
      tags: tags,
      suggestedCollection: matchedCol,
      suggestedTitle: suggestedTitle,
      summary: summary,
    );
  }

  /// 針對網頁、截圖或筆記產生 3 點重點懶人包摘要
  static Future<String> summarizeItem({
    required String title,
    String? url,
    String? note,
    String? imagePath,
  }) async {
    final imagePart = await _buildImagePart(imagePath);
    String webContent = '';

    if (imagePart == null && url != null && url.trim().startsWith('http')) {
      try {
        final resp = await http.get(
          Uri.parse(url.trim()),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36',
          },
        ).timeout(const Duration(seconds: 8));
        if (resp.statusCode == 200) {
          final htmlStr = utf8.decode(resp.bodyBytes, allowMalformed: true);
          final doc = html_parser.parse(htmlStr);
          doc.querySelectorAll('script, style, noscript, svg').forEach((e) => e.remove());
          final rawText = (doc.body?.text ?? '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (rawText.isNotEmpty) {
            webContent = rawText.length > 4000 ? rawText.substring(0, 4000) : rawText;
          }
        }
      } catch (_) {}
    }

    final prompt = '''
請使用自然流暢的臺灣繁體中文，針對以下收藏內容整理出「3 點重點摘要」：
- 每點以「• 」開頭，精簡扼要（每點 1～2 句）。
- 若為截圖，請優先擷取圖中的關鍵資訊（如店名、地址、金額、日期、帳號或步驟）。
- 不要加開場白或結語，直接輸出 3 點重點。

標題：$title
網址：${url ?? '無'}
既有備註：${note ?? '無'}
${webContent.isNotEmpty ? '網頁正文摘錄：$webContent' : ''}
''';

    final List<JsonMap> parts = [
      {'text': prompt},
      if (imagePart != null) imagePart,
    ];

    final summary = await _callGemini(parts: parts, jsonOutput: false, temperature: 0.3);
    if (summary.isEmpty) {
      throw Exception('AI 未回傳摘要內容，請稍後再試');
    }
    return summary;
  }

  /// 自然語言智慧搜尋：用口語提問從收藏庫中篩選最相關項目
  static Future<AiSearchResult> naturalLanguageSearch(
    AppDatabase db,
    String userQuery,
  ) async {
    final allItems = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => drift.OrderingTerm.desc(t.createdAt)])
          ..limit(150))
        .get();

    if (allItems.isEmpty) {
      return const AiSearchResult(
        answer: '目前收藏庫內還沒有任何項目。',
        matchedItems: [],
      );
    }

    final cols = await (db.select(db.collections)
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    final colMap = {for (final c in cols) c.id: c.name};
    final itemMap = {for (final i in allItems) i.id: i};

    final buffer = StringBuffer();
    for (final item in allItems) {
      final colName = item.collectionId != null ? (colMap[item.collectionId!] ?? '未分類') : '未分類';
      final noteSnippet = (item.note ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
      final shortNote = noteSnippet.length > 80 ? '${noteSnippet.substring(0, 80)}...' : noteSnippet;
      final dateStr = item.createdAt.toString().substring(0, 10);
      buffer.writeln(
        '[ID:${item.id}] 標題:${item.title} | 類型:${item.itemType} | 資料夾:$colName | 標籤:${item.tags ?? '無'} | 摘要:$shortNote | 日期:$dateStr',
      );
    }

    final prompt = '''
你是個人收藏庫智慧搜尋助手。請根據使用者的提問，從下方收藏清單中找出最相關的項目（最多 10 筆，依相關度由高到低排序）。
請用自然簡潔的臺灣繁體中文撰寫 1～2 句回覆說明找到了什麼（若找不到請如實說明）。

使用者提問：$userQuery

收藏清單：
${buffer.toString()}

請只輸出 JSON，格式固定如下：
{"answer": "簡短回答文字", "matched_ids": [12, 5, 8]}
''';

    final text = await _callGemini(
      parts: [
        {'text': prompt}
      ],
      jsonOutput: true,
      temperature: 0.1,
    );

    if (text.isEmpty) {
      return const AiSearchResult(answer: '未能取得 AI 搜尋結果，請稍後再試。', matchedItems: []);
    }

    final parsed = jsonDecode(_stripCodeFence(text));
    final answer = (parsed['answer'] ?? '以下是為你找到的相關收藏：').toString().trim();
    final rawIds = (parsed['matched_ids'] as List?) ?? [];

    final matched = <SavedItem>[];
    final seen = <int>{};
    for (final rawId in rawIds) {
      final id = int.tryParse(rawId.toString());
      if (id != null && !seen.contains(id) && itemMap.containsKey(id)) {
        seen.add(id);
        matched.add(itemMap[id]!);
      }
    }

    return AiSearchResult(answer: answer, matchedItems: matched);
  }

  /// 背景整理單一項目（支援網址、文字筆記與本機截圖）
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

    final isImage = item.itemType == 'image';
    final res = await suggestTags(
      title: item.title,
      url: item.url,
      note: item.note,
      imagePath: isImage ? item.localImagePath : null,
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

    final updatedTitle = (isImage &&
            res.suggestedTitle != null &&
            _isGenericImageTitle(item.title))
        ? res.suggestedTitle!
        : item.title;

    final updatedNote = (isImage &&
            res.summary != null &&
            (item.note ?? '').trim().isEmpty)
        ? res.summary
        : item.note;

    await (db.update(db.savedItems)..where((t) => t.id.equals(item.id))).write(
      SavedItemsCompanion(
        title: drift.Value(updatedTitle),
        note: drift.Value(updatedNote),
        tags: drift.Value(res.tags.join(', ')),
        collectionId: drift.Value(newColId),
        updatedAt: drift.Value(DateTime.now()),
      ),
    );
    return true;
  }

  /// 一鍵整理所有尚未加上標籤的收藏項目（含截圖識圖整理）
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
        final isImage = item.itemType == 'image';
        final res = await suggestTags(
          title: item.title,
          url: item.url,
          note: item.note,
          imagePath: isImage ? item.localImagePath : null,
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

          final updatedTitle = (isImage &&
                  res.suggestedTitle != null &&
                  _isGenericImageTitle(item.title))
              ? res.suggestedTitle!
              : item.title;

          final updatedNote = (isImage &&
                  res.summary != null &&
                  (item.note ?? '').trim().isEmpty)
              ? res.summary
              : item.note;

          await (db.update(db.savedItems)..where((t) => t.id.equals(item.id)))
              .write(
            SavedItemsCompanion(
              title: drift.Value(updatedTitle),
              note: drift.Value(updatedNote),
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