import 'dart:async';
import 'dart:core';
import 'dart:io';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/discord_gateway_presence.dart';
import 'package:finamp/services/external_accounts_store.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

Logger _rpcLogger = Logger("DiscordRPC");
bool lastState = false;
Timer? _timer;
final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
final _finampUserHelper = GetIt.instance<FinampUserHelper>();
BaseItemDto? artistItem;

enum _RpcStatus { running, transition, stopped }

_RpcStatus _status = _RpcStatus.stopped;
_RpcStatus _targetStatus = _RpcStatus.stopped;

// Chaphasilor owns the Discord App in case of any issues with that :)
const _discordAppId = "1397542416201945221";

class DiscordRpc {
  static void initialize() {
    if (Platform.isAndroid) {
      _AndroidRpc.initialize();
      return;
    }
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      _rpcLogger.warning("Discord RPC is only supported on Desktop platforms, skipping initialization.");
      return;
    }

    var settingsListener = FinampSettingsHelper.finampSettingsListener;
    FlutterDiscordRPC.initialize(_discordAppId);
    settingsListener.addListener(_reEvaluate);
    _reEvaluate();
    _rpcLogger.info("Initialized");
  }

  static void _reEvaluate() {
    final enabled = FinampSettingsHelper.finampSettings.rpcEnabled;
    final offline = FinampSettingsHelper.finampSettings.isOffline;
    (enabled && !offline) ? start() : stop();
  }

  static Future<void> start() async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }
    _targetStatus = _RpcStatus.running;
    if (_status == _RpcStatus.stopped) {
      _status = _RpcStatus.transition;
      _rpcLogger.info("Starting RPC");

      try {
        await FlutterDiscordRPC.instance.connect(autoRetry: true, retryDelay: Duration(seconds: 3));
        await FlutterDiscordRPC.instance.clearActivity();
      } catch (e) {
        _rpcLogger.severe("Failed to Start", e);
        await stop(force: true);
        return;
      }

      // wait for connection to update RPC and start Interval
      StreamSubscription<bool>? isConnectedStreamSubscription;
      isConnectedStreamSubscription = FlutterDiscordRPC.instance.isConnectedStream.listen((connected) {
        isConnectedStreamSubscription?.cancel();
        if (connected) {
          updateRPC();
          // updates the rpc regularly to fix potential desyncs, keeps connection alive and also to prevent ratelimiting
          // From my research the most mentioned ratelimit is 15 seconds (though inconsistently? a lot of the time rpc can be updated faster, just not all the time)
          // One of the repos which mention 15 seconds is this one: https://github.com/dhinakg/vm-rpc
          // I couldn't find any official ratelimit regarding RPC :/
          _timer = Timer.periodic(Duration(seconds: 15), (timer) => updateRPC());
          _rpcLogger.info("Connected, ${FlutterDiscordRPC.instance.isConnected}");
        }
      });

      _status = _RpcStatus.running;

      if (_targetStatus == _RpcStatus.stopped) await stop();
    }
  }

  static Future<void> stop({bool force = false}) async {
    if (Platform.isAndroid) {
      await _AndroidRpc.stop();
      return;
    }
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }
    _targetStatus = _RpcStatus.stopped;
    if (_status == _RpcStatus.running || force) {
      _rpcLogger.info("Stopping RPC");

      _status = _RpcStatus.transition;
      _timer?.cancel();
      _timer = null;
      artistItem = null;

      try {
        if (FlutterDiscordRPC.instance.isConnected) {
          await FlutterDiscordRPC.instance.clearActivity();
          await FlutterDiscordRPC.instance.disconnect();
        }
        await FlutterDiscordRPC.instance.dispose();
      } catch (e) {
        _rpcLogger.severe("Failed to Stop", e);
      }

      _status = _RpcStatus.stopped;

      if (_targetStatus == _RpcStatus.running) await start();
    }
  }

  static Future<void> updateRPC() async {
    if (Platform.isAndroid) {
      // fire and forget: connecting to the gateway must not hold up playback reporting
      unawaited(_AndroidRpc.update());
      return;
    }
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }
    if (!FlutterDiscordRPC.instance.isConnected) return;
    RPCActivity? currentState;
    try {
      currentState = await _render();
    } catch (e) {
      _rpcLogger.warning("Something went wrong during RPC rendering", e);
      return;
    }

    if (currentState == null) {
      if (lastState) {
        _rpcLogger.finer("Not playing anymore, clearing activity");
        await FlutterDiscordRPC.instance.clearActivity();
        lastState = false;
      }
      return;
    }

    await FlutterDiscordRPC.instance.setActivity(activity: currentState);
    lastState = true;

    _rpcLogger.finest("Updated");
  }

  /// Known limitations:
  /// - may not work on custom DNS
  /// - may not work for selfhosted VPNs depending on configuration
  ///
  /// Only Matches:
  ///
  /// *Note: `.X` values **ARENT** validated.*
  ///
  /// - `127.X.X.X`
  /// - `172.16.X.X` - `172.19.X.X` - `172.20.X.X` - `172.29.X.X` - `172.30.X.X` - `172.31.X.X`
  /// - `192.168.X.X`
  static bool isAddressInLocalAddressRange(String address) {
    // regex from https://stackoverflow.com/a/2814102
    final regex = RegExp(r"(^127\.)|(^10\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^192\.168\.)");
    // 100.64.0.0/10 is CGNAT space, which is what Tailscale and similar VPNs hand out
    final cgnat = RegExp(r"^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.");
    final host = Uri.parse(address).host;
    final isPrivateIp = regex.hasMatch(host) || cgnat.hasMatch(host);
    final isPrivateDomain =
        host.split('.').length == 1 || // match something like `jellyfin:8096`
        host.endsWith(".ts.net") ||
        host.endsWith(".local") ||
        host.endsWith(".lan");
    return isPrivateIp || isPrivateDomain;
  }

  static (String?, String) _fetchImageUrls(BaseItemDto baseItem) {
    String? smallImage;
    String? largeImage;

    final activeAddress = _finampUserHelper.currentUser!.baseURL;
    final activeAddressIsPrivate = isAddressInLocalAddressRange(activeAddress);

    bool forcePublicAddress = false;
    bool skipUrlGetting = false;

    if (activeAddressIsPrivate) {
      final publicAddress = _finampUserHelper.currentUser!.publicAddress;
      final publicAddressIsPrivate = isAddressInLocalAddressRange(publicAddress);
      forcePublicAddress = true;
      skipUrlGetting = publicAddressIsPrivate;
    }

    if (!skipUrlGetting) {
      smallImage = artistItem == null
          ? null
          : _jellyfinApiHelper
                .getImageUrl(item: artistItem!, maxHeight: 128, maxWidth: 128, forcePublicAddress: forcePublicAddress)
                ?.toString();
      largeImage = _jellyfinApiHelper
          .getImageUrl(item: baseItem, maxHeight: 128, maxWidth: 128, forcePublicAddress: forcePublicAddress)
          ?.toString();
    }

    largeImage ??= FinampSettingsHelper.finampSettings.rpcIcon.toString();

    return (smallImage, largeImage);
  }

  static Future<RPCActivity?> _render() async {
    final data = await _renderData();
    if (data == null) return null;
    return RPCActivity(
      activityType: ActivityType.listening,
      details: data.title,
      state: data.artist,
      assets: RPCAssets(
        smallImage: data.smallImage,
        smallText: data.smallImage == null ? null : data.artist,
        largeImage: data.largeImage,
        largeText: data.album,
      ),
      timestamps: RPCTimestamps(start: data.startSeconds, end: data.endSeconds),
    );
  }

  /// Platform-neutral description of what is playing, or null when paused.
  static Future<_NowPlaying?> _renderData() async {
    final audioService = GetIt.instance<MusicPlayerBackgroundTask>();
    final playbackState = audioService.playbackState.valueOrNull;
    final mediaItem = audioService.mediaItem.valueOrNull;

    if (playbackState?.playing == null || !playbackState!.playing || mediaItem == null) {
      return null;
    }

    final baseItem = BaseItemDto.fromJson(mediaItem.extras!["itemJson"] as Map<String, dynamic>);

    final firstArtist = baseItem.artistItems?.firstOrNull;
    if (firstArtist == null) {
      artistItem = null;
    } else if (artistItem == null || !baseItem.artistItems!.any((v) => v.id == artistItem?.id)) {
      try {
        artistItem = await _jellyfinApiHelper.getItemById(firstArtist.id);
      } catch (e) {
        artistItem = null;
      }
    }

    final now = (DateTime.now().millisecondsSinceEpoch / 1000).truncate();
    final progress = playbackState.position.inSeconds;
    final duration = mediaItem.duration?.inSeconds;

    final images = _fetchImageUrls(baseItem);
    return _NowPlaying(
      title: mediaItem.title,
      artist: mediaItem.artist,
      album: mediaItem.album,
      smallImage: images.$1,
      largeImage: images.$2,
      startSeconds: now - progress,
      endSeconds: duration == null ? null : now + (duration - progress),
    );
  }
}

class _NowPlaying {
  const _NowPlaying({
    required this.title,
    this.artist,
    this.album,
    this.smallImage,
    required this.largeImage,
    required this.startSeconds,
    this.endSeconds,
  });

  final String title;
  final String? artist;
  final String? album;
  final String? smallImage;
  final String largeImage;
  final int startSeconds;
  final int? endSeconds;
}

/// Android has no Discord RPC socket, so presence goes through the Discord
/// gateway with the user's own account (see [DiscordGatewayPresence]).
///
/// Uses the same "Discord RPC" toggle and icon setting as desktop, plus a
/// Discord login stored in [ExternalAccountsStore]. The gateway is only kept
/// open while something is playing, and closed a while after playback stops.
class _AndroidRpc {
  static DiscordGatewayPresence? _gateway;
  static Timer? _idleTimer;
  static Timer? _refreshTimer;
  static bool _enabled = false;

  static const _idleDisconnect = Duration(minutes: 2);

  static void initialize() {
    FinampSettingsHelper.finampSettingsListener.addListener(_reEvaluate);
    ExternalAccountsStore.instance.addListener(_reEvaluate);
    _reEvaluate();
    _rpcLogger.info("Initialized Android gateway presence");
  }

  static void _reEvaluate() {
    final settings = FinampSettingsHelper.finampSettings;
    final store = ExternalAccountsStore.instance;
    final token = store.discordToken;
    final enabled = settings.rpcEnabled && !settings.isOffline && token != null && token.isNotEmpty;

    if (_gateway != null && (!enabled || _gateway!.token != token || _gateway!.status != store.discordStatus)) {
      // recreated on the next update with the new token/status
      stop();
    }
    if (enabled && !_enabled) {
      _enabled = true;
      _refreshTimer?.cancel();
      // cheap: the gateway client drops updates that change nothing
      _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) => update());
      update();
    } else if (!enabled && _enabled) {
      _enabled = false;
      _refreshTimer?.cancel();
      _refreshTimer = null;
    } else if (enabled && _gateway == null) {
      update();
    }
  }

  static Future<void> stop() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final gateway = _gateway;
    _gateway = null;
    artistItem = null;
    await gateway?.stop();
  }

  static Future<void> update() async {
    if (!_enabled) return;
    _NowPlaying? data;
    try {
      data = await DiscordRpc._renderData();
    } catch (e) {
      _rpcLogger.warning("Something went wrong during RPC rendering", e);
      return;
    }

    if (data == null) {
      _gateway?.setActivity(null);
      if (_gateway != null && _idleTimer == null) {
        _idleTimer = Timer(_idleDisconnect, () {
          _idleTimer = null;
          stop();
        });
      }
      return;
    }

    _idleTimer?.cancel();
    _idleTimer = null;
    final store = ExternalAccountsStore.instance;
    final token = store.discordToken;
    if (token == null) return;
    if (_gateway == null) {
      final gateway = DiscordGatewayPresence(
        token: token,
        applicationId: _discordAppId,
        status: store.discordStatus,
        onUser: (name) {
          if (store.discordUser != name && store.discordToken == token) {
            store.setDiscordAccount(token, name);
          }
        },
        onAuthFailed: () {
          _rpcLogger.severe("Discord token rejected, clearing it");
          if (store.discordToken == token) store.setDiscordAccount(null, null);
        },
      );
      _gateway = gateway;
      await gateway.start();
    }
    _gateway?.setActivity(
      DiscordPresenceActivity(
        name: "Namp",
        details: data.title,
        state: data.artist,
        largeImage: data.largeImage,
        largeText: data.album,
        smallImage: data.smallImage,
        smallText: data.smallImage == null ? null : data.artist,
        startMs: data.startSeconds * 1000,
        endMs: data.endSeconds == null ? null : data.endSeconds! * 1000,
      ),
    );
  }
}
