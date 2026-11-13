import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rxdart/rxdart.dart';

/// Whether the app's UI is on screen, for pausing UI-only timers.
///
/// Widgets stay mounted while the app is in the background (the player keeps
/// the process alive), and so do their stream subscriptions: the playback
/// position stream alone ticks up to 5 times a second. Streams wrapped with
/// [gate] stop entirely while the UI is hidden and restart when it returns.
class AppForeground with WidgetsBindingObserver {
  AppForeground._();

  static final _instance = AppForeground._();
  static final BehaviorSubject<bool> _visible = BehaviorSubject.seeded(true);

  static bool get isVisible => _visible.value;
  static Stream<bool> get visibleStream => _visible.stream.distinct();

  static void initialize() {
    WidgetsBinding.instance.addObserver(_instance);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible.add(state == AppLifecycleState.resumed || state == AppLifecycleState.inactive);
  }

  /// [source] while the UI is visible, nothing while it is hidden.
  static Stream<T> gate<T>(Stream<T> Function() source) =>
      visibleStream.switchMap((visible) => visible ? source() : Stream<T>.empty());

  /// Playback position for UI, paused while the app is in the background.
  static Stream<Duration> get position => gate(() => AudioService.position);

  /// One shared once-a-minute tick for relative dates ("5 minutes ago"),
  /// paused in the background, instead of one timer per list item.
  static final Stream<DateTime> minuteTicker = gate(
    () => Stream.periodic(const Duration(minutes: 1), (_) => DateTime.now()),
  ).asBroadcastStream(onListen: (sub) => sub.resume(), onCancel: (sub) => sub.pause());
}

final appVisibleProvider = StreamProvider<bool>((ref) => AppForeground.visibleStream);
