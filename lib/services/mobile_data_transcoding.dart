import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:finamp/services/data_source_service.dart';
import 'package:finamp/services/external_accounts_store.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:logging/logging.dart';

final _log = Logger("MobileDataTranscoding");

/// "Transcode on mobile data only": stream originals on Wi-Fi/ethernet and
/// switch to the regular transcoding settings (format + bitrate) while the
/// phone is on mobile data.
///
/// The main transcoding switch still wins: if it is on, everything is
/// transcoded regardless of network.
class MobileDataTranscoding {
  MobileDataTranscoding._();

  static bool _onMobileData = false;
  static bool _lastEffective = false;
  static Timer? _settle;
  static bool _initialized = false;

  /// Whether new queue items should be transcoded right now.
  static bool get shouldTranscode {
    if (FinampSettingsHelper.finampSettings.shouldTranscode) return true;
    if (!_initialized || !ExternalAccountsStore.instance.transcodeOnMobileData) return false;
    return _onMobileData;
  }

  static bool get isOnMobileData => _onMobileData;

  static Future<void> initialize() async {
    if (_initialized || !(Platform.isAndroid || Platform.isIOS)) return;
    _initialized = true;
    try {
      _onMobileData = _isMobile(await Connectivity().checkConnectivity().timeout(const Duration(seconds: 3)));
    } catch (e) {
      _log.warning("Initial connectivity check failed: $e");
    }
    _lastEffective = shouldTranscode;
    Connectivity().onConnectivityChanged.listen((results) {
      // Wi-Fi to mobile hand-overs report a few short-lived states; wait for
      // the network to settle so the queue is not reloaded several times.
      _settle?.cancel();
      _settle = Timer(const Duration(seconds: 8), () {
        _onMobileData = _isMobile(results);
        _reEvaluate();
      });
    });
    ExternalAccountsStore.instance.addListener(_reEvaluate);
    FinampSettingsHelper.finampSettingsListener.addListener(_reEvaluate);
  }

  static bool _isMobile(List<ConnectivityResult> results) =>
      results.contains(ConnectivityResult.mobile) &&
      !results.contains(ConnectivityResult.wifi) &&
      !results.contains(ConnectivityResult.ethernet);

  static void _reEvaluate() {
    final effective = shouldTranscode;
    if (effective == _lastEffective) return;
    _lastEffective = effective;
    // The main switch has its own reload handling in DataSourceService.
    if (FinampSettingsHelper.finampSettings.shouldTranscode) return;
    _log.info(effective ? "On mobile data, switching to transcoding" : "Off mobile data, switching to direct play");
    DataSourceService.notifyTranscodingChanged(effective);
  }
}
