import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../core/services/sync_service.dart';
import 'service_providers.dart';

/// Sync state for UI
class SyncUiState {
  final bool isLoading;
  final bool isSyncing;
  final List<Video> videos;
  final SyncState? syncState;
  final String? statusMessage;
  final String? error;

  const SyncUiState({
    this.isLoading = false,
    this.isSyncing = false,
    this.videos = const [],
    this.syncState,
    this.statusMessage,
    this.error,
  });

  /// Videos that are downloaded and ready to watch (excludes deleted and watched)
  List<Video> get downloadedVideos => videos
      .where(
        (v) =>
            v.downloadStatus == DownloadStatus.completed &&
            !v.isDeleted &&
            !v.watched,
      )
      .toList();

  /// Videos pending download (includes failed, excludes deleted)
  List<Video> get pendingVideos => videos
      .where(
        (v) =>
            (v.downloadStatus == DownloadStatus.pending ||
                v.downloadStatus == DownloadStatus.downloading ||
                v.downloadStatus == DownloadStatus.failed) &&
            !v.isDeleted,
      )
      .toList();

  /// Unwatched videos (excludes deleted)
  List<Video> get unwatchedVideos =>
      videos.where((v) => !v.watched && !v.isDeleted).toList();

  /// Videos with resume position (excludes deleted)
  List<Video> get resumableVideos =>
      videos.where((v) => v.hasResumePosition && !v.isDeleted).toList();

  /// Watched videos (excludes deleted)
  List<Video> get watchedVideos => videos
      .where(
        (v) =>
            v.watched &&
            v.downloadStatus == DownloadStatus.completed &&
            !v.isDeleted,
      )
      .toList();

  /// Deleted videos
  List<Video> get deletedVideos => videos.where((v) => v.isDeleted).toList()
    ..sort(
      (a, b) =>
          (b.deletedAt ?? DateTime(0)).compareTo(a.deletedAt ?? DateTime(0)),
    );

  SyncUiState copyWith({
    bool? isLoading,
    bool? isSyncing,
    List<Video>? videos,
    SyncState? syncState,
    String? statusMessage,
    String? error,
  }) {
    return SyncUiState(
      isLoading: isLoading ?? this.isLoading,
      isSyncing: isSyncing ?? this.isSyncing,
      videos: videos ?? this.videos,
      syncState: syncState ?? this.syncState,
      statusMessage: statusMessage,
      error: error,
    );
  }
}

/// Sync state notifier
class SyncNotifier extends StateNotifier<SyncUiState> {
  final Ref _ref;
  bool _initialized = false;

  SyncNotifier(this._ref) : super(const SyncUiState());

  /// Initialize and load local videos
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    state = state.copyWith(isLoading: true);

    try {
      final syncService = _ref.read(syncServiceProvider);
      await syncService.initialize();

      _loadVideos();
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Load videos from local storage
  void _loadVideos() {
    final syncService = _ref.read(syncServiceProvider);
    final videos = syncService.localVideos;

    // Sort by added date (newest first)
    videos.sort((a, b) => b.addedToPlaylistAt.compareTo(a.addedToPlaylistAt));

    state = state.copyWith(
      isLoading: false,
      videos: videos,
      syncState: syncService.syncState,
    );
  }

  /// Sync with YouTube
  Future<SyncResult> sync() async {
    state = state.copyWith(isSyncing: true, statusMessage: 'Starting sync...');

    try {
      final syncService = _ref.read(syncServiceProvider);

      final result = await syncService.syncWithYouTube(
        autoDownload: true,
        onStatusUpdate: (message) {
          state = state.copyWith(statusMessage: message);
        },
      );

      _loadVideos();

      state = state.copyWith(
        isSyncing: false,
        statusMessage: result.success
            ? 'Sync complete! ${result.newVideos} new videos'
            : 'Sync failed',
        error: result.error,
      );

      return result;
    } catch (e) {
      state = state.copyWith(
        isSyncing: false,
        statusMessage: null,
        error: e.toString(),
      );
      return SyncResult(success: false, error: e.toString());
    }
  }

  /// Download a specific video
  Future<void> downloadVideo(Video video) async {
    try {
      final syncService = _ref.read(syncServiceProvider);
      await syncService.downloadVideo(video);
      _loadVideos();
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Update video watch position
  Future<void> updateWatchPosition(Video video, int positionSeconds) async {
    try {
      final syncService = _ref.read(syncServiceProvider);
      await syncService.updateWatchPosition(video, positionSeconds);
      _loadVideos();
    } catch (e) {
      print('Failed to update watch position: $e');
    }
  }

  /// Mark video as watched
  Future<void> markAsWatched(Video video) async {
    try {
      final syncService = _ref.read(syncServiceProvider);
      await syncService.markAsWatched(video);
      _loadVideos();
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Mark video as unwatched
  Future<void> markAsUnwatched(Video video) async {
    try {
      final syncService = _ref.read(syncServiceProvider);
      await syncService.markAsUnwatched(video);
      _loadVideos();
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Delete a video (soft delete - keeps in database but marks as deleted)
  Future<void> deleteVideo(Video video) async {
    try {
      final syncService = _ref.read(syncServiceProvider);
      await syncService.deleteVideo(video);
      _loadVideos();
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Restore a deleted video (will trigger re-download)
  Future<void> restoreVideo(Video video) async {
    try {
      final syncService = _ref.read(syncServiceProvider);
      await syncService.restoreVideo(video);
      _loadVideos();
      // Start downloading immediately
      await downloadVideo(video);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Permanently delete a video (remove from database completely)
  Future<void> permanentlyDeleteVideo(Video video) async {
    try {
      final syncService = _ref.read(syncServiceProvider);
      await syncService.permanentlyDeleteVideo(video);
      _loadVideos();
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Get video by ID
  Video? getVideo(String videoId) {
    return state.videos.where((v) => v.videoId == videoId).firstOrNull;
  }

  /// Refresh videos from local storage
  void refresh() {
    _loadVideos();
  }

  /// Clear status message
  void clearStatus() {
    state = state.copyWith(statusMessage: null, error: null);
  }
}

/// Sync provider
final syncProvider = StateNotifierProvider<SyncNotifier, SyncUiState>((ref) {
  return SyncNotifier(ref);
});

/// Selected video for playback
final selectedVideoProvider = StateProvider<Video?>((ref) => null);
