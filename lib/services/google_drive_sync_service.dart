import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' as drift;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../database/app_database.dart';

class _GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();
  _GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _client.send(request..headers.addAll(_headers));
  }

  @override
  void close() {
    _client.close();
  }
}

class GoogleDriveSyncService {
  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId: '426482376122-d67pj2oc5r92duld51f9k7kb35no37rp.apps.googleusercontent.com',
    scopes: [drive.DriveApi.driveAppdataScope],
  );

  static GoogleSignInAccount? get currentUser => _googleSignIn.currentUser;

  /// 嘗試靜默登入已綁定的帳號
  static Future<GoogleSignInAccount?> signInSilently() async {
    try {
      return await _googleSignIn.signInSilently();
    } catch (_) {
      return null;
    }
  }

  /// 跳出 Google 帳號選擇視窗進行綁定
  static Future<GoogleSignInAccount?> signIn() async {
    return await _googleSignIn.signIn();
  }

  static Future<void> signOut() async {
    await _googleSignIn.disconnect();
  }

  /// 執行秒級增量差異同步：
  /// 1. 合併輕量 sync_index.json（僅幾 KB）
  /// 2. 僅上傳新增的本地截圖/文件，僅下載缺失的雲端截圖/文件
  static Future<String> syncNow(AppDatabase db) async {
    GoogleSignInAccount? account = _googleSignIn.currentUser;
    account ??= await _googleSignIn.signInSilently();
    account ??= await _googleSignIn.signIn();

    if (account == null) {
      throw Exception('已取消 Google 帳號登入');
    }

    final headers = await account.authHeaders;
    final authClient = _GoogleAuthClient(headers);

    try {
      final driveApi = drive.DriveApi(authClient);
      final docDir = await getApplicationDocumentsDirectory();

      // 1. 列出雲端 appDataFolder 內現有檔案清單
      final fileList = await driveApi.files.list(
        spaces: 'appDataFolder',
        $fields: 'files(id, name, modifiedTime)',
        pageSize: 1000,
      );
      final remoteFiles = fileList.files ?? [];
      final Map<String, drive.File> remoteByName = {
        for (var f in remoteFiles)
          if (f.name != null) f.name!: f
      };

      // 2. 下載雲端輕量索引 sync_index.json（若存在）並進行雙向合併
      final remoteIndexFile = remoteByName['sync_index.json'];
      if (remoteIndexFile != null && remoteIndexFile.id != null) {
        final media = await driveApi.files.get(
          remoteIndexFile.id!,
          downloadOptions: drive.DownloadOptions.fullMedia,
        ) as drive.Media;

        final jsonStr = await utf8.decoder.bind(media.stream).join();
        final Map<String, dynamic> remoteData = jsonDecode(jsonStr);
        await _mergeRemoteData(db, remoteData, docDir.path);
      }

      // 3. 取得合併後的最新本機資料，整理需要上傳的差異檔案
      final allCols = await db.select(db.collections).get();
      final allItems = await db.select(db.savedItems).get();

      final Map<int, String> colIdToUuid = {for (var c in allCols) c.id: c.syncUuid};
      int uploadedCount = 0;
      int downloadedCount = 0;

      // 4. 針對有效項目同步實體媒體檔案（只傳差異！）
      for (final item in allItems) {
        if (item.isDeleted || item.localImagePath == null) continue;

        final fileName = p.basename(item.localImagePath!);
        final subFolder = item.itemType == 'image' ? 'screenshots' : 'files';
        final expectedLocalFile = File(p.join(docDir.path, subFolder, fileName));
        final actualLocalFile = File(item.localImagePath!);

        if (await actualLocalFile.exists() && !remoteByName.containsKey(fileName)) {
          // 本機有、雲端沒有 -> 上傳這一個新檔案
          final driveMeta = drive.File()
            ..name = fileName
            ..parents = ['appDataFolder'];
          await driveApi.files.create(
            driveMeta,
            uploadMedia: drive.Media(actualLocalFile.openRead(), await actualLocalFile.length()),
          );
          uploadedCount++;
        } else if (!await expectedLocalFile.exists() && remoteByName.containsKey(fileName)) {
          // 雲端有、本機沒有 -> 下載這一個新檔案
          final rFile = remoteByName[fileName]!;
          if (rFile.id != null) {
            await expectedLocalFile.parent.create(recursive: true);
            final media = await driveApi.files.get(
              rFile.id!,
              downloadOptions: drive.DownloadOptions.fullMedia,
            ) as drive.Media;
            final sink = expectedLocalFile.openWrite();
            await media.stream.pipe(sink);
            await sink.close();

            // 更新本機資料庫路徑指向新下載的檔案
            await (db.update(db.savedItems)..where((t) => t.id.equals(item.id))).write(
              SavedItemsCompanion(localImagePath: drift.Value(expectedLocalFile.path)),
            );
            downloadedCount++;
          }
        }
      }

      // 5. 清理雲端已刪除項目的殘留媒體檔
      for (final item in allItems) {
        if (item.isDeleted && item.localImagePath != null) {
          final fileName = p.basename(item.localImagePath!);
          final rFile = remoteByName[fileName];
          if (rFile != null && rFile.id != null) {
            try {
              await driveApi.files.delete(rFile.id!);
            } catch (_) {}
          }
        }
      }

      // 6. 產生最新輕量 sync_index.json 並上傳覆蓋至雲端
      final exportPayload = {
        'version': 1,
        'syncedAt': DateTime.now().toIso8601String(),
        'collections': allCols
            .map((c) => {
                  'syncUuid': c.syncUuid,
                  'name': c.name,
                  'iconName': c.iconName,
                  'createdAt': c.createdAt.toIso8601String(),
                  'updatedAt': c.updatedAt.toIso8601String(),
                  'isDeleted': c.isDeleted,
                })
            .toList(),
        'items': allItems
            .map((i) => {
                  'syncUuid': i.syncUuid,
                  'collectionUuid': i.collectionId != null ? colIdToUuid[i.collectionId] : null,
                  'itemType': i.itemType,
                  'url': i.url,
                  'title': i.title,
                  'note': i.note,
                  'tags': i.tags,
                  'mediaFileName': i.localImagePath != null ? p.basename(i.localImagePath!) : null,
                  'isRead': i.isRead,
                  'isPinned': i.isPinned,
                  'isDeleted': i.isDeleted,
                  'createdAt': i.createdAt.toIso8601String(),
                  'updatedAt': i.updatedAt.toIso8601String(),
                })
            .toList(),
      };

      final indexBytes = utf8.encode(jsonEncode(exportPayload));
      final indexStream = Stream.value(indexBytes);
      final indexMedia = drive.Media(indexStream, indexBytes.length);

      if (remoteIndexFile != null && remoteIndexFile.id != null) {
        await driveApi.files.update(drive.File(), remoteIndexFile.id!, uploadMedia: indexMedia);
      } else {
        final newMeta = drive.File()
          ..name = 'sync_index.json'
          ..parents = ['appDataFolder'];
        await driveApi.files.create(newMeta, uploadMedia: indexMedia);
      }

      return '同步完成！上傳 $uploadedCount 個新檔、下載 $downloadedCount 個新檔';
    } finally {
      authClient.close();
    }
  }

  /// 依據 updatedAt 時間戳合併雲端與本機紀錄（較新者勝出）
  static Future<void> _mergeRemoteData(
    AppDatabase db,
    Map<String, dynamic> remoteData,
    String docDirPath,
  ) async {
    final List<dynamic> remoteCols = remoteData['collections'] ?? [];
    final List<dynamic> remoteItems = remoteData['items'] ?? [];

    final localCols = await db.select(db.collections).get();
    final Map<String, Collection> localColMap = {for (var c in localCols) c.syncUuid: c};

    for (final rc in remoteCols) {
      final uuid = rc['syncUuid'] as String;
      final remoteUpdated = DateTime.parse(rc['updatedAt'] as String);
      final local = localColMap[uuid];

      if (local == null) {
        await db.into(db.collections).insert(
              CollectionsCompanion.insert(
                syncUuid: drift.Value(uuid),
                name: rc['name'] as String,
                iconName: drift.Value(rc['iconName'] as String? ?? 'folder'),
                createdAt: drift.Value(DateTime.parse(rc['createdAt'] as String)),
                updatedAt: drift.Value(remoteUpdated),
                isDeleted: drift.Value(rc['isDeleted'] as bool? ?? false),
              ),
            );
      } else if (remoteUpdated.isAfter(local.updatedAt)) {
        await (db.update(db.collections)..where((t) => t.id.equals(local.id))).write(
          CollectionsCompanion(
            name: drift.Value(rc['name'] as String),
            updatedAt: drift.Value(remoteUpdated),
            isDeleted: drift.Value(rc['isDeleted'] as bool? ?? false),
          ),
        );
      }
    }

    // 重新建立最新的 collectionUuid -> localId 對照表
    final updatedCols = await db.select(db.collections).get();
    final Map<String, int> uuidToColId = {for (var c in updatedCols) c.syncUuid: c.id};

    final localItems = await db.select(db.savedItems).get();
    final Map<String, SavedItem> localItemMap = {for (var i in localItems) i.syncUuid: i};

    for (final ri in remoteItems) {
      final uuid = ri['syncUuid'] as String;
      final remoteUpdated = DateTime.parse(ri['updatedAt'] as String);
      final colUuid = ri['collectionUuid'] as String?;
      final mappedColId = colUuid != null ? uuidToColId[colUuid] : null;
      final mediaName = ri['mediaFileName'] as String?;
      final itemType = ri['itemType'] as String;
      final isDeleted = ri['isDeleted'] as bool? ?? false;

      String? expectedPath;
      if (mediaName != null) {
        final subFolder = itemType == 'image' ? 'screenshots' : 'files';
        expectedPath = p.join(docDirPath, subFolder, mediaName);
      }

      final local = localItemMap[uuid];
      if (local == null) {
        await db.into(db.savedItems).insert(
              SavedItemsCompanion.insert(
                syncUuid: drift.Value(uuid),
                collectionId: drift.Value(mappedColId),
                itemType: itemType,
                url: drift.Value(ri['url'] as String?),
                title: drift.Value(ri['title'] as String? ?? '未命名項目'),
                note: drift.Value(ri['note'] as String?),
                tags: drift.Value(ri['tags'] as String?),
                localImagePath: drift.Value(expectedPath),
                isRead: drift.Value(ri['isRead'] as bool? ?? false),
                isPinned: drift.Value(ri['isPinned'] as bool? ?? false),
                isDeleted: drift.Value(isDeleted),
                createdAt: drift.Value(DateTime.parse(ri['createdAt'] as String)),
                updatedAt: drift.Value(remoteUpdated),
              ),
            );
      } else if (remoteUpdated.isAfter(local.updatedAt)) {
        if (isDeleted && local.localImagePath != null) {
          final f = File(local.localImagePath!);
          if (await f.exists()) await f.delete();
        }
        await (db.update(db.savedItems)..where((t) => t.id.equals(local.id))).write(
          SavedItemsCompanion(
            collectionId: drift.Value(mappedColId),
            title: drift.Value(ri['title'] as String? ?? local.title),
            note: drift.Value(ri['note'] as String?),
            tags: drift.Value(ri['tags'] as String?),
            localImagePath: drift.Value(expectedPath ?? local.localImagePath),
            isRead: drift.Value(ri['isRead'] as bool? ?? local.isRead),
            isPinned: drift.Value(ri['isPinned'] as bool? ?? local.isPinned),
            isDeleted: drift.Value(isDeleted),
            updatedAt: drift.Value(remoteUpdated),
          ),
        );
      }
    }
  }
}