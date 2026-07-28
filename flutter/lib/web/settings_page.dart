import 'package:flutter/material.dart';

import 'web_client_settings_page.dart';

class WebSettingsPage extends StatelessWidget {
  const WebSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _buildDesktopButton(context);
  }

  Widget _buildDesktopButton(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.more_vert),
      onPressed: () {
        FocusManager.instance.primaryFocus?.unfocus();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (BuildContext context) => const WebClientSettingsPage(),
          ),
        );
      },
    );
  }
}
