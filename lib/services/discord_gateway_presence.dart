import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

final _log = Logger("DiscordGateway");

/// What to show on the user's Discord profile.
class DiscordPresenceActivity {
  const DiscordPresenceActivity({
    required this.name,
    required this.details,
    this.state,
    this.largeImage,
    this.largeText,
    this.smallImage,
    this.smallText,
    this.startMs,
    this.endMs,
  });

  final String name;
  final String details;
  final String? state;

  /// Either an http(s) URL (proxied through Discord's external assets), an
  /// application asset name, or null.
  final String? largeImage;
  final String? largeText;
  final String? smallImage;
  final String? smallText;
  final int? startMs;
  final int? endMs;

  /// Everything except the timestamps, used to skip redundant updates.
  String get contentKey => jsonEncode([name, details, state, largeImage, largeText, smallImage, smallText]);
}

/// Minimal Discord gateway client that logs in with the user's own account
/// token and sets a "Listening to" activity on it.
///
/// Discord has no local RPC socket on Android, so this is the only way for a
/// third-party Android app to show rich presence. It is the same approach as
/// Kizzy and other Android music players. Automating a user account is
/// against Discord's Terms of Service, so this stays opt-in and the settings
/// screen says so.
class DiscordGatewayPresence {
  DiscordGatewayPresence({
    required this.token,
    required this.applicationId,
    this.status = "online",
    this.onUser,
    this.onAuthFailed,
  });

  static const _gatewayUrl = "wss://gateway.discord.gg/?v=10&encoding=json";
  static const _api = "https://discord.com/api/v10";

  final String token;
  final String applicationId;
  String status;
  final void Function(String displayName)? onUser;
  final void Function()? onAuthFailed;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  bool _heartbeatAcked = true;
  int? _seq;
  String? _sessionId;
  String? _resumeUrl;
  bool _ready = false;
  bool _running = false;
  int _reconnectAttempts = 0;

  DiscordPresenceActivity? _wanted;
  String? _sentKey;
  int? _sentStart;
  bool _sentSomething = false;
  DateTime _lastSend = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _sendTimer;

  final Map<String, String> _externalAssetCache = {};
  Map<String, String>? _appAssets;

  bool get isConnected => _ready;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _reconnectAttempts = 0;
    await _connect();
  }

  Future<void> stop() async {
    _running = false;
    _reconnectTimer?.cancel();
    _sendTimer?.cancel();
    if (_ready && _sentSomething) {
      // Clear explicitly so the activity disappears at once instead of
      // lingering until Discord notices the session is gone.
      _sendPresence(null);
    }
    await _closeSocket(1000);
    _sessionId = null;
    _seq = null;
    _sentKey = null;
    _sentStart = null;
    _sentSomething = false;
  }

  /// Sets (or clears, with null) the activity. Cheap to call often: updates
  /// are only sent when something visible changed or the track position
  /// jumped, and never faster than Discord's presence rate limit allows.
  void setActivity(DiscordPresenceActivity? activity) {
    _wanted = activity;
    _scheduleSend();
  }

  // Connection handling

  Future<void> _connect() async {
    if (!_running) return;
    final url = _resumeUrl != null && _sessionId != null ? "$_resumeUrl/?v=10&encoding=json" : _gatewayUrl;
    try {
      _socket = await WebSocket.connect(url).timeout(const Duration(seconds: 20));
    } catch (e) {
      _log.warning("Could not connect to the gateway: $e");
      _scheduleReconnect();
      return;
    }
    _socketSub = _socket!.listen(
      _onMessage,
      onDone: () => _onClosed(_socket?.closeCode, _socket?.closeReason),
      onError: (Object e) => _log.warning("Gateway socket error: $e"),
      cancelOnError: true,
    );
  }

  Future<void> _closeSocket(int code) async {
    _heartbeatTimer?.cancel();
    _ready = false;
    final socket = _socket;
    _socket = null;
    await _socketSub?.cancel();
    _socketSub = null;
    try {
      await socket?.close(code);
    } catch (_) {}
  }

  void _onClosed(int? code, String? reason) {
    _heartbeatTimer?.cancel();
    _ready = false;
    _socket = null;
    _log.info("Gateway closed: $code $reason");
    if (!_running) return;
    switch (code) {
      case 4004: // authentication failed
        _log.severe("Discord rejected the token, logging out of Discord presence");
        _running = false;
        onAuthFailed?.call();
        return;
      case 4007: // invalid seq
      case 4009: // session timed out
        _sessionId = null;
        _seq = null;
        break;
      case 4010:
      case 4011:
      case 4012:
      case 4013:
      case 4014:
        _running = false;
        return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_running) return;
    _reconnectTimer?.cancel();
    final delay = min(60, pow(2, _reconnectAttempts).toInt()) + Random().nextInt(3);
    _reconnectAttempts++;
    _log.fine("Reconnecting in ${delay}s");
    _reconnectTimer = Timer(Duration(seconds: delay), () async {
      await _closeSocket(4000);
      await _connect();
    });
  }

  void _send(Map<String, dynamic> payload) {
    try {
      _socket?.add(jsonEncode(payload));
    } catch (e) {
      _log.warning("Failed to send gateway payload: $e");
    }
  }

  void _onMessage(dynamic raw) {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (e) {
      return;
    }
    final op = msg["op"] as int?;
    if (msg["s"] is int) _seq = msg["s"] as int;

    switch (op) {
      case 10: // hello
        final interval = (msg["d"]["heartbeat_interval"] as num).toInt();
        _startHeartbeat(interval);
        if (_sessionId != null && _seq != null) {
          _send({
            "op": 6,
            "d": {"token": token, "session_id": _sessionId, "seq": _seq},
          });
        } else {
          _identify();
        }
      case 11: // heartbeat ack
        _heartbeatAcked = true;
      case 1: // server asks for a heartbeat
        _send({"op": 1, "d": _seq});
      case 7: // reconnect
        _log.fine("Gateway asked us to reconnect");
        _closeSocket(4000).then((_) => _connect());
      case 9: // invalid session
        final resumable = msg["d"] == true;
        if (!resumable) {
          _sessionId = null;
          _seq = null;
        }
        Future.delayed(Duration(seconds: 1 + Random().nextInt(4)), () {
          if (!_running || _socket == null) return;
          if (resumable && _sessionId != null) {
            _send({
              "op": 6,
              "d": {"token": token, "session_id": _sessionId, "seq": _seq},
            });
          } else {
            _identify();
          }
        });
      case 0: // dispatch
        final type = msg["t"] as String?;
        if (type == "READY") {
          final d = msg["d"] as Map<String, dynamic>;
          _sessionId = d["session_id"] as String?;
          _resumeUrl = d["resume_gateway_url"] as String?;
          final user = d["user"] as Map<String, dynamic>?;
          final name = (user?["global_name"] ?? user?["username"]) as String?;
          if (name != null) onUser?.call(name);
          _onReady();
        } else if (type == "RESUMED") {
          _onReady();
        }
    }
  }

  void _identify() {
    _send({
      "op": 2,
      "d": {
        "token": token,
        "capabilities": 65,
        "properties": {"os": "Android", "browser": "Discord Android", "device": "Namp"},
        "presence": {"status": status, "since": 0, "activities": <dynamic>[], "afk": true},
        "compress": false,
      },
    });
  }

  void _onReady() {
    _ready = true;
    _reconnectAttempts = 0;
    _log.info("Gateway ready");
    // force the current activity to be (re)sent on the new session
    _sentKey = null;
    _sentStart = null;
    _scheduleSend();
  }

  void _startHeartbeat(int intervalMs) {
    _heartbeatTimer?.cancel();
    _heartbeatAcked = true;
    // first beat after a random fraction of the interval, as the docs ask
    _heartbeatTimer = Timer(Duration(milliseconds: (intervalMs * Random().nextDouble()).toInt()), () {
      if (_socket == null) return;
      _send({"op": 1, "d": _seq});
      _heartbeatTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
        if (!_heartbeatAcked) {
          _log.warning("Heartbeat not acknowledged, reconnecting");
          _closeSocket(4000).then((_) => _scheduleReconnect());
          return;
        }
        _heartbeatAcked = false;
        _send({"op": 1, "d": _seq});
      });
    });
  }

  // Presence updates

  /// Discord allows about 5 presence updates per 20 seconds per session.
  static const _minSendGap = Duration(seconds: 5);

  void _scheduleSend() {
    if (!_ready) return;
    final wanted = _wanted;
    final key = wanted?.contentKey;
    final startJumped =
        wanted?.startMs != null && (_sentStart == null || (wanted!.startMs! - _sentStart!).abs() > 3000);
    if (key == _sentKey && !startJumped) return;
    if (wanted == null && !_sentSomething) return;

    _sendTimer?.cancel();
    final wait = _minSendGap - DateTime.now().difference(_lastSend);
    _sendTimer = Timer(wait.isNegative ? Duration.zero : wait, () async {
      final activity = _wanted;
      Map<String, dynamic>? json;
      if (activity != null) {
        json = await _activityJson(activity);
      }
      if (!_ready || !identical(activity, _wanted)) {
        // a newer activity arrived while we were resolving images
        _scheduleSend();
        return;
      }
      _sendPresence(json);
      _sentKey = activity?.contentKey;
      _sentStart = activity?.startMs;
    });
  }

  void _sendPresence(Map<String, dynamic>? activity) {
    _lastSend = DateTime.now();
    _sentSomething = activity != null;
    _send({
      "op": 3,
      "d": {
        "since": null,
        "activities": [?activity],
        "status": status,
        "afk": true,
      },
    });
    _log.finer(activity == null ? "Cleared activity" : "Updated activity");
  }

  Future<Map<String, dynamic>> _activityJson(DiscordPresenceActivity a) async {
    final large = await _resolveImage(a.largeImage);
    final small = await _resolveImage(a.smallImage);
    String clip(String s) => s.length > 128 ? "${s.substring(0, 127)}…" : s.padRight(2);
    return {
      "name": a.name,
      "type": 2, // listening
      "application_id": applicationId,
      "details": clip(a.details),
      if (a.state != null && a.state!.isNotEmpty) "state": clip(a.state!),
      if (a.startMs != null || a.endMs != null)
        "timestamps": {if (a.startMs != null) "start": a.startMs, if (a.endMs != null) "end": a.endMs},
      if (large != null || small != null)
        "assets": {
          "large_image": ?large,
          if (large != null && a.largeText != null) "large_text": clip(a.largeText!),
          "small_image": ?small,
          if (small != null && a.smallText != null) "small_text": clip(a.smallText!),
        },
    };
  }

  Map<String, String> get _headers => {
    "Authorization": token,
    "Content-Type": "application/json",
    "User-Agent": "Finamp (https://github.com/jmshrv/finamp)",
  };

  Future<String?> _resolveImage(String? image) async {
    if (image == null || image.isEmpty) return null;
    if (image.startsWith("http://") || image.startsWith("https://")) {
      final cached = _externalAssetCache[image];
      if (cached != null) return cached;
      try {
        final res = await http
            .post(
              Uri.parse("$_api/applications/$applicationId/external-assets"),
              headers: _headers,
              body: jsonEncode({
                "urls": [image],
              }),
            )
            .timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          final list = jsonDecode(res.body) as List;
          final path = (list.first as Map<String, dynamic>)["external_asset_path"] as String?;
          if (path != null) {
            if (_externalAssetCache.length > 200) _externalAssetCache.clear();
            return _externalAssetCache[image] = "mp:$path";
          }
        } else {
          _log.warning("external-assets returned ${res.statusCode}");
        }
      } catch (e) {
        _log.warning("Could not proxy image through Discord: $e");
      }
      return null;
    }
    // an application asset name, which the gateway wants as its numeric id
    if (_appAssets == null) {
      try {
        final res = await http
            .get(Uri.parse("$_api/oauth2/applications/$applicationId/assets"), headers: _headers)
            .timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          _appAssets = {
            for (final a in (jsonDecode(res.body) as List).cast<Map<String, dynamic>>())
              a["name"] as String: a["id"] as String,
          };
        }
      } catch (e) {
        _log.warning("Could not fetch application assets: $e");
      }
    }
    return _appAssets?[image];
  }
}
