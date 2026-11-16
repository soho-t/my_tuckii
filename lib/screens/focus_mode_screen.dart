import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_card_swiper/flutter_card_swiper.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import '../database/app_database.dart';

class FocusModeScreen extends StatefulWidget {
  final AppDatabase db;
  const FocusModeScreen({super.key, required this.db});

  @override
  State<FocusModeScreen> createState() => _FocusModeScreenState();
}

class _FocusModeScreenState extends State<FocusModeScreen> {
  final CardSwiperController _swiperController = CardSwiperController();
  List<SavedItem> _unreadItems = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUnreadItems();
  }

  Future<void> _loadUnreadItems() async {
    final items = await widget.db.watchUnreadItems().first;
    if (mounted) {
      setState(() {
        _unreadItems = items;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _swiperController.dispose();
    super.dispose();
  }

  Future<bool> _onSwipe(
    int previousIndex,
    int? currentIndex,
    CardSwiperDirection direction,
  ) async {
    final item = _unreadItems[previousIndex];

    if (direction == CardSwiperDirection.right) {
      await widget.db.markAsRead(item.id);

      if (item.itemType == 'link' && item.url != null) {
        final uri = Uri.tryParse(item.url!);
        if (uri != null) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      } else if (item.itemType == 'image' && item.localImagePath != null && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => Scaffold(
              backgroundColor: Colors.black,
              appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
              body: Center(child: InteractiveViewer(child: Image.file(File(item.localImagePath!)))),
            ),
          ),
        );
      } else if (item.itemType == 'file' && item.localImagePath != null) {
        await OpenFilex.open(item.localImagePath!);
      } else if (item.itemType == 'note' && mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(item.title),
            content: SingleChildScrollView(
              child: SelectableText(
                item.note ?? '',
                style: const TextStyle(fontSize: 16, height: 1.6),
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
                child: const Text('完成閱讀'),
              ),
            ],
          ),
        );
      }
    } else if (direction == CardSwiperDirection.left) {
      await widget.db.markAsRead(item.id);
    } else if (direction == CardSwiperDirection.top) {
      await widget.db.softDeleteItem(item);
    }

    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('專注複習模式'),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _unreadItems.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.check_circle_outline, size: 72, color: Colors.green),
                      const SizedBox(height: 16),
                      const Text('太棒了！所有新存項目都已消化完畢', style: TextStyle(fontSize: 16)),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('返回收藏庫'),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(
                        '← 左滑歸檔  |  ↑ 上滑刪除  |  右滑開啟查看 →',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    ),
                    Expanded(
                      child: CardSwiper(
                        controller: _swiperController,
                        cardsCount: _unreadItems.length,
                        isLoop: false,
                        onSwipe: _onSwipe,
                        onEnd: () => setState(() => _unreadItems.clear()),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                        cardBuilder: (context, index, percentThresholdX, percentThresholdY) {
                          return _buildSwipeCard(_unreadItems[index]);
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          FloatingActionButton(
                            heroTag: 'archive',
                            backgroundColor: Colors.grey.shade200,
                            foregroundColor: Colors.black87,
                            onPressed: () => _swiperController.swipe(CardSwiperDirection.left),
                            tooltip: '歸檔略過',
                            child: const Icon(Icons.archive_outlined),
                          ),
                          FloatingActionButton(
                            heroTag: 'delete',
                            backgroundColor: Colors.red.shade100,
                            foregroundColor: Colors.red.shade800,
                            onPressed: () => _swiperController.swipe(CardSwiperDirection.top),
                            tooltip: '永久刪除',
                            child: const Icon(Icons.delete_outline),
                          ),
                          FloatingActionButton(
                            heroTag: 'open',
                            backgroundColor: Colors.amber.shade400,
                            foregroundColor: Colors.black,
                            onPressed: () => _swiperController.swipe(CardSwiperDirection.right),
                            tooltip: '立即開啟',
                            child: const Icon(Icons.open_in_new),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildSwipeCard(SavedItem item) {
    final isImage = item.itemType == 'image';
    final isNote = item.itemType == 'note';
    final isFile = item.itemType == 'file';
    final hasLocalImage = isImage && item.localImagePath != null && File(item.localImagePath!).existsSync();
    final ext = item.localImagePath != null
        ? p.extension(item.localImagePath!).replaceAll('.', '').toUpperCase()
        : 'FILE';

    return Card(
      elevation: 6,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: hasLocalImage
                ? Image.file(File(item.localImagePath!), fit: BoxFit.cover)
                : isNote
                    ? Container(
                        padding: const EdgeInsets.all(24),
                        color: Theme.of(context).colorScheme.tertiaryContainer.withOpacity(0.5),
                        alignment: Alignment.topLeft,
                        child: SingleChildScrollView(
                          child: Text(
                            item.note ?? '',
                            style: TextStyle(
                              fontSize: 16,
                              height: 1.6,
                              color: Theme.of(context).colorScheme.onTertiaryContainer,
                            ),
                          ),
                        ),
                      )
                    : isFile
                        ? Container(
                            color: Colors.blueGrey.shade50,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.insert_drive_file_rounded, size: 76, color: Colors.blueGrey.shade700),
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.blueGrey.shade700,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    ext.isNotEmpty ? ext : 'DOCUMENT',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Container(
                            color: Theme.of(context).colorScheme.primaryContainer,
                            child: Icon(
                              isImage ? Icons.image : Icons.link,
                              size: 80,
                              color: Theme.of(context).colorScheme.onPrimaryContainer,
                            ),
                          ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      if (!isNote && item.note != null && item.note!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          item.note!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.grey, fontSize: 14),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    item.url ??
                        '${isNote ? "文字筆記" : (isFile ? "本機文件 ($ext)" : "螢幕截圖")} · 儲存於 ${item.createdAt.month}/${item.createdAt.day}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
