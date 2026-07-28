import 'package:flutter/material.dart';

import 'main_home_entry_stub.dart'
    if (dart.library.html) 'main_home_entry_web.dart' as entry;

Widget buildMainHomePage() => entry.buildMainHomePage();

String buildMainAppTitle(String appName) => entry.buildMainAppTitle(appName);
