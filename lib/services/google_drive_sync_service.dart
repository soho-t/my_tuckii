import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' as drift;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  static const String _boundPrefKey = 'is_google_drive_bound';

  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId: '426482376122-d67pj2oc5r92duld51f9k7kb35no37rp.apps.googleusercontent.com',
    scopes: [drive.DriveApi.driveAppdataScope],
  );

  static bool _isBoundCache = false;

  static GoogleSignInAccount? get currentUser =>
      _isBoundCache ? _googleSignIn.currentUser : null;

  static Future<GoogleSignInAccount?> signInSilently() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isBoundCache = prefs.getBool(_boundPrefKey) ?? false;
      if (!_isBoundCache) {
        return null;
      }
      final account = await _googleSignIn.signInSilently();
      if (account == null) {
        _isBoundCache = false;
        await prefs.setBool(_boundPrefKey, false);
      }
      return account;
    } catch (_) {
      return null;
    }
  }

  static Future<GoogleSignInAccount?> signIn() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}

    final account = await _googleSignIn.signIn();
    if (account != null) {
      _isBoundCache = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_boundPrefKey, true);
    }
    return account;
  }

  static Future<void> signOut() async {
    _isBoundCache = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_boundPrefKey, false);
    try {
      await _googleSignIn.disconnect();
    } catch (_) {
      await _googleSignIn.signOut();
    }
  }

  /// 徹底刪除雲端 appDataFolder 所有同步檔案並解除帳號授權
  static Future<void> deleteCloudDataAndDisconnect() async {
    try {
      final account = _googleSignIn.currentUser ?? await _googleSignIn.signInSilently();
      if (account != null) {
        final headers = await account.authHeaders;
        final authClient = _GoogleAuthClient(headers);
        try {
          final driveApi = drive.DriveApi(authClient);
          final fileList = await driveApi.files.list(
            spaces: 'appDataFolder',
            $fields: 'files(id)',
            pageSize: 1000,
          );
          for (final f in (fileList.files ?? [])) {
            if (f.id != null) {
              try {
                await driveApi.files.delete(f.id!);
              } catch (_) {}
            }
          }
        } finally {
          authClient.close();
        }
      }
    } catch (_) {}
    await signOut();
  }

  static Future<String> syncNow(AppDatabase db) async {
    final prefs = await SharedPreferences.getInstance();
    _isBoundCache = prefs.getBool(_boundPrefKey) ?? false;

    GoogleSignInAccount? account;
    if (_isBoundCache) {
      account = _googleSignIn.currentUser ?? await _googleSignIn.signInSilently();
    }
    account ??= await signIn();

    if (account == null) {
      throw Exception('已取消 Google 帳號登入');
    }

    final headers = await account.authHeaders;
    final authClient = _GoogleAuthClient(headers);

    try {
      final driveApi = drive.DriveApi(authClient);
      final docDir = await getApplicationDocumentsDirectory();

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

      final allCols = await db.select(db.collections).get();
      final allItems = await db.select(db.savedItems).get();

      final Map<int, String> colIdToUuid = {for (var c in allCols) c.id: c.syncUuid};
      int uploadedCount = 0;
      int downloadedCount = 0;

      for (final item in allItems) {
        if (item.isDeleted || item.localImagePath == null) continue;

        final fileName = p.basename(item.localImagePath!);
        final subFolder = item.itemType == 'image' ? 'screenshots' : 'files';
        final expectedLocalFile = File(p.join(docDir.path, subFolder, fileName));
        final actualLocalFile = File(item.localImagePath!);

        if (await actualLocalFile.exists() && !remoteByName.containsKey(fileName)) {
          final driveMeta = drive.File()
            ..name = fileName
            ..parents = ['appDataFolder'];
          await driveApi.files.create(
            driveMeta,
            uploadMedia: drive.Media(actualLocalFile.openRead(), await actualLocalFile.length()),
          );
          uploadedCount++;
        } else if (!await expectedLocalFile.exists() && remoteByName.containsKey(fileName)) {
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

            await (db.update(db.savedItems)..where((t) => t.id.equals(item.id))).write(
              SavedItemsCompanion(localImagePath: drift.Value(expectedLocalFile.path)),
            );
            downloadedCount++;
          }
        }
      }

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