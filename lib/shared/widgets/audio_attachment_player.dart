import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';
import '../../utils/sandbox_path_resolver.dart';
import 'ios_tactile.dart';

/// Inline audio attachment card: the app parses the source, the user taps to
/// play. Supports local paths, `file://` URIs, HTTP(S) URLs and base64 data
/// URIs. Playback never starts automatically.
class AudioAttachmentPlayer extends StatefulWidget {
  const AudioAttachmentPlayer({
    super.key,
    required this.source,
    this.label,
  });

  final String source;
  final String? label;

  @override
  State<AudioAttachmentPlayer> createState() => _AudioAttachmentPlayerState();
}

class _AudioAttachmentPlayerState extends State<AudioAttachmentPlayer> {
  static _AudioAttachmentPlayerState? _active;

  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;

  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _starting = false;
  bool _failed = false;

  bool get _isPlaying => _state == PlayerState.playing;
  bool get _isCompleted => _state == PlayerState.completed;

  @override
  void initState() {
    super.initState();
    final player = AudioPlayer();
    _player = player;
    unawaited(player.setReleaseMode(ReleaseMode.stop));
    _stateSub = player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() {
        _state = state;
        if (state == PlayerState.playing) {
          _starting = false;
          _failed = false;
        } else if (state == PlayerState.completed) {
          _starting = false;
          _position = _duration;
        } else if (state == PlayerState.stopped) {
          _position = Duration.zero;
        }
      });
    });
    _positionSub = player.onPositionChanged.listen((position) {
      if (!mounted) return;
      setState(() => _position = position);
    });
    _durationSub = player.onDurationChanged.listen((duration) {
      if (!mounted) return;
      setState(() => _duration = duration);
    });
  }

  @override
  void didUpdateWidget(covariant AudioAttachmentPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source == widget.source) return;
    final player = _player;
    if (player != null) {
      unawaited(player.stop());
    }
    _state = PlayerState.stopped;
    _position = Duration.zero;
    _duration = Duration.zero;
    _failed = false;
    _starting = false;
  }

  @override
  void dispose() {
    if (_active == this) _active = null;
    _stateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final player = _player;
    if (player == null || _starting) return;

    if (_isPlaying) {
      try {
        await player.pause();
      } catch (error) {
        debugPrint('[AudioAttachmentPlayer] pause failed: $error');
      }
      return;
    }

    if (_active != null && _active != this) {
      _active?._pauseFromPeer();
    }
    _active = this;
    if (_failed) {
      setState(() => _failed = false);
    }
    setState(() => _starting = true);
    try {
      if (_isCompleted) {
        await player.seek(Duration.zero);
        await player.resume();
      } else if (_state == PlayerState.paused) {
        await player.resume();
      } else {
        await player.play(_sourceFor(widget.source));
      }
    } catch (error) {
      debugPrint('[AudioAttachmentPlayer] play failed: $error');
      if (!mounted) return;
      setState(() {
        _starting = false;
        _failed = true;
      });
    } finally {
      if (mounted && _starting) {
        setState(() => _starting = false);
      }
    }
  }

  void _pauseFromPeer() {
    _player?.pause();
  }

  Source _sourceFor(String raw) {
    final source = raw.trim();
    if (source.startsWith('data:')) {
      final marker = source.indexOf('base64,');
      final mimeEnd = source.indexOf(';');
      if (marker != -1) {
        final mime = mimeEnd > 5 ? source.substring(5, mimeEnd) : null;
        final bytes = base64Decode(source.substring(marker + 7));
        return BytesSource(bytes, mimeType: mime);
      }
      return UrlSource(source);
    }
    if (source.startsWith('http://') || source.startsWith('https://')) {
      return UrlSource(source);
    }

    var path = source;
    if (path.startsWith('file://')) {
      try {
        path = Uri.parse(path).toFilePath();
      } catch (_) {
        path = path.substring(7);
      }
    }
    return DeviceFileSource(SandboxPathResolver.fix(path));
  }

  String _resolveLabel(BuildContext context) {
    final provided = widget.label?.trim();
    if (provided != null && provided.isNotEmpty) return provided;

    final source = widget.source.trim();
    if (source.startsWith('http://') || source.startsWith('https://')) {
      try {
        final name = Uri.parse(source).pathSegments.last;
        if (name.isNotEmpty) return Uri.decodeComponent(name);
      } catch (_) {}
    } else if (!source.startsWith('data:')) {
      try {
        var path = source;
        if (path.startsWith('file://')) {
          path = Uri.parse(path).toFilePath();
        }
        final name = path.replaceAll('\\', '/').split('/').last;
        if (name.isNotEmpty) return name;
      } catch (_) {}
    }
    return AppLocalizations.of(context)?.ttsFloatingPlayerLabel ?? '';
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context);
    final label = _resolveLabel(context);
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final tooltip = l10n == null
        ? label
        : _isPlaying
        ? l10n.ttsFloatingPauseTooltip
        : _isCompleted
        ? l10n.ttsFloatingReplayTooltip
        : l10n.ttsFloatingResumeTooltip;
    final icon = _failed
        ? Lucide.CircleX
        : _isPlaying
        ? Lucide.Pause
        : _isCompleted
        ? Lucide.RotateCcw
        : Lucide.Play;

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 320),
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : cs.onSurface.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IosIconButton(
              icon: icon,
              size: 20,
              padding: const EdgeInsets.all(7),
              color: _failed ? cs.error : cs.primary,
              semanticLabel: tooltip,
              onTap: _toggle,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: AppFontWeights.medium,
                      color: cs.onSurface.withValues(alpha: 0.86),
                    ),
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      backgroundColor: cs.onSurface.withValues(alpha: 0.12),
                      valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${_formatDuration(_position)} / '
                    '${_duration == Duration.zero ? '--:--' : _formatDuration(_duration)}',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
