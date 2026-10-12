import 'package:aves/widgets/cloud/cloud_server_list_page.dart';
import 'package:material_ui/material_ui.dart';

// Entry point of the cloud features: shows the service management page, which
// also offers a shortcut back to the last browsed folder.
class CloudEntryPage extends StatelessWidget {
  static const routeName = '/cloud';

  const new({super.key});

  @override
  Widget build(BuildContext context) => const CloudServerListPage();
}
