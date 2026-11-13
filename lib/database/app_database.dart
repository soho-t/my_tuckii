import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

class Collections extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 50)();
  TextColumn get iconName => text().withDefault(const Constant('folder'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class SavedItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get itemType => text()(); // 'link' | 'image' | 'note'
  TextColumn get url => text().nullable()();
  TextColumn get title => text().withDefault(const Constant('未命名項目'))();
  TextColumn get note => text().nullable()();
  TextColumn get tags => text().nullable()();
  TextColumn get localImagePath => text().nullable()();
  IntColumn get collectionId =>
      integer().nullable().references(Collections, #id, onDelete: KeyAction.setNull)();
  BoolColumn get isRead => boolean().withDefault(const Constant(false))();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DriftDatabase(tables: [Collections, SavedItems])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  Stream<List<SavedItem>> watchUnreadItems() {
    return (select(savedItems)
          ..where((t) => t.isRead.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  Future<void> markAsRead(int id) {
    return (update(savedItems)..where((t) => t.id.equals(id)))
        .write(const SavedItemsCompanion(isRead: Value(true)));
  }

  Stream<List<Collection>> watchAllCollections() {
    return (select(collections)..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).watch();
  }

  Future<int> createCollection(String name) {
    return into(collections).insert(CollectionsCompanion.insert(name: name));
  }

  Future<void> deleteCollection(int id) {
    return (delete(collections)..where((t) => t.id.equals(id))).go();
  }

  Future<void> batchMoveItems(List<int> ids, int? collectionId) {
    return (update(savedItems)..where((t) => t.id.isIn(ids)))
        .write(SavedItemsCompanion(collectionId: Value(collectionId)));
  }

  Future<void> batchDeleteItems(List<SavedItem> itemsToDelete) async {
    for (final item in itemsToDelete) {
      if (item.localImagePath != null) {
        final file = File(item.localImagePath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
    final ids = itemsToDelete.map((e) => e.id).toList();
    await (delete(savedItems)..where((t) => t.id.isIn(ids))).go();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'my_tuckii.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
