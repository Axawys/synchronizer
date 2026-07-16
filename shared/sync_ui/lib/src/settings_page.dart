import 'package:flutter/material.dart';

import 'storage.dart';

/// Settings. The theme follows the system automatically, so the only choice
/// here is how changes get applied.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _light;

  @override
  void initState() {
    super.initState();
    SyncSettings.lightMode().then((value) {
      if (mounted) setState(() => _light = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final light = _light;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: light == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile(
                  title: const Text('Plain sync'),
                  subtitle: const Text(
                      'Apply changes without showing the diff for confirmation. '
                      'Conflicts are resolved by taking the more recently edited side.'),
                  value: light,
                  onChanged: (value) {
                    setState(() => _light = value);
                    SyncSettings.setLightMode(value);
                  },
                ),
              ],
            ),
    );
  }
}
