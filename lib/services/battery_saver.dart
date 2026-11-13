import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:finamp/services/external_accounts_store.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/playon_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

final _log = Logger("BatterySaver");

enum BatterySaverMode {
  off,
  followSystem,
  on;

  String get label => switch (this) {
    off => "Off",
    followSystem => "When Android's Battery Saver is on",
    on => "Always",
  };
}

/// Cuts background work that keeps the phone awake:
/// - closes the Play On (remote control) connection to the server after a
///   few minutes with nothing playing, instead of pinging it every 30 s
///   forever; it reconnects when playback starts or the app is opened
/// - stops the "now playing" animations and scrolling titles
/// - refreshes Discord presence less often
class BatterySaver extends ChangeNotifier with WidgetsBindingObserver {
  BatterySaver._();

  static final instance = BatterySaver._();

  static const _idleBeforeSuspend = Duration(minutes: 3);

  bool _systemSaver = false;
  bool _active = false;
  bool _playing = false;
  Timer? _idleTimer;
  bool _initialized = false;

  ExternalAccountsStore get _store => ExternalAccountsStore.instance;

  BatterySaverMode get mode => _store.batterySaverMode;

  /// Whether battery saving behaviour is currently on.
  bool get active => _active;

  bool get systemSaverOn => _systemSaver;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    _store.addListener(_recompute);
    await _checkSystemSaver();
    _recompute();

    final audio = GetIt.instance<MusicPlayerBackgroundTask>();
    audio.playbackState.listen(_onPlaybackState);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkSystemSaver().then((_) => _recompute()));
      // opening the app counts as activity: bring remote control back
      _resumePlayOn();
      _scheduleIdleSuspend();
    }
  }

  Future<void> _checkSystemSaver() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      _systemSaver = await Battery().isInBatterySaveMode;
    } catch (e) {
      _log.fine("Could not read battery saver state: $e");
    }
  }

  void _recompute() {
    final active = switch (mode) {
      BatterySaverMode.off => false,
      BatterySaverMode.on => true,
      BatterySaverMode.followSystem => _systemSaver,
    };
    if (active != _active) {
      _active = active;
      _log.info("Battery saver ${active ? "on" : "off"}");
      if (!active) _resumePlayOn();
      _scheduleIdleSuspend();
    }
    notifyListeners();
  }

  void _onPlaybackState(PlaybackState state) {
    final playing = state.playing;
    if (playing == _playing) return;
    _playing = playing;
    if (playing) {
      unawaited(_checkSystemSaver().then((_) => _recompute()));
      _resumePlayOn();
    }
    _scheduleIdleSuspend();
  }

  void _scheduleIdleSuspend() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (!_active || _playing) return;
    _idleTimer = Timer(_idleBeforeSuspend, () {
      _idleTimer = null;
      if (!_active || _playing) return;
      final playOn = GetIt.instance<PlayOnService>();
      if (playOn.isControlled) return; // someone is remote controlling us right now
      playOn.suspendForBattery();
    });
  }

  void _resumePlayOn() {
    if (!GetIt.instance.isRegistered<PlayOnService>()) return;
    GetIt.instance<PlayOnService>().resumeFromBattery();
  }
}

final batterySaverProvider = ChangeNotifierProvider<BatterySaver>((ref) => BatterySaver.instance);

/// True while battery saver wants animations stopped.
final reduceAnimationsProvider = Provider<bool>((ref) => ref.watch(batterySaverProvider).active);
