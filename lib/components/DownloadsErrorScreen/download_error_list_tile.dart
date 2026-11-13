import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:finamp/l10n/app_localizations.dart';

import '../../models/finamp_models.dart';
import '../../services/process_artist.dart';
import '../album_image.dart';

class DownloadErrorListTile extends StatelessWidget {
  const DownloadErrorListTile({super.key, required this.downloadTask, required this.showType, this.canRetry = false});

  final DownloadStub downloadTask;
  final bool showType;

  /// Show a retry button (for failed and sync-failed items).
  final bool canRetry;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: AlbumImage(item: downloadTask.baseItem),
      title: Text(downloadTask.name),
      subtitle: Text(
        showType
            ? AppLocalizations.of(context)!.itemTypeSubtitle(downloadTask.baseItemType.name, "")
            : processArtist(downloadTask.baseItem?.albumArtist, context),
      ),
      trailing: canRetry
          ? IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: "Retry",
              onPressed: () => GetIt.instance<DownloadsService>()
                  .retryItems([downloadTask])
                  .catchError((Object e) => GlobalSnackbar.error(e)),
            )
          : null,
    );
  }
}
