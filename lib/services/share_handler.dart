import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:metadata_fetch/metadata_fetch.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import '../database/app_database.dart';

class ShareHandlerService {
  final AppDatabase db;
  StreamSubscription? _intentSub;

  ShareHandlerService(this.db);

  void init(Function(String message) onSavedCallback) {
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (List<SharedMediaFile> value) {
        if (value.isNotEmpty) {
          _processSharedFiles(value, onSavedCallback);
        }
      },
    );

    ReceiveSharingIntent.instance.getInitialMedia().then(
      (List<SharedMediaFile> value) {
        if (value.isNotEmpty) {
          _processSharedFiles(value, onSavedCallback);
          ReceiveSharingIntent.instance.reset();
        }
      },
    );
  }

  Future<void> _processSharedFiles(
    List<SharedMediaFile> files,
    Function(String) onSavedCallback,
  ) async {
    for (var file in files) {
      if (file.type == SharedMediaType.text || file.type == SharedMediaType.url) {
        await _handleSharedText(file.path, onSavedCallback);
      } else if (file.type == SharedMediaType.image) {
        await _handleSharedImage(file.path, onSavedCallback);
      }
    }
  }

  Future<void> _handleSharedText(String rawText, Function(String) onSavedCallback) async {
    final urlRegExp = RegExp(r'(https?:\/\/[^\s]+)');
    final match = urlRegExp.firstMatch(rawText);
    final cleanUrl = match != null ? match.group(0)! : rawText.trim();

    final itemId = await db.into(db.savedItems).insert(
          SavedItemsCompanion.insert(
            itemType: 'link',
            url: Value(cleanUrl),
            title: Value(cleanUrl),
          ),
        );

    onSavedCallback('已儲存連結');

    try {
      final data = await MetadataFetch.extract(cleanUrl);
      if (data != null && data.title != null && data.title!.trim().isNotEmpty) {
        await (db.update(db.savedItems)..where((t) => t.id.equals(itemId))).write(
          SavedItemsCompanion(
            title: Value(data.title!.trim()),
            note: Value(data.description?.trim()),
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _handleSharedImage(String tempImagePath, Function(String) onSavedCallback) async {
    final appDir = await getApplicationDocumentsDirectory();
    final vaultDir = Directory(p.join(appDir.path, 'screenshots'));
    if (!await vaultDir.exists()) {
      await vaultDir.create(recursive: true);
    }

    final fileName = 'img_${DateTime.now().millisecondsSinceEpoch}.webp';
    final targetPath = p.join(vaultDir.path, fileName);

    final compressedFile = await FlutterImageCompress.compressAndGetFile(
      tempImagePath,
      targetPath,
      quality: 80,
      format: CompressFormat.webp,
    );

    final finalPath = compressedFile?.path ?? tempImagePath;

    await db.into(db.savedItems).insert(
          SavedItemsCompanion.insert(
            itemType: 'image',
            title: Value('螢幕截圖 ${DateTime.now().month}/${DateTime.now().day}'),
            localImagePath: Value(finalPath),
          ),
        );

    onSavedCallback('已儲存截圖');
  }

  void dispose() {
    _intentSub?.cancel();
  }
}
