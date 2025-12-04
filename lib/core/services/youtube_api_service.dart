import 'package:googleapis/youtube/v3.dart' as yt;

import '../../data/models/models.dart';
import 'auth_service.dart';

/// Service for interacting with YouTube Data API v3
class YouTubeApiService {
  final AuthService _authService;

  yt.YouTubeApi? _youtubeApi;

  YouTubeApiService(this._authService);

  /// Initialize YouTube API client
  Future<bool> _ensureApiClient() async {
    if (_youtubeApi != null) return true;

    final client = await _authService.getAuthClient();
    if (client == null) return false;

    _youtubeApi = yt.YouTubeApi(client);
    return true;
  }

  /// Fetch all playlists for the authenticated user
  Future<List<Playlist>> fetchUserPlaylists() async {
    if (!await _ensureApiClient()) {
      throw Exception('Not authenticated');
    }

    final List<Playlist> playlists = [];
    String? pageToken;

    do {
      final response = await _youtubeApi!.playlists.list(
        ['snippet', 'contentDetails'],
        mine: true,
        maxResults: 50,
        pageToken: pageToken,
      );

      if (response.items != null) {
        for (final item in response.items!) {
          final playlist = Playlist(
            playlistId: item.id!,
            title: item.snippet?.title ?? 'Unknown',
            thumbnailUrl:
                item.snippet?.thumbnails?.medium?.url ??
                item.snippet?.thumbnails?.default_?.url,
            itemCount: item.contentDetails?.itemCount ?? 0,
            isOfflinePlaylist: Playlist.isOfflinePlaylistByName(
              item.snippet?.title ?? '',
            ),
          );
          playlists.add(playlist);
        }
      }

      pageToken = response.nextPageToken;
    } while (pageToken != null);

    return playlists;
  }

  /// Find the "offline" playlist
  Future<Playlist?> findOfflinePlaylist() async {
    final playlists = await fetchUserPlaylists();
    return playlists.where((p) => p.isOfflinePlaylist).firstOrNull;
  }

  /// Fetch all videos in a playlist
  Future<List<Video>> fetchPlaylistVideos(String playlistId) async {
    if (!await _ensureApiClient()) {
      throw Exception('Not authenticated');
    }

    final List<Video> videos = [];
    String? pageToken;

    do {
      final response = await _youtubeApi!.playlistItems.list(
        ['snippet', 'contentDetails'],
        playlistId: playlistId,
        maxResults: 50,
        pageToken: pageToken,
      );

      if (response.items != null) {
        // Collect video IDs for batch details fetch
        final videoIds = response.items!
            .where((item) => item.contentDetails?.videoId != null)
            .map((item) => item.contentDetails!.videoId!)
            .toList();

        // Fetch video details (duration, etc.) in batch
        final videoDetails = await _fetchVideoDetails(videoIds);

        for (final item in response.items!) {
          final videoId = item.contentDetails?.videoId;
          if (videoId == null) continue;

          final details = videoDetails[videoId];
          final duration = _parseDuration(details?.contentDetails?.duration);

          final video = Video(
            videoId: videoId,
            title: item.snippet?.title ?? 'Unknown',
            description: item.snippet?.description,
            thumbnailUrl:
                item.snippet?.thumbnails?.medium?.url ??
                item.snippet?.thumbnails?.default_?.url ??
                '',
            channelName: item.snippet?.channelTitle ?? 'Unknown',
            totalDurationSeconds: duration,
            addedToPlaylistAt: item.snippet?.publishedAt ?? DateTime.now(),
          );
          videos.add(video);
        }
      }

      pageToken = response.nextPageToken;
    } while (pageToken != null);

    return videos;
  }

  /// Fetch video details for multiple videos (batch request)
  Future<Map<String, yt.Video>> _fetchVideoDetails(
    List<String> videoIds,
  ) async {
    if (videoIds.isEmpty) return {};

    final Map<String, yt.Video> details = {};

    // YouTube API allows max 50 IDs per request
    for (var i = 0; i < videoIds.length; i += 50) {
      final batch = videoIds.skip(i).take(50).toList();
      final response = await _youtubeApi!.videos.list([
        'contentDetails',
        'snippet',
      ], id: batch);

      if (response.items != null) {
        for (final video in response.items!) {
          if (video.id != null) {
            details[video.id!] = video;
          }
        }
      }
    }

    return details;
  }

  /// Parse ISO 8601 duration (e.g., "PT4M13S") to seconds
  int _parseDuration(String? isoDuration) {
    if (isoDuration == null) return 0;

    final regex = RegExp(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?');
    final match = regex.firstMatch(isoDuration);

    if (match == null) return 0;

    final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
    final minutes = int.tryParse(match.group(2) ?? '0') ?? 0;
    final seconds = int.tryParse(match.group(3) ?? '0') ?? 0;

    return hours * 3600 + minutes * 60 + seconds;
  }

  /// Clear cached API client (e.g., on logout)
  void clearCache() {
    _youtubeApi = null;
  }
}
