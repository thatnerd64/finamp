import 'dart:async';

import 'package:chopper/chopper.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/app_foreground.dart';
import 'package:finamp/services/battery_saver.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api.dart' as jellyfin_api;
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

final _log = Logger("RemoteControl");

/// Ticks per microsecond in Jellyfin's position/runtime fields.
const int _ticksPerMicrosecond = 10;

int durationToTicks(Duration d) => d.inMicroseconds * _ticksPerMicrosecond;
Duration ticksToDuration(int ticks) => Duration(microseconds: ticks ~/ _ticksPerMicrosecond);

enum RemoteRepeatMode {
  none("RepeatNone"),
  all("RepeatAll"),
  one("RepeatOne");

  const RemoteRepeatMode(this.jellyfinName);
  final String jellyfinName;

  static RemoteRepeatMode parse(String? v) =>
      RemoteRepeatMode.values.firstWhere((m) => m.jellyfinName == v, orElse: () => RemoteRepeatMode.none);

  RemoteRepeatMode get next => RemoteRepeatMode.values[(index + 1) % RemoteRepeatMode.values.length];
}

enum RemotePlayCommand {
  playNow("PlayNow"),
  playNext("PlayNext"),
  playLast("PlayLast");

  const RemotePlayCommand(this.jellyfinName);
  final String jellyfinName;
}

/// Another Jellyfin client this user can control (TV, web player, desktop app,
/// another phone). Parsed by hand from `/Sessions` so that fields newer or older
/// servers add or drop cannot break the list.
class RemoteSession {
  RemoteSession({
    required this.id,
    required this.deviceName,
    required this.client,
    required this.userName,
    required this.applicationVersion,
    required this.nowPlaying,
    required this.positionTicks,
    required this.isPaused,
    required this.isMuted,
    required this.volumeLevel,
    required this.canSeek,
    required this.repeatMode,
    required this.shuffled,
    required this.supportedCommands,
    required this.supportsMediaControl,
    required this.playableMediaTypes,
    required this.queueLength,
    required this.fetchedAt,
  });

  final String id;
  final String deviceName;
  final String client;
  final String? userName;
  final String? applicationVersion;
  final BaseItemDto? nowPlaying;
  final int? positionTicks;
  final bool isPaused;
  final bool isMuted;
  final int? volumeLevel;
  final bool canSeek;
  final RemoteRepeatMode repeatMode;
  final bool? shuffled;
  final Set<String> supportedCommands;
  final bool supportsMediaControl;
  final Set<String> playableMediaTypes;
  final int queueLength;
  final DateTime fetchedAt;

  bool get isPlaying => nowPlaying != null;
  bool get canPlayAudio => playableMediaTypes.isEmpty || playableMediaTypes.contains("Audio");
  bool supports(String generalCommand) => supportedCommands.contains(generalCommand);
  bool get canSetVolume => supports("SetVolume");
  bool get canMute => supports("Mute") || supports("ToggleMute");
  bool get canShuffle => supports("SetPlaybackOrder") || supports("SetShuffleQueue");
  bool get canRepeat => supports("SetRepeatMode");

  Duration? get duration => nowPlaying?.runTimeTicksDuration();

  /// Position now, moved forward by the time since the server reported it.
  Duration get position {
    final base = ticksToDuration(positionTicks ?? 0);
    if (!isPlaying || isPaused) return base;
    var p = base + DateTime.now().difference(fetchedAt);
    final d = duration;
    if (d != null && p > d) p = d;
    return p;
  }

  RemoteSession copyWith({
    bool? isPaused,
    bool? isMuted,
    int? volumeLevel,
    int? positionTicks,
    RemoteRepeatMode? repeatMode,
    bool? shuffled,
  }) {
    return RemoteSession(
      id: id,
      deviceName: deviceName,
      client: client,
      userName: userName,
      applicationVersion: applicationVersion,
      nowPlaying: nowPlaying,
      positionTicks: positionTicks ?? (isPaused != null ? durationToTicks(position) : this.positionTicks),
      isPaused: isPaused ?? this.isPaused,
      isMuted: isMuted ?? this.isMuted,
      volumeLevel: volumeLevel ?? this.volumeLevel,
      canSeek: canSeek,
      repeatMode: repeatMode ?? this.repeatMode,
      shuffled: shuffled ?? this.shuffled,
      supportedCommands: supportedCommands,
      supportsMediaControl: supportsMediaControl,
      playableMediaTypes: playableMediaTypes,
      queueLength: queueLength,
      fetchedAt: positionTicks != null || isPaused != null ? DateTime.now() : fetchedAt,
    );
  }

  static RemoteSession? tryParse(Map<dynamic, dynamic> json, DateTime fetchedAt) {
    try {
      final id = json["Id"] as String?;
      if (id == null) return null;
      final playState = (json["PlayState"] as Map?) ?? const {};
      BaseItemDto? nowPlaying;
      final np = json["NowPlayingItem"];
      if (np is Map) {
        try {
          nowPlaying = BaseItemDto.fromJson(Map<String, dynamic>.from(np));
        } catch (e) {
          _log.warning("Could not parse NowPlayingItem of session $id: $e");
        }
      }
      // 10.9+ reports PlaybackOrder ("Default"/"Shuffle"); older servers ShuffleMode ("Sorted"/"Shuffle").
      final order = (playState["PlaybackOrder"] ?? playState["ShuffleMode"]) as String?;
      return RemoteSession(
        id: id,
        deviceName: (json["DeviceName"] as String?) ?? "Unknown device",
        client: (json["Client"] as String?) ?? "",
        userName: json["UserName"] as String?,
        applicationVersion: json["ApplicationVersion"] as String?,
        nowPlaying: nowPlaying,
        positionTicks: (playState["PositionTicks"] as num?)?.toInt(),
        isPaused: (playState["IsPaused"] as bool?) ?? false,
        isMuted: (playState["IsMuted"] as bool?) ?? false,
        volumeLevel: (playState["VolumeLevel"] as num?)?.toInt(),
        canSeek: (playState["CanSeek"] as bool?) ?? true,
        repeatMode: RemoteRepeatMode.parse(playState["RepeatMode"] as String?),
        shuffled: order == null ? null : order == "Shuffle",
        supportedCommands: {...?(json["SupportedCommands"] as List?)?.whereType<String>()},
        supportsMediaControl: (json["SupportsMediaControl"] as bool?) ?? false,
        playableMediaTypes: {...?(json["PlayableMediaTypes"] as List?)?.whereType<String>()},
        queueLength: (json["NowPlayingQueue"] as List?)?.length ?? 0,
        fetchedAt: fetchedAt,
      );
    } catch (e, st) {
      _log.warning("Could not parse session", e, st);
      return null;
    }
  }
}

/// Talks to `/Sessions` to list and control the user's other Jellyfin players.
///
/// Requests go through the app's Chopper client, so they get the server
/// address, auth header and logging like every other API call. The endpoints
/// are written out here instead of in the generated [jellyfin_api.JellyfinApi]
/// to keep the fork free of regenerated code.
class RemoteControlService {
  RemoteControlService._();
  static final instance = RemoteControlService._();

  String? _ownDeviceId;

  ChopperClient get _client => GetIt.instance<JellyfinApiHelper>().jellyfinApi.client;

  Future<Response<dynamic>> _send(String method, String path, {Map<String, dynamic>? params, Object? body}) async {
    final request = Request(method, Uri.parse(path), _client.baseUrl, parameters: params ?? const {}, body: body);
    final response = await _client.send<dynamic, dynamic>(
      request,
      requestConverter: JsonConverter.requestFactory,
      responseConverter: JsonConverter.responseFactory<dynamic, dynamic>,
    );
    if (!response.isSuccessful) {
      throw RemoteControlException("Server answered ${response.statusCode}", response.statusCode);
    }
    return response;
  }

  Future<String?> _getOwnDeviceId() async {
    if (_ownDeviceId != null) return _ownDeviceId;
    final info = await jellyfin_api.getDeviceInfo(deviceId: FinampSettingsHelper.finampSettings.deviceId);
    return _ownDeviceId = info.id;
  }

  /// Sessions this user may control, playing ones first, without this app.
  Future<List<RemoteSession>> fetchSessions() async {
    final user = GetIt.instance<FinampUserHelper>().currentUser;
    if (user == null) return const [];
    final ownDeviceId = await _getOwnDeviceId();
    final response = await _send(
      "GET",
      "/Sessions",
      params: {"controllableByUserId": user.id, "activeWithinSeconds": 960},
    );
    final now = DateTime.now();
    final body = response.body;
    if (body is! List) return const [];
    final sessions = <RemoteSession>[];
    for (final raw in body) {
      if (raw is! Map) continue;
      if (ownDeviceId != null && raw["DeviceId"] == ownDeviceId) continue;
      if (raw["SupportsRemoteControl"] != true) continue;
      final s = RemoteSession.tryParse(raw, now);
      if (s != null) sessions.add(s);
    }
    sessions.sort((a, b) {
      if (a.isPlaying != b.isPlaying) return a.isPlaying ? -1 : 1;
      return a.deviceName.toLowerCase().compareTo(b.deviceName.toLowerCase());
    });
    return sessions;
  }

  // Playstate commands: Stop, Pause, Unpause, NextTrack, PreviousTrack, Seek, Rewind, FastForward, PlayPause.
  Future<void> _playstate(String sessionId, String command, {int? seekPositionTicks}) async {
    _log.info("Session $sessionId: $command${seekPositionTicks != null ? " to $seekPositionTicks" : ""}");
    await _send("POST", "/Sessions/$sessionId/Playing/$command", params: {"seekPositionTicks": ?seekPositionTicks});
  }

  Future<void> pause(String sessionId) => _playstate(sessionId, "Pause");
  Future<void> unpause(String sessionId) => _playstate(sessionId, "Unpause");
  Future<void> playPause(String sessionId) => _playstate(sessionId, "PlayPause");
  Future<void> stop(String sessionId) => _playstate(sessionId, "Stop");
  Future<void> next(String sessionId) => _playstate(sessionId, "NextTrack");
  Future<void> previous(String sessionId) => _playstate(sessionId, "PreviousTrack");
  Future<void> seek(String sessionId, Duration position) =>
      _playstate(sessionId, "Seek", seekPositionTicks: durationToTicks(position));

  Future<void> _general(String sessionId, String name, [Map<String, String>? arguments]) async {
    _log.info("Session $sessionId: $name ${arguments ?? ""}");
    await _send("POST", "/Sessions/$sessionId/Command", body: {"Name": name, "Arguments": arguments ?? {}});
  }

  Future<void> setVolume(String sessionId, int volume) =>
      _general(sessionId, "SetVolume", {"Volume": volume.clamp(0, 100).toString()});
  Future<void> setMuted(String sessionId, bool muted) => _general(sessionId, muted ? "Mute" : "Unmute");
  Future<void> toggleMute(String sessionId) => _general(sessionId, "ToggleMute");
  Future<void> setRepeatMode(String sessionId, RemoteRepeatMode mode) =>
      _general(sessionId, "SetRepeatMode", {"RepeatMode": mode.jellyfinName});

  /// Jellyfin 10.9+ clients take SetPlaybackOrder; older ones SetShuffleQueue.
  Future<void> setShuffle(RemoteSession session, bool shuffle) => session.supports("SetPlaybackOrder")
      ? _general(session.id, "SetPlaybackOrder", {"PlaybackOrder": shuffle ? "Shuffle" : "Default"})
      : _general(session.id, "SetShuffleQueue", {"ShuffleMode": shuffle ? "Shuffle" : "Sorted"});

  /// Plays items on the device. Albums, playlists, artists and genres are
  /// expanded into their tracks by the server.
  Future<void> playItems(
    String sessionId,
    List<BaseItemId> itemIds, {
    RemotePlayCommand command = RemotePlayCommand.playNow,
    int? startIndex,
    Duration? startPosition,
  }) async {
    if (itemIds.isEmpty) return;
    _log.info("Session $sessionId: ${command.jellyfinName} ${itemIds.length} items from $startIndex");
    await _send(
      "POST",
      "/Sessions/$sessionId/Playing",
      params: {
        "playCommand": command.jellyfinName,
        "itemIds": itemIds.map((id) => id.raw).join(","),
        if (startIndex != null && startIndex > 0) "startIndex": startIndex,
        if (startPosition != null && startPosition > Duration.zero)
          "startPositionTicks": durationToTicks(startPosition),
      },
    );
  }

  /// Most track ids sent in one request; long queues are cut to a window
  /// around the current track so the URL stays a sane length.
  static const maxTransferredTracks = 200;

  /// Sends this app's queue to the device, starting at the current track and
  /// position, then pauses playback here. Returns false when nothing is queued.
  Future<bool> transferQueue(String sessionId) async {
    final queueService = GetIt.instance<QueueService>();
    final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
    final info = queueService.getQueue();
    final current = info.currentTrack;
    if (current == null) return false;
    final tracks = [...info.previousTracks, current, ...info.nextUp, ...info.queue];
    final currentIndex = info.previousTracks.length;
    var start = currentIndex - 20;
    if (start < 0) start = 0;
    var end = start + maxTransferredTracks;
    if (end > tracks.length) end = tracks.length;
    final ids = [for (final t in tracks.sublist(start, end)) t.baseItemId];
    await playItems(sessionId, ids, startIndex: currentIndex - start, startPosition: audioHandler.playbackPosition);
    if (!audioHandler.paused) await audioHandler.pause();
    return true;
  }
}

class RemoteControlException implements Exception {
  RemoteControlException(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Polls the session list while a remote-control screen is open and the app
/// is on screen. One instance per screen; [dispose] stops it.
class RemoteSessionsController extends ChangeNotifier {
  RemoteSessionsController() {
    _visibleSub = AppForeground.visibleStream.listen((visible) {
      if (visible) {
        unawaited(refresh());
      } else {
        _timer?.cancel();
        _timer = null;
      }
    });
    unawaited(refresh());
  }

  final _service = RemoteControlService.instance;
  StreamSubscription<bool>? _visibleSub;
  Timer? _timer;
  bool _disposed = false;
  bool _fetching = false;
  bool _refreshSoon = false;

  List<RemoteSession> sessions = const [];
  bool loading = true;
  Object? error;

  Duration get _interval => BatterySaver.instance.active ? const Duration(seconds: 6) : const Duration(seconds: 2);

  RemoteSession? byId(String id) {
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> refresh() async {
    if (_disposed || _fetching) return;
    _fetching = true;
    _timer?.cancel();
    try {
      sessions = await _service.fetchSessions();
      error = null;
    } catch (e) {
      _log.warning("Could not load sessions: $e");
      error = e;
    } finally {
      _fetching = false;
      loading = false;
    }
    if (_disposed) return;
    notifyListeners();
    _timer?.cancel();
    final delay = _refreshSoon ? const Duration(milliseconds: 600) : _interval;
    _refreshSoon = false;
    if (AppForeground.isVisible) _timer = Timer(delay, refresh);
  }

  /// Shows the expected result right away, then checks with the server.
  void _optimistic(String id, RemoteSession Function(RemoteSession) change) {
    sessions = [for (final s in sessions) s.id == id ? change(s) : s];
    notifyListeners();
  }

  /// Runs [action], then refreshes a little later so the device has time to act.
  Future<void> run(
    String sessionId,
    Future<void> Function(RemoteControlService) action, {
    RemoteSession Function(RemoteSession)? optimistic,
  }) async {
    if (optimistic != null) _optimistic(sessionId, optimistic);
    try {
      await action(_service);
    } finally {
      if (_fetching) {
        // the answer in flight may predate the command; poll again soon after it
        _refreshSoon = true;
      } else if (!_disposed) {
        _timer?.cancel();
        _timer = Timer(const Duration(milliseconds: 600), refresh);
      }
    }
  }

  Future<bool> transferQueue(String sessionId) async {
    bool sent = false;
    await run(sessionId, (api) async => sent = await api.transferQueue(sessionId));
    return sent;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _visibleSub?.cancel();
    super.dispose();
  }
}
