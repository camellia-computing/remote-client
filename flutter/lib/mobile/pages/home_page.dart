import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/widgets/adaptive_layout.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/mobile/pages/connection_page.dart';
import 'package:camellia_remote_app/mobile/pages/server_page.dart';
import 'package:camellia_remote_app/mobile/pages/settings_page.dart';
import 'package:get/get.dart';
import '../../common.dart';
import '../../common/widgets/chat_page.dart';
import '../../models/platform_model.dart';
import '../../models/user_model.dart';

abstract class PageShape extends Widget {
  final String title = "";
  final Widget icon = Icon(null);
  final List<Widget> appBarActions = [];
}

class HomePage extends StatefulWidget {
  static final homeKey = GlobalKey<HomePageState>();

  HomePage() : super(key: homeKey);

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  var _selectedIndex = 0;
  int get selectedIndex => _selectedIndex;
  bool get isServerPageCurrentTab =>
      _selectedIndex >= 0 &&
      _selectedIndex < _pages.length &&
      _pages[_selectedIndex] is ServerPage;
  final List<PageShape> _pages = [];
  int _chatPageTabIndex = -1;
  bool get isChatPageCurrentTab => isAndroid
      ? _selectedIndex == _chatPageTabIndex
      : false; // change this when ios have chat page

  void refreshPages() {
    setState(() {
      initPages();
    });
  }

  void selectChatPage() {
    if (_chatPageTabIndex < 0 || _chatPageTabIndex >= _pages.length) {
      return;
    }
    _onDestinationSelected(_chatPageTabIndex);
  }

  @override
  void initState() {
    super.initState();
    initPages();
  }

  void initPages() {
    _pages.clear();
    if (!bind.isIncomingOnly()) {
      _pages.add(ConnectionPage(appBarActions: []));
    }
    if (isAndroid && !bind.isOutgoingOnly()) {
      _chatPageTabIndex = _pages.length;
      _pages.addAll([ChatPage(type: ChatPageType.mobileMain), ServerPage()]);
    }
    _pages.add(SettingsPage());
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _selectedIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectedIndex != 0) {
          setState(() => _selectedIndex = 0);
        }
      },
      child: AppAmbientBackground(
        child: AdaptiveNavigationScaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            toolbarHeight: 62,
            elevation: 0,
            backgroundColor: Theme.of(context).colorScheme.surface,
            foregroundColor: Theme.of(context).textTheme.titleLarge?.color,
            centerTitle: false,
            titleSpacing: 16,
            title: Row(
              children: [
                const CamelliaAnimatedBrandMark(size: 34),
                const SizedBox(width: 10),
                Expanded(child: appTitle()),
              ],
            ),
            actions: [
              ..._pages.elementAt(_selectedIndex).appBarActions,
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: _buildAccountButton(
                  context,
                  MediaQuery.sizeOf(context).width < 600,
                ),
              ),
            ],
          ),
          selectedIndex: _selectedIndex,
          destinations: _pages
              .map(
                (page) => NavigationDestination(
                  icon: page.icon,
                  selectedIcon: page.icon,
                  label: page.title,
                ),
              )
              .toList(growable: false),
          onDestinationSelected: _onDestinationSelected,
          body: SafeArea(
            bottom: false,
            child: AnimatedSwitcher(
              duration: AppMotion.duration(context, AppMotion.route),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.02, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: KeyedSubtree(
                key: ValueKey<int>(_selectedIndex),
                child: _pages.elementAt(_selectedIndex),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAccountButton(BuildContext context, bool compact) {
    return Obx(() {
      final model = gFFI.userModel;
      final state = model.accountState.value;
      final label = model.isLogin
          ? model.displayNameOrUserName
          : state == UserAccountState.disabled
          ? translate('Account')
          : translate('Sign in');
      final detail = switch (state) {
        UserAccountState.disabled => translate('Disabled'),
        UserAccountState.signedOut => translate('Account'),
        UserAccountState.loading => translate('Loading...'),
        UserAccountState.ready =>
          model.email.value.trim().isNotEmpty
              ? model.email.value.trim()
              : model.userName.value.trim().isEmpty
              ? translate('Connected')
              : '@${model.userName.value.trim()}',
        UserAccountState.offline => translate('Offline'),
        UserAccountState.error => translate('Unavailable'),
      };
      final color = switch (state) {
        UserAccountState.ready => AppVisual.tone(context, AppTone.success),
        UserAccountState.offline => AppVisual.tone(context, AppTone.warning),
        UserAccountState.error => AppVisual.tone(context, AppTone.danger),
        UserAccountState.disabled => AppVisual.subduedText(context),
        _ => Theme.of(context).colorScheme.primary,
      };
      return CamelliaAccountButton(
        label: label,
        detail: detail,
        avatarUrl: model.avatar.value,
        statusColor: color,
        statusIcon: switch (state) {
          UserAccountState.ready => Icons.check_circle_rounded,
          UserAccountState.offline => Icons.cloud_off_rounded,
          UserAccountState.error => Icons.error_rounded,
          UserAccountState.disabled => Icons.block_rounded,
          _ => Icons.circle_rounded,
        },
        busy: state == UserAccountState.loading,
        compact: compact,
        onPressed: bind.isDisableAccount() ? null : _openAccountSettings,
      );
    });
  }

  void _openAccountSettings() {
    final settingsIndex = _pages.indexWhere((page) => page is SettingsPage);
    if (settingsIndex >= 0) _onDestinationSelected(settingsIndex);
  }

  void _onDestinationSelected(int index) {
    setState(() {
      if (_selectedIndex != index) {
        _selectedIndex = index;
        if (isChatPageCurrentTab) {
          gFFI.chatModel.hideChatIconOverlay();
          gFFI.chatModel.hideChatWindowOverlay();
          gFFI.chatModel.mobileClearClientUnread(
            gFFI.chatModel.currentKey.connId,
          );
        }
      }
    });
  }

  Widget appTitle() {
    final currentUser = gFFI.chatModel.currentUser;
    final currentKey = gFFI.chatModel.currentKey;
    if (isChatPageCurrentTab &&
        currentUser != null &&
        currentKey.peerId.isNotEmpty) {
      final connected = gFFI.serverModel.clients.any(
        (e) => e.id == currentKey.connId,
      );
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Tooltip(
            message: currentKey.isOut
                ? translate('Outgoing connection')
                : translate('Incoming connection'),
            child: Icon(
              currentKey.isOut
                  ? Icons.call_made_rounded
                  : Icons.call_received_rounded,
            ),
          ),
          Expanded(
            child: Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("${currentUser.firstName}   ${currentUser.id}"),
                  if (connected)
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color.fromARGB(255, 133, 246, 199),
                      ),
                    ).marginSymmetric(horizontal: 2),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return Text(
      _pages.elementAt(_selectedIndex).title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: 0,
      ),
    );
  }
}
