import 'dart:async';

import 'package:finamp/components/album_image.dart';
import 'package:finamp/components/finamp_app_bar_back_button.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/app_foreground.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/remote_control_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

IconData remoteDeviceIcon(RemoteSession s) {
  final c = "${s.client} ${s.deviceName}".toLowerCase();
  if (c.contains("tv") || c.contains("kodi") || c.contains("roku") || c.contains("fire")) return Icons.tv;
  if (c.contains("web") || c.contains("chrome") || c.contains("firefox") || c.contains("safari")) {
    return Icons.language;
  }
  if (c.contains("media player") || c.contains("desktop") || c.contains("windows") || c.contains("linux")) {
    return Icons.computer;
  }
  if (c.contains("android") ||
      c.contains("ios") ||
      c.contains("iphone") ||
      c.contains("amp") ||
      c.contains("finamp") ||
      c.contains("phone")) {
    return Icons.smartphone;
  }
  return Icons.devices_other;
}

String formatRemoteDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, "0");
  return h > 0 ? "$h:${m.toString().padLeft(2, "0")}:$s" : "$m:$s";
}

String _artists(BaseItemDto item) {
  final a = item.artists ?? (item.albumArtist != null ? [item.albumArtist!] : const <String>[]);
  return a.join(", ");
}

void _showError(Object e) {
  GlobalSnackbar.message((_) => "Device didn't respond: $e");
}

/// Lists the user's other Jellyfin players and opens a remote for each.
class RemoteControlScreen extends ConsumerStatefulWidget {
  const RemoteControlScreen({super.key});
  static const routeName = "/remote-control";

  @override
  ConsumerState<RemoteControlScreen> createState() => _RemoteControlScreenState();
}

class _RemoteControlScreenState extends ConsumerState<RemoteControlScreen> {
  late final RemoteSessionsController _controller = RemoteSessionsController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(finampSettingsProvider.isOffline);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Control devices"),
        leading: FinampAppBarBackButton(),
        actions: [IconButton(tooltip: "Refresh", icon: const Icon(Icons.refresh), onPressed: _controller.refresh)],
      ),
      body: offline
          ? const _CenteredNote(
              icon: Icons.cloud_off,
              text: "Controlling other devices needs the server. Leave offline mode first.",
            )
          : ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                if (_controller.loading) return const Center(child: CircularProgressIndicator());
                final sessions = _controller.sessions;
                if (sessions.isEmpty) {
                  return RefreshIndicator(
                    onRefresh: _controller.refresh,
                    child: ListView(
                      children: [
                        const SizedBox(height: 120),
                        _CenteredNote(
                          icon: _controller.error != null ? Icons.error_outline : Icons.cast,
                          text: _controller.error != null
                              ? "Could not load devices: ${_controller.error}"
                              : "No other Jellyfin apps are open on your account right now.\n\n"
                                    "Open Jellyfin on your TV, computer or another phone and it shows up here. "
                                    "The app has to allow remote control (most official apps do).",
                        ),
                      ],
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: _controller.refresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 200),
                    itemCount: sessions.length,
                    itemBuilder: (context, i) => _SessionTile(controller: _controller, session: sessions[i]),
                  ),
                );
              },
            ),
      bottomNavigationBar: offline
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  "Shows Jellyfin apps signed in to your account in the last 15 minutes.",
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
    );
  }
}

class _CenteredNote extends StatelessWidget {
  const _CenteredNote({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.controller, required this.session});
  final RemoteSessionsController controller;
  final RemoteSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final item = s.nowPlaying;
    final theme = Theme.of(context);
    final subtitle = item == null
        ? "${s.client}${s.userName != null ? " · ${s.userName}" : ""} · Nothing playing"
        : [item.name ?? "", _artists(item)].where((e) => e.isNotEmpty).join(" · ");

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        leading: item != null
            ? SizedBox(
                width: 48,
                height: 48,
                child: AlbumImage(item: item, borderRadius: BorderRadius.circular(6)),
              )
            : SizedBox(width: 48, height: 48, child: Icon(remoteDeviceIcon(s), size: 30)),
        title: Row(
          children: [
            if (item != null) ...[Icon(remoteDeviceIcon(s), size: 16), const SizedBox(width: 6)],
            Flexible(child: Text(s.deviceName, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: item == null ? theme.textTheme.bodySmall : null,
        ),
        trailing: item != null && s.supportsMediaControl
            ? IconButton(
                tooltip: s.isPaused ? "Play" : "Pause",
                icon: Icon(s.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 32),
                onPressed: () => controller
                    .run(s.id, (api) => api.playPause(s.id), optimistic: (x) => x.copyWith(isPaused: !s.isPaused))
                    .catchError(_showError),
              )
            : const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: RemoteSessionScreen.routeName),
            builder: (_) => RemoteSessionScreen(controller: controller, sessionId: s.id),
          ),
        ),
      ),
    );
  }
}

/// Remote for one device: what it plays, seek, transport, volume, modes.
class RemoteSessionScreen extends StatefulWidget {
  const RemoteSessionScreen({super.key, required this.controller, required this.sessionId});
  static const routeName = "/remote-control/session";

  final RemoteSessionsController controller;
  final String sessionId;

  @override
  State<RemoteSessionScreen> createState() => _RemoteSessionScreenState();
}

class _RemoteSessionScreenState extends State<RemoteSessionScreen> {
  Timer? _ticker;
  double? _dragPosition; // seconds, while the user drags the seek bar
  double? _dragVolume;
  bool _sending = false;
  RemoteSession? _last;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onUpdate);
    _sync();
  }

  void _onUpdate() {
    _sync();
    if (mounted) setState(() {});
  }

  void _sync() {
    final s = widget.controller.byId(widget.sessionId);
    if (s != null) _last = s;
    final ticking = s != null && s.isPlaying && !s.isPaused;
    if (ticking && _ticker == null) {
      // moves the seek bar between polls; skipped while the app is hidden
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted && _dragPosition == null && AppForeground.isVisible) setState(() {});
      });
    } else if (!ticking) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onUpdate);
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function(RemoteControlService) action, {
    RemoteSession Function(RemoteSession)? optimistic,
  }) async {
    try {
      await widget.controller.run(widget.sessionId, action, optimistic: optimistic);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _transfer() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final ok = await widget.controller.transferQueue(widget.sessionId);
      if (!ok) {
        GlobalSnackbar.message((_) => "Nothing is queued in Namp to send.");
      } else {
        GlobalSnackbar.message((_) => "Sent to ${_last?.deviceName ?? "device"}", isConfirmation: true);
      }
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.controller.byId(widget.sessionId);
    final s = live ?? _last;
    final theme = Theme.of(context);

    if (s == null) {
      return Scaffold(
        appBar: AppBar(leading: FinampAppBarBackButton()),
        body: const _CenteredNote(icon: Icons.portable_wifi_off, text: "This device is gone."),
      );
    }

    final item = s.nowPlaying;
    final hasQueue = GetIt.instance<QueueService>().getCurrentTrack() != null;
    final media = s.supportsMediaControl;

    return Scaffold(
      appBar: AppBar(
        leading: FinampAppBarBackButton(),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.deviceName, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              [s.client, if (s.applicationVersion != null) s.applicationVersion!].join(" "),
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          children: [
            if (live == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  "This device has stopped answering. It may have closed.",
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320, maxHeight: 320),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: item != null
                      ? AlbumImage(item: item, borderRadius: BorderRadius.circular(12))
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(remoteDeviceIcon(s), size: 96, color: theme.colorScheme.outline),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              item?.name ?? "Nothing playing",
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (item != null) ...[
              const SizedBox(height: 4),
              Text(
                [_artists(item), item.album ?? ""].where((e) => e.isNotEmpty).join(" · "),
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              _seekBar(s),
              const SizedBox(height: 4),
              _transport(s, media),
              const SizedBox(height: 8),
              if (s.canShuffle || s.canRepeat) _modes(s),
            ],
            if (s.canSetVolume || s.canMute) ...[const SizedBox(height: 12), _volume(s)],
            if (!media && item != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  "This app shares what it plays but doesn't accept playback commands.",
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: 24),
            if (s.canPlayAudio)
              FilledButton.tonalIcon(
                onPressed: hasQueue && !_sending ? _transfer : null,
                icon: _sending
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cast),
                label: const Text("Play my Namp queue here"),
              ),
            if (s.canPlayAudio)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  hasQueue
                      ? "Starts your current queue on this device where you are, and pauses Namp."
                      : "Start something in Namp first, or long-press any track or album and pick \"Play on another device\".",
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _seekBar(RemoteSession s) {
    final duration = s.duration;
    final total = duration == null || duration <= Duration.zero ? null : duration.inMilliseconds / 1000.0;
    final pos = (_dragPosition ?? s.position.inMilliseconds / 1000.0).clamp(0.0, total ?? double.infinity);
    final theme = Theme.of(context);
    return Column(
      children: [
        Slider(
          value: total == null ? 0 : pos.toDouble(),
          max: total ?? 1,
          onChanged: total == null || !s.canSeek || !s.supportsMediaControl
              ? null
              : (v) => setState(() => _dragPosition = v),
          onChangeEnd: total == null || !s.canSeek || !s.supportsMediaControl
              ? null
              : (v) {
                  final target = Duration(milliseconds: (v * 1000).round());
                  setState(() => _dragPosition = null);
                  _run(
                    (api) => api.seek(s.id, target),
                    optimistic: (x) => x.copyWith(positionTicks: durationToTicks(target)),
                  );
                },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                formatRemoteDuration(Duration(milliseconds: (pos * 1000).round())),
                style: theme.textTheme.bodySmall,
              ),
              Text(duration == null ? "--:--" : formatRemoteDuration(duration), style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }

  Widget _transport(RemoteSession s, bool enabled) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          tooltip: "Stop",
          iconSize: 30,
          icon: const Icon(Icons.stop_rounded),
          onPressed: enabled ? () => _run((api) => api.stop(s.id)) : null,
        ),
        IconButton(
          tooltip: "Previous",
          iconSize: 40,
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: enabled ? () => _run((api) => api.previous(s.id)) : null,
        ),
        IconButton.filled(
          tooltip: s.isPaused ? "Play" : "Pause",
          iconSize: 48,
          icon: Icon(s.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded),
          onPressed: enabled
              ? () => _run((api) => api.playPause(s.id), optimistic: (x) => x.copyWith(isPaused: !s.isPaused))
              : null,
        ),
        IconButton(
          tooltip: "Next",
          iconSize: 40,
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: enabled ? () => _run((api) => api.next(s.id)) : null,
        ),
        // keeps the row symmetric around play/pause
        const SizedBox(width: 48),
      ],
    );
  }

  Widget _modes(RemoteSession s) {
    final active = Theme.of(context).colorScheme.primary;
    final shuffled = s.shuffled ?? false;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (s.canShuffle)
          IconButton(
            tooltip: shuffled ? "Shuffle on" : "Shuffle off",
            icon: Icon(shuffled ? Icons.shuffle_on_rounded : Icons.shuffle_rounded, color: shuffled ? active : null),
            onPressed: () =>
                _run((api) => api.setShuffle(s, !shuffled), optimistic: (x) => x.copyWith(shuffled: !shuffled)),
          ),
        const SizedBox(width: 24),
        if (s.canRepeat)
          IconButton(
            tooltip: switch (s.repeatMode) {
              RemoteRepeatMode.none => "Repeat off",
              RemoteRepeatMode.all => "Repeat all",
              RemoteRepeatMode.one => "Repeat one",
            },
            icon: Icon(switch (s.repeatMode) {
              RemoteRepeatMode.none => Icons.repeat_rounded,
              RemoteRepeatMode.all => Icons.repeat_on_rounded,
              RemoteRepeatMode.one => Icons.repeat_one_on_rounded,
            }, color: s.repeatMode == RemoteRepeatMode.none ? null : active),
            onPressed: () {
              final next = s.repeatMode.next;
              _run((api) => api.setRepeatMode(s.id, next), optimistic: (x) => x.copyWith(repeatMode: next));
            },
          ),
      ],
    );
  }

  Widget _volume(RemoteSession s) {
    final volume = (_dragVolume ?? (s.volumeLevel ?? 100).toDouble()).clamp(0.0, 100.0);
    return Row(
      children: [
        IconButton(
          tooltip: s.isMuted ? "Unmute" : "Mute",
          icon: Icon(
            s.isMuted ? Icons.volume_off_rounded : (volume < 40 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
          ),
          onPressed: s.canMute
              ? () => _run(
                  (api) => s.supports("Mute") && s.supports("Unmute")
                      ? api.setMuted(s.id, !s.isMuted)
                      : api.toggleMute(s.id),
                  optimistic: (x) => x.copyWith(isMuted: !s.isMuted),
                )
              : null,
        ),
        Expanded(
          child: Slider(
            value: volume,
            max: 100,
            divisions: 50,
            label: "${volume.round()}%",
            onChanged: s.canSetVolume ? (v) => setState(() => _dragVolume = v) : null,
            onChangeEnd: s.canSetVolume
                ? (v) {
                    setState(() => _dragVolume = null);
                    final level = v.round();
                    _run((api) => api.setVolume(s.id, level), optimistic: (x) => x.copyWith(volumeLevel: level));
                  }
                : null,
          ),
        ),
        SizedBox(width: 40, child: Text("${volume.round()}%", textAlign: TextAlign.end)),
      ],
    );
  }
}

/// Bottom sheet that plays [item] (a track, album, playlist, artist or genre)
/// on one of the user's other Jellyfin devices.
Future<void> showPlayOnDeviceSheet(BuildContext context, BaseItemDto item) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _PlayOnDeviceSheet(item: item),
  );
}

class _PlayOnDeviceSheet extends StatefulWidget {
  const _PlayOnDeviceSheet({required this.item});
  final BaseItemDto item;

  @override
  State<_PlayOnDeviceSheet> createState() => _PlayOnDeviceSheetState();
}

class _PlayOnDeviceSheetState extends State<_PlayOnDeviceSheet> {
  late final Future<List<RemoteSession>> _sessions = RemoteControlService.instance.fetchSessions();
  RemotePlayCommand _command = RemotePlayCommand.playNow;
  String? _sendingTo;

  Future<void> _play(RemoteSession s) async {
    setState(() => _sendingTo = s.id);
    try {
      await RemoteControlService.instance.playItems(s.id, [widget.item.id], command: _command);
      if (!mounted) return;
      Navigator.of(context).pop();
      final verb = switch (_command) {
        RemotePlayCommand.playNow => "Playing",
        RemotePlayCommand.playNext => "Playing next",
        RemotePlayCommand.playLast => "Added to the queue",
      };
      GlobalSnackbar.message((_) => "$verb on ${s.deviceName}", isConfirmation: true);
    } catch (e) {
      _showError(e);
      if (mounted) setState(() => _sendingTo = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                "Play \"${widget.item.name ?? "this"}\" on",
                style: theme.textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<RemotePlayCommand>(
                segments: const [
                  ButtonSegment(value: RemotePlayCommand.playNow, label: Text("Now")),
                  ButtonSegment(value: RemotePlayCommand.playNext, label: Text("Next")),
                  ButtonSegment(value: RemotePlayCommand.playLast, label: Text("Last")),
                ],
                selected: {_command},
                onSelectionChanged: (v) => setState(() => _command = v.first),
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
              child: FutureBuilder<List<RemoteSession>>(
                future: _sessions,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snap.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text("Could not load devices: ${snap.error}"),
                    );
                  }
                  final sessions = [
                    for (final s in snap.data!)
                      if (s.canPlayAudio) s,
                  ];
                  if (sessions.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        "No other Jellyfin apps that can play music are open on your account.",
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      for (final s in sessions)
                        ListTile(
                          leading: Icon(remoteDeviceIcon(s)),
                          title: Text(s.deviceName),
                          subtitle: Text(
                            s.nowPlaying != null
                                ? "${s.client} · ${s.isPaused ? "Paused" : "Playing"} ${s.nowPlaying!.name ?? ""}"
                                : s.client,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: _sendingTo == s.id
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                              : null,
                          enabled: _sendingTo == null,
                          onTap: () => _play(s),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
