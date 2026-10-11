import 'package:aves/model/settings/settings.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/dialogs/selection_dialogs/common.dart';
import 'package:aves/widgets/dialogs/selection_dialogs/single_selection.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

// layout bar mirroring the local browsing one: a scrollable row of
// outline buttons that each open a selection dialog
class WebDavLayoutBar extends StatelessWidget {
  static const double preferredHeight = 56;
  static const List<String> layoutValues = ['mosaic', 'grid', 'list'];
  static const List<int> columnValues = [2, 3, 4, 5, 6, 7, 8];

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

  @override
  Widget build(BuildContext context) {
    final layout = context.select<Settings, String>((s) => s.webDavLayout);
    final columns = context.select<Settings, double>((s) => s.webDavColumns);
    final immersive = context.select<Settings, bool>((s) => s.webDavImmersive);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: preferredHeight,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          children: [
            _chip(
              context,
              onPressed: () => _pickLayout(context, layout),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(AIcons.layout),
                  const SizedBox(width: 6),
                  Icon(layoutIcon(layout)),
                ],
              ),
            ),
            _chip(
              context,
              enabled: layout != 'list',
              onPressed: () => _pickColumns(context, columns),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(AIcons.layoutGrid),
                  const SizedBox(width: 6),
                  Text('${columns.round()}'),
                ],
              ),
            ),
            _chip(
              context,
              onPressed: () => settings.webDavImmersive = !immersive,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(immersive ? Icons.fullscreen_exit : Icons.fullscreen, size: 20),
                  const SizedBox(width: 6),
                  Text(context.l10n.webdavImmersive),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, {required VoidCallback onPressed, required Widget child, bool enabled = true}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Center(
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.onSurface,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size.square(kMinInteractiveDimension),
          ),
          onPressed: enabled ? onPressed : null,
          child: child,
        ),
      ),
    );
  }

  void _pickLayout(BuildContext context, String current) {
    showSelectionDialog<String>(
      context: context,
      builder: (context) => AvesSingleSelectionDialog<String>(
        initialValue: current,
        options: {for (final value in layoutValues) value: layoutName(context, value)},
        optionIconBuilder: layoutIcon,
        title: context.l10n.webdavLayout,
      ),
      onSelection: (value) => settings.webDavLayout = value,
    );
  }

  void _pickColumns(BuildContext context, double current) {
    showSelectionDialog<int>(
      context: context,
      builder: (context) => AvesSingleSelectionDialog<int>(
        initialValue: current.round(),
        options: {for (final n in columnValues) n: '$n'},
        title: context.l10n.webdavColumnsTitle,
      ),
      onSelection: (value) => settings.webDavColumns = value.toDouble(),
    );
  }
}
