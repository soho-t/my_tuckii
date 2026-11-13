import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../database/app_database.dart';

class BackupService {
  static Future<void> exportBackup(AppDatabase db) async {
    final docDir = await getApplicationDocumentsDirectory();
    final tempDir = await getTemporaryDirectory();

    final dbFile = File(p.join(docDir.path, 'my_tuckii.sqlite'));
    final screenshotsDir = Directory(p.join(docDir.path, 'screenshots'));

    if (!await dbFile.exists()) {
      throw Exception('找不到資料庫檔案，無法備份');
    }

    await db.customStatement('PRAGMA wal_checkpoint(FULL);');

    final now = DateTime.now();
    final timestamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final zipPath = p.join(tempDir.path, 'MyTuckii_Backup_$timestamp.zip');

    final encoder = ZipFileEncoder();
    encoder.create(zipPath);
    await encoder.addFile(dbFile, 'my_tuckii.sqlite');

    if (await screenshotsDir.exists()) {
      await encoder.addDirectory(screenshotsDir, includeDirName: true);
    }
    encoder.close();

    await Share.shareXFiles(
      [XFile(zipPath)],
      subject: '隨手存備份檔 ($timestamp)',
    );
  }

  static Future<AppDatabase?> importBackup(AppDatabase currentDb) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );

    if (result == null || result.files.single.path == null) {
      return null;
    }

    final zipFile = File(result.files.single.path!);
    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final hasValidDb = archive.any((file) => file.name == 'my_tuckii.sqlite');
    if (!hasValidDb) {
      throw Exception('無效的備份檔：壓縮包內找不到資料庫');
    }

    final docDir = await getApplicationDocumentsDirectory();
    await currentDb.close();

    for (final suffix in ['', '-wal', '-shm']) {
      final oldFile = File(p.join(docDir.path, 'my_tuckii.sqlite$suffix'));
      if (await oldFile.exists()) {
        await oldFile.delete();
      }
    }

    final screenshotsDir = Directory(p.join(docDir.path, 'screenshots'));
    if (await screenshotsDir.exists()) {
      await screenshotsDir.delete(recursive: true);
    }

    for (final file in archive) {
      final outPath = p.join(docDir.path, file.name);
      if (file.isFile) {
        final outFile = File(outPath);
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }

    return AppDatabase();
  }
}
