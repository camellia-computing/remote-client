import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/common/widgets/settings_overlay.dart';
import 'package:camellia_remote_app/mobile/pages/connection_page.dart';
import 'package:camellia_remote_app/mobile/pages/server_page.dart';
import 'package:camellia_remote_app/mobile/pages/settings_page.dart';

import '../../common.dart';
import '../../common/widgets/chat_page.dart';
import '../../consts.dart';
import '../../models/platform_model.dart';

abstract class PageShape extends Widget {
  final String title = '';
  final Widget icon = const Icon(null);
  final List<Widget> appBarActions = const [];
}

class HomePage extends StatefulWidget {
  static final homeKey = GlobalKey<HomePageState>();

  HomePage() : super(key: homeKey);

  @override
  HomePageState createState() => HomePageState();
}

/// Hosts one adaptive workspace. Chat and settings are contextual routes, and
/// the visibility getters keep current session notifications on the right
/// surface.
class HomePageState extends State<HomePage> {
  bool _chatActive = false;

  bool get isServerPageCurrentTab =>
      isAndroid && !bind.isOutgoingOnly() && !_chatActive;
  bool get isChatPageCurrentTab => isAndroid && _chatActive;

  void refreshPages() {
    if (mounted) setState(() {});
  }

  void selectChatPage() {
    if (isAndroid) _openChat();
  }

  @override
  Widget build(BuildContext context) {
    final canShare = isAndroid && !bind.isOutgoingOnly();
    final body = bind.isIncomingOnly()
        ? ServerPage()
        : ConnectionPage(
            appBarActions: const [],
            shareSection: canShare ? const ServerWorkspaceSection() : null,
          );
    return AppAmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          centerTitle: false,
          titleSpacing: 16,
          title: Row(
            children: [
              CamelliaAnimatedBrandMark(
                size: 36,
                semanticLabel: bind.mainGetAppNameSync(),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  bind.mainGetAppNameSync(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            if (canShare &&
                !bind.isDisableSettings() &&
                bind.mainGetBuildinOption(key: kOptionHideSecuritySetting) !=
                    'Y')
              const ServerAccessMenuButton(),
            if (isAndroid)
              IconButton(
                tooltip: translate('Chat'),
                onPressed: _openChat,
                icon: const Icon(Icons.chat_bubble_outline_rounded),
              ),
            if (!bind.isDisableSettings())
              IconButton(
                tooltip: translate('Settings'),
                onPressed: _openSettings,
                icon: const Icon(Icons.tune_rounded),
              ),
            const SizedBox(width: 6),
          ],
        ),
        body: SafeArea(top: false, child: body),
      ),
    );
  }

  Future<void> _openSettings() async {
    final page = SettingsPage();
    await showSettingsOverlay<void>(
      context: context,
      title: translate('Settings'),
      actions: page.appBarActions,
      builder: (_) => page,
    );
  }

  Future<void> _openChat() async {
    if (_chatActive) return;
    final page = ChatPage(type: ChatPageType.mobileMain);
    setState(() => _chatActive = true);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(translate('Chat')),
            actions: page.appBarActions,
          ),
          body: SafeArea(top: false, child: page),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _chatActive = false);
    gFFI.chatModel.hideChatIconOverlay();
    gFFI.chatModel.hideChatWindowOverlay();
    gFFI.chatModel.mobileClearClientUnread(gFFI.chatModel.currentKey.connId);
  }
}
