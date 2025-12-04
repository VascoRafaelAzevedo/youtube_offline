import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../data/models/models.dart';
import 'youtube_api_service.dart';
import 'download_service.dart';

/// Service for syncing videos from YouTube to local storage
class SyncService {
  final YouTubeApiService _youtubeApi;
  final DownloadService _downloadService;

  late Box<Video> _videosBox;
  late Box<SyncState> _syncBox;

  SyncService(this._youtubeApi, this._downloadService);

  /// Initialize boxes
  Future<void> initialize() async {
    _videosBox = Hive.box<Video>('videos');
    _syncBox = Hive.box<SyncState>('sync_state');
  }

  /// Get or create sync state
  SyncState get syncState {
    if (_syncBox.isEmpty) {
      final state = SyncState();
      _syncBox.put('state', state);
      return state;
    }
    return _syncBox.get('state')!;
  }

  /// Get all local videos
  List<Video> get localVideos => _videosBox.values.toList();

  /// Get videos by status
  List<Video> getVideosByStatus(DownloadStatus status) {
    return localVideos.where((v) => v.downloadStatus == status).toList();
  }

  /// Get unwatched videos
  List<Video> get unwatchedVideos {
    return localVideos.where((v) => !v.watched).toList();
  }

  /// Get videos pending download (excludes deleted)
  List<Video> get pendingDownloads {
    return localVideos
        .where(
          (v) =>
              v.downloadStatus == DownloadStatus.pending ||
              v.downloadStatus == DownloadStatus.failed,
        )
        .where((v) => !v.watched && !v.isDeleted)
        .toList();
  }

  /// Get deleted videos
  List<Video> get deletedVideos {
    return localVideos.where((v) => v.isDeleted).toList()..sort(
      (a, b) =>
          (b.deletedAt ?? DateTime(0)).compareTo(a.deletedAt ?? DateTime(0)),
    );
  }

  /// Sync with YouTube API
  ///
  /// This will:
  /// 1. Fetch all videos from the "offline" playlist
  /// 2. Add new videos to local storage
  /// 3. Reset failed videos to pending so they can be retried
  /// 4. Start downloading all pending videos
  Future<SyncResult> syncWithYouTube({
    bool autoDownload = true,
    void Function(String message)? onStatusUpdate,
  }) async {
    final state = syncState;
    state.startSync();

    try {
      onStatusUpdate?.call('Finding "offline" playlist...');

      // Find the "offline" playlist
      final offlinePlaylist = await _youtubeApi.findOfflinePlaylist();
      if (offlinePlaylist == null) {
        throw Exception('Playlist "offline" not found');
      }

      state.offlinePlaylistId = offlinePlaylist.playlistId;

      onStatusUpdate?.call('Fetching videos from playlist...');

      // Fetch videos from playlist
      final remoteVideos = await _youtubeApi.fetchPlaylistVideos(
        offlinePlaylist.playlistId,
      );

      onStatusUpdate?.call('Syncing ${remoteVideos.length} videos...');

      // Get existing videos map and deleted IDs
      final existingVideosMap = {for (var v in localVideos) v.videoId: v};
      final deletedIds = deletedVideos.map((v) => v.videoId).toSet();

      var newCount = 0;
      var resetCount = 0;

      // Process each remote video
      for (final remoteVideo in remoteVideos) {
        final videoId = remoteVideo.videoId;

        // Skip deleted videos
        if (deletedIds.contains(videoId)) {
          continue;
        }

        final existingVideo = existingVideosMap[videoId];

        if (existingVideo == null) {
          // New video - add it
          await _videosBox.put(videoId, remoteVideo);
          newCount++;
          print(
            'SyncService: Added new video: $videoId - ${remoteVideo.title}',
          );
        } else {
          // Existing video - check if it needs to be retried
          if (existingVideo.downloadStatus == DownloadStatus.failed) {
            // Reset failed videos to pending
            existingVideo.downloadStatus = DownloadStatus.pending;
            existingVideo.downloadProgress = 0.0;
            await existingVideo.save();
            resetCount++;
            print('SyncService: Reset failed video to pending: $videoId');
          } else if (existingVideo.downloadStatus ==
              DownloadStatus.downloading) {
            // Reset stuck downloading videos to pending
            existingVideo.downloadStatus = DownloadStatus.pending;
            existingVideo.downloadProgress = 0.0;
            await existingVideo.save();
            resetCount++;
            print(
              'SyncService: Reset stuck downloading video to pending: $videoId',
            );
          }
          // Completed and pending videos are left as-is
        }
      }

      // Update sync state
      state.completeSync(
        totalVideos: remoteVideos.length,
        downloaded: getVideosByStatus(DownloadStatus.completed).length,
        watched: localVideos.where((v) => v.watched).length,
      );

      // Get current pending count after processing
      final currentPending = pendingDownloads;

      final result = SyncResult(
        success: true,
        totalVideos: remoteVideos.length,
        newVideos: newCount,
        pendingDownloads: currentPending.length,
      );

      print(
        'SyncService: Sync complete - New: $newCount, Reset: $resetCount, Pending: ${currentPending.length}',
      );

      // Auto-download pending videos if enabled
      if (autoDownload && currentPending.isNotEmpty) {
        onStatusUpdate?.call(
          'Starting downloads for ${currentPending.length} videos...',
        );
        // Don't await - let downloads happen in background
        _downloadPendingVideos(onStatusUpdate: onStatusUpdate);
      }

      return result;
    } catch (e) {
      state.failSync(e.toString());
      return SyncResult(success: false, error: e.toString());
    }
  }

  /// Download all pending videos
  Future<void> _downloadPendingVideos({
    void Function(String message)? onStatusUpdate,
  }) async {
    // Check network settings
    final settingsBox = await Hive.openBox('settings');
    final wifiOnly = settingsBox.get('wifiOnly', defaultValue: true) as bool;

    final canDownloadResult = await _downloadService.canDownload(
      wifiOnly: wifiOnly,
    );
    if (!canDownloadResult.allowed) {
      print('SyncService: Download blocked - ${canDownloadResult.reason}');
      onStatusUpdate?.call(canDownloadResult.reason ?? 'Download bloqueado');
      return;
    }

    final pending = pendingDownloads;
    print('SyncService: Starting download of ${pending.length} pending videos');

    for (var i = 0; i < pending.length; i++) {
      final video = pending[i];
      print('SyncService: ----------------------------------------');
      print('SyncService: Downloading video ${i + 1}/${pending.length}');
      print('SyncService: ID: ${video.videoId}');
      print('SyncService: Title: ${video.title}');
      print('SyncService: ----------------------------------------');

      onStatusUpdate?.call(
        'Downloading (${i + 1}/${pending.length}): ${video.title}',
      );

      video.downloadStatus = DownloadStatus.downloading;
      video.downloadProgress = 0.0;
      await video.save();

      try {
        final filePath = await _downloadService.downloadVideo(
          video,
          onProgress: (videoId, progress, status) async {
            video.downloadProgress = progress;
            video.downloadStatus = status;
            // Save synchronously to avoid race conditions
            await video.save();
          },
        );

        if (filePath != null) {
          print('SyncService: SUCCESS - Video downloaded to: $filePath');
          video.filePath = filePath;
          video.downloadStatus = DownloadStatus.completed;
          video.downloadedAt = DateTime.now();
        } else {
          print('SyncService: FAILED - Video download returned null');
          video.downloadStatus = DownloadStatus.failed;
        }
      } catch (e, stack) {
        print('SyncService: ERROR - Exception during download: $e');
        print('SyncService: Stack: $stack');
        video.downloadStatus = DownloadStatus.failed;
      }

      await video.save();
      print('SyncService: Video saved with status: ${video.downloadStatus}');
    }

    // Update sync state counts
    final state = syncState;
    state.completeSync(
      totalVideos: state.totalVideosInPlaylist,
      downloaded: getVideosByStatus(DownloadStatus.completed).length,
      watched: localVideos.where((v) => v.watched).length,
    );

    print('SyncService: All downloads completed');
    print(
      'SyncService: Completed: ${getVideosByStatus(DownloadStatus.completed).length}',
    );
    print(
      'SyncService: Failed: ${getVideosByStatus(DownloadStatus.failed).length}',
    );
  }

  /// Download a single video
  Future<bool> downloadVideo(Video video) async {
    print('SyncService: Starting single video download: ${video.videoId}');

    // Check network settings
    final settingsBox = await Hive.openBox('settings');
    final wifiOnly = settingsBox.get('wifiOnly', defaultValue: true) as bool;

    final canDownloadResult = await _downloadService.canDownload(
      wifiOnly: wifiOnly,
    );
    if (!canDownloadResult.allowed) {
      print('SyncService: Download blocked - ${canDownloadResult.reason}');
      return false;
    }

    video.downloadStatus = DownloadStatus.downloading;
    video.downloadProgress = 0.0;
    await video.save();

    try {
      final filePath = await _downloadService.downloadVideo(
        video,
        onProgress: (videoId, progress, status) async {
          video.downloadProgress = progress;
          video.downloadStatus = status;
          await video.save();
        },
      );

      if (filePath != null) {
        print('SyncService: Single download SUCCESS: $filePath');
        video.filePath = filePath;
        video.downloadStatus = DownloadStatus.completed;
        video.downloadedAt = DateTime.now();
        await video.save();
        return true;
      } else {
        print('SyncService: Single download FAILED: returned null');
        video.downloadStatus = DownloadStatus.failed;
        await video.save();
        return false;
      }
    } catch (e, stack) {
      print('SyncService: Single download ERROR: $e');
      print('SyncService: Stack: $stack');
      video.downloadStatus = DownloadStatus.failed;
      await video.save();
      return false;
    }
  }

  /// Mark video as watched
  Future<void> markAsWatched(Video video) async {
    video.watched = true;
    video.lastPositionSeconds = 0;
    await video.save();
  }

  /// Mark video as unwatched
  Future<void> markAsUnwatched(Video video) async {
    video.watched = false;
    await video.save();
  }

  /// Update video watch position
  Future<void> updateWatchPosition(Video video, int positionSeconds) async {
    video.updateWatchPosition(positionSeconds);
  }

  /// Get video by ID
  Video? getVideo(String videoId) {
    return _videosBox.get(videoId);
  }

  /// Soft delete video (keeps record but marks as deleted)
  Future<void> deleteVideo(Video video) async {
    // Delete the actual file
    if (video.filePath != null) {
      await _downloadService.deleteVideo(video.filePath!);
    }

    // Mark as deleted (soft delete)
    video.isDeleted = true;
    video.deletedAt = DateTime.now();
    video.filePath = null;
    video.downloadStatus = DownloadStatus.pending;
    video.downloadProgress = 0.0;
    await video.save();
  }

  /// Restore a deleted video (will re-download)
  Future<void> restoreVideo(Video video) async {
    video.isDeleted = false;
    video.deletedAt = null;
    video.downloadStatus = DownloadStatus.pending;
    await video.save();
  }

  /// Permanently delete video (remove from database)
  Future<void> permanentlyDeleteVideo(Video video) async {
    if (video.filePath != null) {
      await _downloadService.deleteVideo(video.filePath!);
    }
    await _videosBox.delete(video.videoId);
  }
}

/// Result of a sync operation
class SyncResult {
  final bool success;
  final int totalVideos;
  final int newVideos;
  final int pendingDownloads;
  final String? error;

  SyncResult({
    required this.success,
    this.totalVideos = 0,
    this.newVideos = 0,
    this.pendingDownloads = 0,
    this.error,
  });

  @override
  String toString() {
    if (!success) return 'SyncResult(failed: $error)';
    return 'SyncResult(total: $totalVideos, new: $newVideos, pending: $pendingDownloads)';
  }
}
