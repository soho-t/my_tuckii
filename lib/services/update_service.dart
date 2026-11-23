import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppUpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String releaseNotes;
  final String downloadUrl;
  final String releasePageUrl;
  final bool hasUpdate;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.releasePageUrl,
    required this.hasUpdate,
  });
}

class UpdateService {
  static const String _repoOwner = 'soho-t';
  static const String _repoName = 'my_tuckii';
  static const String _lastCheckKey = 'update_last_check_ms';
  static const String _skippedVersionKey = 'update_skipped_version';

  /// 判斷距離上次自動檢查是否已超過 24 小時
  static Future<bool> shouldAutoCheck() async {
    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(_lastCheckKey) ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return (nowMs - lastMs) > const Duration(hours: 24).inMilliseconds;
  }

  /// 記錄使用者選擇「略過此版本」
  static Future<void> skipVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_skippedVersionKey, _normalizeVersion(version));
  }

  /// 向 GitHub Releases 查詢最新版本並與本機版本比對
  static Future<AppUpdateInfo?> checkForUpdate({
    bool isManual = false,
  }) async {
    final info = await PackageInfo.fromPlatform();
    final currentVersion = _normalizeVersion(info.version);

    final uri = Uri.parse(
      'https://api.github.com/repos/$_repoOwner/$_repoName/releases/latest',
    );
    final resp = await http.get(
      uri,
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'MyTuckii-Android-App',
      },
    ).timeout(const Duration(seconds: 10));

    if (resp.statusCode != 200) {
      if (isManual) {
        throw Exception('無法連線至 GitHub (${resp.statusCode})');
      }
      return null;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);

    final data = jsonDecode(utf8.decode(resp.bodyBytes));
    final tagName = (data['tag_name'] ?? '').toString().trim();
    final latestVersion = _normalizeVersion(tagName);
    if (latestVersion.isEmpty) return null;

    final releasePageUrl = (data['html_url'] ??
            'https://github.com/$_repoOwner/$_repoName/releases/latest')
        .toString();
    final releaseNotes = (data['body'] ?? '').toString().trim();

    String apkUrl = releasePageUrl;
    final assets = data['assets'];
    if (assets is List) {
      for (final asset in assets) {
        final name = (asset['name'] ?? '').toString().toLowerCase();
        final browserUrl = (asset['browser_download_url'] ?? '').toString();
        if (name.endsWith('.apk') && browserUrl.isNotEmpty) {
          apkUrl = browserUrl;
          break;
        }
      }
    }

    final isNewer = _isNewerVersion(latestVersion, currentVersion);
    if (!isManual && isNewer) {
      final skipped = prefs.getString(_skippedVersionKey) ?? '';
      if (skipped == latestVersion) {
        return null;
      }
    }

    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersion: latestVersion,
      releaseNotes: releaseNotes,
      downloadUrl: apkUrl,
      releasePageUrl: releasePageUrl,
      hasUpdate: isNewer,
    );
  }

  static String _normalizeVersion(String raw) {
    return raw.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
  }

  static bool _isNewerVersion(String latest, String current) {
    final latestParts = latest.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final currentParts = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final maxLen =
        latestParts.length > currentParts.length ? latestParts.length : currentParts.length;

    for (int i = 0; i < maxLen; i++) {
      final l = i < latestParts.length ? latestParts[i] : 0;
      final c = i < currentParts.length ? currentParts[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }
}