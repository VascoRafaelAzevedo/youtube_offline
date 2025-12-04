import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../data/models/models.dart';
import '../../providers/providers.dart';
import '../player/player_screen.dart';
import '../login/login_screen.dart';
import '../settings/settings_page.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _currentIndex = 0;
  Timer? _refreshTimer;
  bool _isSelectionMode = false;
  final Set<String> _selectedVideoIds = {};

  @override
  void initState() {
    super.initState();
    // Initialize sync and start auto-sync
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initAndSync();
    });

    // Refresh UI periodically to show download progress
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) {
        ref.read(syncProvider.notifier).refresh();
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _initAndSync() async {
    await ref.read(syncProvider.notifier).initialize();
    // Auto-sync on app open
    ref.read(syncProvider.notifier).sync();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final syncState = ref.watch(syncProvider);

    // Redirect to login if not authenticated
    if (!authState.isAuthenticated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
      });
    }

    return Scaffold(
      appBar: _isSelectionMode
          ? _buildSelectionAppBar()
          : _buildNormalAppBar(syncState, authState),
      body: Column(
        children: [
          // Status message
          if (syncState.statusMessage != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Text(
                syncState.statusMessage!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
                textAlign: TextAlign.center,
              ),
            ),

          // Error message
          if (syncState.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Theme.of(context).colorScheme.errorContainer,
              child: Text(
                syncState.error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
                textAlign: TextAlign.center,
              ),
            ),

          // Main content
          Expanded(child: _buildBody(syncState)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          if (_isSelectionMode) {
            _clearSelection();
          }
          setState(() => _currentIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.video_library_outlined),
            selectedIcon: Icon(Icons.video_library),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.visibility_outlined),
            selectedIcon: Icon(Icons.visibility),
            label: 'Watched',
          ),
          NavigationDestination(
            icon: Icon(Icons.delete_outline),
            selectedIcon: Icon(Icons.delete),
            label: 'Deleted',
          ),
        ],
      ),
    );
  }

  AppBar _buildNormalAppBar(SyncUiState syncState, AuthState authState) {
    return AppBar(
      title: Text(_getTitle()),
      actions: [
        // Sync button
        if (syncState.isSyncing)
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else
          IconButton(
            icon: const Icon(Icons.sync),
            onPressed: () => ref.read(syncProvider.notifier).sync(),
            tooltip: 'Sync with YouTube',
          ),
        // Settings
        IconButton(
          icon: const Icon(Icons.settings),
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
          tooltip: 'Settings',
        ),
        // User menu
        PopupMenuButton<String>(
          icon: CircleAvatar(
            radius: 16,
            backgroundImage: authState.user?.photoUrl != null
                ? NetworkImage(authState.user!.photoUrl!)
                : null,
            child: authState.user?.photoUrl == null
                ? const Icon(Icons.person, size: 20)
                : null,
          ),
          onSelected: (value) {
            if (value == 'logout') {
              ref.read(authProvider.notifier).signOut();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              enabled: false,
              child: Text(authState.user?.email ?? 'User'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'logout',
              child: Row(
                children: [
                  Icon(Icons.logout),
                  SizedBox(width: 8),
                  Text('Sign out'),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  AppBar _buildSelectionAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text('${_selectedVideoIds.length} selected'),
      actions: [
        IconButton(
          icon: const Icon(Icons.delete, color: Colors.red),
          onPressed: _selectedVideoIds.isNotEmpty
              ? _deleteSelectedVideos
              : null,
          tooltip: 'Delete selected',
        ),
      ],
    );
  }

  void _clearSelection() {
    setState(() {
      _isSelectionMode = false;
      _selectedVideoIds.clear();
    });
  }

  void _toggleVideoSelection(Video video) {
    setState(() {
      if (_selectedVideoIds.contains(video.videoId)) {
        _selectedVideoIds.remove(video.videoId);
        if (_selectedVideoIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedVideoIds.add(video.videoId);
      }
    });
  }

  void _enterSelectionMode(Video video) {
    setState(() {
      _isSelectionMode = true;
      _selectedVideoIds.add(video.videoId);
    });
  }

  Future<void> _deleteSelectedVideos() async {
    final count = _selectedVideoIds.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete videos?'),
        content: Text('Delete $count selected video${count > 1 ? 's' : ''}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final syncState = ref.read(syncProvider);
      final allVideos = [
        ...syncState.downloadedVideos,
        ...syncState.watchedVideos,
      ];
      for (final videoId in _selectedVideoIds) {
        final video = allVideos.where((v) => v.videoId == videoId).firstOrNull;
        if (video != null) {
          await ref.read(syncProvider.notifier).deleteVideo(video);
        }
      }
      _clearSelection();
    }
  }

  String _getTitle() {
    switch (_currentIndex) {
      case 0:
        return 'Library';
      case 1:
        return 'Watched';
      case 2:
        return 'Deleted';
      default:
        return 'Offline YouTube';
    }
  }

  Widget _buildBody(SyncUiState syncState) {
    if (syncState.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    switch (_currentIndex) {
      case 0:
        return _buildLibraryTab(syncState);
      case 1:
        return _buildWatchedTab(syncState);
      case 2:
        return _buildDeletedTab(syncState);
      default:
        return const SizedBox();
    }
  }

  Widget _buildLibraryTab(SyncUiState syncState) {
    final videos = syncState.downloadedVideos;
    final pending = syncState.pendingVideos;

    if (videos.isEmpty && pending.isEmpty) {
      return _buildEmptyState(
        icon: Icons.video_library_outlined,
        title: 'No videos yet',
        subtitle: 'Add videos to your "offline" playlist on YouTube and sync',
      );
    }

    return CustomScrollView(
      slivers: [
        // Pending downloads section
        if (pending.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Downloading (${pending.length})',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _buildDownloadItem(pending[index]),
              ),
              childCount: pending.length,
            ),
          ),
          if (videos.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Library (${videos.length})',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
        // Video grid
        if (videos.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.all(8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.75,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) =>
                    _buildVideoCard(videos[index], showProgress: true),
                childCount: videos.length,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildWatchedTab(SyncUiState syncState) {
    final watched = syncState.watchedVideos;

    if (watched.isEmpty) {
      return _buildEmptyState(
        icon: Icons.visibility_outlined,
        title: 'No watched videos',
        subtitle: 'Videos you finish watching will appear here',
      );
    }

    return _buildVideoGrid(watched, showProgress: true);
  }

  Widget _buildDeletedTab(SyncUiState syncState) {
    final deleted = syncState.deletedVideos;

    if (deleted.isEmpty) {
      return _buildEmptyState(
        icon: Icons.delete_outline,
        title: 'No deleted videos',
        subtitle: 'Videos you delete will appear here',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: deleted.length,
      itemBuilder: (context, index) {
        final video = deleted[index];
        return _buildDeletedItem(video);
      },
    );
  }

  Widget _buildDeletedItem(Video video) {
    final deletedAgo = video.deletedAt != null
        ? _formatTimeAgo(video.deletedAt!)
        : 'Unknown';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Stack(
            children: [
              CachedNetworkImage(
                imageUrl: video.thumbnailUrl,
                width: 80,
                height: 45,
                fit: BoxFit.cover,
              ),
              Container(
                width: 80,
                height: 45,
                color: Colors.black38,
                child: const Icon(
                  Icons.delete,
                  color: Colors.white54,
                  size: 24,
                ),
              ),
            ],
          ),
        ),
        title: Text(
          video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.grey),
        ),
        subtitle: Text('Deleted $deletedAgo'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Restore button
            IconButton(
              icon: const Icon(Icons.restore, color: Colors.green),
              tooltip: 'Restore and download',
              onPressed: () => _restoreVideo(video),
            ),
            // Permanently delete button
            IconButton(
              icon: const Icon(Icons.delete_forever, color: Colors.red),
              tooltip: 'Delete permanently',
              onPressed: () => _confirmPermanentDelete(video),
            ),
          ],
        ),
      ),
    );
  }

  void _showVideoOptions(Video video) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CachedNetworkImage(
                  imageUrl: video.thumbnailUrl,
                  width: 60,
                  height: 34,
                  fit: BoxFit.cover,
                ),
              ),
              title: Text(
                video.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(video.channelName),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.check_box_outlined),
              title: const Text('Select'),
              onTap: () {
                Navigator.pop(context);
                _enterSelectionMode(video);
              },
            ),
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('Play'),
              onTap: () {
                Navigator.pop(context);
                _playVideo(video);
              },
            ),
            if (!video.watched)
              ListTile(
                leading: const Icon(Icons.visibility),
                title: const Text('Mark as watched'),
                onTap: () {
                  Navigator.pop(context);
                  ref.read(syncProvider.notifier).markAsWatched(video);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text(
                'Delete video',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(video);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(Video video) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete video?'),
        content: Text(
          'Delete "${video.title}"?\n\nThe video file will be deleted but you can restore it later from the Deleted tab.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(syncProvider.notifier).deleteVideo(video);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Video deleted'),
                  action: SnackBarAction(
                    label: 'Undo',
                    onPressed: () =>
                        ref.read(syncProvider.notifier).restoreVideo(video),
                  ),
                ),
              );
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _restoreVideo(Video video) {
    ref.read(syncProvider.notifier).restoreVideo(video);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Video restored, downloading...')),
    );
  }

  void _confirmPermanentDelete(Video video) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: Text(
          'Permanently delete "${video.title}"?\n\nThis cannot be undone. The video will be downloaded again on next sync if it\'s still in your playlist.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(syncProvider.notifier).permanentlyDeleteVideo(video);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
  }

  String _formatTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'just now';
    }
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 80, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoGrid(List<Video> videos, {bool showProgress = false}) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 16 / 12,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: videos.length,
      itemBuilder: (context, index) {
        return _buildVideoCard(videos[index], showProgress: showProgress);
      },
    );
  }

  Widget _buildVideoCard(Video video, {bool showProgress = false}) {
    final isSelected = _selectedVideoIds.contains(video.videoId);

    return GestureDetector(
      onTap: () {
        if (_isSelectionMode) {
          _toggleVideoSelection(video);
        } else {
          _playVideo(video);
        }
      },
      onLongPress: () {
        if (_isSelectionMode) {
          // Already in selection mode, do nothing special
        } else {
          // Show options menu on long press
          _showVideoOptions(video);
        }
      },
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Thumbnail
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedNetworkImage(
                        imageUrl: video.thumbnailUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(
                          color: Colors.grey[300],
                          child: const Center(
                            child: CircularProgressIndicator(),
                          ),
                        ),
                        errorWidget: (_, __, ___) => Container(
                          color: Colors.grey[300],
                          child: const Icon(Icons.error),
                        ),
                      ),
                      // Duration badge
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _formatDuration(video.totalDurationSeconds),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      // Watched badge
                      if (video.watched && !_isSelectionMode)
                        Positioned(
                          left: 4,
                          top: 4,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.green,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Icon(
                              Icons.check,
                              color: Colors.white,
                              size: 16,
                            ),
                          ),
                        ),
                      // Progress bar
                      if (showProgress && video.watchProgress > 0)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            value: video.watchProgress,
                            backgroundColor: Colors.black54,
                            valueColor: AlwaysStoppedAnimation(
                              Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // Info
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        video.channelName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // Selection overlay
            if (_isSelectionMode)
              Positioned(
                left: 8,
                top: 8,
                child: Container(
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                      width: 2,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      Icons.check,
                      size: 18,
                      color: isSelected ? Colors.white : Colors.transparent,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadItem(Video video) {
    final isWaitingForServer =
        video.downloadStatus == DownloadStatus.downloading &&
        video.downloadProgress < 0.1;
    final isFailed = video.downloadStatus == DownloadStatus.failed;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: isFailed ? Colors.red.shade50 : null,
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Stack(
            children: [
              CachedNetworkImage(
                imageUrl: video.thumbnailUrl,
                width: 80,
                height: 45,
                fit: BoxFit.cover,
              ),
              if (isFailed)
                Container(
                  width: 80,
                  height: 45,
                  color: Colors.red.withOpacity(0.3),
                  child: const Icon(Icons.error, color: Colors.white, size: 24),
                ),
            ],
          ),
        ),
        title: Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(video.channelName),
            const SizedBox(height: 4),
            if (video.downloadStatus == DownloadStatus.downloading) ...[
              if (isWaitingForServer)
                Row(
                  children: const [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Servidor a descarregar...',
                        style: TextStyle(fontSize: 12, color: Colors.orange),
                      ),
                    ),
                  ],
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(
                      value:
                          (video.downloadProgress - 0.1) /
                          0.9, // Normalize transfer progress
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'A transferir: ${((video.downloadProgress - 0.1) / 0.9 * 100).toInt()}%',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
            ] else if (video.downloadStatus == DownloadStatus.pending)
              const Text(
                'Aguardando...',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              )
            else if (isFailed)
              const Text(
                'Falhou - toca para tentar novamente',
                style: TextStyle(fontSize: 12, color: Colors.red),
              ),
          ],
        ),
        trailing: _buildDownloadStatusIcon(video),
        onTap: isFailed
            ? () => ref.read(syncProvider.notifier).downloadVideo(video)
            : null,
      ),
    );
  }

  Widget _buildDownloadStatusIcon(Video video) {
    switch (video.downloadStatus) {
      case DownloadStatus.pending:
        return const Icon(Icons.hourglass_empty, color: Colors.orange);
      case DownloadStatus.downloading:
        return Text('${(video.downloadProgress * 100).toInt()}%');
      case DownloadStatus.completed:
        return const Icon(Icons.check_circle, color: Colors.green);
      case DownloadStatus.failed:
        return IconButton(
          icon: const Icon(Icons.refresh, color: Colors.red),
          onPressed: () => ref.read(syncProvider.notifier).downloadVideo(video),
        );
    }
  }

  void _playVideo(Video video) {
    if (video.downloadStatus != DownloadStatus.completed ||
        video.filePath == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Video not downloaded yet')));
      return;
    }

    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => PlayerScreen(video: video)));
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }
}
