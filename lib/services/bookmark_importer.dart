import 'dart:io';
import 'package:drift/drift.dart';
import 'package:file_picker/file_picker.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import '../database/app_database.dart';

class BookmarkImporterService {
  static Future<int?> importFromHtmlFile(AppDatabase db) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['html', 'htm'],
    );

    if (result == null || result.files.single.path == null) {
      return null;
    }

    final file = File(result.files.single.path!);
    final htmlContent = await file.readAsString();
    final document = html_parser.parse(htmlContent);

    final existingCollections = await db.select(db.collections).get();
    final Map<String, int> collectionMap = {
      for (var c in existingCollections) c.name.toLowerCase(): c.id,
    };

    final existingItems = await db.select(db.savedItems).get();
    final Set<String> existingUrls = existingItems
        .where((item) => item.url != null)
        .map((item) => item.url!.trim())
        .toSet();

    const ignoredFolders = {'書籤列', 'Bookmarks bar', '其他書籤', 'Other bookmarks', 'Bookmarks'};
    final List<SavedItemsCompanion> itemsToInsert = [];

    final anchorElements = document.querySelectorAll('a');

    for (final anchor in anchorElements) {
      final rawHref = anchor.attributes['href']?.trim();
      if (rawHref == null || !rawHref.startsWith('http')) continue;
      if (existingUrls.contains(rawHref)) continue;

      final title = anchor.text.trim().isNotEmpty ? anchor.text.trim() : rawHref;
      final tags = anchor.attributes['tags']?.trim();

      DateTime createdAt = DateTime.now();
      final addDateStr = anchor.attributes['add_date'];
      if (addDateStr != null) {
        final timestamp = int.tryParse(addDateStr);
        if (timestamp != null) {
          createdAt = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
        }
      }

      final folderName = _findParentFolderName(anchor);
      int? targetCollectionId;

      if (folderName != null && !ignoredFolders.contains(folderName)) {
        final key = folderName.toLowerCase();
        if (collectionMap.containsKey(key)) {
          targetCollectionId = collectionMap[key];
        } else {
          final newColId = await db.createCollection(folderName);
          collectionMap[key] = newColId;
          targetCollectionId = newColId;
        }
      }

      existingUrls.add(rawHref);

      itemsToInsert.add(
        SavedItemsCompanion.insert(
          itemType: 'link',
          url: Value(rawHref),
          title: Value(title),
          tags: Value(tags),
          collectionId: Value(targetCollectionId),
          isRead: const Value(true),
          createdAt: Value(createdAt),
        ),
      );
    }

    if (itemsToInsert.isNotEmpty) {
      await db.batch((batch) {
        batch.insertAll(db.savedItems, itemsToInsert);
      });
    }

    return itemsToInsert.length;
  }

  static String? _findParentFolderName(dom.Element anchor) {
    dom.Element? current = anchor.parent;
    while (current != null) {
      if (current.localName == 'dl') {
        dom.Element? prev = current.previousElementSibling;
        if (prev != null && prev.localName == 'h3') {
          return prev.text.trim();
        }
        final parentDt = current.parent;
        if (parentDt != null && parentDt.localName == 'dt') {
          final h3 = parentDt.querySelector('h3');
          if (h3 != null) return h3.text.trim();
        }
      }
      current = current.parent;
    }
    return null;
  }
}
