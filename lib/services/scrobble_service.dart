import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:crypto/crypto.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/external_accounts_store.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';

final _log = Logger("Scrobbler");

/// One track worth scrobbling, as stored in the offline queue.
class ScrobbleTrack {
  ScrobbleTrack({
    required this.title,
    required this.artists,
    this.album,
    this.albumArtist,
    this.durationSeconds,
    this.trackNumber,
    this.recordingMbid,
    this.trackMbid,
    this.releaseMbid,
    this.artistMbids = const [],
    this.listenedAt,
  });

  final String title;
  final List<String> artists;
  final String? album;
  final String? albumArtist;
  final int? durationSeconds;
  final int? trackNumber;
  final String? recordingMbid;
  final String? trackMbid;
  final String? releaseMbid;
  final List<String> artistMbids;

  /// Unix seconds when playback of the track started.
  final int? listenedAt;

  String get artistCredit => artists.join(", ");
  String get primaryArtist => artists.isNotEmpty ? artists.first : (albumArtist ?? "");

  static ScrobbleTrack? fromMediaItem(MediaItem item) {
    final json = item.extras?["itemJson"];
    BaseItemDto? base;
    if (json is Map<String, dynamic>) {
      try {
        base = BaseItemDto.fromJson(json);
      } catch (_) {}
    }
    final type = base?.type;
    if (type != null && type != "Audio" && type != "MusicVideo") return null;

    final artists = (base?.artists?.where((a) => a.trim().isNotEmpty).toList() ?? []);
    if (artists.isEmpty && item.artist != null && item.artist!.isNotEmpty) artists.add(item.artist!);
    if (artists.isEmpty || item.title.isEmpty) return null;

    String? provider(String key) {
      final v = base?.providerIds?[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final artistMbids = provider("MusicBrainzArtist")?.split("/").where((s) => s.isNotEmpty).toList() ?? const [];

    return ScrobbleTrack(
      title: item.title,
      artists: artists,
      album: base?.album ?? item.album,
      albumArtist: base?.albumArtist,
      durationSeconds: item.duration?.inSeconds,
      trackNumber: base?.indexNumber,
      recordingMbid: provider("MusicBrainzRecording"),
      trackMbid: provider("MusicBrainzTrack"),
      releaseMbid: provider("MusicBrainzAlbum"),
      artistMbids: artistMbids,
    );
  }

  ScrobbleTrack withListenedAt(int at) => ScrobbleTrack(
    title: title,
    artists: artists,
    album: album,
    albumArtist: albumArtist,
    durationSeconds: durationSeconds,
    trackNumber: trackNumber,
    recordingMbid: recordingMbid,
    trackMbid: trackMbid,
    releaseMbid: releaseMbid,
    artistMbids: artistMbids,
    listenedAt: at,
  );

  Map<String, dynamic> toJson() => {
    "title": title,
    "artists": artists,
    "album": album,
    "albumArtist": albumArtist,
    "duration": durationSeconds,
    "trackNumber": trackNumber,
    "recordingMbid": recordingMbid,
    "trackMbid": trackMbid,
    "releaseMbid": releaseMbid,
    "artistMbids": artistMbids,
    "listenedAt": listenedAt,
  };

  static ScrobbleTrack fromJson(Map<String, dynamic> j) => ScrobbleTrack(
    title: j["title"] as String,
    artists: (j["artists"] as List).cast<String>(),
    album: j["album"] as String?,
    albumArtist: j["albumArtist"] as String?,
    durationSeconds: j["duration"] as int?,
    trackNumber: j["trackNumber"] as int?,
    recordingMbid: j["recordingMbid"] as String?,
    trackMbid: j["trackMbid"] as String?,
    releaseMbid: j["releaseMbid"] as String?,
    artistMbids: (j["artistMbids"] as List?)?.cast<String>() ?? const [],
    listenedAt: j["listenedAt"] as int?,
  );
}

/// Thrown by the service clients. [retry] says whether trying again later
/// could help (network trouble, rate limits, server errors).
class ScrobbleException implements Exception {
  ScrobbleException(this.message, {this.retry = true, this.authFailed = false});
  final String message;
  final bool retry;
  final bool authFailed;
  @override
  String toString() => message;
}

String _clientVersion = "unknown";

class ListenBrainzClient {
  ListenBrainzClient(this.baseUrl, this.token);
  final String baseUrl;
  final String token;

  Map<String, String> get _headers => {"Authorization": "Token $token", "Content-Type": "application/json"};

  /// Returns the user name for a valid token, or throws.
  Future<String> validate() async {
    final res = await http
        .get(Uri.parse("$baseUrl/1/validate-token"), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw ScrobbleException("ListenBrainz returned ${res.statusCode}");
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body["valid"] != true) throw ScrobbleException("Invalid ListenBrainz token", retry: false, authFailed: true);
    return body["user_name"] as String;
  }

  Map<String, dynamic> _metadata(ScrobbleTrack t) => {
    "artist_name": t.artistCredit,
    "track_name": t.title,
    if (t.album != null) "release_name": t.album,
    "additional_info": {
      "media_player": "Finamp",
      "submission_client": "Finamp",
      "submission_client_version": _clientVersion,
      if (t.durationSeconds != null) "duration_ms": t.durationSeconds! * 1000,
      if (t.trackNumber != null) "tracknumber": t.trackNumber,
      if (t.recordingMbid != null) "recording_mbid": t.recordingMbid,
      if (t.trackMbid != null) "track_mbid": t.trackMbid,
      if (t.releaseMbid != null) "release_mbid": t.releaseMbid,
      if (t.artistMbids.isNotEmpty) "artist_mbids": t.artistMbids,
      if (t.albumArtist != null) "release_artist_name": t.albumArtist,
    },
  };

  Future<void> nowPlaying(ScrobbleTrack t) => _submit("playing_now", [
    {"track_metadata": _metadata(t)},
  ]);

  Future<void> scrobble(List<ScrobbleTrack> tracks) => _submit(tracks.length == 1 ? "single" : "import", [
    for (final t in tracks) {"listened_at": t.listenedAt, "track_metadata": _metadata(t)},
  ]);

  Future<void> _submit(String type, List<Map<String, dynamic>> payload) async {
    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse("$baseUrl/1/submit-listens"),
            headers: _headers,
            body: jsonEncode({"listen_type": type, "payload": payload}),
          )
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw ScrobbleException("ListenBrainz unreachable: $e");
    }
    if (res.statusCode == 200) return;
    if (res.statusCode == 401) {
      throw ScrobbleException("ListenBrainz rejected the token", retry: false, authFailed: true);
    }
    if (res.statusCode == 400) {
      // malformed listen, retrying will not help
      throw ScrobbleException("ListenBrainz refused the listen: ${res.body}", retry: false);
    }
    throw ScrobbleException("ListenBrainz returned ${res.statusCode}");
  }
}

class LastFmClient {
  LastFmClient(this.apiKey, this.apiSecret, [this.sessionKey]);
  final String apiKey;
  final String apiSecret;
  final String? sessionKey;

  static final _endpoint = Uri.parse("https://ws.audioscrobbler.com/2.0/");

  String _sign(Map<String, String> params) {
    final keys = params.keys.where((k) => k != "format" && k != "callback").toList()..sort();
    final buf = StringBuffer();
    for (final k in keys) {
      buf
        ..write(k)
        ..write(params[k]);
    }
    buf.write(apiSecret);
    return md5.convert(utf8.encode(buf.toString())).toString();
  }

  Future<Map<String, dynamic>> _call(String method, Map<String, String> params) async {
    final all = {...params, "method": method, "api_key": apiKey, "sk": ?sessionKey};
    all["api_sig"] = _sign(all);
    all["format"] = "json";
    final http.Response res;
    try {
      res = await http.post(_endpoint, body: all).timeout(const Duration(seconds: 20));
    } catch (e) {
      throw ScrobbleException("Last.fm unreachable: $e");
    }
    Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw ScrobbleException("Last.fm returned ${res.statusCode}");
    }
    final error = body["error"];
    if (error is int) {
      final message = body["message"]?.toString() ?? "error $error";
      switch (error) {
        case 4: // authentication failed (bad user/password)
        case 9: // invalid session key
        case 10: // invalid api key
        case 14: // unauthorized token
        case 26: // suspended api key
          throw ScrobbleException("Last.fm: $message", retry: false, authFailed: true);
        case 11: // service offline
        case 16: // temporary error
        case 29: // rate limit
          throw ScrobbleException("Last.fm: $message");
        default:
          throw ScrobbleException("Last.fm: $message", retry: false);
      }
    }
    if (res.statusCode >= 500) throw ScrobbleException("Last.fm returned ${res.statusCode}");
    return body;
  }

  /// Exchanges a user name and password for a session key. The password is
  /// only sent to Last.fm, never stored.
  Future<({String sessionKey, String user})> login(String username, String password) async {
    final body = await _call("auth.getMobileSession", {"username": username, "password": password});
    final session = body["session"] as Map<String, dynamic>;
    return (sessionKey: session["key"] as String, user: session["name"] as String);
  }

  Map<String, String> _trackParams(ScrobbleTrack t, [String suffix = ""]) => {
    "artist$suffix": t.primaryArtist,
    "track$suffix": t.title,
    if (t.album != null) "album$suffix": t.album!,
    if (t.albumArtist != null) "albumArtist$suffix": t.albumArtist!,
    if (t.durationSeconds != null) "duration$suffix": t.durationSeconds.toString(),
    if (t.trackNumber != null) "trackNumber$suffix": t.trackNumber.toString(),
    if (t.recordingMbid != null) "mbid$suffix": t.recordingMbid!,
  };

  Future<void> nowPlaying(ScrobbleTrack t) => _call("track.updateNowPlaying", _trackParams(t));

  /// Up to 50 tracks per call.
  Future<void> scrobble(List<ScrobbleTrack> tracks) => _call("track.scrobble", {
    for (var i = 0; i < tracks.length; i++) ...{
      ..._trackParams(tracks[i], "[$i]"),
      "timestamp[$i]": tracks[i].listenedAt.toString(),
    },
  });
}

class _PlaySession {
  _PlaySession(this.mediaId, this.track) : startedAt = DateTime.now();
  final String mediaId;
  ScrobbleTrack track;
  final DateTime startedAt;
  Duration played = Duration.zero;
  DateTime? playingSince;
  bool nowPlayingSent = false;
  Duration lastPosition = Duration.zero;

  Duration get totalPlayed =>
      played + (playingSince == null ? Duration.zero : DateTime.now().difference(playingSince!));
}

/// Watches the player and scrobbles finished tracks to ListenBrainz and/or
/// Last.fm using the usual rules: the track is longer than 30 seconds and was
/// actually listened to (time spent playing, seeking does not count) for half
/// its length or 4 minutes, whichever comes first.
///
/// Scrobbles that cannot be sent right away (offline, server trouble) are
/// kept in a persistent queue and retried.
class ScrobbleService {
  ScrobbleService() {
    PackageInfo.fromPlatform().then((info) => _clientVersion = info.version).ignore();
    _audio.mediaItem.listen(_onMediaItem);
    _audio.playbackState.listen(_onPlaybackState);
    _retryTimer = Timer.periodic(const Duration(minutes: 5), (_) => flush());
    Future.delayed(const Duration(seconds: 20), flush);
  }

  final _audio = GetIt.instance<MusicPlayerBackgroundTask>();
  ExternalAccountsStore get _store => ExternalAccountsStore.instance;

  _PlaySession? _session;
  Timer? _retryTimer;

  /// In-memory copy of the persisted queue; the single source of truth while
  /// the app runs, so enqueueing during a flush cannot lose entries.
  late final List<Map<String, dynamic>> _queue = _store.scrobbleQueue;

  Future<void> _persist() => _store.setScrobbleQueue(List.of(_queue));
  bool _flushing = false;

  /// Last error per service, shown in settings.
  String? lastListenBrainzError;
  String? lastLastFmError;

  bool get _anyEnabled => _store.listenBrainzReady || _store.lastFmReady;

  void _onMediaItem(MediaItem? item) {
    final session = _session;
    if (item != null && item.id == session?.mediaId) {
      // same item re-emitted, e.g. once its duration is known
      if (session!.track.durationSeconds == null && item.duration != null) {
        session.track = ScrobbleTrack.fromMediaItem(item) ?? session.track;
      }
      return;
    }
    _finishSession();
    if (item == null) return;
    final track = ScrobbleTrack.fromMediaItem(item);
    if (track == null) return;
    _session = _PlaySession(item.id, track);
    final state = _audio.playbackState.valueOrNull;
    if (state != null) _onPlaybackState(state);
  }

  void _onPlaybackState(PlaybackState state) {
    final session = _session;
    if (session == null) return;

    final playing =
        state.playing &&
        (state.processingState == AudioProcessingState.ready ||
            state.processingState == AudioProcessingState.buffering);

    // Repeat-one: same item, position went from the end back to the start.
    final duration = session.track.durationSeconds;
    if (duration != null &&
        state.position < const Duration(seconds: 3) &&
        session.lastPosition > Duration(seconds: duration - 10) &&
        session.totalPlayed > Duration(seconds: duration ~/ 2)) {
      final id = session.mediaId;
      final track = session.track;
      _finishSession();
      _session = _PlaySession(id, track);
      _onPlaybackState(state);
      return;
    }
    session.lastPosition = state.position;

    if (playing && session.playingSince == null) {
      session.playingSince = DateTime.now();
      if (!session.nowPlayingSent) {
        session.nowPlayingSent = true;
        _sendNowPlaying(session.track);
      }
    } else if (!playing && session.playingSince != null) {
      session.played += DateTime.now().difference(session.playingSince!);
      session.playingSince = null;
    }

    if (state.processingState == AudioProcessingState.completed || state.processingState == AudioProcessingState.idle) {
      _finishSession();
    }
  }

  void _finishSession() {
    final session = _session;
    _session = null;
    if (session == null) return;
    final played = session.totalPlayed;
    final duration = session.track.durationSeconds;
    if (duration == null || duration <= 30) return;
    final needed = Duration(seconds: duration ~/ 2 < 240 ? duration ~/ 2 : 240);
    if (played < needed) {
      _log.finer("Not scrobbling ${session.track.title}: played ${played.inSeconds}s of ${needed.inSeconds}s needed");
      return;
    }
    if (!_anyEnabled) return;
    final track = session.track.withListenedAt(session.startedAt.toUtc().millisecondsSinceEpoch ~/ 1000);
    _enqueue(track);
  }

  Future<void> _enqueue(ScrobbleTrack track) async {
    _queue.add({"track": track.toJson(), "lb": _store.listenBrainzReady, "lfm": _store.lastFmReady});
    // keep the queue bounded; Last.fm refuses scrobbles older than 2 weeks anyway
    while (_queue.length > 3000) {
      _queue.removeAt(0);
    }
    await _persist();
    _log.info("Queued scrobble: ${track.primaryArtist} - ${track.title}");
    await flush();
  }

  Future<void> _sendNowPlaying(ScrobbleTrack track) async {
    if (!_store.sendNowPlaying) return;
    if (_store.listenBrainzReady) {
      unawaited(
        ListenBrainzClient(
          _store.listenBrainzApiUrl,
          _store.listenBrainzToken!,
        ).nowPlaying(track).catchError((Object e) => _log.fine("ListenBrainz now playing failed: $e")),
      );
    }
    if (_store.lastFmReady) {
      unawaited(
        LastFmClient(
          _store.lastFmApiKey!,
          _store.lastFmApiSecret!,
          _store.lastFmSessionKey,
        ).nowPlaying(track).catchError((Object e) => _log.fine("Last.fm now playing failed: $e")),
      );
    }
  }

  int get pendingCount => _queue.length;

  Future<void> clearQueue() async {
    _queue.clear();
    await _persist();
  }

  /// Sends everything in the queue that can be sent.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final queue = _queue;
      if (queue.isEmpty) return;

      // Drop flags for services that were turned off or logged out since.
      for (final e in queue) {
        if (!_store.listenBrainzReady) e["lb"] = false;
        if (!_store.lastFmReady) e["lfm"] = false;
      }
      queue.removeWhere((e) => e["lb"] != true && e["lfm"] != true);

      if (_store.listenBrainzReady) {
        await _flushService(
          flag: "lb",
          batchSize: 100,
          send: (tracks) => ListenBrainzClient(_store.listenBrainzApiUrl, _store.listenBrainzToken!).scrobble(tracks),
          onError: (e) {
            lastListenBrainzError = e.message;
            if (e.authFailed) _store.setListenBrainzAccount(null, null);
          },
          onOk: () => lastListenBrainzError = null,
        );
      }
      if (_store.lastFmReady) {
        await _flushService(
          flag: "lfm",
          batchSize: 50,
          send: (tracks) =>
              LastFmClient(_store.lastFmApiKey!, _store.lastFmApiSecret!, _store.lastFmSessionKey).scrobble(tracks),
          onError: (e) {
            lastLastFmError = e.message;
            if (e.authFailed) {
              _store.setLastFmAccount(
                apiKey: _store.lastFmApiKey,
                apiSecret: _store.lastFmApiSecret,
                sessionKey: null,
                user: null,
              );
            }
          },
          onOk: () => lastLastFmError = null,
        );
      }
      queue.removeWhere((e) => e["lb"] != true && e["lfm"] != true);
      await _persist();
    } catch (e, st) {
      _log.warning("Scrobble flush failed", e, st);
    } finally {
      _flushing = false;
    }
  }

  Future<void> _flushService({
    required String flag,
    required int batchSize,
    required Future<void> Function(List<ScrobbleTrack>) send,
    required void Function(ScrobbleException) onError,
    required void Function() onOk,
  }) async {
    final pending = _queue.where((e) => e[flag] == true).toList();
    for (var i = 0; i < pending.length; i += batchSize) {
      final batch = pending.sublist(i, i + batchSize > pending.length ? pending.length : i + batchSize);
      try {
        await send([for (final e in batch) ScrobbleTrack.fromJson(e["track"] as Map<String, dynamic>)]);
        for (final e in batch) {
          e[flag] = false;
        }
        onOk();
        _log.info("Scrobbled ${batch.length} track(s) to $flag");
      } on ScrobbleException catch (e) {
        _log.warning("Scrobbling to $flag failed: $e");
        onError(e);
        if (!e.retry) {
          // a bad batch would block the queue forever, so drop it
          for (final e in batch) {
            e[flag] = false;
          }
          if (e.authFailed) break;
          continue;
        }
        break; // try again later
      }
    }
    // persist progress after each service so a crash does not double-scrobble
    await _persist();
  }

  void dispose() {
    _retryTimer?.cancel();
  }
}
