import 'package:hive/hive.dart';

part 'playlist.g.dart';

@HiveType(typeId: 2)
class Playlist extends HiveObject {
  @HiveField(0)
  final String playlistId;

  @HiveField(1)
  final String title;

  @HiveField(2)
  final String? thumbnailUrl;

  @HiveField(3)
  final int itemCount;

  @HiveField(4)
  DateTime? lastSyncedAt;

  @HiveField(5)
  String? nextPageToken;

  @HiveField(6)
  final bool isOfflinePlaylist;

  Playlist({
    required this.playlistId,
    required this.title,
    this.thumbnailUrl,
    required this.itemCount,
    this.lastSyncedAt,
    this.nextPageToken,
    this.isOfflinePlaylist = false,
  });

  /// Check if this is the "offline" playlist by name
  static bool isOfflinePlaylistByName(String title) {
    return title.toLowerCase().trim() == 'offline';
  }

  Playlist copyWith({
    String? playlistId,
    String? title,
    String? thumbnailUrl,
    int? itemCount,
    DateTime? lastSyncedAt,
    String? nextPageToken,
    bool? isOfflinePlaylist,
  }) {
    return Playlist(
      playlistId: playlistId ?? this.playlistId,
      title: title ?? this.title,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      itemCount: itemCount ?? this.itemCount,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      nextPageToken: nextPageToken ?? this.nextPageToken,
      isOfflinePlaylist: isOfflinePlaylist ?? this.isOfflinePlaylist,
    );
  }

  @override
  String toString() {
    return 'Playlist(id: $playlistId, title: $title, items: $itemCount, isOffline: $isOfflinePlaylist)';
  }
}
