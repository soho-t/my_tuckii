import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' as drift;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:metadata_fetch/metadata_fetch.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../database/app_database.dart';
import '../main.dart';
import '../services/ai_organizer_service.dart';
import '../services/backup_service.dart';
import '../services/bookmark_importer.dart';
import '../services/google_drive_sync_service.dart';
import '../services/library_maintenance_service.dart';
import '../services/reminder_service.dart';
import '../services/share_handler.dart';
import '../services/update_service.dart';
import 'focus_mode_screen.dart';

class HomeScreen extends StatefulWidget {
  final AppDatabase db;
  const HomeScreen({super.key, required this.db});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const MethodChannel _quickSaveChannel =
      MethodChannel('io.github.sohot.mytuckii/quick_save');

  late ShareHandlerService _shareHandler;
  final TextEditingController _searchController = TextEditingController();

  String _searchQuery = '';
  String _selectedFilter = 'all';
  int? _selectedCollectionId;
  bool _isSyncing = false;
  bool _isHandlingQuickSave = false;
  bool _isCheckingUpdate = false;
  String? _updateStatusText;

  // 動態版本號與網頁 OG 封面圖快取
  String _appVersion = '1.9.0';
  Map<String, String> _linkCoverCache = {};

  // 外觀與收錄設定
  bool _highContrastMode = false;
  bool _enhancedPreview = true;
  bool _detectClipboardOnOpen = false;
  bool _persistentClipNotif = false;
  String? _lastExportTime;
  String? _lastPromptedClipUrl;

  // AI 智慧整理設定
  String _geminiApiKey = '';
  bool _aiAutoTagEnabled = false;
  bool _isAiOrganizing = false;
  int _aiCurrent = 0;
  int _aiTotal = 0;

  // 提醒與連結健康檢查狀態
  bool _notifPermissionGranted = false;
  bool _dailyReviewEnabled = true;
  int _dailyReviewHour = 21;
  int _dailyReviewMinute = 0;
  bool _staleReminderEnabled = true;
  int _staleDays = 30;
  bool _weekendReminderEnabled = false;
  bool _linkHealthCheckEnabled = false;
  bool _isCheckingLinks = false;
  int _scanCurrent = 0;
  int _scanTotal = 0;

  final Set<int> _selectedIds = {};
  List<SavedItem> _currentItems = [];
  bool get _isSelectionMode => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _setupQuickSaveChannel();

    ReminderService.init(onTap: _handleNotificationPayload).then((_) async {
      final launchPayload = await ReminderService.getLaunchPayload();
      if (launchPayload != null && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _handleNotificationPayload(launchPayload);
        });
      }
    });

    _loadAppSettings();

    GoogleDriveSyncService.signInSilently().then((_) {
      if (mounted) setState(() {});
    });

    _shareHandler = ShareHandlerService(widget.db);
    _shareHandler.init((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareHandler.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ReminderService.isPermissionGranted().then((granted) {
        if (mounted && granted != _notifPermissionGranted) {
          setState(() => _notifPermissionGranted = granted);
        }
      });
      if (_detectClipboardOnOpen && !_isHandlingQuickSave) {
        _checkClipboardForNewLink();
      }
    }
  }

  /// 安全開啟外部網址（失敗時自動嘗試預設模式，仍失敗則複製網址並跳出提示）
  Future<void> _openExternalUrl(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) return;

    bool launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }

    if (!launched) {
      try {
        launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
      } catch (_) {
        launched = false;
      }
    }

    if (!launched && mounted) {
      await Clipboard.setData(ClipboardData(text: rawUrl));
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('無法自動開啟瀏覽器'),
          content: Text('已將網址複製到剪貼簿，請直接貼到瀏覽器開啟：\n\n$rawUrl'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('確定'),
            ),
          ],
        ),
      );
    }
  }

  void _setupQuickSaveChannel() {
    _quickSaveChannel.setMethodCallHandler((call) async {
      if (call.method == 'onQuickSaveTrigger') {
        final nativeText = call.arguments?.toString();
        await _executeQuickClipboardSave(
          autoMinimize: true,
          nativeText: nativeText,
        );
      }
    });

    _quickSaveChannel.invokeMethod('consumePendingQuickSave').then((res) {
      if (!mounted) return;
      if (res is Map && res['pending'] == true) {
        final nativeText = res['text']?.toString();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _executeQuickClipboardSave(
            autoMinimize: true,
            nativeText: nativeText,
          );
        });
      }
    }).catchError((_) {});
  }

  Future<void> _executeQuickClipboardSave({
    required bool autoMinimize,
    String? nativeText,
  }) async {
    if (_isHandlingQuickSave) return;
    _isHandlingQuickSave = true;

    try {
      String rawText = nativeText?.trim() ?? '';
      if (rawText.isEmpty) {
        try {
          rawText = (await _quickSaveChannel
                  .invokeMethod<String>('readClipboardWhenFocused'))
              ?.trim() ?? '';
        } catch (_) {}
      }
      if (rawText.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 250));
        final clipData = await Clipboard.getData(Clipboard.kTextPlain);
        rawText = clipData?.text?.trim() ?? '';
      }

      if (rawText.isEmpty) {
        await _notifyNativeToast('剪貼簿目前沒有文字或連結', minimize: autoMinimize);
        return;
      }

      final urlRegExp = RegExp(r'(https?:\/\/[^\s]+)');
      final match = urlRegExp.firstMatch(rawText);

      if (match != null) {
        final cleanUrl = match.group(0)!;
        final existing = await (widget.db.select(widget.db.savedItems)
              ..where((t) => t.url.equals(cleanUrl) & t.isDeleted.equals(false)))
            .get();

        if (existing.isNotEmpty) {
          await _notifyNativeToast('這個連結已經在隨手存裡了', minimize: autoMinimize);
          return;
        }

        final itemId = await widget.db.into(widget.db.savedItems).insert(
              SavedItemsCompanion.insert(
                itemType: 'link',
                url: drift.Value(cleanUrl),
                title: drift.Value(cleanUrl),
              ),
            );
        _lastPromptedClipUrl = cleanUrl;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('setting_last_clip_url', cleanUrl);

        if (_enhancedPreview) {
          _fetchTitleInBackground(itemId, cleanUrl, triggerAiTag: true);
        } else if (_aiAutoTagEnabled && _geminiApiKey.isNotEmpty) {
          AiOrganizerService.organizeSingleItemById(widget.db, itemId).catchError((_) => false);
        }
        await _notifyNativeToast('已將連結存入隨手存！', minimize: autoMinimize);
      } else {
        final noteTitle =
            rawText.length > 20 ? '${rawText.substring(0, 20)}...' : rawText;
        final itemId = await widget.db.into(widget.db.savedItems).insert(
              SavedItemsCompanion.insert(
                itemType: 'note',
                title: drift.Value(noteTitle),
                note: drift.Value(rawText),
              ),
            );
        if (_aiAutoTagEnabled && _geminiApiKey.isNotEmpty) {
          AiOrganizerService.organizeSingleItemById(widget.db, itemId).catchError((_) => false);
        }
        await _notifyNativeToast('已將剪貼簿文字存為筆記！', minimize: autoMinimize);
      }
    } catch (_) {
      await _notifyNativeToast('讀取剪貼簿失敗，請再試一次', minimize: false);
    } finally {
      _isHandlingQuickSave = false;
    }
  }

  Future<void> _notifyNativeToast(String message, {required bool minimize}) async {
    try {
      await _quickSaveChannel.invokeMethod('showToastAndMinimize', {
        'message': message,
        'minimize': minimize,
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Future<void> _requestAddQuickSettingsTile() async {
    String status = 'manual';
    try {
      status = await _quickSaveChannel.invokeMethod<String>('requestAddTile') ?? 'manual';
    } catch (_) {}

    if (!mounted) return;
    if (status == 'manual') {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('手動加入快速設定磚'),
          content: const Text(
            '1. 從螢幕最上方往下拉兩次，展開完整快速設定面板\n'
            '2. 點擊面板上的「編輯（鉛筆圖示）」\n'
            '3. 在下方找到「存進隨手存」方塊，按住拖曳到常用區即可',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _requestPinHomeWidget() async {
    String status = 'manual';
    try {
      status = await _quickSaveChannel.invokeMethod<String>('requestPinWidget') ?? 'manual';
    } catch (_) {}

    if (!mounted) return;
    if (status == 'manual') {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('手動加入桌面小工具'),
          content: const Text(
            '1. 回到手機桌面，長按空白處\n'
            '2. 點選下方的「小工具（Widgets）」\n'
            '3. 找到「隨手存 · 存剪貼簿」，拖曳放到桌面即可一鍵存剪貼簿',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _checkUpdateOnStartup() async {
    if (_isHandlingQuickSave) return;
    try {
      if (!await UpdateService.shouldAutoCheck()) return;
      final info = await UpdateService.checkForUpdate(isManual: false);
      if (info != null && info.hasUpdate && mounted) {
        _showUpdateDialog(info);
      }
    } catch (_) {}
  }

  Future<void> _showUpdateDialog(AppUpdateInfo info) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('發現新版本 v${info.latestVersion}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '目前版本：v${info.currentVersion}',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Text(
                info.releaseNotes.isNotEmpty
                    ? info.releaseNotes
                    : '已發布新版安裝檔，下載後直接覆蓋安裝即可保留所有資料。',
                style: const TextStyle(fontSize: 14, height: 1.45),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await UpdateService.skipVersion(info.latestVersion);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('略過此版'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍後再說'),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              await _openExternalUrl(info.downloadUrl);
            },
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('下載新版 APK'),
          ),
        ],
      ),
    );
  }

  // ==================== v1.8.0 回收桶面板 ====================

  void _showTrashSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFAF7F2),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.78,
        minChildSize: 0.5,
        maxChildSize: 0.94,
        builder: (_, scrollController) => Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.brown.withOpacity(0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.delete_outline, color: Color(0xFF8C6239)),
                      SizedBox(width: 8),
                      Text(
                        '回收桶',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2C2520),
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<List<SavedItem>>(
                stream: LibraryMaintenanceService.watchTrashedItems(widget.db),
                builder: (context, snapshot) {
                  final trashed = snapshot.data ?? [];
                  if (trashed.isEmpty) {
                    return const Center(
                      child: Text(
                        '回收桶目前是空的\n刪除的收藏會暫存在這裡方便隨時救回。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    );
                  }

                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  final count = await LibraryMaintenanceService.restoreAll(widget.db);
                                  if (mounted && count > 0) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('已還原全部 $count 筆收藏')),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.restore, size: 18),
                                label: Text('全部還原 (${trashed.length})'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.red.shade700,
                                  side: BorderSide(color: Colors.red.shade300),
                                ),
                                onPressed: () async {
                                  final ok = await showDialog<bool>(
                                    context: ctx,
                                    builder: (dCtx) => AlertDialog(
                                      title: const Text('清空回收桶？'),
                                      content: Text('將永久刪除這 ${trashed.length} 筆項目與本機檔案，刪除後無法復原。'),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(dCtx, false),
                                          child: const Text('取消'),
                                        ),
                                        FilledButton(
                                          style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                          onPressed: () => Navigator.pop(dCtx, true),
                                          child: const Text('永久清空'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    await LibraryMaintenanceService.emptyTrash(widget.db);
                                  }
                                },
                                icon: const Icon(Icons.delete_forever, size: 18),
                                label: const Text('清空回收桶'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                          itemCount: trashed.length,
                          itemBuilder: (_, index) {
                            final item = trashed[index];
                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                leading: Icon(
                                  item.itemType == 'image'
                                      ? Icons.screenshot
                                      : (item.itemType == 'file'
                                          ? Icons.description_outlined
                                          : (item.itemType == 'note'
                                              ? Icons.sticky_note_2_outlined
                                              : Icons.link)),
                                  color: Colors.grey.shade700,
                                ),
                                title: Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  item.tags?.isNotEmpty == true
                                      ? '#${item.tags}'
                                      : (item.url ?? item.itemType),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: '還原',
                                      icon: const Icon(Icons.restore, color: Color(0xFF4A7C59)),
                                      onPressed: () =>
                                          LibraryMaintenanceService.restoreItem(widget.db, item.id),
                                    ),
                                    IconButton(
                                      tooltip: '永久刪除',
                                      icon: Icon(Icons.delete_forever, color: Colors.red.shade600),
                                      onPressed: () =>
                                          LibraryMaintenanceService.permanentlyDeleteItem(widget.db, item),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== v1.8.0 標籤雲與標籤管理面板 ====================

  void _showTagManagerSheet() {
    List<TagStat> stats = [];
    bool loading = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFAF7F2),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> reload() async {
            final data = await LibraryMaintenanceService.getAllTagStats(widget.db);
            if (ctx.mounted) {
              setSheetState(() {
                stats = data;
                loading = false;
              });
            }
          }

          if (loading) {
            reload();
          }

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.78,
            minChildSize: 0.5,
            maxChildSize: 0.94,
            builder: (_, scrollController) => Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.brown.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.sell_outlined, color: Color(0xFF8C6239)),
                          SizedBox(width: 8),
                          Text(
                            '標籤總覽與管理',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF2C2520),
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Text(
                    '點選標籤即可快速篩選收藏；點右側編輯可重新命名或輸入既有標籤名稱來合併同義詞。',
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : stats.isEmpty
                          ? const Center(
                              child: Text(
                                '目前還沒有任何標籤\n試著在編輯卡片時加上標籤，或用 AI 一鍵整理吧！',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                              itemCount: stats.length,
                              itemBuilder: (_, i) {
                                final t = stats[i];
                                return Card(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: ListTile(
                                    leading: const Icon(Icons.tag, color: Color(0xFF7A5C3E)),
                                    title: Text(
                                      '#${t.name}',
                                      style: const TextStyle(fontWeight: FontWeight.w600),
                                    ),
                                    subtitle: Text('${t.count} 筆收藏'),
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      setState(() {
                                        _selectedFilter = 'all';
                                        _selectedCollectionId = null;
                                        _searchController.text = t.name;
                                        _searchQuery = t.name;
                                      });
                                    },
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: '重新命名或合併',
                                          icon: const Icon(Icons.edit_outlined, size: 20),
                                          onPressed: () async {
                                            final ctrl = TextEditingController(text: t.name);
                                            final newName = await showDialog<String>(
                                              context: ctx,
                                              builder: (dCtx) => AlertDialog(
                                                title: Text('重新命名／合併「#${t.name}」'),
                                                content: TextField(
                                                  controller: ctrl,
                                                  autofocus: true,
                                                  decoration: const InputDecoration(
                                                    labelText: '新標籤名稱',
                                                    hintText: '輸入既有標籤名稱即可自動合併',
                                                    border: OutlineInputBorder(),
                                                  ),
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () => Navigator.pop(dCtx),
                                                    child: const Text('取消'),
                                                  ),
                                                  FilledButton(
                                                    onPressed: () =>
                                                        Navigator.pop(dCtx, ctrl.text.trim()),
                                                    child: const Text('套用'),
                                                  ),
                                                ],
                                              ),
                                            );
                                            if (newName != null &&
                                                newName.isNotEmpty &&
                                                newName != t.name) {
                                              await LibraryMaintenanceService.renameOrMergeTag(
                                                widget.db,
                                                t.name,
                                                newName,
                                              );
                                              await reload();
                                            }
                                          },
                                        ),
                                        IconButton(
                                          tooltip: '從所有收藏移除此標籤',
                                          icon: Icon(Icons.delete_outline,
                                              size: 20, color: Colors.red.shade600),
                                          onPressed: () async {
                                            final ok = await showDialog<bool>(
                                              context: ctx,
                                              builder: (dCtx) => AlertDialog(
                                                title: Text('移除標籤「#${t.name}」？'),
                                                content: Text('會從 ${t.count} 筆收藏中移除此標籤，不會刪除收藏本身。'),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () => Navigator.pop(dCtx, false),
                                                    child: const Text('取消'),
                                                  ),
                                                  FilledButton(
                                                    style: FilledButton.styleFrom(
                                                        backgroundColor: Colors.red),
                                                    onPressed: () => Navigator.pop(dCtx, true),
                                                    child: const Text('移除'),
                                                  ),
                                                ],
                                              ),
                                            );
                                            if (ok == true) {
                                              await LibraryMaintenanceService.deleteTagFromAll(
                                                widget.db,
                                                t.name,
                                              );
                                              await reload();
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ==================== v1.8.0 重複連結偵測與合併面板 ====================

  void _showDuplicateCleanerSheet() {
    List<DuplicateGroup> groups = [];
    bool loading = true;
    bool merging = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFAF7F2),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> scan() async {
            final res = await LibraryMaintenanceService.findDuplicateLinks(widget.db);
            if (ctx.mounted) {
              setSheetState(() {
                groups = res;
                loading = false;
              });
            }
          }

          if (loading) {
            scan();
          }

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.78,
            minChildSize: 0.5,
            maxChildSize: 0.94,
            builder: (_, scrollController) => Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.brown.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.cleaning_services_outlined, color: Color(0xFF8C6239)),
                          SizedBox(width: 8),
                          Text(
                            '重複連結偵測與合併',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF2C2520),
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Text(
                    '自動忽略 utm、fbclid 等追蹤參數比對重複網址；合併時會保留最完整的一筆並整併標籤，多餘項目移入回收桶。',
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                  ),
                ),
                if (!loading && groups.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: merging
                            ? null
                            : () async {
                                setSheetState(() => merging = true);
                                try {
                                  final removed =
                                      await LibraryMaintenanceService.mergeAllDuplicates(widget.db);
                                  await scan();
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('合併完成！已整理並移入回收桶 $removed 筆重複連結。')),
                                    );
                                  }
                                } finally {
                                  if (ctx.mounted) setSheetState(() => merging = false);
                                }
                              },
                        icon: merging
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.merge_type, size: 18),
                        label: Text('一鍵合併全部 ${groups.length} 組重複連結'),
                      ),
                    ),
                  ),
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : groups.isEmpty
                          ? const Center(
                              child: Text(
                                '太乾淨了！目前沒有發現重複的網頁連結。',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                              itemCount: groups.length,
                              itemBuilder: (_, idx) {
                                final g = groups[idx];
                                return Card(
                                  margin: const EdgeInsets.only(bottom: 10),
                                  child: Padding(
                                    padding: const EdgeInsets.all(14),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                g.normalizedUrl,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 13,
                                                  color: Color(0xFF5A4328),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            TextButton(
                                              onPressed: merging
                                                  ? null
                                                  : () async {
                                                      await LibraryMaintenanceService
                                                          .mergeDuplicateGroup(widget.db, g);
                                                      await scan();
                                                    },
                                              child: const Text('合併這組'),
                                            ),
                                          ],
                                        ),
                                        const Divider(height: 10),
                                        ...g.items.map((item) => Padding(
                                              padding: const EdgeInsets.symmetric(vertical: 2),
                                              child: Text(
                                                '• ${item.title}${item.tags?.isNotEmpty == true ? ' (#${item.tags})' : ''}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontSize: 13),
                                              ),
                                            )),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 自然語言智慧搜尋面板（AI 找收藏）
  void _showAiSearchSheet() {
    if (_geminiApiKey.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('尚未設定 Gemini API Key'),
          content: const Text('請先至右上角「設定 → ✨ AI 智慧整理」填入個人免費金鑰，即可使用口語智慧搜尋。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _showSettingsBottomSheet();
              },
              child: const Text('前往設定'),
            ),
          ],
        ),
      );
      return;
    }

    final queryCtrl = TextEditingController(text: _searchController.text.trim());
    bool isSearching = false;
    AiSearchResult? searchResult;
    String? errorMsg;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFAF7F2),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> runSearch() async {
            final q = queryCtrl.text.trim();
            if (q.isEmpty || isSearching) return;
            FocusScope.of(ctx).unfocus();
            setSheetState(() {
              isSearching = true;
              errorMsg = null;
            });
            try {
              final res = await AiOrganizerService.naturalLanguageSearch(widget.db, q);
              if (ctx.mounted) {
                setSheetState(() => searchResult = res);
              }
            } catch (e) {
              if (ctx.mounted) {
                setSheetState(() => errorMsg = '$e');
              }
            } finally {
              if (ctx.mounted) {
                setSheetState(() => isSearching = false);
              }
            }
          }

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.78,
            minChildSize: 0.5,
            maxChildSize: 0.94,
            builder: (_, scrollController) => Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.brown.withOpacity(0.25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.auto_awesome, color: Color(0xFF8C6239)),
                            SizedBox(width: 8),
                            Text(
                              'AI 智慧搜尋',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF2C2520),
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: queryCtrl,
                            textInputAction: TextInputAction.search,
                            onSubmitted: (_) => runSearch(),
                            decoration: InputDecoration(
                              hintText: '用口語問我，例如：之前存的美食或報表...',
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: isSearching ? null : runSearch,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: isSearching
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('搜尋'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      children: [
                        if (errorMsg != null)
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.red.shade200),
                            ),
                            child: Text(
                              '搜尋失敗：$errorMsg',
                              style: TextStyle(color: Colors.red.shade900),
                            ),
                          ),
                        if (searchResult != null) ...[
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: const Color(0xFFE6DEC8)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.tips_and_updates_outlined,
                                    color: Color(0xFF8C6239), size: 20),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    searchResult!.answer,
                                    style: const TextStyle(fontSize: 14, height: 1.45),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (searchResult!.matchedItems.isNotEmpty) ...[
                            Text(
                              '找到 ${searchResult!.matchedItems.length} 筆相關收藏：',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF7A5C3E),
                              ),
                            ),
                            const SizedBox(height: 8),
                            ...searchResult!.matchedItems.map((item) => Card(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: ListTile(
                                    leading: Icon(
                                      item.itemType == 'image'
                                          ? Icons.screenshot
                                          : (item.itemType == 'file'
                                              ? Icons.description_outlined
                                              : (item.itemType == 'note'
                                                  ? Icons.sticky_note_2_outlined
                                                  : Icons.link)),
                                      color: const Color(0xFF7A5C3E),
                                    ),
                                    title: Text(
                                      item.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.w600),
                                    ),
                                    subtitle: Text(
                                      item.tags?.isNotEmpty == true
                                          ? '#${item.tags}'
                                          : (item.note?.isNotEmpty == true
                                              ? item.note!
                                              : (item.url ?? '')),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      _openItemDetail(item);
                                    },
                                  ),
                                )),
                          ],
                        ] else if (!isSearching && errorMsg == null) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 24),
                            child: Text(
                              '試著輸入你想找的主題、時間或截圖裡的關鍵字，Gemini 會幫你從最近的 150 筆收藏中精準篩選。',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showGeminiApiKeyDialog(StateSetter setSheetState) async {
    final keyCtrl = TextEditingController(text: _geminiApiKey);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('設定 Gemini API Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '金鑰僅儲存在這支手機本機，用於呼叫 Gemini 2.5 Flash 進行截圖識圖、重點摘要、自動標籤與口語搜尋。',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: keyCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Gemini API Key',
                hintText: '貼上 AIza... 開頭的金鑰',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: () => _openExternalUrl('https://aistudio.google.com/apikey'),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('前往 Google AI Studio 免費申請金鑰', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('儲存'),
          ),
        ],
      ),
    );

    if (saved == true) {
      final newKey = keyCtrl.text.trim();
      await AiOrganizerService.saveApiKey(newKey);
      setSheetState(() => _geminiApiKey = newKey);
      if (mounted) {
        setState(() => _geminiApiKey = newKey);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(newKey.isEmpty ? '已清除 API Key' : '已儲存 Gemini API Key')),
        );
      }
    }
  }

  void _handleNotificationPayload(String payload) {
    if (!mounted) return;
    if (payload == 'quick_clip_save') {
      _executeQuickClipboardSave(autoMinimize: true);
    } else if (payload == 'link_health') {
      setState(() {
        _selectedFilter = 'all';
        _selectedCollectionId = null;
        _searchController.text = '失效連結';
        _searchQuery = '失效連結';
      });
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FocusModeScreen(db: widget.db),
        ),
      );
    }
  }

  Future<void> _loadAppSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final granted = await ReminderService.isPermissionGranted();
    final apiKey = await AiOrganizerService.getApiKey();
    final aiAutoTag = await AiOrganizerService.isAutoTagEnabled();

    String detectedVersion = _appVersion;
    try {
      final info = await PackageInfo.fromPlatform();
      detectedVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {}

    Map<String, String> loadedCovers = {};
    try {
      final rawJson = prefs.getString('setting_link_cover_cache');
      if (rawJson != null && rawJson.isNotEmpty) {
        final decoded = jsonDecode(rawJson);
        if (decoded is Map) {
          loadedCovers = decoded.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          );
        }
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _appVersion = detectedVersion;
      _linkCoverCache = loadedCovers;

      _highContrastMode = prefs.getBool('setting_high_contrast') ?? false;
      _enhancedPreview = prefs.getBool('setting_enhanced_preview') ?? true;
      _detectClipboardOnOpen = prefs.getBool('setting_detect_clipboard') ?? false;
      _persistentClipNotif = prefs.getBool('setting_persistent_clip_notif') ?? false;
      _lastExportTime = prefs.getString('setting_last_export_time');
      _lastPromptedClipUrl = prefs.getString('setting_last_clip_url');

      _geminiApiKey = apiKey;
      _aiAutoTagEnabled = aiAutoTag;

      _notifPermissionGranted = granted;
      _dailyReviewEnabled = prefs.getBool('rem_daily_enabled') ?? true;
      _dailyReviewHour = prefs.getInt('rem_daily_hour') ?? 21;
      _dailyReviewMinute = prefs.getInt('rem_daily_minute') ?? 0;
      _staleReminderEnabled = prefs.getBool('rem_stale_enabled') ?? true;
      _staleDays = prefs.getInt('rem_stale_days') ?? 30;
      _weekendReminderEnabled = prefs.getBool('rem_weekend_enabled') ?? false;
      _linkHealthCheckEnabled = prefs.getBool('rem_link_health_enabled') ?? false;
    });

    if (granted) {
      ReminderService.rescheduleAll(widget.db);
    }
    if (_detectClipboardOnOpen && !_isHandlingQuickSave) {
      Future.delayed(const Duration(milliseconds: 600), _checkClipboardForNewLink);
    }
    if (_linkHealthCheckEnabled) {
      _autoRunWeeklyLinkHealthCheck(prefs);
    }
    Future.delayed(const Duration(seconds: 2), _checkUpdateOnStartup);
  }

  Future<void> _saveLinkCover(String url, String imageUrl) async {
    final trimmed = imageUrl.trim();
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      return;
    }
    _linkCoverCache[url] = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('setting_link_cover_cache', jsonEncode(_linkCoverCache));
    if (mounted) setState(() {});
  }

  Future<void> _ensureNotifPermissionIfEnabling(
    bool enabling,
    StateSetter setSheetState,
  ) async {
    if (!enabling || _notifPermissionGranted) return;
    final ok = await ReminderService.requestPermission();
    setSheetState(() => _notifPermissionGranted = ok);
    if (mounted) setState(() => _notifPermissionGranted = ok);
  }

  Future<void> _autoRunWeeklyLinkHealthCheck(SharedPreferences prefs) async {
    final lastCheckMs = prefs.getInt('rem_last_link_check_ms') ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - lastCheckMs > const Duration(days: 7).inMilliseconds) {
      final res = await ReminderService.runLinkHealthCheck(
        widget.db,
        requireWifi: true,
      );
      if (!res.skippedNoWifi) {
        await prefs.setInt('rem_last_link_check_ms', nowMs);
      }
    }
  }

  Future<void> _checkClipboardForNewLink() async {
    try {
      final clipData = await Clipboard.getData(Clipboard.kTextPlain);
      final rawText = clipData?.text?.trim() ?? '';
      if (rawText.isEmpty) return;

      final urlRegExp = RegExp(r'(https?:\/\/[^\s]+)');
      final match = urlRegExp.firstMatch(rawText);
      if (match == null) return;

      final detectedUrl = match.group(0)!;
      if (detectedUrl == _lastPromptedClipUrl) return;

      final existing = await (widget.db.select(widget.db.savedItems)
            ..where((t) => t.url.equals(detectedUrl) & t.isDeleted.equals(false)))
          .get();
      if (existing.isNotEmpty) return;

      _lastPromptedClipUrl = detectedUrl;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('setting_last_clip_url', detectedUrl);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
          content: Text(
            '偵測到複製的連結：\n$detectedUrl',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          action: SnackBarAction(
            label: '一鍵收藏',
            onPressed: () async {
              final itemId = await widget.db.into(widget.db.savedItems).insert(
                    SavedItemsCompanion.insert(
                      itemType: 'link',
                      url: drift.Value(detectedUrl),
                      title: drift.Value(detectedUrl),
                    ),
                  );
              if (_enhancedPreview) {
                _fetchTitleInBackground(itemId, detectedUrl, triggerAiTag: true);
              } else if (_aiAutoTagEnabled && _geminiApiKey.isNotEmpty) {
                AiOrganizerService.organizeSingleItemById(widget.db, itemId).catchError((_) => false);
              }
            },
          ),
        ),
      );
    } catch (_) {}
  }

  Future<void> _handleGoogleSync() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);

    try {
      final resultMsg = await GoogleDriveSyncService.syncNow(widget.db);
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(resultMsg),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('同步失敗：$e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  void _toggleSelection(int id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedIds.length == _currentItems.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(_currentItems.map((e) => e.id));
      }
    });
  }

  Stream<List<SavedItem>> _watchFilteredItems() {
    final query = widget.db.select(widget.db.savedItems);

    query.where((t) {
      drift.Expression<bool> condition = t.isDeleted.equals(false);

      if (_selectedCollectionId != null) {
        if (_selectedCollectionId == -1) {
          condition = condition & t.collectionId.isNull();
        } else {
          condition = condition & t.collectionId.equals(_selectedCollectionId!);
        }
      }

      if (_selectedFilter == 'link') {
        condition = condition & t.itemType.equals('link');
      } else if (_selectedFilter == 'image') {
        condition = condition & t.itemType.equals('image');
      } else if (_selectedFilter == 'file') {
        condition = condition & t.itemType.equals('file');
      } else if (_selectedFilter == 'note') {
        condition = condition & t.itemType.equals('note');
      } else if (_selectedFilter == 'unread') {
        condition = condition & t.isRead.equals(false);
      }

      if (_searchQuery.isNotEmpty) {
        final pattern = '%$_searchQuery%';
        condition = condition &
            (t.title.like(pattern) |
                t.url.like(pattern) |
                t.note.like(pattern) |
                t.tags.like(pattern));
      }
      return condition;
    });

    query.orderBy([
      (t) => drift.OrderingTerm.desc(t.isPinned),
      (t) => drift.OrderingTerm.desc(t.createdAt),
    ]);

    return query.watch();
  }

  @override
  Widget build(BuildContext context) {
    final googleUser = GoogleDriveSyncService.currentUser;

    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isSelectionMode) {
          setState(() => _selectedIds.clear());
        }
      },
      child: Scaffold(
        appBar: _isSelectionMode
            ? AppBar(
                backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '取消多選',
                  onPressed: () => setState(() => _selectedIds.clear()),
                ),
                title: Text(
                  '已選取 ${_selectedIds.length} 項',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                actions: [
                  IconButton(
                    icon: Icon(
                      _selectedIds.length == _currentItems.length
                          ? Icons.deselect
                          : Icons.select_all,
                    ),
                    tooltip: '全選 / 取消全選',
                    onPressed: _toggleSelectAll,
                  ),
                ],
              )
            : AppBar(
                title: const Text('我的收藏庫', style: TextStyle(fontWeight: FontWeight.bold)),
                actions: [
                  _isSyncing
                      ? const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: Icon(
                            googleUser != null ? Icons.cloud_done : Icons.cloud_sync_outlined,
                            color: googleUser != null ? Colors.green : null,
                          ),
                          tooltip: googleUser != null
                              ? '點擊同步 (${googleUser.email})'
                              : '綁定 Google 帳號雲端同步',
                          onPressed: _handleGoogleSync,
                        ),
                  StreamBuilder<List<SavedItem>>(
                    stream: widget.db.watchUnreadItems(),
                    builder: (context, snapshot) {
                      final unreadCount = snapshot.data?.length ?? 0;
                      return FilledButton.tonalIcon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => FocusModeScreen(db: widget.db),
                            ),
                          );
                        },
                        icon: const Icon(Icons.style_rounded, size: 18),
                        label: Text('複習 ($unreadCount)'),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    tooltip: '設定',
                    onPressed: _showSettingsBottomSheet,
                  ),
                ],
              ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
              child: SearchBar(
                controller: _searchController,
                hintText: '搜尋標題、備註、標籤或網址...',
                leading: const Icon(Icons.search),
                trailing: [
                  if (_searchQuery.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    ),
                  IconButton(
                    icon: const Icon(Icons.auto_awesome, color: Color(0xFF8C6239)),
                    tooltip: 'AI 口語智慧搜尋',
                    onPressed: _showAiSearchSheet,
                  ),
                ],
                elevation: WidgetStateProperty.all(0),
                backgroundColor: WidgetStateProperty.all(
                  Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                ),
                onChanged: (val) => setState(() => _searchQuery = val.trim()),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Row(
                children: [
                  _buildFilterChip('全部類型', 'all'),
                  const SizedBox(width: 8),
                  _buildFilterChip('未讀項目', 'unread'),
                  const SizedBox(width: 8),
                  _buildFilterChip('本機文件', 'file'),
                  const SizedBox(width: 8),
                  _buildFilterChip('螢幕截圖', 'image'),
                  const SizedBox(width: 8),
                  _buildFilterChip('網頁連結', 'link'),
                  const SizedBox(width: 8),
                  _buildFilterChip('文字筆記', 'note'),
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: const Icon(Icons.sell_outlined, size: 16),
                    label: const Text('標籤'),
                    onPressed: _showTagManagerSheet,
                  ),
                ],
              ),
            ),
            StreamBuilder<List<Collection>>(
              stream: widget.db.watchAllCollections(),
              builder: (context, snapshot) {
                final collections = snapshot.data ?? [];
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      ChoiceChip(
                        avatar: const Icon(Icons.all_inbox, size: 16),
                        label: const Text('所有資料夾'),
                        selected: _selectedCollectionId == null,
                        onSelected: (_) => setState(() => _selectedCollectionId = null),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('未分類'),
                        selected: _selectedCollectionId == -1,
                        onSelected: (_) => setState(() => _selectedCollectionId = -1),
                      ),
                      ...collections.map((col) {
                        final isSelected = _selectedCollectionId == col.id;
                        return Padding(
                          padding: const EdgeInsets.only(left: 8.0),
                          child: GestureDetector(
                            onLongPress: () => _confirmDeleteCollection(col),
                            child: ChoiceChip(
                              avatar: const Icon(Icons.folder_outlined, size: 16),
                              label: Text(col.name),
                              selected: isSelected,
                              onSelected: (_) => setState(() => _selectedCollectionId = col.id),
                            ),
                          ),
                        );
                      }),
                      const SizedBox(width: 8),
                      ActionChip(
                        avatar: const Icon(Icons.create_new_folder_outlined, size: 16),
                        label: const Text('新增'),
                        onPressed: _showCreateCollectionDialog,
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        avatar: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('回收桶'),
                        onPressed: _showTrashSheet,
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 6),
            Expanded(
              child: StreamBuilder<List<SavedItem>>(
                stream: _watchFilteredItems(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final items = snapshot.data ?? [];
                  _currentItems = items;

                  if (items.isEmpty) {
                    return const Center(
                      child: Text(
                        '目前沒有符合的收藏項目\n試著從其他 App 點擊「分享」或按右下角「+ 新增」吧！',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    );
                  }

                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 0.78,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, index) => _buildItemCard(items[index]),
                  );
                },
              ),
            ),
          ],
        ),
        floatingActionButton: _isSelectionMode
            ? null
            : FloatingActionButton.extended(
                onPressed: _showQuickAddBottomSheet,
                icon: const Icon(Icons.add),
                label: const Text('新增'),
              ),
        bottomNavigationBar: _isSelectionMode
            ? BottomAppBar(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _showBatchMoveDialog,
                      icon: const Icon(Icons.drive_file_move_outline),
                      label: const Text('移動至收藏夾'),
                    ),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade100,
                        foregroundColor: Colors.red.shade900,
                      ),
                      onPressed: _confirmBatchDelete,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('批次刪除'),
                    ),
                  ],
                ),
              )
            : null,
      ),
    );
  }

  String _formatTime(int hour, int minute) {
    final h = hour.toString().padLeft(2, '0');
    final m = minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  void _showSettingsBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFAF7F2),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final googleUser = GoogleDriveSyncService.currentUser;
          final timeStr = _formatTime(_dailyReviewHour, _dailyReviewMinute);

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.88,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            builder: (_, scrollController) => Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.brown.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '設定',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2C2520),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                    children: [
                      _buildSectionHeader('帳號'),
                      _buildSettingsCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (googleUser != null) ...[
                              Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: const Color(0xFFE8DFD1),
                                    foregroundColor: const Color(0xFF4A3B2C),
                                    child: Text(
                                      (googleUser.displayName?.isNotEmpty == true
                                              ? googleUser.displayName![0]
                                              : googleUser.email[0])
                                          .toUpperCase(),
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          googleUser.displayName ?? 'Google 使用者',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                        Text(
                                          googleUser.email,
                                          style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                                        ),
                                        Text(
                                          '已用 Google 帳戶登入',
                                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                '雲端同步',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '資料將加密同步至你個人 Google Drive 隱藏專屬資料夾（appDataFolder），開發者無法存取。',
                                style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 10,
                                runSpacing: 8,
                                children: [
                                  FilledButton.tonalIcon(
                                    onPressed: () async {
                                      Navigator.pop(ctx);
                                      await _handleGoogleSync();
                                    },
                                    icon: const Icon(Icons.sync, size: 18),
                                    label: const Text('立即同步'),
                                  ),
                                  OutlinedButton(
                                    onPressed: () async {
                                      await GoogleDriveSyncService.signOut();
                                      setSheetState(() {});
                                      if (mounted) {
                                        setState(() {});
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('已登出並解除 Google 帳號綁定')),
                                        );
                                      }
                                    },
                                    child: const Text('登出'),
                                  ),
                                  OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.red.shade700,
                                      side: BorderSide(color: Colors.red.shade300),
                                    ),
                                    onPressed: () => _confirmDeleteAccountAndData(ctx),
                                    child: const Text('刪除帳號與資料'),
                                  ),
                                ],
                              ),
                            ] else ...[
                              const Text(
                                '尚未綁定 Google 帳號',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '目前收藏只存在這支手機。綁定個人 Google 帳號後即可跨裝置秒級增量同步。',
                                style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                              ),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: () async {
                                  Navigator.pop(ctx);
                                  await _handleGoogleSync();
                                },
                                icon: const Icon(Icons.login),
                                label: const Text('綁定 Google 帳號'),
                              ),
                            ],
                            const Divider(height: 24),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.computer, color: Color(0xFF7A5C3E)),
                              title: const Text(
                                '電腦網頁伴侶版',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: const Text('免安裝，在電腦瀏覽器登入同一個 Google 帳號同步管理'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () {
                                Navigator.pop(ctx);
                                _showWebCompanionGuideSheet();
                              },
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

                      _buildSectionHeader('外觀'),
                      _buildSettingsCard(
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            '無障礙高對比模式',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          subtitle: const Text('加深卡片邊框、顏色更清楚、提升文字辨識度'),
                          value: _highContrastMode,
                          onChanged: (val) async {
                            final prefs = await SharedPreferences.getInstance();
                            await prefs.setBool('setting_high_contrast', val);
                            setSheetState(() => _highContrastMode = val);
                            if (mounted) setState(() {});
                          },
                        ),
                      ),

                      const SizedBox(height: 20),

                      _buildSectionHeader('✨ AI 智慧整理'),
                      _buildSettingsCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.key_outlined, color: Color(0xFF7A5C3E)),
                              title: const Text(
                                'Gemini API Key',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: Text(
                                _geminiApiKey.isEmpty
                                    ? '尚未設定（填入個人免費金鑰即可啟用）'
                                    : '已設定 (${_geminiApiKey.length > 8 ? '${_geminiApiKey.substring(0, 6)}••••' : '••••'})',
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _showGeminiApiKeyDialog(setSheetState),
                            ),
                            const Divider(),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '新增時自動 AI 整理標籤',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: const Text('存入連結或筆記後，自動交給 Gemini 產生標籤並歸入合適收藏夾'),
                              value: _aiAutoTagEnabled,
                              onChanged: (val) async {
                                if (val && _geminiApiKey.isEmpty) {
                                  await _showGeminiApiKeyDialog(setSheetState);
                                  if (_geminiApiKey.isEmpty) return;
                                }
                                await AiOrganizerService.setAutoTagEnabled(val);
                                setSheetState(() => _aiAutoTagEnabled = val);
                                if (mounted) setState(() {});
                              },
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _isAiOrganizing
                                    ? null
                                    : () async {
                                        if (_geminiApiKey.isEmpty) {
                                          await _showGeminiApiKeyDialog(setSheetState);
                                          if (_geminiApiKey.isEmpty) return;
                                        }
                                        setSheetState(() {
                                          _isAiOrganizing = true;
                                          _aiCurrent = 0;
                                          _aiTotal = 0;
                                        });
                                        try {
                                          final done = await AiOrganizerService.organizeUntaggedItems(
                                            widget.db,
                                            onProgress: (cur, tot) {
                                              if (ctx.mounted) {
                                                setSheetState(() {
                                                  _aiCurrent = cur;
                                                  _aiTotal = tot;
                                                });
                                              }
                                            },
                                          );
                                          if (mounted) {
                                            showDialog(
                                              context: context,
                                              builder: (dCtx) => AlertDialog(
                                                title: const Text('AI 整理完成'),
                                                content: Text(
                                                  done > 0
                                                      ? '已為 $done 筆收藏（含截圖識圖）補上標籤、摘要與分類。'
                                                      : '目前沒有需要整理的無標籤收藏。',
                                                ),
                                                actions: [
                                                  FilledButton(
                                                    onPressed: () => Navigator.pop(dCtx),
                                                    child: const Text('確定'),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }
                                        } catch (e) {
                                          if (mounted) {
                                            showDialog(
                                              context: context,
                                              builder: (dCtx) => AlertDialog(
                                                title: const Text('AI 整理失敗'),
                                                content: Text('$e'),
                                                actions: [
                                                  FilledButton(
                                                    onPressed: () => Navigator.pop(dCtx),
                                                    child: const Text('確定'),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }
                                        } finally {
                                          if (ctx.mounted) {
                                            setSheetState(() => _isAiOrganizing = false);
                                          }
                                        }
                                      },
                                icon: _isAiOrganizing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.auto_awesome, size: 18),
                                label: Text(
                                  _isAiOrganizing
                                      ? (_aiTotal > 0
                                          ? 'AI 整理中 ($_aiCurrent / $_aiTotal)...'
                                          : '準備呼叫 Gemini...')
                                      : '一鍵整理所有無標籤收藏（含截圖識圖）',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

                      _buildSectionHeader('🗂️ 收藏庫維護'),
                      _buildSettingsCard(
                        child: Column(
                          children: [
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.sell_outlined, color: Color(0xFF7A5C3E)),
                              title: const Text(
                                '標籤總覽與管理',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: const Text('檢視常用標籤、批次改名或合併同義標籤'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () {
                                Navigator.pop(ctx);
                                _showTagManagerSheet();
                              },
                            ),
                            const Divider(),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.cleaning_services_outlined,
                                  color: Color(0xFF7A5C3E)),
                              title: const Text(
                                '偵測與合併重複連結',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: const Text('忽略追蹤參數比對重複網址，保留完整內容並整併標籤'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () {
                                Navigator.pop(ctx);
                                _showDuplicateCleanerSheet();
                              },
                            ),
                            const Divider(),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.delete_outline, color: Color(0xFF7A5C3E)),
                              title: const Text(
                                '回收桶',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: const Text('還原誤刪項目，或永久清空釋放手機空間'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () {
                                Navigator.pop(ctx);
                                _showTrashSheet();
                              },
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

                      _buildSectionHeader('收錄'),
                      _buildSettingsCard(
                        child: Column(
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '增強預覽',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: const Text('存入網址時自動在背景載入公開頁面以取得標題、摘要與封面圖'),
                              value: _enhancedPreview,
                              onChanged: (val) async {
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setBool('setting_enhanced_preview', val);
                                setSheetState(() => _enhancedPreview = val);
                                if (mounted) setState(() {});
                              },
                            ),
                            const Divider(),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '開啟時偵測剪貼簿連結',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: const Text('打開隨手存時，自動檢查剪貼簿裡是否有新複製的連結並提示一鍵收藏'),
                              value: _detectClipboardOnOpen,
                              onChanged: (val) async {
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setBool('setting_detect_clipboard', val);
                                setSheetState(() => _detectClipboardOnOpen = val);
                                if (mounted) setState(() {});
                                if (val) _checkClipboardForNewLink();
                              },
                            ),
                            const Divider(),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '剪貼簿常駐通知',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: const Text('通知欄放一個「存剪貼簿」按鈕，在抖音、小紅書複製連結後一鍵存'),
                              value: _persistentClipNotif,
                              onChanged: (val) async {
                                await _ensureNotifPermissionIfEnabling(val, setSheetState);
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setBool('setting_persistent_clip_notif', val);
                                setSheetState(() => _persistentClipNotif = val);
                                if (mounted) setState(() {});
                                await ReminderService.setPersistentClipboardNotification(val);
                              },
                            ),
                            const Divider(),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '加入快速設定磚',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: const Text('下拉通知欄，點「存進隨手存」就能存剪貼簿裡的連結'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: _requestAddQuickSettingsTile,
                            ),
                            const Divider(),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '加到桌面小工具',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: const Text('桌面上放一個「存剪貼簿」按鈕，隨時一鍵存入'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: _requestPinHomeWidget,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

                      _buildSectionHeader('🔔 提醒'),
                      _buildSettingsCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!_notifPermissionGranted) ...[
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF8E7),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFFE5C97B)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.warning_amber_rounded, color: Color(0xFF9C6F19)),
                                    const SizedBox(width: 10),
                                    const Expanded(
                                      child: Text(
                                        '還沒允許通知，提醒不會出現',
                                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                      ),
                                    ),
                                    OutlinedButton(
                                      onPressed: () async {
                                        final ok = await ReminderService.requestPermission();
                                        setSheetState(() => _notifPermissionGranted = ok);
                                        if (mounted) setState(() => _notifPermissionGranted = ok);
                                        if (ok) {
                                          await ReminderService.rescheduleAll(widget.db);
                                        }
                                      },
                                      child: const Text('允許通知'),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],

                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '每日回顧',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: Text('每天約 $timeStr 隨機挑 1–3 則舊收藏給你'),
                              value: _dailyReviewEnabled,
                              onChanged: (val) async {
                                await _ensureNotifPermissionIfEnabling(val, setSheetState);
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setBool('rem_daily_enabled', val);
                                setSheetState(() => _dailyReviewEnabled = val);
                                if (mounted) setState(() {});
                                await ReminderService.rescheduleAll(widget.db);
                              },
                            ),
                            InkWell(
                              onTap: () async {
                                final picked = await showTimePicker(
                                  context: context,
                                  initialTime: TimeOfDay(
                                    hour: _dailyReviewHour,
                                    minute: _dailyReviewMinute,
                                  ),
                                );
                                if (picked != null) {
                                  final prefs = await SharedPreferences.getInstance();
                                  await prefs.setInt('rem_daily_hour', picked.hour);
                                  await prefs.setInt('rem_daily_minute', picked.minute);
                                  setSheetState(() {
                                    _dailyReviewHour = picked.hour;
                                    _dailyReviewMinute = picked.minute;
                                  });
                                  if (mounted) setState(() {});
                                  await ReminderService.rescheduleAll(widget.db);
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text('回顧時間', style: TextStyle(fontSize: 15)),
                                    Row(
                                      children: [
                                        Text(
                                          '約 $timeStr',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15,
                                            color: Color(0xFF5A4328),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        const Icon(Icons.access_time, size: 18, color: Color(0xFF7A5C3E)),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () async {
                                  final ok = await ReminderService.requestPermission();
                                  setSheetState(() => _notifPermissionGranted = ok);
                                  if (mounted) setState(() => _notifPermissionGranted = ok);
                                  if (ok) {
                                    await ReminderService.sendInstantReviewPreview(widget.db);
                                  }
                                },
                                icon: const Icon(Icons.notifications_active_outlined, size: 16),
                                label: const Text('立即發送一則回顧預覽', style: TextStyle(fontSize: 12)),
                              ),
                            ),

                            const Divider(height: 20),

                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '久未看提醒',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: Text('每週提醒你整理超過 $_staleDays 天沒看的收藏'),
                              value: _staleReminderEnabled,
                              onChanged: (val) async {
                                await _ensureNotifPermissionIfEnabling(val, setSheetState);
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setBool('rem_stale_enabled', val);
                                setSheetState(() => _staleReminderEnabled = val);
                                if (mounted) setState(() {});
                                await ReminderService.rescheduleAll(widget.db);
                              },
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [14, 30, 60].map((days) {
                                final isSelected = _staleDays == days;
                                return Padding(
                                  padding: const EdgeInsets.only(right: 10),
                                  child: ChoiceChip(
                                    label: Text(
                                      '$days 天',
                                      style: TextStyle(
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                      ),
                                    ),
                                    selected: isSelected,
                                    onSelected: (_) async {
                                      final prefs = await SharedPreferences.getInstance();
                                      await prefs.setInt('rem_stale_days', days);
                                      setSheetState(() => _staleDays = days);
                                      if (mounted) setState(() {});
                                      await ReminderService.rescheduleAll(widget.db);
                                    },
                                  ),
                                );
                              }).toList(),
                            ),

                            const Divider(height: 24),

                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '清單週末提醒',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: const Text('週五 19:00 提醒你清單上還沒去的店、還沒看的收藏'),
                              value: _weekendReminderEnabled,
                              onChanged: (val) async {
                                await _ensureNotifPermissionIfEnabling(val, setSheetState);
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setBool('rem_weekend_enabled', val);
                                setSheetState(() => _weekendReminderEnabled = val);
                                if (mounted) setState(() {});
                                await ReminderService.rescheduleAll(widget.db);
                              },
                            ),

                            const Divider(height: 24),

                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '連結健康檢查',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              subtitle: const Text(
                                '每週在 Wi-Fi 下檢查 YouTube、X、Spotify 與網頁收藏，原作失效時標記 #失效連結 並通知你',
                              ),
                              value: _linkHealthCheckEnabled,
                              onChanged: (val) async {
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setBool('rem_link_health_enabled', val);
                                setSheetState(() => _linkHealthCheckEnabled = val);
                                if (mounted) setState(() {});
                              },
                            ),
                            const SizedBox(height: 6),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _isCheckingLinks
                                    ? null
                                    : () async {
                                        setSheetState(() {
                                          _isCheckingLinks = true;
                                          _scanCurrent = 0;
                                          _scanTotal = 0;
                                        });
                                        try {
                                          final res = await ReminderService.runLinkHealthCheck(
                                            widget.db,
                                            onProgress: (current, total) {
                                              if (ctx.mounted) {
                                                setSheetState(() {
                                                  _scanCurrent = current;
                                                  _scanTotal = total;
                                                });
                                              }
                                            },
                                          );
                                          if (mounted) {
                                            showDialog(
                                              context: context,
                                              builder: (dCtx) => AlertDialog(
                                                title: const Text('連結健康檢查完成'),
                                                content: Text(
                                                  '共掃描 ${res.checked} 個連結，新發現 ${res.broken} 個失效連結。',
                                                ),
                                                actions: [
                                                  FilledButton(
                                                    onPressed: () => Navigator.pop(dCtx),
                                                    child: const Text('確定'),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }
                                        } finally {
                                          if (ctx.mounted) {
                                            setSheetState(() => _isCheckingLinks = false);
                                          }
                                        }
                                      },
                                icon: _isCheckingLinks
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.health_and_safety_outlined, size: 18),
                                label: Text(
                                  _isCheckingLinks
                                      ? (_scanTotal > 0
                                          ? '掃描中 ($_scanCurrent / $_scanTotal)...'
                                          : '準備掃描連結...')
                                      : '立即掃描所有連結健康度',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 4, top: 6),
                        child: Text(
                          '提醒是大約時間，手機省電模式開啟時可能會稍微延後推播。',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                        ),
                      ),

                      const SizedBox(height: 20),

                      _buildSectionHeader('備份與匯入'),
                      _buildSettingsCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '將所有收藏、收藏夾、標籤、筆記與本機截圖/文件完整打包成一個離線 ZIP 檔。',
                              style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _lastExportTime != null ? '上次匯出：$_lastExportTime' : '還沒匯出過',
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () async {
                                      try {
                                        await BackupService.exportBackup(widget.db);
                                        final nowStr = DateTime.now().toString().substring(0, 16);
                                        final prefs = await SharedPreferences.getInstance();
                                        await prefs.setString('setting_last_export_time', nowStr);
                                        setSheetState(() => _lastExportTime = nowStr);
                                      } catch (e) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('備份失敗：$e')),
                                          );
                                        }
                                      }
                                    },
                                    icon: const Icon(Icons.ios_share, size: 18),
                                    label: const Text('匯出備份'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () async {
                                      Navigator.pop(ctx);
                                      await _confirmAndRestoreBackup();
                                    },
                                    icon: const Icon(Icons.restore, size: 18),
                                    label: const Text('從備份還原'),
                                  ),
                                ),
                              ],
                            ),
                            const Divider(height: 24),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.bookmark_add_outlined),
                              title: const Text(
                                '匯入瀏覽器書籤 (HTML)',
                                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                              ),
                              subtitle: const Text('支援 Chrome / Edge / Safari 匯出的書籤檔'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () async {
                                Navigator.pop(ctx);
                                try {
                                  final count = await BookmarkImporterService.importFromHtmlFile(widget.db);
                                  if (count != null && mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          count > 0
                                              ? '成功匯入 $count 筆書籤，並自動建立對應收藏夾！'
                                              : '沒有發現新的書籤（可能皆已存在於收藏庫中）',
                                        ),
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('書籤匯入失敗：$e')),
                                    );
                                  }
                                }
                              },
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

                      _buildSectionHeader('關於'),
                      _buildSettingsCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '隨手存 MyTuckii',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '版本 $_appVersion',
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                            ),
                            const Divider(height: 20),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: _isCheckingUpdate
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.system_update_outlined, color: Color(0xFF7A5C3E)),
                              title: const Text(
                                '檢查更新',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(
                                _isCheckingUpdate
                                    ? '正在連線 GitHub 檢查最新版本...'
                                    : (_updateStatusText ?? '檢查 GitHub Releases 是否有新版 APK'),
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: _isCheckingUpdate
                                  ? null
                                  : () async {
                                      setSheetState(() {
                                        _isCheckingUpdate = true;
                                        _updateStatusText = null;
                                      });
                                      try {
                                        final info = await UpdateService.checkForUpdate(isManual: true);
                                        if (!mounted) return;
                                        if (info != null && info.hasUpdate) {
                                          setSheetState(() {
                                            _updateStatusText = '發現新版本 v${info.latestVersion}';
                                          });
                                          if (ctx.mounted) Navigator.pop(ctx);
                                          await _showUpdateDialog(info);
                                        } else {
                                          final cur = info?.currentVersion ?? _appVersion;
                                          setSheetState(() {
                                            _updateStatusText = '目前已是最新版本 (v$cur)';
                                          });
                                          showDialog(
                                            context: context,
                                            builder: (dCtx) => AlertDialog(
                                              title: const Text('已是最新版本'),
                                              content: Text('你目前安裝的 v$cur 已經是最新發布版本。'),
                                              actions: [
                                                FilledButton(
                                                  onPressed: () => Navigator.pop(dCtx),
                                                  child: const Text('確定'),
                                                ),
                                              ],
                                            ),
                                          );
                                        }
                                      } catch (e) {
                                        final errText = e.toString();
                                        final hint = errText.contains('404')
                                            ? '\n\n提示：若 GitHub 倉庫設為「私有 (Private)」，App 無法直接讀取 Releases，需先將倉庫改為公開。'
                                            : '';
                                        if (ctx.mounted) {
                                          setSheetState(() {
                                            _updateStatusText = '檢查失敗，請點擊重試';
                                          });
                                        }
                                        if (mounted) {
                                          showDialog(
                                            context: context,
                                            builder: (dCtx) => AlertDialog(
                                              title: const Text('檢查更新失敗'),
                                              content: Text('$errText$hint'),
                                              actions: [
                                                FilledButton(
                                                  onPressed: () => Navigator.pop(dCtx),
                                                  child: const Text('確定'),
                                                ),
                                              ],
                                            ),
                                          );
                                        }
                                      } finally {
                                        if (ctx.mounted) {
                                          setSheetState(() => _isCheckingUpdate = false);
                                        }
                                      }
                                    },
                            ),
                            const Divider(height: 8),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.coffee_outlined, color: Color(0xFF7A5C3E)),
                              title: const Text(
                                '請作者喝杯咖啡',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              subtitle: const Text('單次贊助支持開發，不是訂閱'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _showCoffeeSponsorSheet(),
                            ),
                            const Divider(height: 8),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('隱私權政策與專案首頁'),
                              trailing: const Icon(Icons.open_in_new, size: 18),
                              onTap: () => _openExternalUrl('https://github.com/soho-t/my_tuckii'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Color(0xFF7A5C3E),
        ),
      ),
    );
  }

  Widget _buildSettingsCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE6DEC8)),
      ),
      child: child,
    );
  }

  void _showWebCompanionGuideSheet() {
    const webUrl = 'https://soho-t.github.io/my_tuckii/';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFAF7F2),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.computer, color: Color(0xFF8C6239)),
                    SizedBox(width: 8),
                    Text(
                      '電腦網頁伴侶版使用指南',
                      style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE6DEC8)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('1. 手機端先開啟雲端同步', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  Text('在設定頁「帳號」綁定 Google 帳號並點一次「立即同步」，將收藏上傳至個人 Google Drive 專屬空間。', style: TextStyle(fontSize: 13, color: Colors.black87)),
                  SizedBox(height: 10),
                  Text('2. 電腦瀏覽器開啟網頁版', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  Text('點擊下方「複製網址」傳到電腦（例如透過 LINE 傳給自己），使用 Chrome 或 Edge 開啟。', style: TextStyle(fontSize: 13, color: Colors.black87)),
                  SizedBox(height: 10),
                  Text('3. 登入同一個 Google 帳號', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  Text('在網頁版登入與手機相同的 Google 帳號，系統會自動讀取同一份加密同步資料，彼此資料完全獨立。', style: TextStyle(fontSize: 13, color: Colors.black87)),
                  SizedBox(height: 10),
                  Text('4. 電腦存、手機看；手機存、電腦查', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  Text('在電腦新增或編輯後會自動存回雲端；回手機點右上角雲端圖示即可更新。', style: TextStyle(fontSize: 13, color: Colors.black87)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFEFE9DC),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const SelectableText(
                webUrl,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF5A4328)),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(const ClipboardData(text: webUrl));
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已複製電腦網頁版網址')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('複製網址'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _openExternalUrl(webUrl);
                    },
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('直接開啟網頁'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showCoffeeSponsorSheet() {
    int selectedTier = 1;
    final tiers = [
      {'title': '小杯', 'sub': '一點心意', 'price': '\$30.00'},
      {'title': '中杯', 'sub': '一杯拿鐵', 'price': '\$90.00'},
      {'title': '大杯', 'sub': '再加一塊蛋糕', 'price': '\$150.00'},
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFAF7F2),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setCoffeeState) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '請作者喝杯咖啡',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('選一杯', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF7A5C3E))),
              const SizedBox(height: 10),
              ...List.generate(tiers.length, (i) {
                final isSelected = selectedTier == i;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setCoffeeState(() => selectedTier = i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isSelected ? const Color(0xFF8C6239) : const Color(0xFFE0D6C3),
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                            color: isSelected ? const Color(0xFF8C6239) : Colors.grey,
                          ),
                          const SizedBox(width: 10),
                          const Icon(Icons.coffee, size: 20, color: Color(0xFF8C6239)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tiers[i]['title']!,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                                Text(
                                  tiers[i]['sub']!,
                                  style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            tiers[i]['price']!,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 6),
              Text(
                '單次付款，由 Google Play 收款，不會自動續費。隨手存所有核心功能皆免費開放使用。',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFB68D40),
                  foregroundColor: Colors.black87,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('感謝您的支持！待應用程式於 Google Play 正式上架後即可啟用 ${tiers[selectedTier]['price']} 贊助通道。'),
                    ),
                  );
                },
                icon: const Icon(Icons.coffee),
                label: Text(
                  '請喝一杯 · ${tiers[selectedTier]['price']}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteAccountAndData(BuildContext sheetCtx) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('確定要刪除帳號與所有資料？'),
        content: const Text(
          '此操作將會：\n1. 清空您個人 Google Drive 隱藏資料夾內的同步備份\n2. 刪除手機本機所有收藏項目、截圖與文件\n3. 解除 Google 帳號綁定\n\n刪除後無法復原，確定繼續嗎？',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('確定徹底刪除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    if (sheetCtx.mounted) Navigator.pop(sheetCtx);

    setState(() => _isSyncing = true);
    try {
      await GoogleDriveSyncService.deleteCloudDataAndDisconnect();
      final allItems = await widget.db.select(widget.db.savedItems).get();
      for (final item in allItems) {
        if (item.localImagePath != null) {
          final f = File(item.localImagePath!);
          if (await f.exists()) await f.delete();
        }
      }
      await widget.db.delete(widget.db.savedItems).go();
      await widget.db.delete(widget.db.collections).go();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已徹底刪除雲端與本機所有資料，並解除帳號綁定')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('刪除過程發生錯誤：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _confirmAndRestoreBackup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('確定要還原備份？'),
        content: const Text('還原將會覆蓋目前手機上的所有書籤、截圖與文件，此操作無法復原。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('選取備份檔')),
        ],
      ),
    );

    if (confirm == true) {
      try {
        final newDb = await BackupService.importBackup(widget.db);
        if (newDb != null && mounted) {
          globalDb = newDb;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => HomeScreen(db: globalDb)),
          );
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('資料還原成功！')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('還原失敗：$e')));
        }
      }
    }
  }

  Widget _buildFilterChip(String label, String value) {
    return ChoiceChip(
      label: Text(label),
      selected: _selectedFilter == value,
      onSelected: (_) => setState(() => _selectedFilter = value),
    );
  }

  Widget _buildDefaultPlaceholder(bool isImage) {
    return Container(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Icon(
        isImage ? Icons.cloud_download_outlined : Icons.link_rounded,
        size: 40,
        color: Theme.of(context).colorScheme.onSecondaryContainer,
      ),
    );
  }

  Widget _buildItemCard(SavedItem item) {
    final isImage = item.itemType == 'image';
    final isNote = item.itemType == 'note';
    final isFile = item.itemType == 'file';
    final hasLocalImage = isImage && item.localImagePath != null && File(item.localImagePath!).existsSync();
    final coverUrl = (!isImage && !isNote && !isFile && item.url != null)
        ? _linkCoverCache[item.url!]
        : null;
    final isSelected = _selectedIds.contains(item.id);
    final ext = item.localImagePath != null
        ? p.extension(item.localImagePath!).replaceAll('.', '').toUpperCase()
        : 'FILE';

    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: isSelected ? 4 : (_highContrastMode ? 2 : 1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: isSelected
            ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 3)
            : (_highContrastMode
                ? const BorderSide(color: Colors.black87, width: 1.5)
                : BorderSide.none),
      ),
      child: InkWell(
        onTap: () {
          if (_isSelectionMode) {
            _toggleSelection(item.id);
          } else {
            _openItemDetail(item);
          }
        },
        onLongPress: () => _toggleSelection(item.id),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hasLocalImage)
                        Image.file(
                          File(item.localImagePath!),
                          fit: BoxFit.cover,
                          cacheWidth: 400,
                        )
                      else if (isNote)
                        Container(
                          padding: const EdgeInsets.all(12),
                          color: Theme.of(context).colorScheme.tertiaryContainer.withOpacity(0.6),
                          alignment: Alignment.topLeft,
                          child: Text(
                            item.note ?? '',
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: Theme.of(context).colorScheme.onTertiaryContainer,
                            ),
                          ),
                        )
                      else if (isFile)
                        Container(
                          color: Colors.blueGrey.shade50,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.description_rounded, size: 42, color: Colors.blueGrey.shade700),
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.blueGrey.shade700,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  ext.isNotEmpty ? ext : 'FILE',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      else if (coverUrl != null)
                        Image.network(
                          coverUrl,
                          fit: BoxFit.cover,
                          cacheWidth: 400,
                          errorBuilder: (_, __, ___) => _buildDefaultPlaceholder(false),
                        )
                      else
                        _buildDefaultPlaceholder(isImage),
                      if (isSelected)
                        Container(color: Theme.of(context).colorScheme.primary.withOpacity(0.25)),
                    ],
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(10.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: _highContrastMode ? FontWeight.bold : FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        Row(
                          children: [
                            Icon(
                              isImage
                                  ? Icons.screenshot
                                  : (isNote
                                      ? Icons.sticky_note_2_outlined
                                      : (isFile ? Icons.attach_file : Icons.public)),
                              size: 12,
                              color: _highContrastMode ? Colors.black87 : Colors.grey,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                item.tags?.isNotEmpty == true
                                    ? '#${item.tags}'
                                    : (item.url ?? (isNote ? '文字筆記' : (isFile ? '本機文件' : '本機截圖'))),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _highContrastMode ? Colors.black87 : Colors.grey,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            Positioned(
              top: 6,
              right: 6,
              child: _isSelectionMode
                  ? Icon(
                      isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: isSelected ? Theme.of(context).colorScheme.primary : Colors.white,
                      size: 26,
                    )
                  : Row(
                      children: [
                        if (item.isPinned) _badgeIcon(Icons.push_pin, Colors.amber),
                        if (!item.isRead) ...[
                          const SizedBox(width: 4),
                          _badgeIcon(Icons.circle, Colors.blueAccent, size: 10),
                        ],
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: () => _showEditBottomSheet(item),
                          child: _badgeIcon(Icons.more_horiz, Colors.white, size: 16),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badgeIcon(IconData icon, Color color, {double size = 14}) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
      child: Icon(icon, size: size, color: color),
    );
  }

  Future<void> _openItemDetail(SavedItem item) async {
    await widget.db.markAsRead(item.id);
    if (!mounted) return;

    if (item.itemType == 'image' && item.localImagePath != null) {
      if (!File(item.localImagePath!).existsSync()) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('本機尚未下載此圖檔，請點擊上方雲端同步按鈕下載')),
        );
        return;
      }
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(item.title),
              actions: [
                IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () => _showEditBottomSheet(item),
                ),
              ],
            ),
            body: Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.file(File(item.localImagePath!)),
              ),
            ),
          ),
        ),
      );
    } else if (item.itemType == 'file' && item.localImagePath != null) {
      if (!File(item.localImagePath!).existsSync()) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('本機尚未下載此文件，請點擊上方雲端同步按鈕下載')),
        );
        return;
      }
      final result = await OpenFilex.open(item.localImagePath!);
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('無法開啟此檔案：${result.message}')),
        );
      }
    } else if (item.itemType == 'note') {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(item.title),
          content: SingleChildScrollView(
            child: SelectableText(
              item.note ?? '',
              style: const TextStyle(fontSize: 15, height: 1.5),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: item.note ?? ''));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已複製筆記內容')),
                );
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('複製全文'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('關閉'),
            ),
          ],
        ),
      );
    } else if (item.url != null) {
      await _openExternalUrl(item.url!);
    }
  }

  void _showEditBottomSheet(SavedItem item) async {
    final titleCtrl = TextEditingController(text: item.title);
    final tagsCtrl = TextEditingController(text: item.tags ?? '');
    final noteCtrl = TextEditingController(text: item.note ?? '');

    final allCollections = await widget.db.select(widget.db.collections).get();
    int? selectedColId = item.collectionId;
    bool isGeneratingAi = false;
    bool isSummarizingAi = false;

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('編輯與歸類', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(item.isPinned ? Icons.push_pin : Icons.push_pin_outlined),
                        tooltip: '置頂',
                        onPressed: () async {
                          await (widget.db.update(widget.db.savedItems)
                                ..where((t) => t.id.equals(item.id)))
                              .write(SavedItemsCompanion(
                            isPinned: drift.Value(!item.isPinned),
                            updatedAt: drift.Value(DateTime.now()),
                          ));
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                        tooltip: '移至回收桶',
                        onPressed: () async {
                          await (widget.db.update(widget.db.savedItems)
                                ..where((t) => t.id.equals(item.id)))
                              .write(SavedItemsCompanion(
                            isDeleted: const drift.Value(true),
                            updatedAt: drift.Value(DateTime.now()),
                          ));
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text('已移至回收桶'),
                                action: SnackBarAction(
                                  label: '復原',
                                  onPressed: () =>
                                      LibraryMaintenanceService.restoreItem(widget.db, item.id),
                                ),
                              ),
                            );
                          }
                        },
                      ),
                    ],
                  )
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                value: allCollections.any((c) => c.id == selectedColId) ? selectedColId : null,
                decoration: const InputDecoration(
                  labelText: '所屬收藏夾',
                  prefixIcon: Icon(Icons.folder_open),
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('未分類')),
                  ...allCollections.map((col) => DropdownMenuItem<int?>(
                        value: col.id,
                        child: Text(col.name),
                      )),
                ],
                onChanged: (val) => setModalState(() => selectedColId = val),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(labelText: '名稱 / 標題', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tagsCtrl,
                decoration: InputDecoration(
                  labelText: '標籤 (方便搜尋，如：合約, 報表)',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: item.itemType == 'image' ? 'AI 識圖產生標籤與摘要' : 'AI 自動產生標籤與歸類',
                    onPressed: isGeneratingAi
                        ? null
                        : () async {
                            if (_geminiApiKey.isEmpty) {
                              showDialog(
                                context: context,
                                builder: (dCtx) => AlertDialog(
                                  title: const Text('尚未設定 API Key'),
                                  content: const Text('請先至右上角「設定 → AI 智慧整理」填入 Gemini API Key。'),
                                  actions: [
                                    FilledButton(
                                      onPressed: () => Navigator.pop(dCtx),
                                      child: const Text('確定'),
                                    ),
                                  ],
                                ),
                              );
                              return;
                            }
                            setModalState(() => isGeneratingAi = true);
                            try {
                              final res = await AiOrganizerService.suggestTags(
                                title: titleCtrl.text.trim(),
                                url: item.url,
                                note: noteCtrl.text.trim(),
                                imagePath: item.itemType == 'image' ? item.localImagePath : null,
                                existingCollections: allCollections.map((c) => c.name).toList(),
                              );
                              if (res != null && ctx.mounted) {
                                setModalState(() {
                                  if (res.tags.isNotEmpty) {
                                    tagsCtrl.text = res.tags.join(', ');
                                  }
                                  if (res.suggestedTitle != null &&
                                      item.itemType == 'image') {
                                    titleCtrl.text = res.suggestedTitle!;
                                  }
                                  if (res.summary != null &&
                                      noteCtrl.text.trim().isEmpty) {
                                    noteCtrl.text = res.summary!;
                                  }
                                  if (selectedColId == null && res.suggestedCollection != null) {
                                    for (final col in allCollections) {
                                      if (col.name == res.suggestedCollection) {
                                        selectedColId = col.id;
                                        break;
                                      }
                                    }
                                  }
                                });
                              }
                            } catch (e) {
                              if (mounted) {
                                showDialog(
                                  context: context,
                                  builder: (dCtx) => AlertDialog(
                                    title: const Text('AI 產生失敗'),
                                    content: Text('$e'),
                                    actions: [
                                      FilledButton(
                                        onPressed: () => Navigator.pop(dCtx),
                                        child: const Text('確定'),
                                      ),
                                    ],
                                  ),
                                );
                              }
                            } finally {
                              if (ctx.mounted) setModalState(() => isGeneratingAi = false);
                            }
                          },
                    icon: isGeneratingAi
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome, color: Color(0xFF8C6239)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteCtrl,
                maxLines: 4,
                decoration: const InputDecoration(labelText: '備註或重點摘要', border: OutlineInputBorder()),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: isSummarizingAi
                      ? null
                      : () async {
                          if (_geminiApiKey.isEmpty) {
                            showDialog(
                              context: context,
                              builder: (dCtx) => AlertDialog(
                                title: const Text('尚未設定 API Key'),
                                content: const Text('請先至右上角「設定 → AI 智慧整理」填入 Gemini API Key。'),
                                actions: [
                                  FilledButton(
                                    onPressed: () => Navigator.pop(dCtx),
                                    child: const Text('確定'),
                                  ),
                                ],
                              ),
                            );
                            return;
                          }
                          setModalState(() => isSummarizingAi = true);
                          try {
                            final summary = await AiOrganizerService.summarizeItem(
                              title: titleCtrl.text.trim(),
                              url: item.url,
                              note: noteCtrl.text.trim(),
                              imagePath: item.itemType == 'image' ? item.localImagePath : null,
                            );
                            if (ctx.mounted) {
                              setModalState(() => noteCtrl.text = summary);
                            }
                          } catch (e) {
                            if (mounted) {
                              showDialog(
                                context: context,
                                builder: (dCtx) => AlertDialog(
                                  title: const Text('摘要產生失敗'),
                                  content: Text('$e'),
                                  actions: [
                                    FilledButton(
                                      onPressed: () => Navigator.pop(dCtx),
                                      child: const Text('確定'),
                                    ),
                                  ],
                                ),
                              );
                            }
                          } finally {
                            if (ctx.mounted) setModalState(() => isSummarizingAi = false);
                          }
                        },
                  icon: isSummarizingAi
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.summarize_outlined, size: 16),
                  label: Text(
                    isSummarizingAi ? '正在產生 3 點重點摘要...' : 'AI 產生 3 點重點摘要',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () async {
                  await (widget.db.update(widget.db.savedItems)..where((t) => t.id.equals(item.id)))
                      .write(
                    SavedItemsCompanion(
                      collectionId: drift.Value(selectedColId),
                      title: drift.Value(titleCtrl.text.trim()),
                      tags: drift.Value(tagsCtrl.text.trim()),
                      note: drift.Value(noteCtrl.text.trim()),
                      updatedAt: drift.Value(DateTime.now()),
                    ),
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('儲存變更'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndSaveLocalFile(int? targetCollectionId, String customTags) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: false);
    if (result == null || result.files.single.path == null) return;

    final sourceFile = File(result.files.single.path!);
    final originalName = result.files.single.name;
    final ext = p.extension(originalName).replaceAll('.', '').toUpperCase();

    final appDir = await getApplicationDocumentsDirectory();
    final filesDir = Directory(p.join(appDir.path, 'files'));
    if (!await filesDir.exists()) {
      await filesDir.create(recursive: true);
    }

    final savedFileName = '${DateTime.now().millisecondsSinceEpoch}_$originalName';
    final targetPath = p.join(filesDir.path, savedFileName);
    await sourceFile.copy(targetPath);

    final finalTags = customTags.isNotEmpty ? customTags : (ext.isNotEmpty ? ext : 'FILE');

    await widget.db.into(widget.db.savedItems).insert(
          SavedItemsCompanion.insert(
            itemType: 'file',
            title: drift.Value(originalName),
            tags: drift.Value(finalTags),
            localImagePath: drift.Value(targetPath),
            collectionId: drift.Value(targetCollectionId),
          ),
        );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已將檔案「$originalName」存入收藏庫')),
      );
    }
  }

  Future<void> _showQuickAddBottomSheet() async {
    final contentCtrl = TextEditingController();
    final titleCtrl = TextEditingController();
    final tagsCtrl = TextEditingController();

    final allCollections = await widget.db.select(widget.db.collections).get();
    int? selectedColId = (_selectedCollectionId != null && _selectedCollectionId! > 0)
        ? _selectedCollectionId
        : null;

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '隨手新增項目',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final clipData = await Clipboard.getData(Clipboard.kTextPlain);
                      if (clipData?.text != null && clipData!.text!.isNotEmpty) {
                        setModalState(() => contentCtrl.text = clipData.text!.trim());
                      }
                    },
                    icon: const Icon(Icons.content_paste, size: 18),
                    label: const Text('貼上剪貼簿'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final colId = selectedColId;
                  final tags = tagsCtrl.text.trim();
                  Navigator.pop(ctx);
                  await _pickAndSaveLocalFile(colId, tags);
                },
                icon: const Icon(Icons.upload_file),
                label: const Text('選取手機檔案 (PDF / Word / Excel / 任意格式)'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('或輸入網址 / 文字筆記', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    ),
                    Expanded(child: Divider()),
                  ],
                ),
              ),
              TextField(
                controller: contentCtrl,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: '網址或靈感筆記內容',
                  hintText: '貼上 https://... 連結，或直接輸入文字筆記',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                  labelText: '自訂標題 (選填，網址留白會自動抓取)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int?>(
                      value: allCollections.any((c) => c.id == selectedColId) ? selectedColId : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '收藏夾',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<int?>(value: null, child: Text('未分類')),
                        ...allCollections.map((col) => DropdownMenuItem<int?>(
                              value: col.id,
                              child: Text(col.name, overflow: TextOverflow.ellipsis),
                            )),
                      ],
                      onChanged: (val) => setModalState(() => selectedColId = val),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: tagsCtrl,
                      decoration: const InputDecoration(
                        labelText: '標籤 (選填)',
                        hintText: '合約, 報表',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () async {
                  final rawInput = contentCtrl.text.trim();
                  if (rawInput.isEmpty) return;

                  final customTitle = titleCtrl.text.trim();
                  final tags = tagsCtrl.text.trim();
                  final shouldAutoTag = tags.isEmpty && _aiAutoTagEnabled && _geminiApiKey.isNotEmpty;

                  final urlRegExp = RegExp(r'(https?:\/\/[^\s]+)');
                  final match = urlRegExp.firstMatch(rawInput);

                  if (match != null) {
                    final cleanUrl = match.group(0)!;
                    final itemId = await widget.db.into(widget.db.savedItems).insert(
                          SavedItemsCompanion.insert(
                            itemType: 'link',
                            url: drift.Value(cleanUrl),
                            title: drift.Value(customTitle.isNotEmpty ? customTitle : cleanUrl),
                            tags: drift.Value(tags.isNotEmpty ? tags : null),
                            collectionId: drift.Value(selectedColId),
                          ),
                        );
                    if (_enhancedPreview) {
                      _fetchTitleInBackground(
                        itemId,
                        cleanUrl,
                        updateTitle: customTitle.isEmpty,
                        triggerAiTag: shouldAutoTag,
                      );
                    } else if (shouldAutoTag) {
                      AiOrganizerService.organizeSingleItemById(widget.db, itemId).catchError((_) => false);
                    }
                  } else {
                    final noteTitle = customTitle.isNotEmpty
                        ? customTitle
                        : (rawInput.length > 20 ? '${rawInput.substring(0, 20)}...' : rawInput);

                    final itemId = await widget.db.into(widget.db.savedItems).insert(
                          SavedItemsCompanion.insert(
                            itemType: 'note',
                            title: drift.Value(noteTitle),
                            note: drift.Value(rawInput),
                            tags: drift.Value(tags.isNotEmpty ? tags : null),
                            collectionId: drift.Value(selectedColId),
                          ),
                        );
                    if (shouldAutoTag) {
                      AiOrganizerService.organizeSingleItemById(widget.db, itemId).catchError((_) => false);
                    }
                  }

                  if (ctx.mounted) Navigator.pop(ctx);
                },
                icon: const Icon(Icons.check),
                label: const Text('存入收藏庫'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _fetchTitleInBackground(
    int itemId,
    String url, {
    bool updateTitle = true,
    bool triggerAiTag = false,
  }) async {
    try {
      final data = await MetadataFetch.extract(url);
      if (data != null) {
        if (data.image != null && data.image!.trim().isNotEmpty) {
          await _saveLinkCover(url, data.image!.trim());
        }

        if (updateTitle && data.title != null && data.title!.trim().isNotEmpty) {
          await (widget.db.update(widget.db.savedItems)..where((t) => t.id.equals(itemId))).write(
            SavedItemsCompanion(
              title: drift.Value(data.title!.trim()),
              note: drift.Value(data.description?.trim()),
              updatedAt: drift.Value(DateTime.now()),
            ),
          );
        }
      }
    } catch (_) {}

    if (triggerAiTag && _aiAutoTagEnabled && _geminiApiKey.isNotEmpty) {
      try {
        await AiOrganizerService.organizeSingleItemById(widget.db, itemId);
      } catch (_) {}
    }
  }

  void _showCreateCollectionDialog() {
    final nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增收藏夾'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '例如：旅遊靈感、必吃美食、工作文件',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isNotEmpty) {
                final newId = await widget.db.createCollection(name);
                if (mounted) setState(() => _selectedCollectionId = newId);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('建立'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteCollection(Collection col) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('刪除「${col.name}」？'),
        content: const Text('刪除資料夾不會刪掉裡面的項目，它們會自動移回「未分類」。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              await widget.db.deleteCollection(col.id);
              if (mounted && _selectedCollectionId == col.id) {
                setState(() => _selectedCollectionId = null);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('刪除'),
          ),
        ],
      ),
    );
  }

  Future<void> _showBatchMoveDialog() async {
    final allCollections = await widget.db.select(widget.db.collections).get();
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                '將 ${_selectedIds.length} 個項目移動至...',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('未分類'),
              onTap: () async {
                await widget.db.batchMoveItems(_selectedIds.toList(), null);
                setState(() => _selectedIds.clear());
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
            ...allCollections.map((col) => ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(col.name),
                  onTap: () async {
                    await widget.db.batchMoveItems(_selectedIds.toList(), col.id);
                    setState(() => _selectedIds.clear());
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                )),
          ],
        ),
      ),
    );
  }

  void _confirmBatchDelete() {
    final count = _selectedIds.length;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('將這 $count 個項目移至回收桶？'),
        content: const Text('項目會先移至回收桶保留，日後仍可還原，或到回收桶永久清空。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              final ids = _selectedIds.toList();
              await (widget.db.update(widget.db.savedItems)
                    ..where((t) => t.id.isIn(ids)))
                  .write(SavedItemsCompanion(
                isDeleted: const drift.Value(true),
                updatedAt: drift.Value(DateTime.now()),
              ));
              setState(() => _selectedIds.clear());
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('移至回收桶'),
          ),
        ],
      ),
    );
  }
}