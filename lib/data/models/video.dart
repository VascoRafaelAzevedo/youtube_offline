import 'package:hive/hive.dart';

part 'video.g.dart';

@HiveType(typeId: 0)
enum DownloadStatus {
  @HiveField(0)
  pending,
  @HiveField(1)
  downloading,
  @HiveField(2)
  completed,
  @HiveField(3)
  failed,
}

@HiveType(typeId: 1)
class Video extends HiveObject {
  @HiveField(0)
  final String videoId;

  @HiveField(1)
  final String title;

  @HiveField(2)
  final String? description;

  @HiveField(3)
  final String thumbnailUrl;

  @HiveField(4)
  String? filePath;

  @HiveField(5)
  DownloadStatus downloadStatus;

  @HiveField(6)
  bool watched;

  @HiveField(7)
  int lastPositionSeconds;

  @HiveField(8)
  final int totalDurationSeconds;

  @HiveField(9)
  final DateTime addedToPlaylistAt;

  @HiveField(10)
  DateTime? downloadedAt;

  @HiveField(11)
  double downloadProgress;

  @HiveField(12)
  final String channelName;

  @HiveField(13)
  bool isDeleted;

  @HiveField(14)
  DateTime? deletedAt;

  Video({
    required this.videoId,
    required this.title,
    this.description,
    required this.thumbnailUrl,
    this.filePath,
    this.downloadStatus = DownloadStatus.pending,
    this.watched = false,
    this.lastPositionSeconds = 0,
    required this.totalDurationSeconds,
    required this.addedToPlaylistAt,
    this.downloadedAt,
    this.downloadProgress = 0.0,
    required this.channelName,
    this.isDeleted = false,
    this.deletedAt,
  });

  /// Check if video should be considered as "resume from position"
  bool get hasResumePosition => lastPositionSeconds > 0 && !watched;

  /// Progress percentage (0.0 to 1.0)
  double get watchProgress {
    if (totalDurationSeconds == 0) return 0.0;
    return lastPositionSeconds / totalDurationSeconds;
  }

  /// Update watch position and auto-mark as watched if >= 70%
  void updateWatchPosition(int positionSeconds) {
    lastPositionSeconds = positionSeconds;

    final progress = positionSeconds / totalDurationSeconds;

    // Mark as watched if >= 70%
    if (progress >= 0.70) {
      watched = true;
    }

    // Reset position if >= 95% (video finished)
    if (progress >= 0.95) {
      lastPositionSeconds = 0;
    }

    save();
  }

  /// Copy with new values
  Video copyWith({
    String? videoId,
    String? title,
    String? description,
    String? thumbnailUrl,
    String? filePath,
    DownloadStatus? downloadStatus,
    bool? watched,
    int? lastPositionSeconds,
    int? totalDurationSeconds,
    DateTime? addedToPlaylistAt,
    DateTime? downloadedAt,
    double? downloadProgress,
    String? channelName,
    bool? isDeleted,
    DateTime? deletedAt,
  }) {
    return Video(
      videoId: videoId ?? this.videoId,
      title: title ?? this.title,
      description: description ?? this.description,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      filePath: filePath ?? this.filePath,
      downloadStatus: downloadStatus ?? this.downloadStatus,
      watched: watched ?? this.watched,
      lastPositionSeconds: lastPositionSeconds ?? this.lastPositionSeconds,
      totalDurationSeconds: totalDurationSeconds ?? this.totalDurationSeconds,
      addedToPlaylistAt: addedToPlaylistAt ?? this.addedToPlaylistAt,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      channelName: channelName ?? this.channelName,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  @override
  String toString() {
    return 'Video(videoId: $videoId, title: $title, status: $downloadStatus, watched: $watched)';
  }
}
