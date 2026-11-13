import 'dart:convert';

import 'package:finamp/services/battery_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds credentials and settings for the third-party services added by this
/// fork (Discord presence on Android, ListenBrainz and Last.fm scrobbling).
///
/// These live in their own SharedPreferences keys instead of the Hive
/// FinampSettings object on purpose: secrets never end up in settings exports
/// or logs, and the fork does not touch upstream's generated settings code,
/// which keeps rebasing onto upstream's beta branch painless.
class ExternalAccountsStore extends ChangeNotifier {
  ExternalAccountsStore._(this._prefs);

  static const _prefix = "finampFork.";
  static const _kDiscordToken = "${_prefix}discordToken";
  static const _kDiscordUser = "${_prefix}discordUser";
  static const _kDiscordStatus = "${_prefix}discordStatus";
  static const _kLbEnabled = "${_prefix}listenBrainzEnabled";
  static const _kLbToken = "${_prefix}listenBrainzToken";
  static const _kLbUser = "${_prefix}listenBrainzUser";
  static const _kLbUrl = "${_prefix}listenBrainzApiUrl";
  static const _kLfmEnabled = "${_prefix}lastFmEnabled";
  static const _kLfmApiKey = "${_prefix}lastFmApiKey";
  static const _kLfmApiSecret = "${_prefix}lastFmApiSecret";
  static const _kLfmSession = "${_prefix}lastFmSessionKey";
  static const _kLfmUser = "${_prefix}lastFmUser";
  static const _kScrobbleQueue = "${_prefix}scrobbleQueue";
  static const _kSendNowPlaying = "${_prefix}scrobbleNowPlaying";
  static const _kTranscodeOnMobile = "${_prefix}transcodeOnMobileData";
  static const _kBatterySaver = "${_prefix}batterySaverMode";

  static const defaultListenBrainzUrl = "https://api.listenbrainz.org";

  final SharedPreferencesWithCache _prefs;

  static Future<ExternalAccountsStore> create() async {
    final prefs = await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(
        allowList: {
          _kDiscordToken,
          _kDiscordUser,
          _kDiscordStatus,
          _kLbEnabled,
          _kLbToken,
          _kLbUser,
          _kLbUrl,
          _kLfmEnabled,
          _kLfmApiKey,
          _kLfmApiSecret,
          _kLfmSession,
          _kLfmUser,
          _kScrobbleQueue,
          _kSendNowPlaying,
          _kTranscodeOnMobile,
          _kBatterySaver,
        },
      ),
    );
    return ExternalAccountsStore._(prefs);
  }

  static ExternalAccountsStore get instance => GetIt.instance<ExternalAccountsStore>();

  Future<void> _setString(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value);
    }
    notifyListeners();
  }

  Future<void> _setBool(String key, bool value) async {
    await _prefs.setBool(key, value);
    notifyListeners();
  }

  // Discord

  String? get discordToken => _prefs.getString(_kDiscordToken);
  String? get discordUser => _prefs.getString(_kDiscordUser);

  /// Status sent with the presence: online, idle, dnd or invisible.
  String get discordStatus => _prefs.getString(_kDiscordStatus) ?? "online";

  Future<void> setDiscordAccount(String? token, String? user) async {
    if (token == null || token.isEmpty) {
      await _prefs.remove(_kDiscordToken);
      await _prefs.remove(_kDiscordUser);
    } else {
      await _prefs.setString(_kDiscordToken, token);
      if (user != null) await _prefs.setString(_kDiscordUser, user);
    }
    notifyListeners();
  }

  Future<void> setDiscordStatus(String status) => _setString(_kDiscordStatus, status);

  // ListenBrainz

  bool get listenBrainzEnabled => _prefs.getBool(_kLbEnabled) ?? false;
  String? get listenBrainzToken => _prefs.getString(_kLbToken);
  String? get listenBrainzUser => _prefs.getString(_kLbUser);
  String get listenBrainzApiUrl => _prefs.getString(_kLbUrl) ?? defaultListenBrainzUrl;
  bool get listenBrainzReady => listenBrainzEnabled && (listenBrainzToken?.isNotEmpty ?? false);

  Future<void> setListenBrainzEnabled(bool v) => _setBool(_kLbEnabled, v);
  Future<void> setListenBrainzApiUrl(String? v) => _setString(_kLbUrl, v);

  Future<void> setListenBrainzAccount(String? token, String? user) async {
    if (token == null || token.isEmpty) {
      await _prefs.remove(_kLbToken);
      await _prefs.remove(_kLbUser);
    } else {
      await _prefs.setString(_kLbToken, token);
      if (user != null) await _prefs.setString(_kLbUser, user);
    }
    notifyListeners();
  }

  // Last.fm

  bool get lastFmEnabled => _prefs.getBool(_kLfmEnabled) ?? false;
  String? get lastFmApiKey => _prefs.getString(_kLfmApiKey);
  String? get lastFmApiSecret => _prefs.getString(_kLfmApiSecret);
  String? get lastFmSessionKey => _prefs.getString(_kLfmSession);
  String? get lastFmUser => _prefs.getString(_kLfmUser);
  bool get lastFmReady =>
      lastFmEnabled &&
      (lastFmApiKey?.isNotEmpty ?? false) &&
      (lastFmApiSecret?.isNotEmpty ?? false) &&
      (lastFmSessionKey?.isNotEmpty ?? false);

  Future<void> setLastFmEnabled(bool v) => _setBool(_kLfmEnabled, v);

  Future<void> setLastFmAccount({
    required String? apiKey,
    required String? apiSecret,
    required String? sessionKey,
    required String? user,
  }) async {
    for (final (key, value) in [
      (_kLfmApiKey, apiKey),
      (_kLfmApiSecret, apiSecret),
      (_kLfmSession, sessionKey),
      (_kLfmUser, user),
    ]) {
      if (value == null || value.isEmpty) {
        await _prefs.remove(key);
      } else {
        await _prefs.setString(key, value);
      }
    }
    notifyListeners();
  }

  // Shared scrobbling options

  bool get sendNowPlaying => _prefs.getBool(_kSendNowPlaying) ?? true;
  Future<void> setSendNowPlaying(bool v) => _setBool(_kSendNowPlaying, v);

  // Playback

  /// Transcode only while on mobile data (see MobileDataTranscoding).
  bool get transcodeOnMobileData => _prefs.getBool(_kTranscodeOnMobile) ?? false;
  Future<void> setTranscodeOnMobileData(bool v) => _setBool(_kTranscodeOnMobile, v);

  BatterySaverMode get batterySaverMode => BatterySaverMode.values.firstWhere(
    (m) => m.name == _prefs.getString(_kBatterySaver),
    orElse: () => BatterySaverMode.followSystem,
  );
  Future<void> setBatterySaverMode(BatterySaverMode m) => _setString(_kBatterySaver, m.name);

  /// Scrobbles that could not be sent yet, oldest first. Each entry is a JSON
  /// object understood by [ScrobbleService].
  List<Map<String, dynamic>> get scrobbleQueue {
    final raw = _prefs.getString(_kScrobbleQueue);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> setScrobbleQueue(List<Map<String, dynamic>> queue) async {
    if (queue.isEmpty) {
      await _prefs.remove(_kScrobbleQueue);
    } else {
      await _prefs.setString(_kScrobbleQueue, jsonEncode(queue));
    }
    notifyListeners();
  }
}

final externalAccountsProvider = ChangeNotifierProvider<ExternalAccountsStore>((ref) => ExternalAccountsStore.instance);
