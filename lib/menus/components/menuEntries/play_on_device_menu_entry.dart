import 'package:finamp/menus/components/menuEntries/menu_entry.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/screens/remote_control_screen.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../extensions/localizations.dart';

/// Plays a track, album, playlist, artist or genre on another Jellyfin device.
class PlayOnDeviceMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  final BaseItemDto baseItem;

  const PlayOnDeviceMenuEntry({super.key, required this.baseItem});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(finampSettingsProvider.isOffline);
    return MenuEntry(
      icon: Icons.cast,
      title: "Play on another device",
      enabled: !offline,
      tooltip: offline ? context.l10n.notAvailableInOfflineMode : null,
      onTap: () {
        // the sheet needs a context that outlives this menu
        final navigatorContext = Navigator.of(context, rootNavigator: true).context;
        Navigator.pop(context); // close menu
        showPlayOnDeviceSheet(navigatorContext, baseItem);
      },
    );
  }

  @override
  bool get isVisible => true;
}
