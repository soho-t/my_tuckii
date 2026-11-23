import 'dart:io';
import 'package:drift/drift.dart' as drift;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:metadata_fetch/metadata_fetch.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../database/app_database.dart';
import '../main.dart';
import '../services/backup_service.dart';
import '../services/bookmark_importer.dart';
import '../services/google_drive_sync_service.dart';
import '../services/reminder_service.dart';
import '../services/share_handler.dart';
import 'focus_mode_screen.dart';

class HomeScreen extends StatefulWidget {
  final AppDatabase db;
  const HomeScreen({super.key, required this.db});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late ShareHandlerService _shareHandler;
  final TextEditingController _searchController = TextEditingController();

  String _searchQuery = '';
  String _selectedFilter = 'all';
  int? _selectedCollectionId;
  bool _isSyncing = false;

  // 第一階段：外觀與收錄設定狀態
  bool _highContrastMode = false;
  bool _enhancedPreview = true;
  bool _detectClipboardOnOpen = false;
  String? _lastExportTime;
  String? _lastPromptedClipUrl;

  // 第二階段：提醒與連結健康檢查狀態
  bool _notifPermissionGranted = false;
  bool _dailyReviewEnabled = true;
  int _dailyReviewHour = 21;
  int _dailyReviewMinute = 0;
  bool _staleReminderEnabled = true;
  int _staleDays = 30;
  bool _weekendReminderEnabled = false;
  bool _linkHealthCheckEnabled = false;
  bool _isCheckingLinks = false;

  final Set<int> _selectedIds = {};
  List<SavedItem> _currentItems = [];
  bool get _isSelectionMode => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

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
      if (_detectClipboardOnOpen) {
        _checkClipboardForNewLink();
      }
    }
  }

  void _handleNotificationPayload(String payload) {
    if (!mounted) return;
    if (payload == 'link_health') {
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
    if (!mounted) return;
    setState(() {
      _highContrastMode = prefs.getBool('setting_high_contrast') ?? false;
      _enhancedPreview = prefs.getBool('setting_enhanced_preview') ?? true;
      _detectClipboardOnOpen = prefs.getBool('setting_detect_clipboard') ?? false;
      _lastExportTime = prefs.getString('setting_last_export_time');
      _lastPromptedClipUrl = prefs.getString('setting_last_clip_url');

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
    if (_detectClipboardOnOpen) {
      Future.delayed(const Duration(milliseconds: 600), _checkClipboardForNewLink);
    }
    if (_linkHealthCheckEnabled) {
      _autoRunWeeklyLinkHealthCheck(prefs);
    }
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
                _fetchTitleInBackground(itemId, detectedUrl);
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
                              subtitle: const Text('存入網址時自動在背景載入公開頁面以取得標題與摘要'),
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
                              subtitle: Text('每週最多一次，告訴你有幾則超過 $_staleDays 天沒看'),
                              value: _staleReminderEnabled,
                              onChanged: (val) async {
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
                                        setSheetState(() => _isCheckingLinks = true);
                                        try {
                                          final res = await ReminderService.runLinkHealthCheck(widget.db);
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '健康檢查完成！共掃描 ${res.checked} 個連結，發現 ${res.broken} 個失效連結。',
                                                ),
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
                                label: Text(_isCheckingLinks ? '正在掃描收藏連結...' : '立即掃描所有連結健康度'),
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
                              '版本 1.4.0',
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                            ),
                            const Divider(height: 20),
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
                              onTap: () => launchUrl(
                                Uri.parse('https://github.com/sohot-t/my_tuckii'),
                                mode: LaunchMode.externalApplication,
                              ),
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

  Widget _buildItemCard(SavedItem item) {
    final isImage = item.itemType == 'image';
    final isNote = item.itemType == 'note';
    final isFile = item.itemType == 'file';
    final hasLocalImage = isImage && item.localImagePath != null && File(item.localImagePath!).existsSync();
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
                      else
                        Container(
                          color: Theme.of(context).colorScheme.secondaryContainer,
                          child: Icon(
                            isImage ? Icons.cloud_download_outlined : Icons.link_rounded,
                            size: 40,
                            color: Theme.of(context).colorScheme.onSecondaryContainer,
                          ),
                        ),
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
      final uri = Uri.tryParse(item.url!);
      if (uri != null) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }

  void _showEditBottomSheet(SavedItem item) async {
    final titleCtrl = TextEditingController(text: item.title);
    final tagsCtrl = TextEditingController(text: item.tags ?? '');
    final noteCtrl = TextEditingController(text: item.note ?? '');

    final allCollections = await widget.db.select(widget.db.collections).get();
    int? selectedColId = item.collectionId;

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
                        tooltip: '刪除',
                        onPressed: () async {
                          await widget.db.softDeleteItem(item);
                          if (ctx.mounted) Navigator.pop(ctx);
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
                decoration: const InputDecoration(
                  labelText: '標籤 (方便搜尋，如：合約, 報表)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteCtrl,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '備註或筆記內文', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
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
                    if (customTitle.isEmpty && _enhancedPreview) {
                      _fetchTitleInBackground(itemId, cleanUrl);
                    }
                  } else {
                    final noteTitle = customTitle.isNotEmpty
                        ? customTitle
                        : (rawInput.length > 20 ? '${rawInput.substring(0, 20)}...' : rawInput);

                    await widget.db.into(widget.db.savedItems).insert(
                          SavedItemsCompanion.insert(
                            itemType: 'note',
                            title: drift.Value(noteTitle),
                            note: drift.Value(rawInput),
                            tags: drift.Value(tags.isNotEmpty ? tags : null),
                            collectionId: drift.Value(selectedColId),
                          ),
                        );
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

  Future<void> _fetchTitleInBackground(int itemId, String url) async {
    try {
      final data = await MetadataFetch.extract(url);
      if (data != null && data.title != null && data.title!.trim().isNotEmpty) {
        await (widget.db.update(widget.db.savedItems)..where((t) => t.id.equals(itemId))).write(
          SavedItemsCompanion(
            title: drift.Value(data.title!.trim()),
            note: drift.Value(data.description?.trim()),
            updatedAt: drift.Value(DateTime.now()),
          ),
        );
      }
    } catch (_) {}
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
        title: Text('刪除這 $count 個項目？'),
        content: const Text('刪除後將一併移除本機截圖與文件檔案，且雲端同步時也會一併移除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              final itemsToDelete =
                  _currentItems.where((item) => _selectedIds.contains(item.id)).toList();
              await widget.db.batchDeleteItems(itemsToDelete);
              setState(() => _selectedIds.clear());
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('全部刪除'),
          ),
        ],
      ),
    );
  }
}