import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../../data/models/models.dart';

/// Callback for download progress updates
typedef DownloadProgressCallback =
    void Function(String videoId, double progress, DownloadStatus status);

/// Callback for download status message updates
typedef DownloadStatusCallback = void Function(String videoId, String message);

/// Video quality options for download
enum VideoQuality {
  max, // Best available (4K if available)
  hd1080, // Up to 1080p
  hd720, // Up to 720p
  sd360, // Up to 360p (small files)
}

extension VideoQualityExtension on VideoQuality {
  String get apiValue {
    switch (this) {
      case VideoQuality.max:
        return 'max';
      case VideoQuality.hd1080:
        return '1080';
      case VideoQuality.hd720:
        return '720';
      case VideoQuality.sd360:
        return '360';
    }
  }

  String get displayName {
    switch (this) {
      case VideoQuality.max:
        return 'Máxima';
      case VideoQuality.hd1080:
        return '1080p';
      case VideoQuality.hd720:
        return '720p';
      case VideoQuality.sd360:
        return '360p';
    }
  }
}

/// Configuration for the download server
class DownloadServerConfig {
  /// Server URL (e.g., "http://192.168.1.100:8765")
  final String serverUrl;

  /// API key for authentication
  final String apiKey;

  /// Default quality for downloads
  final VideoQuality defaultQuality;

  const DownloadServerConfig({
    required this.serverUrl,
    required this.apiKey,
    this.defaultQuality = VideoQuality.hd1080,
  });

  /// Create from environment or defaults
  /// TODO: Make this configurable in app settings
  factory DownloadServerConfig.defaults() {
    return const DownloadServerConfig(
      // CHANGE THIS to your server's IP address
      serverUrl: 'http://192.168.0.13:8765',
      apiKey: 'offline_yt_secret_2025',
      defaultQuality: VideoQuality.hd1080,
    );
  }
}

/// Service for downloading YouTube videos via remote server
///
/// The server uses yt-dlp to download videos in high quality
/// and streams them back to the mobile app.
class DownloadService {
  /// Server configuration
  DownloadServerConfig _config;

  /// HTTP client for API requests
  final http.Client _httpClient = http.Client();

  /// Active downloads map (videoId -> cancelled)
  final Map<String, bool> _cancelledDownloads = {};

  DownloadService() : _config = DownloadServerConfig.defaults();

  /// Update server configuration
  void updateConfig(DownloadServerConfig config) {
    _config = config;
  }

  /// Get current server URL
  String get serverUrl => _config.serverUrl;

  /// Get current API key
  String get apiKey => _config.apiKey;

  /// Get default quality
  VideoQuality get defaultQuality => _config.defaultQuality;

  /// Get the downloads directory path
  Future<String> get _downloadsPath async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/OfflineYT');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// Check if we're connected via WiFi
  Future<bool> isOnWifi() async {
    final connectivity = await Connectivity().checkConnectivity();
    return connectivity.contains(ConnectivityResult.wifi);
  }

  /// Check if we're connected via mobile data
  Future<bool> isOnMobileData() async {
    final connectivity = await Connectivity().checkConnectivity();
    return connectivity.contains(ConnectivityResult.mobile);
  }

  /// Check if download is allowed based on connection type and settings
  Future<({bool allowed, String? reason})> canDownload({
    required bool wifiOnly,
  }) async {
    final connectivity = await Connectivity().checkConnectivity();

    final hasWifi = connectivity.contains(ConnectivityResult.wifi);
    final hasMobile = connectivity.contains(ConnectivityResult.mobile);
    final hasEthernet = connectivity.contains(ConnectivityResult.ethernet);

    // If on WiFi or Ethernet, always allow
    if (hasWifi || hasEthernet) {
      return (allowed: true, reason: null);
    }

    // If on mobile data
    if (hasMobile) {
      if (wifiOnly) {
        return (allowed: false, reason: 'Downloads só permitidos por WiFi');
      }
      return (allowed: true, reason: null);
    }

    // No connection
    return (allowed: false, reason: 'Sem conexão à internet');
  }

  /// Check if server is available
  Future<bool> isServerAvailable() async {
    try {
      final response = await _httpClient
          .get(Uri.parse('${_config.serverUrl}/health'))
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (e) {
      print('DownloadService: Server not available: $e');
      return false;
    }
  }

  /// Get download status from server
  Future<Map<String, dynamic>?> getServerStatus(String videoId) async {
    try {
      final response = await _httpClient
          .get(
            Uri.parse('${_config.serverUrl}/status?video_id=$videoId'),
            headers: {'X-API-Key': _config.apiKey},
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true && data['status'] is Map) {
          return Map<String, dynamic>.from(data['status']);
        }
      }
      return null;
    } catch (e) {
      print('DownloadService: Failed to get server status: $e');
      return null;
    }
  }

  /// Download a video from the server with real-time progress
  ///
  /// Progress is shown in two phases:
  /// 1. Server downloading from YouTube (0-50%)
  /// 2. Transferring to device (50-100%)
  Future<String?> downloadVideo(
    Video video, {
    DownloadProgressCallback? onProgress,
    VideoQuality? quality,
  }) async {
    final videoId = video.videoId;
    final selectedQuality = quality ?? _config.defaultQuality;
    _cancelledDownloads[videoId] = false;

    // Timer for polling server status
    Timer? statusTimer;

    try {
      print('DownloadService: ========================================');
      print('DownloadService: Starting download for $videoId');
      print('DownloadService: Title: ${video.title}');
      print('DownloadService: Quality: ${selectedQuality.displayName}');
      print('DownloadService: ========================================');
      onProgress?.call(videoId, 0.0, DownloadStatus.downloading);

      // Check server availability first (quick check)
      print('DownloadService: Checking server at ${_config.serverUrl}...');
      if (!await isServerAvailable()) {
        print(
          'DownloadService: ERROR - Server not available at ${_config.serverUrl}',
        );
        onProgress?.call(videoId, 0.0, DownloadStatus.failed);
        return null;
      }
      print('DownloadService: Server is available!');

      final downloadsDir = await _downloadsPath;
      final safeTitle = _sanitizeFileName(video.title);
      final outputPath = '$downloadsDir/$safeTitle.mp4';
      print('DownloadService: Output path: $outputPath');

      // Check if already downloaded
      if (await File(outputPath).exists()) {
        final existingSize = await File(outputPath).length();
        if (existingSize > 1024 * 1024) {
          // At least 1MB
          print(
            'DownloadService: File already exists (${(existingSize / 1024 / 1024).toStringAsFixed(1)} MB)',
          );
          onProgress?.call(videoId, 1.0, DownloadStatus.completed);
          return outputPath;
        }
        print('DownloadService: Deleting incomplete file...');
        await File(outputPath).delete();
      }

      // Build the download URL
      final downloadUrl = Uri.parse(
        '${_config.serverUrl}/download?video_id=$videoId&quality=${selectedQuality.apiValue}',
      );

      print('DownloadService: Requesting: $downloadUrl');
      onProgress?.call(videoId, 0.01, DownloadStatus.downloading);

      // Create HTTP request with auth header
      final request = http.Request('GET', downloadUrl);
      request.headers['X-API-Key'] = _config.apiKey;

      print('DownloadService: Sending request to server...');

      // Start polling for server status (updates progress during yt-dlp download)
      statusTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (_cancelledDownloads[videoId] == true) return;

        final status = await getServerStatus(videoId);
        if (status != null) {
          final phase = status['phase'] as String? ?? '';
          final progress = (status['progress'] as num?)?.toDouble() ?? 0;
          final progressText = status['progress_text'] as String? ?? '';

          print(
            'DownloadService: Server status - Phase: $phase, Progress: $progress%, Text: $progressText',
          );

          // Map server progress to app progress (0-50% for yt-dlp phase)
          if (phase == 'yt-dlp' || phase == 'merge') {
            final mappedProgress = progress / 100 * 0.5; // 0-50%
            onProgress?.call(
              videoId,
              mappedProgress,
              DownloadStatus.downloading,
            );
          }
        }
      });

      // Send request - this waits until server finishes downloading and starts streaming
      final streamedResponse = await _httpClient.send(request);

      // Stop polling once we get a response
      statusTimer.cancel();
      statusTimer = null;

      print(
        'DownloadService: Got response with status: ${streamedResponse.statusCode}',
      );

      if (streamedResponse.statusCode != 200) {
        final body = await streamedResponse.stream.bytesToString();
        print(
          'DownloadService: ERROR - Server returned ${streamedResponse.statusCode}: $body',
        );

        // Parse error response
        Map<String, dynamic>? errorData;
        try {
          errorData = json.decode(body) as Map<String, dynamic>?;
        } catch (_) {}

        // Check for specific error types
        if (streamedResponse.statusCode == 429) {
          // Video blocked or rate limited
          final retryAfter = errorData?['retry_after'] as int? ?? 60;
          final failCount = errorData?['fail_count'] as int? ?? 0;
          print(
            'DownloadService: Video blocked (fails: $failCount), retry after ${retryAfter}s',
          );
          onProgress?.call(videoId, 0.0, DownloadStatus.failed);
          return null;
        } else if (streamedResponse.statusCode == 503) {
          // Bot detection - server needs cooldown
          print(
            'DownloadService: Bot detection on server, waiting for cooldown',
          );
          onProgress?.call(videoId, 0.0, DownloadStatus.failed);
          return null;
        }

        onProgress?.call(videoId, 0.0, DownloadStatus.failed);
        return null;
      }

      // Get total size from headers
      final totalBytes = streamedResponse.contentLength ?? 0;
      print(
        'DownloadService: Server finished download, starting transfer: ${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB',
      );

      // Update progress - server finished, now transferring (50% base)
      onProgress?.call(videoId, 0.5, DownloadStatus.downloading);

      // Create output file
      final outputFile = File(outputPath);
      final sink = outputFile.openWrite();

      var downloadedBytes = 0;
      var lastLogPercent = 0;
      var lastProgressUpdate = DateTime.now();

      // Stream the response to file
      await for (final chunk in streamedResponse.stream) {
        // Check for cancellation
        if (_cancelledDownloads[videoId] == true) {
          await sink.close();
          if (await outputFile.exists()) {
            await outputFile.delete();
          }
          print('DownloadService: Download cancelled by user: $videoId');
          onProgress?.call(videoId, 0.0, DownloadStatus.failed);
          return null;
        }

        sink.add(chunk);
        downloadedBytes += chunk.length;

        // Calculate progress (50-100% for transfer phase)
        final transferProgress = totalBytes > 0
            ? downloadedBytes / totalBytes
            : 0.0;
        final overallProgress = 0.5 + (transferProgress * 0.5); // 50-100%

        // Throttle progress updates to avoid overwhelming UI
        final now = DateTime.now();
        if (now.difference(lastProgressUpdate).inMilliseconds > 100) {
          onProgress?.call(
            videoId,
            overallProgress,
            DownloadStatus.downloading,
          );
          lastProgressUpdate = now;
        }

        // Log progress every 10%
        final currentPercent = (transferProgress * 100).toInt();
        if (currentPercent >= lastLogPercent + 10) {
          lastLogPercent = currentPercent;
          print(
            'DownloadService: Transfer progress: $currentPercent% (${(downloadedBytes / 1024 / 1024).toStringAsFixed(1)} / ${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB)',
          );
        }
      }

      await sink.flush();
      await sink.close();

      // Verify file
      if (await outputFile.exists()) {
        final finalSize = await outputFile.length();
        if (finalSize > 0) {
          print('DownloadService: ========================================');
          print('DownloadService: SUCCESS! Download completed');
          print('DownloadService: File: $outputPath');
          print(
            'DownloadService: Size: ${(finalSize / 1024 / 1024).toStringAsFixed(1)} MB',
          );
          print('DownloadService: ========================================');
          onProgress?.call(videoId, 1.0, DownloadStatus.completed);
          _cancelledDownloads.remove(videoId);
          return outputPath;
        }
      }

      print('DownloadService: ERROR - Downloaded file is empty or missing');
      onProgress?.call(videoId, 0.0, DownloadStatus.failed);
      return null;
    } catch (e, stack) {
      print('DownloadService: ========================================');
      print('DownloadService: ERROR downloading $videoId');
      print('DownloadService: Exception: $e');
      print('DownloadService: Stack: $stack');
      print('DownloadService: ========================================');
      onProgress?.call(videoId, 0.0, DownloadStatus.failed);
      _cancelledDownloads.remove(videoId);
      return null;
    } finally {
      statusTimer?.cancel();
    }
  }

  /// Download a video with automatic retry on failure
  ///
  /// Will retry up to [maxRetries] times with exponential backoff.
  /// The delay starts at [initialDelay] seconds and doubles each retry.
  Future<String?> downloadVideoWithRetry(
    Video video, {
    DownloadProgressCallback? onProgress,
    DownloadStatusCallback? onStatusUpdate,
    VideoQuality? quality,
    int maxRetries = 3,
    int initialDelay = 5,
  }) async {
    int attempt = 0;
    int delay = initialDelay;

    while (attempt <= maxRetries) {
      if (_cancelledDownloads[video.videoId] == true) {
        print('DownloadService: Download cancelled, stopping retries');
        return null;
      }

      if (attempt > 0) {
        print(
          'DownloadService: Retry attempt $attempt/$maxRetries after ${delay}s delay',
        );
        onStatusUpdate?.call(
          video.videoId,
          'Tentativa $attempt de $maxRetries (aguardando ${delay}s)...',
        );
        await Future.delayed(Duration(seconds: delay));
        delay = (delay * 2).clamp(5, 90); // Exponential backoff, max 90s
      }

      // Check if video is blocked before attempting
      final preStatus = await getServerStatus(video.videoId);
      if (preStatus != null) {
        final status = preStatus['status'] as Map<String, dynamic>?;
        if (status != null && status['status'] == 'blocked') {
          final retryAfter = status['retry_after'] as int? ?? 60;
          print(
            'DownloadService: Video blocked on server, waiting ${retryAfter}s',
          );
          onStatusUpdate?.call(
            video.videoId,
            'Servidor bloqueado, aguardando ${retryAfter}s...',
          );
          await Future.delayed(Duration(seconds: retryAfter));
          continue; // Retry after waiting
        }
      }

      final result = await downloadVideo(
        video,
        onProgress: onProgress,
        quality: quality,
      );

      if (result != null) {
        return result;
      }

      // Check server status to understand the failure
      final status = await getServerStatus(video.videoId);
      if (status != null) {
        final statusData = status['status'];

        if (statusData is Map<String, dynamic>) {
          final serverStatus = statusData['status'] as String? ?? '';

          if (serverStatus == 'queued' || serverStatus == 'downloading') {
            print(
              'DownloadService: Video is queued/downloading on server, waiting...',
            );
            onStatusUpdate?.call(video.videoId, 'Na fila do servidor...');
            final queueResult = await _waitForServerQueue(
              video,
              onProgress: onProgress,
              onStatusUpdate: onStatusUpdate,
              quality: quality,
            );
            if (queueResult != null) {
              return queueResult;
            }
          } else if (serverStatus == 'blocked') {
            final retryAfter = statusData['retry_after'] as int? ?? 60;
            print('DownloadService: Video blocked, waiting ${retryAfter}s');
            onStatusUpdate?.call(
              video.videoId,
              'Vídeo bloqueado, aguardando ${retryAfter}s...',
            );
            await Future.delayed(Duration(seconds: retryAfter));
            // Don't count as retry if we're waiting for block to expire
            continue;
          }
        } else if (statusData is String) {
          if (statusData == 'queued' || statusData == 'downloading') {
            print(
              'DownloadService: Video is queued/downloading on server, waiting...',
            );
            onStatusUpdate?.call(video.videoId, 'Na fila do servidor...');
            final queueResult = await _waitForServerQueue(
              video,
              onProgress: onProgress,
              onStatusUpdate: onStatusUpdate,
              quality: quality,
            );
            if (queueResult != null) {
              return queueResult;
            }
          }
        }
      }

      attempt++;
    }

    print('DownloadService: All retry attempts failed for ${video.videoId}');
    onStatusUpdate?.call(video.videoId, 'Falhou após $maxRetries tentativas');
    return null;
  }

  /// Wait for video to be processed in server queue, then download
  Future<String?> _waitForServerQueue(
    Video video, {
    DownloadProgressCallback? onProgress,
    DownloadStatusCallback? onStatusUpdate,
    VideoQuality? quality,
    int maxWaitSeconds = 300, // 5 minutes max wait
  }) async {
    final startTime = DateTime.now();
    int pollCount = 0;

    while (DateTime.now().difference(startTime).inSeconds < maxWaitSeconds) {
      if (_cancelledDownloads[video.videoId] == true) {
        return null;
      }

      await Future.delayed(const Duration(seconds: 3));
      pollCount++;

      final status = await getServerStatus(video.videoId);
      if (status == null) continue;

      final serverStatus = status['status'] as String? ?? '';
      final queuePosition = status['queue_position'] as int? ?? 0;

      print(
        'DownloadService: Queue poll #$pollCount - Status: $serverStatus, Position: $queuePosition',
      );

      if (serverStatus == 'queued') {
        onStatusUpdate?.call(video.videoId, 'Na fila: posição $queuePosition');
        onProgress?.call(video.videoId, 0.05, DownloadStatus.downloading);
      } else if (serverStatus == 'downloading') {
        final progress = (status['progress'] as num?)?.toDouble() ?? 0;
        onStatusUpdate?.call(
          video.videoId,
          'A fazer download no servidor (${progress.toStringAsFixed(0)}%)',
        );
        onProgress?.call(
          video.videoId,
          0.1 + (progress / 100 * 0.4),
          DownloadStatus.downloading,
        );
      } else if (serverStatus == 'cached') {
        // Video is ready, download it
        print('DownloadService: Video is cached, downloading...');
        onStatusUpdate?.call(video.videoId, 'Pronto! A transferir...');
        return await downloadVideo(
          video,
          onProgress: onProgress,
          quality: quality,
        );
      } else if (serverStatus == 'failed') {
        print('DownloadService: Server reported download failed');
        onStatusUpdate?.call(video.videoId, 'Falhou no servidor');
        return null;
      }
    }

    print('DownloadService: Timeout waiting for server queue');
    onStatusUpdate?.call(video.videoId, 'Timeout a esperar pelo servidor');
    return null;
  }

  /// Get queue information from server
  Future<Map<String, dynamic>?> getQueueInfo() async {
    try {
      final response = await _httpClient
          .get(
            Uri.parse('${_config.serverUrl}/queue'),
            headers: {'X-API-Key': _config.apiKey},
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      print('DownloadService: Failed to get queue info: $e');
      return null;
    }
  }

  /// Cancel a download
  void cancelDownload(String videoId) {
    _cancelledDownloads[videoId] = true;
  }

  /// Cancel all downloads
  void cancelAllDownloads() {
    for (final key in _cancelledDownloads.keys) {
      _cancelledDownloads[key] = true;
    }
  }

  /// Check if a download is active
  bool isDownloading(String videoId) {
    return _cancelledDownloads.containsKey(videoId) &&
        _cancelledDownloads[videoId] == false;
  }

  /// Get active downloads on server
  Future<List<String>> getActiveDownloads() async {
    try {
      final response = await _httpClient
          .get(
            Uri.parse('${_config.serverUrl}/active'),
            headers: {'X-API-Key': _config.apiKey},
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return List<String>.from(data['active_downloads'] ?? []);
      }
      return [];
    } catch (e) {
      print('DownloadService: Failed to get active downloads: $e');
      return [];
    }
  }

  /// Delete a downloaded video file
  Future<bool> deleteVideo(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      print('DownloadService: Failed to delete file: $e');
      return false;
    }
  }

  /// Get video thumbnail URL
  String getThumbnailUrl(String videoId, {bool highQuality = false}) {
    if (highQuality) {
      return 'https://img.youtube.com/vi/$videoId/maxresdefault.jpg';
    }
    return 'https://img.youtube.com/vi/$videoId/mqdefault.jpg';
  }

  /// Sanitize file name
  String _sanitizeFileName(String name) {
    final sanitized = name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (sanitized.length > 100) {
      return sanitized.substring(0, 100);
    }
    return sanitized.isEmpty ? 'video' : sanitized;
  }

  /// Clean up resources
  void dispose() {
    cancelAllDownloads();
    _httpClient.close();
  }
}
