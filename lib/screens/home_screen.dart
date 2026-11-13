import 'dart:io';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:metadata_fetch/metadata_fetch.dart';
import 'package:url_launcher/url_launcher.dart';
import '../database/app_database.dart';
import '../main.dart';
import '../services/backup_service.dart';
import '../services/bookmark_importer.dart';
import '../services/share_handler.dart';
import 'focus_mode_screen.dart';

class HomeScreen extends StatefulWidget {
  final AppDatabase db;
  const HomeScreen({super.key, required this.db});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late ShareHandlerService _shareHandler;
  final TextEditingController _searchController = TextEditingController();

  String _searchQuery = '';
  String _selectedFilter = 'all';
  int? _selectedCollectionId;

  final Set<int> _selectedIds = {};
  List<SavedItem> _currentItems = [];
  bool get _isSelectionMode => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
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
    _shareHandler.dispose();
    _searchController.dispose();
    super.dispose();
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
      drift.Expression<bool> condition = const drift.Constant(true);

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
                        label: Text('專注複習 ($unreadCount)'),
                      );
                    },
                  ),
                  _buildMoreMenuButton(),
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
                        '目前沒有符合的收藏項目
試著從其他 App 點擊「分享」或按右下角「+ 新增」吧！',
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

  Widget _buildMoreMenuButton() {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      onSelected: (value) async {
        if (value == 'export') {
          try {
            await BackupService.exportBackup(widget.db);
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('備份失敗：$e')));
            }
          }
        } else if (value == 'import') {
          final confirm = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('確定要還原備份？'),
              content: const Text('還原將會覆蓋目前手機上的所有書籤與截圖，此操作無法復原。'),
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
        } else if (value == 'import_html') {
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
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('書籤匯入失敗：$e')));
            }
          }
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'import_html',
          child: ListTile(
            leading: Icon(Icons.bookmark_add_outlined),
            title: Text('匯入瀏覽器書籤 (HTML)'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          value: 'export',
          child: ListTile(
            leading: Icon(Icons.cloud_upload_outlined),
            title: Text('匯出 ZIP 備份包'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          value: 'import',
          child: ListTile(
            leading: Icon(Icons.restore_page_outlined),
            title: Text('從 ZIP 備份還原'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
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
    final hasLocalFile = item.localImagePath != null && File(item.localImagePath!).existsSync();
    final isSelected = _selectedIds.contains(item.id);

    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: isSelected ? 4 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: isSelected
            ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 3)
            : BorderSide.none,
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
                      if (hasLocalFile)
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
                      else
                        Container(
                          color: Theme.of(context).colorScheme.secondaryContainer,
                          child: Icon(
                            isImage ? Icons.image_not_supported : Icons.link_rounded,
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
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        Row(
                          children: [
                            Icon(
                              isImage
                                  ? Icons.screenshot
                                  : (isNote ? Icons.sticky_note_2_outlined : Icons.public),
                              size: 12,
                              color: Colors.grey,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                item.tags?.isNotEmpty == true
                                    ? '#${item.tags}'
                                    : (item.url ?? (isNote ? '文字筆記' : '本機截圖')),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11, color: Colors.grey),
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
                              .write(SavedItemsCompanion(isPinned: drift.Value(!item.isPinned)));
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                        tooltip: '刪除',
                        onPressed: () async {
                          if (item.localImagePath != null) {
                            final file = File(item.localImagePath!);
                            if (await file.exists()) await file.delete();
                          }
                          await (widget.db.delete(widget.db.savedItems)
                                ..where((t) => t.id.equals(item.id)))
                              .go();
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
                  labelText: '標籤 (方便搜尋，如：美食, 台北)',
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
                    '隨手記一筆 / 貼上網址',
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
              const SizedBox(height: 12),
              TextField(
                controller: contentCtrl,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: '網址或靈感筆記內容 *',
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
                        hintText: '靈感, 待辦',
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
                    if (customTitle.isEmpty) {
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
            hintText: '例如：旅遊靈感、必吃美食、工作參考',
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
        content: const Text('刪除資料夾不會刪掉裡面的書籤或截圖，它們會自動移回「未分類」。'),
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
        content: const Text('刪除後將一併移除本機截圖檔案，且無法復原。'),
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
