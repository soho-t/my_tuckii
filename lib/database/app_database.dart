import 'dart:io';
import 'dart:math';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

String generateSyncUuid() {
  final rand = Random.secure();
  final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final r1 = rand.nextInt(1 << 32).toRadixString(36);
  final r2 = rand.nextInt(1 << 32).toRadixString(36);
  return '$ts-$r1-$r2';
}

class Collections extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncUuid => text().clientDefault(generateSyncUuid)();
  TextColumn get name => text().withLength(min: 1, max: 50)();
  TextColumn get iconName => text().withDefault(const Constant('folder'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

class SavedItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncUuid => text().clientDefault(generateSyncUuid)();
  IntColumn get collectionId => integer().nullable().references(Collections, #id)();
  TextColumn get itemType => text()(); // 'link', 'image', 'file', 'note'
  TextColumn get url => text().nullable()();
  TextColumn get title => text().withDefault(const Constant('未命名項目'))();
  TextColumn get note => text().nullable()();
  TextColumn get tags => text().nullable()();
  TextColumn get localImagePath => text().nullable()();
  BoolColumn get isRead => boolean().withDefault(const Constant(false))();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

@DriftDatabase(tables: [Collections, SavedItems])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(collections);
            await m.addColumn(savedItems, savedItems.collectionId);
            await m.addColumn(savedItems, savedItems.tags);
            await m.addColumn(savedItems, savedItems.isPinned);
          }
          if (from < 3) {
            await m.addColumn(collections, collections.syncUuid);
            await m.addColumn(collections, collections.updatedAt);
            await m.addColumn(collections, collections.isDeleted);
            await m.addColumn(savedItems, savedItems.syncUuid);
            await m.addColumn(savedItems, savedItems.isDeleted);
            await m.addColumn(savedItems, savedItems.updatedAt);
          }
        },
      );

  Stream<List<SavedItem>> watchAllItems() {
    return (select(savedItems)
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([
            (t) => OrderingTerm.desc(t.isPinned),
            (t) => OrderingTerm.desc(t.createdAt),
          ]))
        .watch();
  }

  Stream<List<SavedItem>> watchUnreadItems() {
    return (select(savedItems)
          ..where((t) => t.isRead.equals(false) & t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  Future<int> markAsRead(int id) {
    return (update(savedItems)..where((t) => t.id.equals(id))).write(
      SavedItemsCompanion(
        isRead: const Value(true),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 軟刪除：標記 isDeleted = true 並清理本機實體檔，確保同步時能通知其他裝置一併刪除
  Future<void> softDeleteItem(SavedItem item) async {
    if (item.localImagePath != null) {
      final file = File(item.localImagePath!);
      if (await file.exists()) await file.delete();
    }
    await (update(savedItems)..where((t) => t.id.equals(item.id))).write(
      SavedItemsCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Stream<List<Collection>> watchAllCollections() {
    return (select(collections)
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch();
  }

  Future<int> createCollection(String name) {
    return into(collections).insert(CollectionsCompanion.insert(name: name));
  }

  Future<void> deleteCollection(int id) async {
    await (update(savedItems)..where((t) => t.collectionId.equals(id))).write(
      SavedItemsCompanion(
        collectionId: const Value(null),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await (update(collections)..where((t) => t.id.equals(id))).write(
      CollectionsCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> batchMoveItems(List<int> ids, int? targetCollectionId) {
    return (update(savedItems)..where((t) => t.id.isIn(ids))).write(
      SavedItemsCompanion(
        collectionId: Value(targetCollectionId),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> batchDeleteItems(List<SavedItem> itemsToDelete) async {
    for (final item in itemsToDelete) {
      await softDeleteItem(item);
    }
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'my_tuckii.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
