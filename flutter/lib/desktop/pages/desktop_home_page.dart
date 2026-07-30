import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/adaptive_layout.dart';
import 'package:camellia_remote_app/common/widgets/animated_rotation_widget.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/common/widgets/custom_password.dart';
import 'package:camellia_remote_app/common/widgets/peer_tab_page.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/server_model.dart';
import 'package:camellia_remote_app/models/user_model.dart';
import 'package:camellia_remote_app/plugin/ui_manager.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import 'package:camellia_remote_app/utils/platform_channel.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'package:window_size/window_size.dart' as window_size;

class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({Key? key}) : super(key: key);

  @override
  State<DesktopHomePage> createState() => _DesktopHomePageState();
}

class _DesktopHomePageState extends State<DesktopHomePage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final _leftPaneScrollController = ScrollController();

  @override
  bool get wantKeepAlive => true;
  var systemError = '';
  StreamSubscription? _uniLinksSubscription;
  var svcStopped = false.obs;
  var watchIsCanScreenRecording = false;
  var watchIsProcessTrust = false;
  var watchIsInputMonitoring = false;
  var watchIsCanRecordAudio = false;
  Timer? _updateTimer;
  bool isCardClosed = false;
  int _navigationIndex = 0;
  SettingsTabKey _settingsInitialTab = SettingsTabKey.general;

  final RxBool _editHover = false.obs;
  final RxBool _block = false.obs;

  final GlobalKey _childKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildBlock(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final layout = AppLayout.forWidth(constraints.maxWidth);
          final compact = layout == AppLayoutSize.compact;
          final extendedRail =
              constraints.maxWidth >= AppLayout.railExtendBreakpoint;
          final workspace = Column(
            children: [
              _buildWorkspaceHeader(context, compact),
              Divider(height: 1, color: AppVisual.border(context)),
              Expanded(
                child: AnimatedSwitcher(
                  duration: AppMotion.duration(context, AppMotion.route),
                  switchInCurve: AppMotion.enterCurve,
                  switchOutCurve: AppMotion.exitCurve,
                  child: KeyedSubtree(
                    key: ValueKey(_navigationIndex),
                    child: _buildDestinationWorkspace(
                      context,
                      constraints: constraints,
                    ),
                  ),
                ),
              ),
            ],
          );
          return CamelliaBackdrop(
            child: compact
                ? Column(
                    children: [
                      Expanded(child: workspace),
                      NavigationBar(
                        selectedIndex: _navigationIndex,
                        onDestinationSelected: _selectNavigationDestination,
                        destinations: _navigationDestinations(),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      CamelliaNavigationRail(
                        extended: extendedRail,
                        selectedIndex: _navigationIndex,
                        onDestinationSelected: _selectNavigationDestination,
                        destinations: _navigationDestinations(),
                      ),
                      Expanded(child: workspace),
                    ],
                  ),
          );
        },
      ),
    );
  }

  List<NavigationDestination> _navigationDestinations() => [
    NavigationDestination(
      icon: const Icon(Icons.home_outlined),
      selectedIcon: const Icon(Icons.home_rounded),
      label: translate('Home'),
    ),
    NavigationDestination(
      icon: const Icon(Icons.devices_outlined),
      selectedIcon: const Icon(Icons.devices_rounded),
      label: translate('Devices'),
    ),
    NavigationDestination(
      icon: const Icon(Icons.tune_outlined),
      selectedIcon: const Icon(Icons.tune_rounded),
      label: translate('Settings'),
    ),
  ];

  Widget _buildDestinationWorkspace(
    BuildContext context, {
    required BoxConstraints constraints,
  }) {
    switch (_navigationIndex) {
      case 1:
        final compact = constraints.maxWidth < AppLayout.compactBreakpoint;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 12 : 22,
            16,
            compact ? 12 : 22,
            12,
          ),
          child: const PeerTabPage(),
        );
      case 2:
        return DesktopSettingPage(
          key: ValueKey(_settingsInitialTab),
          initialTabkey: _settingsInitialTab,
        );
      default:
        return _buildHomeWorkspace(context, constraints);
    }
  }

  Widget _buildHomeWorkspace(BuildContext context, BoxConstraints constraints) {
    final incomingOnly = bind.isIncomingOnly();
    final outgoingOnly = bind.isOutgoingOnly();
    final wide =
        constraints.maxWidth >= AppLayout.splitBreakpoint &&
        constraints.maxHeight >= 600;
    if (incomingOnly) {
      return Align(
        alignment: Alignment.topCenter,
        child: buildLeftPane(
          context,
          width: constraints.maxWidth.clamp(320.0, 520.0).toDouble(),
        ),
      );
    }
    if (outgoingOnly) {
      return const ConnectionPage();
    }
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          buildLeftPane(
            context,
            width: constraints.maxWidth >= AppLayout.railExtendBreakpoint
                ? 390
                : 350,
          ),
          const Expanded(child: ConnectionPage()),
        ],
      );
    }
    final identityHeight = (constraints.maxHeight * 0.38)
        .clamp(280.0, 360.0)
        .toDouble();
    return Column(
      children: [
        SizedBox(
          height: identityHeight,
          child: buildLeftPane(context, width: constraints.maxWidth),
        ),
        const Expanded(child: ConnectionPage()),
      ],
    );
  }

  void _selectNavigationDestination(int index) {
    setState(() => _navigationIndex = index);
  }

  Widget _buildWorkspaceHeader(BuildContext context, bool compact) {
    final theme = Theme.of(context);
    final title = switch (_navigationIndex) {
      1 => translate('Devices'),
      2 => translate('Settings'),
      _ => translate('Remote workspace'),
    };
    final subtitle = switch (_navigationIndex) {
      1 => translate('Recent, favorite, discovered, and shared devices'),
      2 => translate('Client preferences and security'),
      _ => translate('Connect, share, and manage trusted devices'),
    };
    return Container(
      height: compact ? 60 : 68,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.94),
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 22),
        child: Row(
          children: [
            if (compact) ...[
              const CamelliaAnimatedBrandMark(size: 34),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!compact)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppVisual.subduedText(context),
                      ),
                    ),
                ],
              ),
            ),
            _buildAccountButton(context, compact),
            if (compact && !bind.isDisableSettings()) ...[
              const SizedBox(width: 6),
              IconButton(
                tooltip: translate('Settings'),
                onPressed: () => _selectNavigationDestination(2),
                icon: const Icon(Icons.tune_rounded),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAccountButton(BuildContext context, bool compact) {
    return Obx(() {
      final model = gFFI.userModel;
      final state = model.accountState.value;
      final signedIn = model.isLogin;
      final label = signedIn
          ? model.displayNameOrUserName
          : state == UserAccountState.disabled
          ? translate('Account')
          : translate('Sign in');
      final handle = model.userName.value.trim();
      final detail = switch (state) {
        UserAccountState.disabled => translate('Disabled'),
        UserAccountState.signedOut => translate('Account'),
        UserAccountState.loading => translate('Loading...'),
        UserAccountState.ready =>
          model.email.value.trim().isNotEmpty
              ? model.email.value.trim()
              : handle.isEmpty
              ? translate('Connected')
              : '@$handle',
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
      final icon = switch (state) {
        UserAccountState.ready => Icons.check_circle_rounded,
        UserAccountState.offline => Icons.cloud_off_rounded,
        UserAccountState.error => Icons.error_rounded,
        UserAccountState.disabled => Icons.block_rounded,
        _ => Icons.circle_rounded,
      };
      return CamelliaAccountButton(
        label: label,
        detail: detail,
        avatarUrl: model.avatar.value,
        statusColor: color,
        statusIcon: icon,
        busy: state == UserAccountState.loading,
        compact: compact,
        onPressed: bind.isDisableAccount()
            ? null
            : () {
                setState(() {
                  _settingsInitialTab = SettingsTabKey.account;
                  _navigationIndex = 2;
                });
              },
      );
    });
  }

  Widget _buildBlock({required Widget child}) {
    return buildRemoteBlock(
      block: _block,
      mask: true,
      use: canBeBlocked,
      child: child,
    );
  }

  Widget buildLeftPane(BuildContext context, {double? width}) {
    final isIncomingOnly = bind.isIncomingOnly();
    final isOutgoingOnly = bind.isOutgoingOnly();
    final children = <Widget>[
      if (!isOutgoingOnly) buildPresetPasswordWarning(),
      if (bind.isCustomClient())
        Align(alignment: Alignment.center, child: loadPowered(context)),
      buildTip(context),
      if (!isOutgoingOnly) buildIDBoard(context),
      if (!isOutgoingOnly) buildPasswordBoard(context),
      FutureBuilder<Widget>(
        future: Future.value(buildHelpCards()),
        builder: (_, data) {
          if (data.hasData) {
            if (isIncomingOnly) {
              if (isInHomePage()) {
                Future.delayed(Duration(milliseconds: 300), () {
                  _updateWindowSize();
                });
              }
            }
            return data.data!;
          } else {
            return const Offstage();
          }
        },
      ),
      buildPluginEntry(),
    ];
    if (isIncomingOnly) {
      children.addAll([
        Divider(),
        OnlineStatusWidget(
          onSvcStatusChanged: () {
            if (isInHomePage()) {
              Future.delayed(Duration(milliseconds: 300), () {
                _updateWindowSize();
              });
            }
          },
        ).marginOnly(bottom: 6, right: 6),
      ]);
    }
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: AnimatedContainer(
        duration: AppMotion.duration(context, AppMotion.stateChange),
        curve: Curves.easeOutCubic,
        width: width ?? (isIncomingOnly ? 340.0 : 330.0),
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    controller: _leftPaneScrollController,
                    padding: const EdgeInsets.fromLTRB(0, 10, 0, 12),
                    child: Column(
                      key: _childKey,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                ),
              ],
            ),
            if (isOutgoingOnly)
              Positioned(
                bottom: 10,
                left: 12,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    child: Obx(
                      () => Icon(
                        Icons.settings,
                        color: _editHover.value
                            ? textColor
                            : Colors.grey.withValues(alpha: 0.5),
                        size: 22,
                      ),
                    ),
                    onTap: () => {
                      if (DesktopSettingPage.tabKeys.isNotEmpty)
                        {
                          DesktopSettingPage.switch2page(
                            DesktopSettingPage.tabKeys[0],
                          ),
                        },
                    },
                    onHover: (value) => _editHover.value = value,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  buildRightPane(BuildContext context) {
    return AnimatedContainer(
      duration: AppMotion.duration(context, AppMotion.stateChange),
      curve: Curves.easeOutCubic,
      color: Colors.transparent,
      child: const ConnectionPage(),
    );
  }

  buildIDBoard(BuildContext context) {
    final model = gFFI.serverModel;
    final theme = Theme.of(context);
    return AppSurface(
      margin: const EdgeInsets.only(left: 14, right: 14, top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: AppVisual.toneContainer(context, AppTone.info),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const AppIconBadge(
            icon: Icons.fingerprint_rounded,
            colors: AppVisual.identityGradient,
            size: 36,
            iconSize: 19,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      translate("ID"),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: AppVisual.subduedText(context),
                      ),
                    ),
                    buildPopupMenu(context),
                  ],
                ),
                GestureDetector(
                  onDoubleTap: () {
                    Clipboard.setData(ClipboardData(text: model.serverId.text));
                    showToast(translate("Copied"));
                  },
                  child: TextFormField(
                    controller: model.serverId,
                    readOnly: true,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.only(top: 4),
                    ),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ).workaroundFreezeLinuxMint(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildPopupMenu(BuildContext context) {
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    RxBool hover = false.obs;
    return InkWell(
      borderRadius: BorderRadius.circular(CamelliaRadius.status),
      onTap: () => _selectNavigationDestination(2),
      child: Tooltip(
        message: translate('Settings'),
        child: Obx(
          () => CircleAvatar(
            radius: 15,
            backgroundColor: hover.value
                ? Theme.of(context).scaffoldBackgroundColor
                : AppVisual.inset(context),
            child: Icon(
              Icons.more_vert_outlined,
              size: 20,
              color: hover.value
                  ? textColor
                  : textColor?.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
      onHover: (value) => hover.value = value,
    );
  }

  buildPasswordBoard(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Consumer<ServerModel>(
        builder: (context, model, child) {
          return buildPasswordBoard2(context, model);
        },
      ),
    );
  }

  buildPasswordBoard2(BuildContext context, ServerModel model) {
    RxBool refreshHover = false.obs;
    RxBool editHover = false.obs;
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    final showOneTime =
        model.approveMode != 'click' &&
        model.verificationMethod != kUsePermanentPassword;
    return AppSurface(
      margin: const EdgeInsets.only(left: 14, right: 14, top: 12, bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: AppVisual.toneContainer(context, AppTone.warning),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const AppIconBadge(
            icon: Icons.key_rounded,
            colors: AppVisual.securityGradient,
            size: 36,
            iconSize: 19,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AutoSizeText(
                  translate("One-time Password"),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppVisual.subduedText(context),
                  ),
                  maxLines: 1,
                ),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onDoubleTap: () {
                          if (showOneTime) {
                            Clipboard.setData(
                              ClipboardData(text: model.serverPasswd.text),
                            );
                            showToast(translate("Copied"));
                          }
                        },
                        child: TextFormField(
                          controller: model.serverPasswd,
                          readOnly: true,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.only(top: 8),
                          ),
                          style: TextStyle(fontSize: 15, color: textColor),
                        ).workaroundFreezeLinuxMint(),
                      ),
                    ),
                    if (showOneTime)
                      AnimatedRotationWidget(
                        onPressed: () => bind.mainUpdateTemporaryPassword(),
                        child: Tooltip(
                          message: translate('Refresh Password'),
                          child: Obx(
                            () => RotatedBox(
                              quarterTurns: 2,
                              child: Icon(
                                Icons.refresh_rounded,
                                color: refreshHover.value
                                    ? textColor
                                    : AppVisual.subduedText(context),
                                size: 21,
                              ),
                            ),
                          ),
                        ),
                        onHover: (value) => refreshHover.value = value,
                      ).marginOnly(right: 8, top: 4),
                    if (!bind.isDisableSettings())
                      InkWell(
                        child: Tooltip(
                          message: translate('Change Password'),
                          child: Obx(
                            () => Icon(
                              Icons.edit_rounded,
                              color: editHover.value
                                  ? textColor
                                  : AppVisual.subduedText(context),
                              size: 20,
                            ).marginOnly(right: 4, top: 4),
                          ),
                        ),
                        onTap: () => DesktopSettingPage.switch2page(
                          SettingsTabKey.safety,
                        ),
                        onHover: (value) => editHover.value = value,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  buildTip(BuildContext context) {
    final isOutgoingOnly = bind.isOutgoingOnly();
    return Padding(
      padding: const EdgeInsets.only(
        left: 14.0,
        right: 14,
        top: 16.0,
        bottom: 5,
      ),
      child: AppSectionHeader(
        icon: isOutgoingOnly ? null : Icons.desktop_windows_rounded,
        colors: AppVisual.connectGradient,
        title: isOutgoingOnly
            ? bind.mainGetAppNameSync()
            : translate("Your Desktop"),
        subtitle: translate(
          isOutgoingOnly ? "outgoing_only_desk_tip" : "desk_tip",
        ),
      ),
    );
  }

  Widget _buildCardButton(
    String text,
    GestureTapCallback onPressed, {
    bool outline = false,
  }) {
    return SizedBox(
      height: 34,
      child: outline
          ? OutlinedButton(
              onPressed: onPressed,
              child: Text(text, overflow: TextOverflow.ellipsis),
            )
          : FilledButton(
              onPressed: onPressed,
              child: Text(text, overflow: TextOverflow.ellipsis),
            ),
    );
  }

  Widget _buildInstallActionRow(
    String btnText,
    GestureTapCallback onPressed,
    String? help,
    String? link,
  ) {
    if (btnText.isEmpty && help == null) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        if (btnText.isNotEmpty)
          Expanded(child: _buildCardButton(translate(btnText), onPressed)),
        if (help != null) ...[
          if (btnText.isNotEmpty) const SizedBox(width: 8),
          Expanded(
            child: _buildCardButton(
              translate(help),
              () async => await launchUrl(Uri.parse(link!)),
              outline: true,
            ),
          ),
        ],
      ],
    );
  }

  Widget buildHelpCards() {
    if (systemError.isNotEmpty) {
      return buildInstallCard("", systemError, "", () {}, tone: AppTone.danger);
    }

    if (isWindows && !bind.isDisableInstallation()) {
      if (!bind.mainIsInstalled()) {
        return buildInstallCard(
          "",
          bind.isOutgoingOnly() ? "" : "install_tip",
          "Install",
          () async {
            await rustDeskWinManager.closeAllSubWindows();
            bind.mainGotoInstall();
          },
        );
      } else if (bind.mainIsInstalledLowerVersion()) {
        return buildInstallCard(
          "Status",
          "Your installation is lower version.",
          "Click to upgrade",
          () async {
            await rustDeskWinManager.closeAllSubWindows();
            bind.mainUpdateMe();
          },
        );
      }
    } else if (isMacOS) {
      final isOutgoingOnly = bind.isOutgoingOnly();
      if (!(isOutgoingOnly || bind.mainIsCanScreenRecording(prompt: false))) {
        return buildInstallCard(
          "Permissions",
          "config_screen",
          "Configure",
          () async {
            bind.mainIsCanScreenRecording(prompt: true);
            watchIsCanScreenRecording = true;
          },
          help: 'Help',
          link: translate("doc_mac_permission"),
        );
      } else if (!isOutgoingOnly && !bind.mainIsProcessTrusted(prompt: false)) {
        return buildInstallCard(
          "Permissions",
          "config_acc",
          "Configure",
          () async {
            bind.mainIsProcessTrusted(prompt: true);
            watchIsProcessTrust = true;
          },
          help: 'Help',
          link: translate("doc_mac_permission"),
        );
      } else if (!bind.mainIsCanInputMonitoring(prompt: false)) {
        return buildInstallCard(
          "Permissions",
          "config_input",
          "Configure",
          () async {
            bind.mainIsCanInputMonitoring(prompt: true);
            watchIsInputMonitoring = true;
          },
          help: 'Help',
          link: translate("doc_mac_permission"),
        );
      } else if (!isOutgoingOnly &&
          !svcStopped.value &&
          bind.mainIsInstalled() &&
          !bind.mainIsInstalledDaemon(prompt: false)) {
        return buildInstallCard("", "install_daemon_tip", "Install", () async {
          bind.mainIsInstalledDaemon(prompt: true);
        });
      }
      //// Disable microphone configuration for macOS. We will request the permission when needed.
      // else if ((await osxCanRecordAudio() !=
      //     PermissionAuthorizeType.authorized)) {
      //   return buildInstallCard("Permissions", "config_microphone", "Configure",
      //       () async {
      //     osxRequestAudio();
      //     watchIsCanRecordAudio = true;
      //   });
      // }
    } else if (isLinux) {
      if (bind.isOutgoingOnly()) {
        return Container();
      }
      final LinuxCards = <Widget>[];
      if (bind.isSelinuxEnforcing()) {
        // Check is SELinux enforcing, but show user a tip of is SELinux enabled for simple.
        final keyShowSelinuxHelpTip = "show-selinux-help-tip";
        if (bind.mainGetLocalOption(key: keyShowSelinuxHelpTip) != 'N') {
          LinuxCards.add(
            buildInstallCard(
              "Warning",
              "selinux_tip",
              "",
              () async {},
              marginTop: LinuxCards.isEmpty ? 20.0 : 5.0,
              help: 'Help',
              link:
                  'https://github.com/camellia-computing/remote-client/blob/main/docs/platform-notes.md#linux-display-requirements',
              closeButton: true,
              closeOption: keyShowSelinuxHelpTip,
            ),
          );
        }
      }
      if (bind.mainCurrentIsWayland()) {
        LinuxCards.add(
          buildInstallCard(
            "Warning",
            "wayland_experiment_tip",
            "",
            () async {},
            marginTop: LinuxCards.isEmpty ? 20.0 : 5.0,
            help: 'Help',
            link:
                'https://github.com/camellia-computing/remote-client/blob/main/docs/platform-notes.md#linux-display-requirements',
          ),
        );
      } else if (bind.mainIsLoginWayland()) {
        LinuxCards.add(
          buildInstallCard(
            "Warning",
            "Login screen using Wayland is not supported",
            "",
            () async {},
            marginTop: LinuxCards.isEmpty ? 20.0 : 5.0,
            help: 'Help',
            link:
                'https://github.com/camellia-computing/remote-client/blob/main/docs/platform-notes.md#linux-display-requirements',
          ),
        );
      }
      if (LinuxCards.isNotEmpty) {
        return Column(children: LinuxCards);
      }
    }
    if (bind.isIncomingOnly()) {
      return Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton(
          onPressed: () {
            SystemNavigator.pop(); // Close the application
            // https://github.com/flutter/flutter/issues/66631
            if (isWindows) {
              exit(0);
            }
          },
          child: Text(translate('Quit')),
        ),
      ).marginAll(14);
    }
    return Container();
  }

  Widget buildInstallCard(
    String title,
    String content,
    String btnText,
    GestureTapCallback onPressed, {
    double marginTop = 20.0,
    String? help,
    String? link,
    bool? closeButton,
    String? closeOption,
    AppTone? tone,
  }) {
    if (bind.mainGetBuildinOption(key: kOptionHideHelpCards) == 'Y' &&
        content != 'install_daemon_tip') {
      return const SizedBox();
    }
    void closeCard() async {
      if (closeOption != null) {
        await bind.mainSetLocalOption(key: closeOption, value: 'N');
        if (bind.mainGetLocalOption(key: closeOption) == 'N') {
          setState(() {
            isCardClosed = true;
          });
        }
      } else {
        setState(() {
          isCardClosed = true;
        });
      }
    }

    final theme = Theme.of(context);
    final cardTone =
        tone ??
        switch (title) {
          'Warning' => AppTone.warning,
          'Permissions' => AppTone.info,
          'Status' => AppTone.brand,
          _ => AppTone.info,
        };
    final toneColor = AppVisual.tone(context, cardTone);
    final toneIcon = switch (cardTone) {
      AppTone.warning => Icons.warning_rounded,
      AppTone.danger => Icons.error_rounded,
      AppTone.brand => Icons.campaign_rounded,
      _ => Icons.info_rounded,
    };
    return Stack(
      children: [
        Container(
          margin: EdgeInsets.fromLTRB(
            14,
            marginTop,
            14,
            bind.isIncomingOnly() ? marginTop : 0,
          ),
          child: AppSurface(
            padding: const EdgeInsets.all(14),
            color: AppVisual.toneContainer(context, cardTone),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(toneIcon, size: 18, color: toneColor)
                        .marginOnly(top: 1),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (title.isNotEmpty)
                            Text(
                              translate(title),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ).marginOnly(bottom: content.isEmpty ? 0 : 4),
                          if (content.isNotEmpty)
                            Text(
                              translate(content),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.82,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ).marginOnly(
                  bottom: btnText.isEmpty && help == null ? 0 : 12,
                ),
                _buildInstallActionRow(btnText, onPressed, help, link),
              ],
            ),
          ),
        ),
        if (closeButton != null && closeButton == true)
          Positioned(
            top: marginTop + 2,
            right: 16,
            child: IconButton(
              icon: Icon(
                Icons.close,
                color: AppVisual.subduedText(context),
                size: 18,
              ),
              onPressed: closeCard,
            ),
          ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _updateTimer = periodic_immediate(const Duration(seconds: 1), () async {
      await gFFI.serverModel.fetchID();
      final error = await bind.mainGetError();
      if (systemError != error) {
        systemError = error;
        setState(() {});
      }
      final v = await mainGetBoolOption(kOptionStopService);
      if (v != svcStopped.value) {
        svcStopped.value = v;
        setState(() {});
      }
      if (watchIsCanScreenRecording) {
        if (bind.mainIsCanScreenRecording(prompt: false)) {
          watchIsCanScreenRecording = false;
          setState(() {});
        }
      }
      if (watchIsProcessTrust) {
        if (bind.mainIsProcessTrusted(prompt: false)) {
          watchIsProcessTrust = false;
          setState(() {});
        }
      }
      if (watchIsInputMonitoring) {
        if (bind.mainIsCanInputMonitoring(prompt: false)) {
          watchIsInputMonitoring = false;
          // Do not notify for now.
          // Monitoring may not take effect until the process is restarted.
          // rustDeskWinManager.call(
          //     WindowType.RemoteDesktop, kWindowDisableGrabKeyboard, '');
          setState(() {});
        }
      }
      if (watchIsCanRecordAudio) {
        if (isMacOS) {
          Future.microtask(() async {
            if ((await osxCanRecordAudio() ==
                PermissionAuthorizeType.authorized)) {
              watchIsCanRecordAudio = false;
              setState(() {});
            }
          });
        } else {
          watchIsCanRecordAudio = false;
          setState(() {});
        }
      }
    });
    Get.put<RxBool>(svcStopped, tag: 'stop-service');
    rustDeskWinManager.registerActiveWindowListener(onActiveWindowChanged);

    screenToMap(window_size.Screen screen) => {
      'frame': {
        'l': screen.frame.left,
        't': screen.frame.top,
        'r': screen.frame.right,
        'b': screen.frame.bottom,
      },
      'visibleFrame': {
        'l': screen.visibleFrame.left,
        't': screen.visibleFrame.top,
        'r': screen.visibleFrame.right,
        'b': screen.visibleFrame.bottom,
      },
      'scaleFactor': screen.scaleFactor,
    };

    bool isChattyMethod(String methodName) {
      switch (methodName) {
        case kWindowBumpMouse:
          return true;
      }

      return false;
    }

    rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
      if (!isChattyMethod(call.method)) {
        debugPrint(
          "[Main] call ${call.method} with args ${call.arguments} from window $fromWindowId",
        );
      }
      if (call.method == kWindowMainWindowOnTop) {
        windowOnTop(null);
      } else if (call.method == kWindowRefreshCurrentUser) {
        gFFI.userModel.refreshCurrentUser();
      } else if (call.method == kWindowGetWindowInfo) {
        final screen = (await window_size.getWindowInfo()).screen;
        if (screen == null) {
          return '';
        } else {
          return jsonEncode(screenToMap(screen));
        }
      } else if (call.method == kWindowGetScreenList) {
        return jsonEncode(
          (await window_size.getScreenList()).map(screenToMap).toList(),
        );
      } else if (call.method == kWindowActionRebuild) {
        reloadCurrentWindow();
      } else if (call.method == kWindowEventShow) {
        await rustDeskWinManager.registerActiveWindow(call.arguments["id"]);
      } else if (call.method == kWindowEventHide) {
        await rustDeskWinManager.unregisterActiveWindow(call.arguments['id']);
      } else if (call.method == kWindowConnect) {
        await connectMainDesktop(
          call.arguments['id'],
          isFileTransfer: call.arguments['isFileTransfer'],
          isViewCamera: call.arguments['isViewCamera'],
          isTerminal: call.arguments['isTerminal'],
          isTcpTunneling: call.arguments['isTcpTunneling'],
          isRDP: call.arguments['isRDP'],
          password: call.arguments['password'],
          forceRelay: call.arguments['forceRelay'],
          connToken: call.arguments['connToken'],
        );
      } else if (call.method == kWindowBumpMouse) {
        return RdPlatformChannel.instance.bumpMouse(
          dx: call.arguments['dx'],
          dy: call.arguments['dy'],
        );
      } else if (call.method == kWindowEventMoveTabToNewWindow) {
        final args = call.arguments.split(',');
        int? windowId;
        try {
          windowId = int.parse(args[0]);
        } catch (e) {
          debugPrint("Failed to parse window id '${call.arguments}': $e");
        }
        WindowType? windowType;
        try {
          windowType = WindowType.values.byName(args[3]);
        } catch (e) {
          debugPrint("Failed to parse window type '${call.arguments}': $e");
        }
        if (windowId != null && windowType != null) {
          await rustDeskWinManager.moveTabToNewWindow(
            windowId,
            args[1],
            args[2],
            windowType,
          );
        }
      } else if (call.method == kWindowEventOpenMonitorSession) {
        final args = jsonDecode(call.arguments);
        final windowId = args['window_id'] as int;
        final peerId = args['peer_id'] as String;
        final display = args['display'] as int;
        final displayCount = args['display_count'] as int;
        final windowType = args['window_type'] as int;
        final screenRect = parseParamScreenRect(args);
        await rustDeskWinManager.openMonitorSession(
          windowId,
          peerId,
          display,
          displayCount,
          screenRect,
          windowType,
        );
      } else if (call.method == kWindowEventRemoteWindowCoords) {
        final windowId = int.tryParse(call.arguments);
        if (windowId != null) {
          return jsonEncode(
            await rustDeskWinManager.getOtherRemoteWindowCoords(windowId),
          );
        }
      }
    });
    _uniLinksSubscription = listenUniLinks();

    if (bind.isIncomingOnly()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateWindowSize();
      });
    }
    WidgetsBinding.instance.addObserver(this);
  }

  _updateWindowSize() {
    RenderObject? renderObject = _childKey.currentContext?.findRenderObject();
    if (renderObject == null) {
      return;
    }
    if (renderObject is RenderBox) {
      final size = renderObject.size;
      if (size != imcomingOnlyHomeSize) {
        imcomingOnlyHomeSize = size;
        windowManager.setSize(getIncomingOnlyHomeSize());
      }
    }
  }

  @override
  void dispose() {
    _uniLinksSubscription?.cancel();
    Get.delete<RxBool>(tag: 'stop-service');
    _updateTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _leftPaneScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      shouldBeBlocked(_block, canBeBlocked);
    }
  }

  Widget buildPluginEntry() {
    final entries = PluginUiManager.instance.entries.entries;
    return Offstage(
      offstage: entries.isEmpty,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...entries.map((entry) {
            return entry.value;
          }),
        ],
      ),
    );
  }
}

void setPasswordDialog({VoidCallback? notEmptyCallback}) async {
  final p0 = TextEditingController(text: "");
  final p1 = TextEditingController(text: "");
  var errMsg0 = "";
  var errMsg1 = "";
  final localPasswordSet =
      (await bind.mainGetCommon(key: "local-permanent-password-set")) == "true";
  final permanentPasswordSet =
      (await bind.mainGetCommon(key: "permanent-password-set")) == "true";
  final presetPassword = permanentPasswordSet && !localPasswordSet;
  var canSubmit = false;
  final RxString rxPass = "".obs;
  final rules = [
    DigitValidationRule(),
    UppercaseValidationRule(),
    LowercaseValidationRule(),
    // SpecialCharacterValidationRule(),
    MinCharactersValidationRule(8),
  ];
  final maxLength = bind.mainMaxEncryptLen();
  final statusTip = localPasswordSet
      ? translate('password-hidden-tip')
      : (presetPassword ? translate('preset-password-in-use-tip') : '');
  final showStatusTipOnMobile =
      statusTip.isNotEmpty && !isDesktop && !isWebDesktop;

  gFFI.dialogManager.show((setState, close, context) {
    updateCanSubmit() {
      canSubmit = p0.text.trim().isNotEmpty || p1.text.trim().isNotEmpty;
    }

    submit() async {
      if (!canSubmit) {
        return;
      }
      setState(() {
        errMsg0 = "";
        errMsg1 = "";
      });
      final pass = p0.text.trim();
      if (pass.isNotEmpty) {
        final Iterable violations = rules.where((r) => !r.validate(pass));
        if (violations.isNotEmpty) {
          setState(() {
            errMsg0 =
                '${translate('Prompt')}: ${violations.map((r) => r.name).join(', ')}';
          });
          return;
        }
      }
      if (p1.text.trim() != pass) {
        setState(() {
          errMsg1 =
              '${translate('Prompt')}: ${translate("The confirmation is not identical.")}';
        });
        return;
      }
      final ok = await bind.mainSetPermanentPasswordWithResult(password: pass);
      if (!ok) {
        setState(() {
          errMsg0 = '${translate('Prompt')}: ${translate("Failed")}';
        });
        return;
      }
      if (pass.isNotEmpty) {
        notEmptyCallback?.call();
      }
      close();
    }

    return CustomAlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.key, color: MyTheme.accent),
          Text(translate("Set Password")).paddingOnly(left: 10),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 500),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: showStatusTipOnMobile ? 0.0 : 6.0),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: translate('Password'),
                      errorText: errMsg0.isNotEmpty ? errMsg0 : null,
                    ),
                    controller: p0,
                    autofocus: true,
                    onChanged: (value) {
                      rxPass.value = value.trim();
                      setState(() {
                        errMsg0 = '';
                        updateCanSubmit();
                      });
                    },
                    maxLength: maxLength,
                  ).workaroundFreezeLinuxMint(),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(child: PasswordStrengthIndicator(password: rxPass)),
              ],
            ).marginOnly(top: 2, bottom: showStatusTipOnMobile ? 2 : 8),
            SizedBox(height: showStatusTipOnMobile ? 0.0 : 8.0),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: translate('Confirmation'),
                      errorText: errMsg1.isNotEmpty ? errMsg1 : null,
                    ),
                    controller: p1,
                    onChanged: (value) {
                      setState(() {
                        errMsg1 = '';
                        updateCanSubmit();
                      });
                    },
                    maxLength: maxLength,
                  ).workaroundFreezeLinuxMint(),
                ),
              ],
            ),
            if (statusTip.isNotEmpty)
              Row(
                children: [
                  Icon(
                    Icons.info,
                    color: AppVisual.tone(context, AppTone.warning),
                    size: 18,
                  ).marginOnly(right: 6),
                  Expanded(
                    child: Text(
                      statusTip,
                      style: const TextStyle(fontSize: 13, height: 1.1),
                    ),
                  ),
                ],
              ).marginOnly(top: 6, bottom: 2),
            SizedBox(height: showStatusTipOnMobile ? 0.0 : 8.0),
            Obx(
              () => Wrap(
                runSpacing: showStatusTipOnMobile ? 2.0 : 8.0,
                spacing: 4,
                children: rules.map((e) {
                  var checked = e.validate(rxPass.value.trim());
                  final tone = checked ? AppTone.success : AppTone.danger;
                  return Chip(
                    label: Text(
                      e.name,
                      style: TextStyle(color: AppVisual.tone(context, tone)),
                    ),
                    side: BorderSide(
                      color: AppVisual.tone(
                        context,
                        tone,
                      ).withValues(alpha: 0.35),
                    ),
                    backgroundColor: AppVisual.toneContainer(context, tone),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
      actions: (() {
        final cancelButton = dialogButton(
          "Cancel",
          icon: Icon(Icons.close_rounded),
          onPressed: close,
          isOutline: true,
        );
        final removeButton = dialogButton(
          "Remove",
          icon: Icon(Icons.delete_outline_rounded),
          onPressed: () async {
            setState(() {
              errMsg0 = "";
              errMsg1 = "";
            });
            final ok = await bind.mainSetPermanentPasswordWithResult(
              password: "",
            );
            if (!ok) {
              setState(() {
                errMsg0 = '${translate('Prompt')}: ${translate("Failed")}';
              });
              return;
            }
            close();
          },
          buttonStyle: ButtonStyle(
            backgroundColor: WidgetStatePropertyAll(
              AppVisual.tone(context, AppTone.danger),
            ),
          ),
        );
        final okButton = dialogButton(
          "OK",
          icon: Icon(Icons.done_rounded),
          onPressed: canSubmit ? submit : null,
        );
        if (!isDesktop && !isWebDesktop && localPasswordSet) {
          return [
            Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    cancelButton,
                    const SizedBox(width: 4),
                    removeButton,
                    const SizedBox(width: 4),
                    okButton,
                  ],
                ),
              ),
            ),
          ];
        }
        return [cancelButton, if (localPasswordSet) removeButton, okButton];
      })(),
      onSubmit: canSubmit ? submit : null,
      onCancel: close,
    );
  });
}
