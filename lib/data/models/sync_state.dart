import 'package:hive/hive.dart';

part 'sync_state.g.dart';

@HiveType(typeId: 3)
class SyncState extends HiveObject {
  @HiveField(0)
  DateTime? lastFullSyncAt;

  @HiveField(1)
  bool isSyncing;

  @HiveField(2)
  String? lastError;

  @HiveField(3)
  int totalVideosInPlaylist;

  @HiveField(4)
  int downloadedVideosCount;

  @HiveField(5)
  int watchedVideosCount;

  @HiveField(6)
  String? offlinePlaylistId;

  SyncState({
    this.lastFullSyncAt,
    this.isSyncing = false,
    this.lastError,
    this.totalVideosInPlaylist = 0,
    this.downloadedVideosCount = 0,
    this.watchedVideosCount = 0,
    this.offlinePlaylistId,
  });

  /// Time since last sync
  Duration? get timeSinceLastSync {
    if (lastFullSyncAt == null) return null;
    return DateTime.now().difference(lastFullSyncAt!);
  }

  /// Check if sync is needed (more than 1 hour since last sync)
  bool get needsSync {
    if (lastFullSyncAt == null) return true;
    return timeSinceLastSync!.inHours >= 1;
  }

  void startSync() {
    isSyncing = true;
    lastError = null;
    save();
  }

  void completeSync({
    required int totalVideos,
    required int downloaded,
    required int watched,
  }) {
    isSyncing = false;
    lastFullSyncAt = DateTime.now();
    totalVideosInPlaylist = totalVideos;
    downloadedVideosCount = downloaded;
    watchedVideosCount = watched;
    lastError = null;
    save();
  }

  void failSync(String error) {
    isSyncing = false;
    lastError = error;
    save();
  }

  @override
  String toString() {
    return 'SyncState(lastSync: $lastFullSyncAt, syncing: $isSyncing, total: $totalVideosInPlaylist)';
  }
}
