import 'dart:async';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../models/finamp_models.dart';
import '../../services/downloads_service.dart';
import '../global_snackbar.dart';

const double downloadsOverviewCardLoadingHeight = 120;

class DownloadsOverview extends StatefulWidget {
  const DownloadsOverview({super.key});

  @override
  State<DownloadsOverview> createState() => _DownloadsOverviewState();
}

class _DownloadsOverviewState extends State<DownloadsOverview> with WidgetsBindingObserver {
  final downloadsService = GetIt.instance<DownloadsService>();
  Timer? _refresh;

  // This used to start a new timer on every build, so they piled up and kept
  // running database counts every 4 s for as long as the screen existed.
  // Now there is one timer, paused while the app is in the background.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    downloadsService.updateDownloadCounts();
    downloadsService.restartDownloads();
    _startRefresh();
  }

  void _startRefresh() {
    _refresh?.cancel();
    _refresh = Timer.periodic(const Duration(seconds: 4), (_) => downloadsService.updateDownloadCounts());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      downloadsService.updateDownloadCounts();
      _startRefresh();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _refresh?.cancel();
      _refresh = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // This is refreshed once every 4 seconds by above timer
    return StreamBuilder<Map<String, int>>(
      stream: downloadsService.downloadCountsStream,
      initialData: downloadsService.downloadCounts,
      builder: (context, countSnapshot) {
        // This is throttled to 10 per second in downloadsService constructor.
        return StreamBuilder<Map<DownloadItemState, int>>(
          stream: downloadsService.downloadStatusesStream,
          initialData: downloadsService.downloadStatuses,
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              final downloadCount =
                  (snapshot.data?[DownloadItemState.complete] ?? 0) +
                  (snapshot.data?[DownloadItemState.needsRedownloadComplete] ?? 0) +
                  (snapshot.data?[DownloadItemState.needsRedownload] ?? 0) +
                  (snapshot.data?[DownloadItemState.failed] ?? 0) +
                  (snapshot.data?[DownloadItemState.enqueued] ?? 0) +
                  (snapshot.data?[DownloadItemState.downloading] ?? 0);

              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AutoSizeText(
                                AppLocalizations.of(context)!.downloadCount(downloadCount),
                                style: const TextStyle(fontSize: 28),
                                maxLines: 1,
                              ),
                              Text(
                                AppLocalizations.of(context)!.downloadedCountUnified(
                                  countSnapshot.data?["track"] ?? -1,
                                  countSnapshot.data?["image"] ?? -1,
                                  countSnapshot.data?["sync"] ?? -1,
                                  countSnapshot.data?[repairStepTrackingName] ?? 0,
                                ),
                                style: const TextStyle(color: Colors.grey),
                              ),
                              if (downloadsService.serverMissingBlurhash)
                                Text(
                                  AppLocalizations.of(context)!.missingBlurhashWarning,
                                  style: const TextStyle(color: Colors.red),
                                ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 50),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                AppLocalizations.of(context)!.dlComplete(
                                  (snapshot.data?[DownloadItemState.complete] ?? -1) +
                                      (snapshot.data?[DownloadItemState.needsRedownloadComplete] ?? -1),
                                ),
                                style: const TextStyle(color: Colors.blue),
                              ),
                              Text(
                                AppLocalizations.of(context)!.dlFailed(
                                  (snapshot.data?[DownloadItemState.syncFailed] ?? 0) +
                                      (snapshot.data?[DownloadItemState.failed] ?? -1),
                                ),
                                style: const TextStyle(color: Colors.red),
                              ),
                              Text(
                                AppLocalizations.of(
                                  context,
                                )!.dlEnqueued(snapshot.data?[DownloadItemState.enqueued] ?? -1),
                                style: const TextStyle(color: Colors.grey),
                              ),
                              Text(
                                AppLocalizations.of(
                                  context,
                                )!.dlRunning(snapshot.data?[DownloadItemState.downloading] ?? -1),
                                style: const TextStyle(color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            } else if (snapshot.hasError) {
              GlobalSnackbar.error(snapshot.error);
              return const SizedBox(
                height: downloadsOverviewCardLoadingHeight,
                child: Card(child: Icon(Icons.error)),
              );
            } else {
              return const SizedBox(
                height: downloadsOverviewCardLoadingHeight,
                child: Card(child: Center(child: CircularProgressIndicator.adaptive())),
              );
            }
          },
        );
      },
    );
  }
}
