import 'package:aves/model/settings/modules/cloud.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:material_ui/material_ui.dart';

Future<void> showCloudViewOptions(
  BuildContext context, {
  required String url,
  required bool video,
  Future<void> Function()? onRebuildThumbnails,
  Future<void> Function()? onExportProgress,
  Future<void> Function()? onImportProgress,
  Future<void> Function()? onClearProgress,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    // never take more than half of the screen
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height / 2),
    builder: (context) => SizedBox.expand(
      child: CloudViewOptionsSheet(
        url: url,
        video: video,
        onRebuildThumbnails: onRebuildThumbnails,
        onExportProgress: onExportProgress,
        onImportProgress: onImportProgress,
        onClearProgress: onClearProgress,
      ),
    ),
  );
}

// All the view related options, gathered behind the app bar "view" button.
// Reads the global `settings` directly (no `Provider` lookup) so that it also
// works when shown from a separate modal route.
//
// Options are split into four tabs: the sheet used to be one long scroll that
// did not fit in half a screen.
class CloudViewOptionsSheet extends StatelessWidget {
  static const List<String> layoutValues = ['mosaic', 'grid', 'list'];
  static const List<String> mediaValues = ['all', 'image', 'video'];
  static const List<String> sortValues = ['nameAsc', 'nameDesc'];

  final String url;
  final bool video;
  final Future<void> Function()? onRebuildThumbnails;
  final Future<void> Function()? onExportProgress;
  final Future<void> Function()? onImportProgress;
  final Future<void> Function()? onClearProgress;

  const new({
    super.key,
    required this.url,
    required this.video,
    this.onRebuildThumbnails,
    this.onExportProgress,
    this.onImportProgress,
    this.onClearProgress,
  });

  static IconData layoutIcon(String layout) => switch (layout) {
    'mosaic' => AIcons.layoutMosaic,
    'list' => AIcons.layoutList,
    _ => AIcons.layoutGrid,
  };

  static String layoutName(BuildContext context, String layout) => switch (layout) {
    'mosaic' => context.l10n.webdavLayoutMosaic,
    'list' => context.l10n.webdavLayoutList,
    _ => context.l10n.webdavLayoutGrid,
  };

  static IconData mediaIcon(String media) => switch (media) {
    'image' => Icons.image_outlined,
    'video' => Icons.videocam_outlined,
    _ => Icons.collections_outlined,
  };

  static String mediaName(BuildContext context, String media) => switch (media) {
    'image' => context.l10n.webdavMediaImages,
    'video' => context.l10n.webdavMediaVideos,
    _ => context.l10n.webdavMediaAll,
  };

  static String sortName(BuildContext context, String sort) => sort == 'nameDesc' ? context.l10n.cloudSortNameDesc : context.l10n.cloudSortNameAsc;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return DefaultTabController(
      length: 4,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, child) => SafeArea(
          top: false,
          child: Column(
            children: [
              TabBar(
                labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                tabs: [
                  Tab(text: l10n.cloudTabLayout),
                  Tab(text: l10n.cloudTabDisplay),
                  Tab(text: l10n.cloudTabVideo),
                  Tab(text: l10n.cloudTabProgress),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildLayoutTab(context),
                    _buildDisplayTab(context),
                    _buildVideoTab(context),
                    _buildProgressTab(context),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLayoutTab(BuildContext context) {
    final l10n = context.l10n;
    final currentLayout = settings.cloudLayoutFor(url, video: video);
    final columns = settings.cloudColumns;
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        _sectionTitle(context, video ? l10n.cloudLayoutVideo : l10n.cloudLayoutCurrent),
        _chips<String>(
          values: layoutValues,
          selected: currentLayout,
          label: (v) => layoutName(context, v),
          icon: layoutIcon,
          onSelected: (v) => settings.setCloudLayoutFor(url, v, video: video),
        ),
        if (currentLayout != 'list') ...[
          _sectionTitle(context, '${l10n.webdavColumnsTitle}  ${columns.round()}'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Slider(
              value: columns.clamp(1, 8),
              min: 1,
              max: 8,
              divisions: 14,
              label: '${columns.round()}',
              onChanged: (v) => settings.cloudColumns = v,
            ),
          ),
        ],
        const Divider(height: 24),
        _sectionTitle(context, l10n.cloudDefaultViews),
        _chipRow(context, l10n.cloudDefaultImage, settings.cloudImageLayout, (v) => settings.cloudImageLayout = v),
        const SizedBox(height: 8),
        _chipRow(context, l10n.cloudDefaultVideo, settings.cloudVideoLayout, (v) => settings.cloudVideoLayout = v),
        SwitchListTile(
          title: Text(l10n.cloudLayoutPerFolder),
          value: settings.cloudLayoutPerFolder,
          onChanged: (v) => settings.cloudLayoutPerFolder = v,
        ),
      ],
    );
  }

  Widget _buildDisplayTab(BuildContext context) {
    final l10n = context.l10n;
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        _sectionTitle(context, l10n.webdavMediaType),
        _chips<String>(
          values: mediaValues,
          selected: settings.cloudMediaFilter,
          label: (v) => mediaName(context, v),
          icon: mediaIcon,
          onSelected: (v) => settings.cloudMediaFilter = v,
        ),
        _sectionTitle(context, l10n.cloudSort),
        _chips<String>(
          values: sortValues,
          selected: settings.cloudSort,
          label: (v) => sortName(context, v),
          icon: (v) => v == 'nameDesc' ? AIcons.sortOrder : AIcons.sort,
          onSelected: (v) => settings.cloudSort = v,
        ),
        const Divider(height: 24),
        SwitchListTile(
          title: Text(l10n.webdavShowFileNames),
          value: settings.cloudShowNames,
          onChanged: (v) => settings.cloudShowNames = v,
        ),
        SwitchListTile(
          title: Text(l10n.cloudShowFileSizes),
          value: settings.cloudShowSizes,
          onChanged: (v) => settings.cloudShowSizes = v,
        ),
        const Divider(height: 24),
        SwitchListTile(
          title: Text(l10n.cloudViewerThumbnails),
          value: settings.cloudViewerThumbnails,
          onChanged: (v) => settings.cloudViewerThumbnails = v,
        ),
        SwitchListTile(
          title: Text(l10n.webdavImmersive),
          value: settings.cloudImmersive,
          onChanged: (v) => settings.cloudImmersive = v,
        ),
      ],
    );
  }

  Widget _buildVideoTab(BuildContext context) {
    final l10n = context.l10n;
    final videoThumbnails = settings.cloudVideoThumbnails;
    final videoThumbnailPercent = settings.cloudVideoThumbnailPercent;
    final thumbnailConcurrency = settings.cloudThumbnailConcurrency;
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        SwitchListTile(
          title: Text(l10n.cloudShowVideoThumbnails),
          value: videoThumbnails,
          onChanged: (v) => settings.cloudVideoThumbnails = v,
        ),
        SwitchListTile(
          title: Text(l10n.cloudShowVideoDuration),
          value: settings.cloudVideoDurationVisible,
          onChanged: (v) => settings.cloudVideoDurationVisible = v,
        ),
        SwitchListTile(
          title: Text(l10n.cloudShowVideoPlayIcon),
          value: settings.cloudVideoPlayIcon,
          onChanged: (v) => settings.cloudVideoPlayIcon = v,
        ),
        if (videoThumbnails) ...[
          _sectionTitle(context, '${l10n.cloudVideoThumbnailPosition}  ${videoThumbnailPercent.toStringAsFixed(1)}%'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Slider(
              value: videoThumbnailPercent.clamp(CloudSettings.minVideoThumbnailPercent, CloudSettings.maxVideoThumbnailPercent),
              min: CloudSettings.minVideoThumbnailPercent,
              max: CloudSettings.maxVideoThumbnailPercent,
              divisions: ((CloudSettings.maxVideoThumbnailPercent - CloudSettings.minVideoThumbnailPercent) / .5).round(),
              label: '${videoThumbnailPercent.toStringAsFixed(1)}%',
              onChanged: (v) => settings.cloudVideoThumbnailPercent = v,
            ),
          ),
          _sectionTitle(context, '${l10n.cloudThumbnailConcurrency}  $thumbnailConcurrency'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Slider(
              value: thumbnailConcurrency.toDouble(),
              min: CloudSettings.minThumbnailConcurrency.toDouble(),
              max: CloudSettings.maxThumbnailConcurrency.toDouble(),
              divisions: CloudSettings.maxThumbnailConcurrency - CloudSettings.minThumbnailConcurrency,
              label: '$thumbnailConcurrency',
              onChanged: (v) => settings.cloudThumbnailConcurrency = v.round(),
            ),
          ),
        ],
        const Divider(height: 24),
        // always available: frames captured during playback are affected too
        ListTile(
          leading: const Icon(Icons.refresh),
          title: Text(l10n.cloudRebuildThumbnails),
          onTap: () => _runAndClose(context, onRebuildThumbnails),
        ),
      ],
    );
  }

  Widget _buildProgressTab(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        ListTile(
          leading: const Icon(Icons.insights),
          title: Text(l10n.cloudProgressSummary(settings.cloudProgressFolderCount, settings.cloudProgressImageCount)),
        ),
        const Divider(height: 24),
        ListTile(
          leading: const Icon(Icons.upload_file),
          title: Text(l10n.cloudExportProgress),
          onTap: () => _runAndClose(context, onExportProgress),
        ),
        ListTile(
          leading: const Icon(Icons.download),
          title: Text(l10n.cloudImportProgress),
          onTap: () => _runAndClose(context, onImportProgress),
        ),
        ListTile(
          leading: Icon(Icons.delete_forever, color: theme.colorScheme.error),
          title: Text(l10n.cloudClearProgress, style: TextStyle(color: theme.colorScheme.error)),
          onTap: () => _runAndClose(context, onClearProgress),
        ),
      ],
    );
  }

  void _runAndClose(BuildContext context, Future<void> Function()? action) {
    if (action == null) return;
    Navigator.pop(context);
    action();
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
  }

  Widget _chipRow(BuildContext context, String label, String selected, ValueChanged<String> onSelected) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in layoutValues)
                ChoiceChip(
                  avatar: Icon(layoutIcon(value), size: 18),
                  label: Text(layoutName(context, value)),
                  selected: value == selected,
                  onSelected: (_) => onSelected(value),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chips<T>({
    required List<T> values,
    required T selected,
    required String Function(T) label,
    required IconData Function(T) icon,
    required ValueChanged<T> onSelected,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final value in values)
            ChoiceChip(
              avatar: Icon(icon(value), size: 18),
              label: Text(label(value)),
              selected: value == selected,
              onSelected: (_) => onSelected(value),
            ),
        ],
      ),
    );
  }
}
