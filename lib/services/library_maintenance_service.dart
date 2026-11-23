import 'dart:io';
import 'package:drift/drift.dart' as drift;
import '../database/app_database.dart';

class TagStat {
  final String name;
  final int count;

  const TagStat({required this.name, required this.count});
}

class DuplicateGroup {
  final String normalizedUrl;
  final List<SavedItem> items;

  const DuplicateGroup({
    required this.normalizedUrl,
    required this.items,
  });
}

class LibraryMaintenanceService {
  // 常見社群與廣告追蹤參數（比對重複網址時自動忽略）
  static const Set<String> _trackingParams = {
    'fbclid',
    'gclid',
    'dclid',
    'igshid',
    'si',
    'ref',
    'ref_src',
    'ref_url',
    'spm',
    'share_id',
    'feature',
    'mc_cid',
    'mc_eid',
    's',
    't',
  };

  // ==================== 1. 回收桶功能 ====================

  static Stream<List<SavedItem>> watchTrashedItems(AppDatabase db) {
    return (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(true))
          ..orderBy([(t) => drift.OrderingTerm.desc(t.updatedAt)]))
        .watch();
  }

  static Future<void> restoreItem(AppDatabase db, int id) async {
    await (db.update(db.savedItems)..where((t) => t.id.equals(id))).write(
      SavedItemsCompanion(
        isDeleted: const drift.Value(false),
        updatedAt: drift.Value(DateTime.now()),
      ),
    );
  }

  static Future<int> restoreAll(AppDatabase db) async {
    final trashed = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(true)))
        .get();
    if (trashed.isEmpty) return 0;

    await (db.update(db.savedItems)..where((t) => t.isDeleted.equals(true)))
        .write(
      SavedItemsCompanion(
        isDeleted: const drift.Value(false),
        updatedAt: drift.Value(DateTime.now()),
      ),
    );
    return trashed.length;
  }

  static Future<void> permanentlyDeleteItem(AppDatabase db, SavedItem item) async {
    if (item.localImagePath != null && item.localImagePath!.isNotEmpty) {
      try {
        final f = File(item.localImagePath!);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }
    await (db.delete(db.savedItems)..where((t) => t.id.equals(item.id))).go();
  }

  static Future<int> emptyTrash(AppDatabase db) async {
    final trashed = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(true)))
        .get();
    for (final item in trashed) {
      await permanentlyDeleteItem(db, item);
    }
    return trashed.length;
  }

  // ==================== 2. 標籤雲與批次管理 ====================

  static List<String> _parseTags(String? raw) {
    if (raw == null || raw.trim().isEmpty) return [];
    return raw
        .split(RegExp(r'[,，、\s]+'))
        .map((e) => e.replaceAll('#', '').trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static Future<List<TagStat>> getAllTagStats(AppDatabase db) async {
    final items = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(false)))
        .get();

    final counts = <String, int>{};
    for (final item in items) {
      final uniqueTags = _parseTags(item.tags).toSet();
      for (final tag in uniqueTags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }

    final stats = counts.entries
        .map((e) => TagStat(name: e.key, count: e.value))
        .toList();
    stats.sort((a, b) {
      final cmp = b.count.compareTo(a.count);
      return cmp != 0 ? cmp : a.name.compareTo(b.name);
    });
    return stats;
  }

  /// 重新命名標籤；若目標名稱已存在，會自動合併並去除同項目內的重複標籤
  static Future<int> renameOrMergeTag(
    AppDatabase db,
    String oldTag,
    String newTag,
  ) async {
    final cleanedNew = newTag.replaceAll('#', '').trim();
    if (cleanedNew.isEmpty || cleanedNew == oldTag) return 0;

    final items = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(false)))
        .get();

    int affected = 0;
    for (final item in items) {
      final tags = _parseTags(item.tags);
      if (!tags.contains(oldTag)) continue;

      final updatedList = <String>[];
      final seen = <String>{};
      for (final t in tags) {
        final target = (t == oldTag) ? cleanedNew : t;
        if (seen.add(target)) {
          updatedList.add(target);
        }
      }

      await (db.update(db.savedItems)..where((t) => t.id.equals(item.id))).write(
        SavedItemsCompanion(
          tags: drift.Value(updatedList.join(', ')),
          updatedAt: drift.Value(DateTime.now()),
        ),
      );
      affected++;
    }
    return affected;
  }

  static Future<int> deleteTagFromAll(AppDatabase db, String tagToDelete) async {
    final items = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(false)))
        .get();

    int affected = 0;
    for (final item in items) {
      final tags = _parseTags(item.tags);
      if (!tags.contains(tagToDelete)) continue;

      final updatedList = tags.where((t) => t != tagToDelete).toList();
      await (db.update(db.savedItems)..where((t) => t.id.equals(item.id))).write(
        SavedItemsCompanion(
          tags: drift.Value(updatedList.isEmpty ? null : updatedList.join(', ')),
          updatedAt: drift.Value(DateTime.now()),
        ),
      );
      affected++;
    }
    return affected;
  }

  // ==================== 3. 重複連結偵測與合併 ====================

  static String normalizeUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return trimmed.toLowerCase();

    var host = uri.host.toLowerCase();
    if (host.startsWith('www.')) host = host.substring(4);
    if (host.startsWith('m.')) host = host.substring(2);

    // 統一 YouTube 短網址格式（youtu.be/ID -> youtube.com/watch?v=ID）
    if (host == 'youtu.be' && uri.pathSegments.isNotEmpty) {
      return 'youtube.com/watch?v=${uri.pathSegments.first}';
    }

    var path = uri.path;
    while (path.endsWith('/') && path.length > 1) {
      path = path.substring(0, path.length - 1);
    }
    if (path == '/') path = '';

    final cleanParams = <String, String>{};
    uri.queryParameters.forEach((key, value) {
      final lowerKey = key.toLowerCase();
      if (!lowerKey.startsWith('utm_') && !_trackingParams.contains(lowerKey)) {
        cleanParams[key] = value;
      }
    });

    final sortedKeys = cleanParams.keys.toList()..sort();
    final queryStr = sortedKeys.map((k) => '$k=${cleanParams[k]}').join('&');

    return queryStr.isEmpty ? '$host$path' : '$host$path?$queryStr';
  }

  static Future<List<DuplicateGroup>> findDuplicateLinks(AppDatabase db) async {
    final links = await (db.select(db.savedItems)
          ..where((t) => t.isDeleted.equals(false) & t.itemType.equals('link'))
          ..orderBy([(t) => drift.OrderingTerm.desc(t.createdAt)]))
        .get();

    final grouped = <String, List<SavedItem>>{};
    for (final item in links) {
      final rawUrl = item.url?.trim() ?? '';
      if (rawUrl.isEmpty) continue;
      final norm = normalizeUrl(rawUrl);
      grouped.putIfAbsent(norm, () => []).add(item);
    }

    final result = grouped.entries
        .where((e) => e.value.length > 1)
        .map((e) => DuplicateGroup(normalizedUrl: e.key, items: e.value))
        .toList();

    result.sort((a, b) => b.items.length.compareTo(a.items.length));
    return result;
  }

  /// 合併單一重複群組：保留最完整的一筆，整併標籤與備註，多餘的移入回收桶
  static Future<int> mergeDuplicateGroup(
    AppDatabase db,
    DuplicateGroup group,
  ) async {
    if (group.items.length < 2) return 0;

    final sorted = List<SavedItem>.from(group.items);
    sorted.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      final aHasCol = a.collectionId != null ? 1 : 0;
      final bHasCol = b.collectionId != null ? 1 : 0;
      if (aHasCol != bHasCol) return bHasCol.compareTo(aHasCol);
      final aNoteLen = (a.note ?? '').trim().length;
      final bNoteLen = (b.note ?? '').trim().length;
      if (aNoteLen != bNoteLen) return bNoteLen.compareTo(aNoteLen);
      return b.createdAt.compareTo(a.createdAt);
    });

    final keeper = sorted.first;
    final duplicates = sorted.sublist(1);

    final mergedTags = <String>[];
    final seenTags = <String>{};
    for (final item in sorted) {
      for (final tag in _parseTags(item.tags)) {
        if (seenTags.add(tag)) mergedTags.add(tag);
      }
    }

    final mergedNotes = <String>[];
    for (final item in sorted) {
      final n = (item.note ?? '').trim();
      if (n.isNotEmpty && !mergedNotes.contains(n)) {
        mergedNotes.add(n);
      }
    }

    int? finalColId = keeper.collectionId;
    if (finalColId == null) {
      for (final dup in duplicates) {
        if (dup.collectionId != null) {
          finalColId = dup.collectionId;
          break;
        }
      }
    }

    final anyPinned = sorted.any((i) => i.isPinned);

    await (db.update(db.savedItems)..where((t) => t.id.equals(keeper.id))).write(
      SavedItemsCompanion(
        tags: drift.Value(mergedTags.isEmpty ? null : mergedTags.join(', ')),
        note: drift.Value(mergedNotes.isEmpty ? null : mergedNotes.join('\n\n')),
        collectionId: drift.Value(finalColId),
        isPinned: drift.Value(anyPinned),
        updatedAt: drift.Value(DateTime.now()),
      ),
    );

    for (final dup in duplicates) {
      await (db.update(db.savedItems)..where((t) => t.id.equals(dup.id))).write(
        SavedItemsCompanion(
          isDeleted: const drift.Value(true),
          updatedAt: drift.Value(DateTime.now()),
        ),
      );
    }

    return duplicates.length;
  }

  static Future<int> mergeAllDuplicates(AppDatabase db) async {
    final groups = await findDuplicateLinks(db);
    int removedCount = 0;
    for (final g in groups) {
      removedCount += await mergeDuplicateGroup(db, g);
    }
    return removedCount;
  }
}