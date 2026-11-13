import 'dart:async';
import 'dart:convert';

import 'package:finamp/components/finamp_app_bar_back_button.dart';
import 'package:finamp/services/external_accounts_store.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:webview_flutter/webview_flutter.dart';

final _log = Logger("DiscordLogin");

/// Checks a Discord token and returns the account's display name.
Future<String> validateDiscordToken(String token) async {
  final res = await http
      .get(Uri.parse("https://discord.com/api/v10/users/@me"), headers: {"Authorization": token})
      .timeout(const Duration(seconds: 15));
  if (res.statusCode == 401) throw Exception("Discord rejected this token");
  if (res.statusCode != 200) throw Exception("Discord returned ${res.statusCode}");
  final user = jsonDecode(res.body) as Map<String, dynamic>;
  return (user["global_name"] ?? user["username"]) as String;
}

/// Logs in to discord.com in a WebView and picks up the account token once
/// the login finishes. The token never leaves the device except to Discord.
class DiscordLoginScreen extends StatefulWidget {
  const DiscordLoginScreen({super.key});
  static const routeName = "/settings/discord-login";

  @override
  State<DiscordLoginScreen> createState() => _DiscordLoginScreenState();
}

class _DiscordLoginScreenState extends State<DiscordLoginScreen> {
  late final WebViewController _controller;
  Timer? _poll;
  bool _done = false;
  String? _error;

  // Discord deletes window.localStorage once the app loads, but a fresh
  // iframe on the same origin still exposes it.
  static const _grabTokenJs = """
(function () {
  try {
    var f = document.createElement('iframe');
    f.style.display = 'none';
    document.body.appendChild(f);
    var t = f.contentWindow.localStorage.getItem('token');
    f.remove();
    if (t) FinampToken.postMessage(JSON.parse(t));
  } catch (e) {}
})();
""";

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
      )
      ..addJavaScriptChannel("FinampToken", onMessageReceived: (m) => _onToken(m.message))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (!request.isMainFrame) return NavigationDecision.navigate;
            final host = Uri.tryParse(request.url)?.host ?? "";
            // stay on Discord (hCaptcha is loaded in frames, which this does not affect)
            if (host == "discord.com" || host.endsWith(".discord.com")) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(Uri.parse("https://discord.com/login"));
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_done) _controller.runJavaScript(_grabTokenJs).catchError((_) {});
    });
  }

  Future<void> _onToken(String token) async {
    if (_done || token.isEmpty) return;
    _done = true;
    _poll?.cancel();
    try {
      final name = await validateDiscordToken(token);
      await ExternalAccountsStore.instance.setDiscordAccount(token, name);
      // drop the web session's local copy; the token itself stays valid
      await WebViewCookieManager().clearCookies();
      await _controller.clearLocalStorage();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _log.warning("Discord login failed: $e");
      setState(() {
        _done = false;
        _error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Log in to Discord"), leading: FinampAppBarBackButton()),
      body: Column(
        children: [
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [TextButton(onPressed: () => setState(() => _error = null), child: const Text("OK"))],
            ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
