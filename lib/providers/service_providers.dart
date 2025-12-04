import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/services.dart';

/// Auth service provider (singleton)
final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService();
});

/// YouTube API service provider
final youtubeApiServiceProvider = Provider<YouTubeApiService>((ref) {
  final authService = ref.watch(authServiceProvider);
  return YouTubeApiService(authService);
});

/// Download service provider (singleton)
final downloadServiceProvider = Provider<DownloadService>((ref) {
  final service = DownloadService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Sync service provider
final syncServiceProvider = Provider<SyncService>((ref) {
  final youtubeApi = ref.watch(youtubeApiServiceProvider);
  final downloadService = ref.watch(downloadServiceProvider);
  return SyncService(youtubeApi, downloadService);
});
