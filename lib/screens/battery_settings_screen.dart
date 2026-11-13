import 'dart:io';

import 'package:finamp/components/finamp_app_bar_back_button.dart';
import 'package:finamp/services/battery_saver.dart';
import 'package:finamp/services/external_accounts_store.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class BatterySettingsScreen extends ConsumerWidget {
  const BatterySettingsScreen({super.key});
  static const routeName = "/settings/battery";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(externalAccountsProvider);
    final saver = ref.watch(batterySaverProvider);
    final theme = Theme.of(context);

    Widget note(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Text(text, style: theme.textTheme.bodySmall),
    );

    return Scaffold(
      appBar: AppBar(title: const Text("Battery"), leading: FinampAppBarBackButton()),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 200.0),
        children: [
          ListTile(
            leading: const Icon(Icons.battery_saver_outlined),
            title: const Text("Battery saver"),
            subtitle: Text(saver.active ? "Active now" : "Not active"),
            trailing: DropdownButton<BatterySaverMode>(
              value: store.batterySaverMode,
              onChanged: (m) => m == null ? null : store.setBatterySaverMode(m),
              items: [
                for (final m in BatterySaverMode.values)
                  DropdownMenuItem(
                    value: m,
                    child: Text(m == BatterySaverMode.followSystem ? "With Android" : m.label),
                  ),
              ],
            ),
          ),
          note(
            "While active: the remote-control (Play On) connection to your server closes after 3 minutes "
            "with nothing playing instead of pinging it every 30 seconds, the playing animations and "
            "scrolling titles stop, and Discord status refreshes less often. "
            "\"With Android\" follows the system Battery Saver.",
          ),
          if (Platform.isAndroid) ...[
            const Divider(),
            SwitchListTile.adaptive(
              secondary: const Icon(Icons.memory_outlined),
              title: const Text("Audio offloading"),
              subtitle: const Text("Let the phone's audio chip decode instead of the CPU. Restart the app to apply."),
              value: ref.watch(finampSettingsProvider.forceAudioOffloadingOnAndroid),
              onChanged: FinampSetters.setForceAudioOffloadingOnAndroid,
            ),
            note(
              "Usually the biggest saving with the screen off, especially for downloaded or untranscoded tracks. "
              "Some phones have glitches with it (gaps between tracks, volume jumps); turn it off again if so.",
            ),
          ],
          const Divider(),
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.cast_outlined),
            title: const Text("Remote control (Play On)"),
            subtitle: const Text("Lets other Jellyfin apps control this phone. Off saves the most."),
            value: ref.watch(finampSettingsProvider.enablePlayon),
            onChanged: FinampSetters.setEnablePlayon,
          ),
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.stop_circle_outlined),
            title: const Text("Release the player when paused"),
            subtitle: const Text("Lets Android put the app to sleep while paused (applies after a restart)."),
            value: ref.watch(finampSettingsProvider.androidStopForegroundOnPause),
            onChanged: FinampSetters.setAndroidStopForegroundOnPause,
          ),
        ],
      ),
    );
  }
}
