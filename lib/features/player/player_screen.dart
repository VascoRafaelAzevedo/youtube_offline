import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' as media_kit;

import '../../data/models/models.dart';
import '../../providers/providers.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  final Video video;

  const PlayerScreen({super.key, required this.video});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  // Media Kit player and controller
  late final Player _player;
  late final media_kit.VideoController _controller;

  bool _isInitialized = false;
  String? _error;

  // UI state
  bool _showControls = true;
  Timer? _hideControlsTimer;
  bool _isSpedUp = false;
  double _currentSpeed = 1.0;

  // Buffering state
  bool _isBuffering = false;

  // Available playback speeds
  static const List<double> _playbackSpeeds = [
    0.25,
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
    2.5,
    3.0,
  ];

  // Double tap animation
  bool _showForwardAnimation = false;
  bool _showBackwardAnimation = false;
  int _seekSeconds = 0;

  // Stream subscriptions
  final List<StreamSubscription> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _initializePlayer();
    // Lock to landscape for better viewing
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _initializePlayer() async {
    try {
      final file = File(widget.video.filePath!);
      if (!await file.exists()) {
        setState(() => _error = 'Video file not found');
        return;
      }

      // Create player with configuration
      _player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 64 * 1024 * 1024, // 64MB buffer for smooth playback
        ),
      );

      // Create video controller for rendering
      _controller = media_kit.VideoController(
        _player,
        configuration: const media_kit.VideoControllerConfiguration(
          enableHardwareAcceleration: true,
        ),
      );

      // Set up stream listeners
      _subscriptions.add(
        _player.stream.buffering.listen((buffering) {
          if (mounted) {
            setState(() => _isBuffering = buffering);
          }
        }),
      );

      _subscriptions.add(
        _player.stream.position.listen((position) {
          if (position.inSeconds % 5 == 0) {
            _savePosition(position.inSeconds);
          }
        }),
      );

      _subscriptions.add(
        _player.stream.completed.listen((completed) {
          if (completed) {
            _onVideoCompleted();
          }
        }),
      );

      // Open the media file
      await _player.open(Media(file.path));

      // Seek to last position if resuming
      if (widget.video.hasResumePosition) {
        await _player.seek(Duration(seconds: widget.video.lastPositionSeconds));
      }

      await _player.play();
      setState(() => _isInitialized = true);
      _startHideControlsTimer();
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _onVideoCompleted() {
    // Mark as watched when video ends
    final video = ref
        .read(syncProvider.notifier)
        .getVideo(widget.video.videoId);
    if (video != null && !video.watched) {
      ref.read(syncProvider.notifier).markAsWatched(video);
    }
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _player.state.playing) {
        setState(() => _showControls = false);
      }
    });
  }

  Future<void> _savePosition(int positionSeconds) async {
    final video = ref
        .read(syncProvider.notifier)
        .getVideo(widget.video.videoId);
    if (video != null) {
      await ref
          .read(syncProvider.notifier)
          .updateWatchPosition(video, positionSeconds);
    }
  }

  void _togglePlayPause() {
    _player.playOrPause();
    if (_player.state.playing) {
      _startHideControlsTimer();
    }
    setState(() {});
  }

  void _seekForward([int seconds = 10]) {
    final newPosition = _player.state.position + Duration(seconds: seconds);
    final duration = _player.state.duration;
    _player.seek(newPosition > duration ? duration : newPosition);

    setState(() {
      _seekSeconds += seconds;
      _showForwardAnimation = true;
    });

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _showForwardAnimation = false;
          _seekSeconds = 0;
        });
      }
    });
  }

  void _seekBackward([int seconds = 10]) {
    final newPosition = _player.state.position - Duration(seconds: seconds);
    _player.seek(newPosition < Duration.zero ? Duration.zero : newPosition);

    setState(() {
      _seekSeconds += seconds;
      _showBackwardAnimation = true;
    });

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _showBackwardAnimation = false;
          _seekSeconds = 0;
        });
      }
    });
  }

  void _onLongPressStart() {
    if (!_isSpedUp) {
      _player.setRate(2.0);
      setState(() => _isSpedUp = true);
    }
  }

  void _onLongPressEnd() {
    if (_isSpedUp) {
      _player.setRate(_currentSpeed);
      setState(() => _isSpedUp = false);
    }
  }

  void _showSpeedMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Playback Speed',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            SizedBox(
              height: 200,
              child: ListView.builder(
                itemCount: _playbackSpeeds.length,
                itemBuilder: (context, index) {
                  final speed = _playbackSpeeds[index];
                  final isSelected = speed == _currentSpeed;
                  return ListTile(
                    leading: isSelected
                        ? const Icon(Icons.check, color: Colors.blue)
                        : const SizedBox(width: 24),
                    title: Text(
                      speed == 1.0 ? 'Normal' : '${speed}x',
                      style: TextStyle(
                        color: isSelected ? Colors.blue : Colors.white,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    onTap: () {
                      setState(() => _currentSpeed = speed);
                      _player.setRate(speed);
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _onTap() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _startHideControlsTimer();
    }
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();

    // Save final position
    if (_isInitialized) {
      _savePosition(_player.state.position.inSeconds);
    }

    // Cancel subscriptions
    for (final sub in _subscriptions) {
      sub.cancel();
    }

    // Dispose player
    _player.dispose();

    // Reset orientation
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: Colors.black, body: _buildBody());
  }

  Widget _buildBody() {
    if (_error != null) {
      return _buildErrorWidget();
    }

    if (!_isInitialized) {
      return _buildLoadingWidget();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Video with media_kit - smooth GPU-accelerated rendering
        GestureDetector(
          onTap: _onTap,
          onDoubleTapDown: (details) {
            final screenWidth = MediaQuery.of(context).size.width;
            if (details.globalPosition.dx < screenWidth / 2) {
              _seekBackward();
            } else {
              _seekForward();
            }
          },
          onDoubleTap: () {},
          onLongPressStart: (_) => _onLongPressStart(),
          onLongPressEnd: (_) => _onLongPressEnd(),
          child: media_kit.Video(
            controller: _controller,
            controls: media_kit.NoVideoControls, // We use our custom controls
            fill: Colors.black,
          ),
        ),

        // Buffering indicator (YouTube-style)
        if (_isBuffering)
          const Center(
            child: CircularProgressIndicator(
              color: Colors.white,
              strokeWidth: 3,
            ),
          ),

        // Seek backward animation (left side)
        if (_showBackwardAnimation)
          Positioned(
            left: 50,
            top: 0,
            bottom: 0,
            child: Center(child: _buildSeekAnimation(false)),
          ),

        // Seek forward animation (right side)
        if (_showForwardAnimation)
          Positioned(
            right: 50,
            top: 0,
            bottom: 0,
            child: Center(child: _buildSeekAnimation(true)),
          ),

        // 2x speed indicator
        if (_isSpedUp)
          Positioned(
            top: 60,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.fast_forward, color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Text(
                      '2x Speed',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // Controls overlay
        if (_showControls) _buildControlsOverlay(),
      ],
    );
  }

  Widget _buildSeekAnimation(bool isForward) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.3),
        shape: BoxShape.circle,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isForward ? Icons.fast_forward : Icons.fast_rewind,
            color: Colors.white,
            size: 40,
          ),
          Text(
            '${_seekSeconds}s',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlsOverlay() {
    return StreamBuilder<Duration>(
      stream: _player.stream.position,
      builder: (context, positionSnapshot) {
        final position = positionSnapshot.data ?? Duration.zero;
        final duration = _player.state.duration;
        final isPlaying = _player.state.playing;

        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black54,
                Colors.transparent,
                Colors.transparent,
                Colors.black54,
              ],
              stops: const [0.0, 0.2, 0.8, 1.0],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                // Top bar
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Text(
                          widget.video.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.settings, color: Colors.white),
                        onPressed: _showSpeedMenu,
                      ),
                      IconButton(
                        icon: Icon(
                          widget.video.watched
                              ? Icons.visibility
                              : Icons.visibility_outlined,
                          color: Colors.white,
                        ),
                        onPressed: _toggleWatched,
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // Center play/pause button
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        iconSize: 36,
                        icon: const Icon(Icons.replay_10, color: Colors.white),
                        onPressed: () => _seekBackward(10),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          iconSize: 48,
                          icon: Icon(
                            isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                          ),
                          onPressed: _togglePlayPause,
                        ),
                      ),
                      IconButton(
                        iconSize: 36,
                        icon: const Icon(Icons.forward_10, color: Colors.white),
                        onPressed: () => _seekForward(10),
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // Bottom controls with smooth seek bar
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      // Smooth seek bar with buffer indicator
                      StreamBuilder<Duration>(
                        stream: _player.stream.buffer,
                        builder: (context, bufferSnapshot) {
                          final buffered = bufferSnapshot.data ?? Duration.zero;
                          final bufferedFraction = duration.inMilliseconds > 0
                              ? buffered.inMilliseconds /
                                    duration.inMilliseconds
                              : 0.0;

                          return SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 4,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 8,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 16,
                              ),
                              activeTrackColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                              inactiveTrackColor: Colors.white30,
                              thumbColor: Theme.of(context).colorScheme.primary,
                              secondaryActiveTrackColor: Colors.white54,
                            ),
                            child: Slider(
                              value: position.inMilliseconds.toDouble().clamp(
                                0.0,
                                duration.inMilliseconds.toDouble(),
                              ),
                              max: duration.inMilliseconds.toDouble().clamp(
                                1.0,
                                double.infinity,
                              ),
                              secondaryTrackValue:
                                  (bufferedFraction * duration.inMilliseconds)
                                      .clamp(
                                        0.0,
                                        duration.inMilliseconds.toDouble(),
                                      ),
                              onChanged: (value) {
                                _player.seek(
                                  Duration(milliseconds: value.toInt()),
                                );
                              },
                            ),
                          );
                        },
                      ),
                      // Time display
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(position),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                            if (_currentSpeed != 1.0)
                              GestureDetector(
                                onTap: _showSpeedMenu,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.blue,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${_currentSpeed}x',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              )
                            else
                              Text(
                                widget.video.channelName,
                                style: TextStyle(
                                  color: Colors.grey[400],
                                  fontSize: 12,
                                ),
                              ),
                            Text(
                              _formatDuration(duration),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildErrorWidget() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              'Error loading video',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Go back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingWidget() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 16),
          Text('Loading video...', style: TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  void _toggleWatched() async {
    final video = ref
        .read(syncProvider.notifier)
        .getVideo(widget.video.videoId);
    if (video != null) {
      if (video.watched) {
        await ref.read(syncProvider.notifier).markAsUnwatched(video);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Marked as unwatched')));
      } else {
        await ref.read(syncProvider.notifier).markAsWatched(video);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Marked as watched')));
      }
      setState(() {});
    }
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}
