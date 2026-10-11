import 'package:aves/model/settings/settings.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:material_ui/material_ui.dart';

Future<void> showWebDavViewOptions(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const WebDavViewOptionsSheet(),
  );
}

// all the view related options, gathered behind the app bar "view" button.
// reads the global `settings` directly (no `Provider` lookup) so that it also
// works when shown from a separate modal route.
class WebDavViewOptionsSheet extends StatelessWidget {
  static const List<String> layoutValues = ['mosaic', 'grid', 'list'];
  static const List<String> mediaValues = ['all', 'image', 'video'];

  const new({super.key});

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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, child) {
        final layout = settings.webDavLayout;
        final columns = settings.webDavColumns;
        final media = settings.webDavMediaFilter;
        final showNames = settings.webDavShowNames;
        final immersive = settings.webDavImmersive;

        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle(context, l10n.webdavLayout),
                _chips<String>(
                  values: layoutValues,
                  selected: layout,
                  label: (v) => layoutName(context, v),
                  icon: layoutIcon,
                  onSelected: (v) => settings.webDavLayout = v,
                ),
                if (layout != 'list') ...[
                  _sectionTitle(context, '${l10n.webdavColumnsTitle}  ${columns.round()}'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Slider(
                      value: columns.clamp(1.5, 8),
                      min: 1.5,
                      max: 8,
                      divisions: 13,
                      label: '${columns.round()}',
                      onChanged: (v) => settings.webDavColumns = v,
                    ),
                  ),
                ],
                _sectionTitle(context, l10n.webdavMediaType),
                _chips<String>(
                  values: mediaValues,
                  selected: media,
                  label: (v) => mediaName(context, v),
                  icon: mediaIcon,
                  onSelected: (v) => settings.webDavMediaFilter = v,
                ),
                const Divider(height: 24),
                SwitchListTile(
                  title: Text(l10n.webdavShowFileNames),
                  value: showNames,
                  onChanged: (v) => settings.webDavShowNames = v,
                ),
                SwitchListTile(
                  title: Text(l10n.webdavImmersive),
                  value: immersive,
                  onChanged: (v) => settings.webDavImmersive = v,
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
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
