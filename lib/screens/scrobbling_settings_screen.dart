import 'dart:io';

import 'package:finamp/components/PlaybackReportingSettingsScreen/discord_rpc_icon_selector.dart';
import 'package:finamp/components/PlaybackReportingSettingsScreen/enabled_discord_rpc.dart';
import 'package:finamp/components/finamp_app_bar_back_button.dart';
import 'package:finamp/screens/discord_login_screen.dart';
import 'package:finamp/services/external_accounts_store.dart';
import 'package:finamp/services/scrobble_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:url_launcher/url_launcher.dart';

/// Discord presence and scrobbling (ListenBrainz, Last.fm) in one place.
class ScrobblingSettingsScreen extends ConsumerStatefulWidget {
  const ScrobblingSettingsScreen({super.key});
  static const routeName = "/settings/discord-scrobbling";

  @override
  ConsumerState<ScrobblingSettingsScreen> createState() => _ScrobblingSettingsScreenState();
}

class _ScrobblingSettingsScreenState extends ConsumerState<ScrobblingSettingsScreen> {
  ScrobbleService get _scrobbler => GetIt.instance<ScrobbleService>();

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(externalAccountsProvider);
    final theme = Theme.of(context);
    final hasDesktopRpc = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );

    Widget note(String text) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(text, style: theme.textTheme.bodySmall),
    );

    return Scaffold(
      appBar: AppBar(title: const Text("Discord & scrobbling"), leading: FinampAppBarBackButton()),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 200.0),
        children: [
          header("Discord"),
          if (hasDesktopRpc) ...[
            const EnabledDiscordRpc(),
            const DiscordRpcIconSelector(),
            note("On desktop, presence goes through the Discord app running on this computer."),
          ],
          if (Platform.isAndroid) ...[
            const EnabledDiscordRpc(),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text(
                store.discordToken == null ? "Log in to Discord" : "Logged in as ${store.discordUser ?? "unknown"}",
              ),
              subtitle: Text(
                store.discordToken == null ? "Needed to show what you're playing on your profile" : "Tap to log out",
              ),
              onTap: store.discordToken == null ? _discordLogin : () => store.setDiscordAccount(null, null),
            ),
            if (store.discordToken == null)
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: const Text("Paste a token instead"),
                onTap: _discordPasteToken,
              ),
            ListTile(
              leading: const Icon(Icons.circle_outlined),
              title: const Text("Status while playing"),
              trailing: DropdownButton<String>(
                value: store.discordStatus,
                onChanged: (v) => v == null ? null : store.setDiscordStatus(v),
                items: const [
                  DropdownMenuItem(value: "online", child: Text("Online")),
                  DropdownMenuItem(value: "idle", child: Text("Idle")),
                  DropdownMenuItem(value: "dnd", child: Text("Do not disturb")),
                  DropdownMenuItem(value: "invisible", child: Text("Invisible")),
                ],
              ),
            ),
            const DiscordRpcIconSelector(),
            note(
              "Android has no Discord RPC, so Namp connects to Discord as your account (like Kizzy does). "
              "Discord's terms do not allow automating user accounts; use at your own risk. "
              "Album art only shows if your server has a public address Discord can reach.",
            ),
          ],
          if (!hasDesktopRpc && !Platform.isAndroid) note("Discord presence is not available on this platform."),

          header("ListenBrainz"),
          SwitchListTile.adaptive(
            title: const Text("Scrobble to ListenBrainz"),
            value: store.listenBrainzEnabled,
            onChanged: store.setListenBrainzEnabled,
          ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(
              store.listenBrainzToken == null
                  ? "Set user token"
                  : "Logged in as ${store.listenBrainzUser ?? "unknown"}",
            ),
            subtitle: Text(store.listenBrainzToken == null ? "Find it at listenbrainz.org/settings" : "Tap to log out"),
            onTap: store.listenBrainzToken == null
                ? _listenBrainzLogin
                : () => store.setListenBrainzAccount(null, null),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text("API URL"),
            subtitle: Text(store.listenBrainzApiUrl),
            onTap: _listenBrainzUrl,
          ),
          if (_scrobbler.lastListenBrainzError != null) note("Last error: ${_scrobbler.lastListenBrainzError}"),

          header("Last.fm"),
          SwitchListTile.adaptive(
            title: const Text("Scrobble to Last.fm"),
            value: store.lastFmEnabled,
            onChanged: store.setLastFmEnabled,
          ),
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(
              store.lastFmSessionKey == null
                  ? "Connect Last.fm account"
                  : "Logged in as ${store.lastFmUser ?? "unknown"}",
            ),
            subtitle: Text(store.lastFmSessionKey == null ? "Needs your own Last.fm API key" : "Tap to log out"),
            onTap: store.lastFmSessionKey == null
                ? _lastFmLogin
                : () => store.setLastFmAccount(
                    apiKey: store.lastFmApiKey,
                    apiSecret: store.lastFmApiSecret,
                    sessionKey: null,
                    user: null,
                  ),
          ),
          if (_scrobbler.lastLastFmError != null) note("Last error: ${_scrobbler.lastLastFmError}"),

          header("Scrobbling"),
          SwitchListTile.adaptive(
            title: const Text("Send \"now playing\""),
            subtitle: const Text("Show the current track on your profile while it plays"),
            value: store.sendNowPlaying,
            onChanged: store.setSendNowPlaying,
          ),
          ListTile(
            leading: const Icon(Icons.schedule_send_outlined),
            title: Text("${_scrobbler.pendingCount} scrobble(s) waiting to be sent"),
            subtitle: const Text("Plays made offline are sent when the connection is back. Tap to send now."),
            onTap: () async {
              await _scrobbler.flush();
              setState(() {});
              _snack(_scrobbler.pendingCount == 0 ? "All scrobbles sent" : "Some scrobbles could not be sent yet");
            },
            onLongPress: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text("Discard waiting scrobbles?"),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Discard")),
                  ],
                ),
              );
              if (ok ?? false) {
                await _scrobbler.clearQueue();
                setState(() {});
              }
            },
          ),
          note(
            "A track is scrobbled once it has played for half its length or 4 minutes, and only if it is longer than 30 seconds.",
          ),
        ],
      ),
    );
  }

  Future<void> _discordLogin() async {
    final ok = await Navigator.of(context).pushNamed(DiscordLoginScreen.routeName);
    if (ok == true) _snack("Logged in to Discord");
  }

  Future<String?> _askText({
    required String title,
    required String label,
    String? initial,
    bool obscure = false,
    String? help,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (help != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(help)),
            TextField(
              controller: controller,
              obscureText: obscure,
              autofocus: true,
              decoration: InputDecoration(labelText: label),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text("OK")),
        ],
      ),
    );
  }

  Future<void> _discordPasteToken() async {
    final token = await _askText(title: "Discord token", label: "Token", obscure: true);
    if (token == null || token.isEmpty) return;
    try {
      final name = await validateDiscordToken(token);
      await ExternalAccountsStore.instance.setDiscordAccount(token, name);
      _snack("Logged in to Discord as $name");
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> _listenBrainzLogin() async {
    final store = ExternalAccountsStore.instance;
    final token = await _askText(
      title: "ListenBrainz",
      label: "User token",
      obscure: true,
      help: "Copy your user token from listenbrainz.org/settings.",
    );
    if (token == null || token.isEmpty) return;
    try {
      final user = await ListenBrainzClient(store.listenBrainzApiUrl, token).validate();
      await store.setListenBrainzAccount(token, user);
      if (!store.listenBrainzEnabled) await store.setListenBrainzEnabled(true);
      _snack("Logged in to ListenBrainz as $user");
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> _listenBrainzUrl() async {
    final store = ExternalAccountsStore.instance;
    final url = await _askText(
      title: "ListenBrainz API URL",
      label: "URL",
      initial: store.listenBrainzApiUrl,
      help: "Change this to use a ListenBrainz-compatible server such as Maloja or Koito. Leave empty for the default.",
    );
    if (url == null) return;
    var cleaned = url;
    while (cleaned.endsWith("/")) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    await store.setListenBrainzApiUrl(cleaned.isEmpty ? null : cleaned);
  }

  Future<void> _lastFmLogin() async {
    final store = ExternalAccountsStore.instance;
    final apiKey = TextEditingController(text: store.lastFmApiKey);
    final apiSecret = TextEditingController(text: store.lastFmApiSecret);
    final user = TextEditingController();
    final password = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Connect Last.fm"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Last.fm needs an API key per app. Create one (any name, no callback URL needed), "
                "then enter it with your login. Your password is only sent to Last.fm to get a session and is not saved.",
              ),
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse("https://www.last.fm/api/account/create"),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text("Create an API key"),
              ),
              TextField(
                controller: apiKey,
                decoration: const InputDecoration(labelText: "API key"),
              ),
              TextField(
                controller: apiSecret,
                decoration: const InputDecoration(labelText: "Shared secret"),
              ),
              TextField(
                controller: user,
                decoration: const InputDecoration(labelText: "Username"),
              ),
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(labelText: "Password"),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Connect")),
        ],
      ),
    );
    if (go != true) return;
    final key = apiKey.text.trim();
    final secret = apiSecret.text.trim();
    try {
      final session = await LastFmClient(key, secret).login(user.text.trim(), password.text);
      await store.setLastFmAccount(apiKey: key, apiSecret: secret, sessionKey: session.sessionKey, user: session.user);
      if (!store.lastFmEnabled) await store.setLastFmEnabled(true);
      _snack("Logged in to Last.fm as ${session.user}");
    } catch (e) {
      _snack(e.toString());
    } finally {
      password.clear();
    }
  }
}
