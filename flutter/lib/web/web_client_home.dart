import 'dart:async';
import 'dart:convert';

import 'package:auto_size_text_field/auto_size_text_field.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/formatter/id_formatter.dart';
import 'package:camellia_remote_app/common/widgets/adaptive_layout.dart';
import 'package:camellia_remote_app/common/widgets/autocomplete.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/common/widgets/peer_tab_page.dart';
import 'package:camellia_remote_app/models/ab_model.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/peer_tab_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/models/user_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/web/settings_page.dart';
import 'package:camellia_remote_app/web/web_client_settings_page.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../common.dart';
import '../models/model.dart';
import '../models/platform_model.dart';

const Color _camelliaInk = CamelliaColors.lightText;
const Color _camelliaRose = CamelliaColors.coral;
const Color _camelliaRoseDark = CamelliaColors.coralStrong;
const Color _camelliaBlush = CamelliaColors.lightPetalWash;
const Color _camelliaGold = CamelliaColors.sun;
const Color _camelliaSlate = CamelliaColors.lightMuted;
const Color _camelliaMint = CamelliaColors.aqua;
const Color _camelliaLine = CamelliaColors.lightBorder;

TextStyle _camelliaFraunces({
  double? fontSize,
  FontWeight? fontWeight,
  Color? color,
  double? letterSpacing,
  double? height,
}) {
  return TextStyle(
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
    fontFamily: 'SF Pro Display',
    fontFamilyFallback: const [
      'SF Pro Text',
      'Segoe UI',
      'Helvetica Neue',
      'Arial',
    ],
  );
}

TextStyle _camelliaOutfit({
  double? fontSize,
  FontWeight? fontWeight,
  Color? color,
  double? letterSpacing,
  double? height,
}) {
  return TextStyle(
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
    fontFamily: 'SF Pro Text',
    fontFamilyFallback: const [
      'Segoe UI',
      'Helvetica Neue',
      'Arial',
      'sans-serif',
    ],
  );
}

class WebClientHomePage extends StatefulWidget {
  const WebClientHomePage({super.key});

  @override
  State<WebClientHomePage> createState() => _WebClientHomePageState();
}

class _WebClientHomePageState extends State<WebClientHomePage> {
  final IDTextEditingController _idController = IDTextEditingController();
  final FocusNode _idFocusNode = FocusNode();
  final TextEditingController _idEditingController = TextEditingController();
  final AllPeersLoader _allPeersLoader = AllPeersLoader();

  StreamSubscription? _uniLinksSubscription;
  Iterable<Peer> _autocompleteOpts = [];
  bool _idEmpty = true;
  bool _isFieldFocused = false;
  Timer? _statusTimer;
  String _myId = '';
  int _navigationIndex = 0;

  @override
  void initState() {
    super.initState();
    stateGlobal.isInMainPage = true;
    if (!isWeb) {
      _uniLinksSubscription = listenUniLinks();
    }
    _allPeersLoader.init(setState);
    _idController.addListener(() {
      final empty = _idController.text.isEmpty;
      if (empty != _idEmpty) {
        setState(() {
          _idEmpty = empty;
        });
      }
    });
    _idFocusNode.addListener(_onFocusChanged);

    if (_idController.text.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final lastRemoteId = await bind.mainGetLastRemoteId();
        if (lastRemoteId != _idController.id) {
          setState(() {
            _idController.id = lastRemoteId;
          });
        }
      });
    }

    Get.put<IDTextEditingController>(_idController);
    Get.put<TextEditingController>(_idEditingController);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleUnilink(context);
    });
    _syncClientStatus();
    _refreshMyId();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _syncClientStatus();
    });
    gFFI.peerTabModel.addListener(_syncNavigationWithPeerTab);
  }

  @override
  void dispose() {
    _uniLinksSubscription?.cancel();
    _idController.dispose();
    _idFocusNode.removeListener(_onFocusChanged);
    _idFocusNode.dispose();
    _idEditingController.dispose();
    _statusTimer?.cancel();
    _allPeersLoader.clear();
    gFFI.peerTabModel.removeListener(_syncNavigationWithPeerTab);
    if (Get.isRegistered<IDTextEditingController>()) {
      Get.delete<IDTextEditingController>();
    }
    if (Get.isRegistered<TextEditingController>()) {
      Get.delete<TextEditingController>();
    }
    super.dispose();
  }

  Future<void> _syncClientStatus() async {
    try {
      final rawStatus = await bind.mainGetConnectStatus();
      final status = jsonDecode(rawStatus) as Map<String, dynamic>;
      final statusNum = (status['status_num'] as num?)?.toInt() ?? -1;
      if (statusNum == 1) {
        stateGlobal.svcStatus.value = SvcStatus.ready;
      } else if (statusNum == 0) {
        stateGlobal.svcStatus.value = SvcStatus.connecting;
      } else {
        stateGlobal.svcStatus.value = SvcStatus.notReady;
      }
    } catch (_) {
      stateGlobal.svcStatus.value = SvcStatus.notReady;
    }

    // Control-only web client: no local ID/password status to refresh.
    if (_myId.isEmpty) {
      _refreshMyId();
    }
  }

  Future<void> _refreshMyId() async {
    try {
      final id = await bind.mainGetMyId();
      if (mounted && id.isNotEmpty && id != _myId) {
        setState(() {
          _myId = id;
        });
      }
    } catch (_) {
      // Ignore ID refresh failures; keep last known value.
    }
  }

  Future<void> _rotateMyId() async {
    try {
      await bind.mainChangeId(newId: '');
      await _refreshMyId();
    } catch (_) {
      // Ignore rotation errors for now.
    }
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<FfiModel>(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = AppLayout.forWidth(constraints.maxWidth);
        final compact = layout == AppLayoutSize.compact;
        final content = AdaptiveContent(
          maxWidth: 1220,
          child: Column(
            children: [
              _buildWorkspaceHeader(context, compact),
              const SizedBox(height: 18),
              if (compact) ...[
                _buildConnectionSection(true),
                const SizedBox(height: 12),
                _buildStatusCard(),
              ] else
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _buildConnectionSection(false)),
                      const SizedBox(width: 18),
                      SizedBox(width: 324, child: _buildStatusCard()),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              _buildPeersPanel(compact),
            ],
          ),
        );
        return Scaffold(
          backgroundColor: AppVisual.tokens(context).page,
          bottomNavigationBar: compact
              ? NavigationBar(
                  selectedIndex: _navigationIndex,
                  onDestinationSelected: _selectNavigationDestination,
                  destinations: [
                    NavigationDestination(
                      icon: const Icon(Icons.devices_outlined),
                      selectedIcon: const Icon(Icons.devices_rounded),
                      label: translate('Devices'),
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.menu_book_outlined),
                      selectedIcon: const Icon(Icons.menu_book_rounded),
                      label: translate('Address book'),
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.tune_outlined),
                      selectedIcon: const Icon(Icons.tune_rounded),
                      label: translate('Settings'),
                    ),
                  ],
                )
              : null,
          body: CamelliaBackdrop(
            child: Row(
              children: [
                if (!compact)
                  CamelliaNavigationRail(
                    extended: layout == AppLayoutSize.expanded,
                    selectedIndex: _navigationIndex,
                    onDestinationSelected: _selectNavigationDestination,
                    destinations: [
                      NavigationDestination(
                        icon: const Icon(Icons.devices_outlined),
                        selectedIcon: const Icon(Icons.devices_rounded),
                        label: translate('Devices'),
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.menu_book_outlined),
                        selectedIcon: const Icon(Icons.menu_book_rounded),
                        label: translate('Address book'),
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.tune_outlined),
                        selectedIcon: const Icon(Icons.tune_rounded),
                        label: translate('Settings'),
                      ),
                    ],
                  ),
                Expanded(
                  child: SafeArea(
                    child: FocusTraversalGroup(
                      policy: WidgetOrderTraversalPolicy(),
                      child: SingleChildScrollView(child: content),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _selectNavigationDestination(int index) {
    if (index == 2) {
      _openSettings();
      return;
    }
    gFFI.peerTabModel.setCurrentTab(
      index == 1 ? PeerTabIndex.ab.index : PeerTabIndex.recent.index,
    );
    if (index == 1) {
      gFFI.abModel.pullAb(force: ForcePullAb.listAndCurrent, quiet: false);
    }
    setState(() => _navigationIndex = index);
  }

  void _syncNavigationWithPeerTab() {
    final index = gFFI.peerTabModel.currentTab == PeerTabIndex.ab.index ? 1 : 0;
    if (mounted && index != _navigationIndex) {
      setState(() => _navigationIndex = index);
    }
  }

  void _openSettings() {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const WebClientSettingsPage()),
    );
  }

  Widget _buildWorkspaceHeader(BuildContext context, bool compact) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: CamelliaPageHeader(
        title: translate('Remote workspace'),
        subtitle: translate(
          'Connect and manage trusted devices in your browser',
        ),
        leading: compact ? const CamelliaAnimatedBrandMark(size: 42) : null,
        actions: [
          _buildAccountButton(compact),
        ],
      ),
    );
  }

  Widget _buildAccountButton(bool compact) {
    return Obx(() {
      final model = gFFI.userModel;
      final state = model.accountState.value;
      return CamelliaAccountButton(
        label: model.isLogin
            ? model.displayNameOrUserName
            : translate('Sign in'),
        detail: model.isLogin
            ? model.email.value.trim().isNotEmpty
                  ? model.email.value.trim()
                  : '@${model.userName.value}'
            : translate('Account'),
        avatarUrl: model.avatar.value,
        statusColor: switch (state) {
          UserAccountState.ready => AppVisual.tone(context, AppTone.success),
          UserAccountState.offline => AppVisual.tone(context, AppTone.warning),
          UserAccountState.error => AppVisual.tone(context, AppTone.danger),
          _ => Theme.of(context).colorScheme.primary,
        },
        statusIcon: state == UserAccountState.offline
            ? Icons.cloud_off_rounded
            : Icons.check_circle_rounded,
        busy: state == UserAccountState.loading,
        compact: compact,
        onPressed: _openSettings,
      );
    });
  }

  void _onFocusChanged() {
    final focused = _idFocusNode.hasFocus;
    if (focused != _isFieldFocused) {
      setState(() {
        _isFieldFocused = focused;
      });
    }
    _idEmpty = _idEditingController.text.isEmpty;
    if (_idFocusNode.hasFocus) {
      if (_allPeersLoader.needLoad) {
        _allPeersLoader.getAllPeers();
      }
      final textLength = _idEditingController.value.text.length;
      _idEditingController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: textLength,
      );
    }
  }

  void _onConnect({
    bool isFileTransfer = false,
    bool isViewCamera = false,
    bool isTerminal = false,
  }) {
    final id = _idController.id;
    connect(
      context,
      id,
      isFileTransfer: isFileTransfer,
      isViewCamera: isViewCamera,
      isTerminal: isTerminal,
    );
  }

  void _handleUnilink(BuildContext context) {
    if (webInitialLink.isEmpty) {
      return;
    }
    final link = webInitialLink;
    webInitialLink = '';
    final splitter = ["/#/", "/#", "#/", "#"];
    var fakelink = '';
    for (var s in splitter) {
      if (link.contains(s)) {
        var list = link.split(s);
        if (list.length < 2 || list[1].isEmpty) {
          return;
        }
        list.removeAt(0);
        fakelink = "${bind.mainUriPrefixSync()}${list.join(s)}";
        break;
      }
    }
    if (fakelink.isEmpty) {
      return;
    }
    final uri = Uri.tryParse(fakelink);
    if (uri == null) {
      return;
    }
    final args = urlLinkToCmdArgs(uri);
    if (args == null || args.isEmpty) {
      return;
    }
    bool isFileTransfer = false;
    bool isViewCamera = false;
    bool isTerminal = false;
    String? id;
    String? password;
    for (int i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--connect':
        case '--play':
          id = args[i + 1];
          i++;
          break;
        case '--file-transfer':
          isFileTransfer = true;
          id = args[i + 1];
          i++;
          break;
        case '--view-camera':
          isViewCamera = true;
          id = args[i + 1];
          i++;
          break;
        case '--terminal':
          isTerminal = true;
          id = args[i + 1];
          i++;
          break;
        case '--terminal-admin':
          setEnvTerminalAdmin();
          isTerminal = true;
          id = args[i + 1];
          i++;
          break;
        case '--password':
          password = args[i + 1];
          i++;
          break;
        default:
          break;
      }
    }
    if (id != null) {
      connect(
        context,
        id,
        isFileTransfer: isFileTransfer,
        isViewCamera: isViewCamera,
        isTerminal: isTerminal,
        password: password,
      );
    }
  }

  // Legacy decorative helpers remain available for downstream custom web
  // builds, but the default client uses the theme-driven workspace above.
  // ignore: unused_element
  Widget _buildBackgroundDecoration() {
    return Stack(
      children: [
        Positioned(
          top: -120,
          left: -130,
          child: _buildGlow(
            size: 300,
            color: _camelliaRose.withValues(alpha: 0.18),
            intensity: 0.42,
          ),
        ),
        Positioned(
          top: -140,
          right: -70,
          child: _buildGlow(
            size: 360,
            color: _camelliaBlush.withValues(alpha: 0.7),
            intensity: 0.6,
          ),
        ),
        Positioned(
          top: 140,
          right: -120,
          child: _buildGlow(
            size: 280,
            color: _camelliaGold.withValues(alpha: 0.16),
            intensity: 0.34,
          ),
        ),
        Positioned(
          bottom: -170,
          left: -40,
          child: _buildGlow(
            size: 340,
            color: _camelliaMint.withValues(alpha: 0.16),
            intensity: 0.45,
          ),
        ),
        Positioned(
          top: 210,
          left: -100,
          child: _buildGlow(
            size: 260,
            color: _camelliaGold.withValues(alpha: 0.14),
            intensity: 0.35,
          ),
        ),
        Positioned(
          bottom: 90,
          right: -60,
          child: _buildGlow(
            size: 260,
            color: _camelliaMint.withValues(alpha: 0.15),
            intensity: 0.34,
          ),
        ),
        Positioned(
          top: 280,
          right: 80,
          child: _buildRibbon(
            width: 220,
            height: 98,
            colorA: _camelliaRose.withValues(alpha: 0.16),
            colorB: _camelliaMint.withValues(alpha: 0.12),
            angle: 0.36,
          ),
        ),
        Positioned(
          bottom: 180,
          left: 90,
          child: _buildRibbon(
            width: 190,
            height: 86,
            colorA: _camelliaGold.withValues(alpha: 0.13),
            colorB: _camelliaBlush.withValues(alpha: 0.2),
            angle: -0.28,
          ),
        ),
      ],
    );
  }

  Widget _buildGlow({
    required double size,
    required Color color,
    double intensity = 0.5,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withValues(alpha: intensity),
            color.withValues(alpha: 0.0),
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildTopBar(bool isNarrow, bool isPhone) {
    if (isPhone) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildBrandMark(),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bind.mainGetAppNameSync(),
                        style: _camelliaFraunces(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          color: _camelliaInk,
                        ),
                      ),
                      Text(
                        translate('Web Client'),
                        style: _camelliaOutfit(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: _camelliaSlate,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _buildChip(
                  icon: Icons.verified_user_outlined,
                  label: translate('Secure'),
                  color: _camelliaMint,
                ),
                const Spacer(),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _camelliaLine.withValues(alpha: 0.8),
                    ),
                  ),
                  child: const WebSettingsPage(),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isNarrow ? 16 : 24,
        vertical: 8,
      ),
      child: Row(
        children: [
          _buildBrandMark(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bind.mainGetAppNameSync(),
                  style: _camelliaFraunces(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: _camelliaInk,
                    letterSpacing: 0.2,
                  ),
                ),
                Text(
                  translate('Web Client'),
                  style: _camelliaOutfit(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _camelliaSlate,
                  ),
                ),
              ],
            ),
          ),
          if (!isNarrow)
            _buildChip(
              icon: Icons.verified_user_outlined,
              label: translate('Secure'),
              color: _camelliaMint,
            ),
          const SizedBox(width: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _camelliaLine.withValues(alpha: 0.8)),
            ),
            child: const WebSettingsPage(),
          ),
        ],
      ),
    );
  }

  Widget _buildBrandMark() {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          colors: [_camelliaRose, _camelliaRoseDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: _camelliaRose.withValues(alpha: 0.24),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Center(
        child: Text(
          'C',
          style: _camelliaFraunces(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildHeroSection(bool isNarrow, bool isPhone) {
    final hero = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          translate('Control Remote Desktop'),
          style: _camelliaFraunces(
            fontSize: isPhone ? 28 : (isNarrow ? 30 : 38),
            fontWeight: FontWeight.w600,
            color: _camelliaInk,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          translate(
            'Secure Camellia sessions directly in your browser with the same tools you trust on desktop.',
          ),
          style: _camelliaOutfit(
            fontSize: 15,
            height: 1.5,
            color: _camelliaSlate,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            _buildChip(
              icon: Icons.lock_outline,
              label: translate('End-to-end encryption'),
              color: _camelliaRose,
            ),
            _buildChip(
              icon: Icons.speed,
              label: translate('Adaptive performance'),
              color: _camelliaGold,
            ),
            _buildChip(
              icon: Icons.language,
              label: translate('Browser ready'),
              color: _camelliaSlate,
            ),
          ],
        ),
      ],
    );

    final card = _buildStatusCard();

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isNarrow ? 16 : 24,
        vertical: 10,
      ),
      child: isNarrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [hero, const SizedBox(height: 18), card],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: hero),
                const SizedBox(width: 24),
                SizedBox(width: 340, child: card),
              ],
            ),
    );
  }

  Widget _buildStatusCard() {
    const rowGap = SizedBox(height: 12);
    final muted = AppVisual.subduedText(context);
    return CamelliaSection(
      padding: const EdgeInsets.all(18),
      accent: CamelliaColors.aqua,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            translate('Session status'),
            style: _camelliaOutfit(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: muted,
            ),
          ),
          const SizedBox(height: 12),
          Obx(() {
            final status = stateGlobal.svcStatus.value;
            String label;
            Color color;
            switch (status) {
              case SvcStatus.ready:
                label = translate('Ready');
                color = AppVisual.tone(context, AppTone.success);
                break;
              case SvcStatus.connecting:
                label = translate('Connecting');
                color = AppVisual.tone(context, AppTone.warning);
                break;
              default:
                label = translate('Not ready');
                color = muted;
            }
            return _buildStatusRow(
              icon: Icons.circle,
              color: color,
              title: translate('Service'),
              value: label,
            );
          }),
          rowGap,
          _buildStatusRow(
            icon: Icons.lock_outline,
            color: muted,
            title: translate('Mode'),
            value: translate('Control-only'),
            trailing: Tooltip(
              message: translate(
                'Web client does not accept incoming connections. Use desktop/mobile to be controlled.',
              ),
              child: const Icon(Icons.info_outline, size: 16),
            ),
          ),
          rowGap,
          _buildStatusRow(
            icon: Icons.badge_outlined,
            color: muted,
            title: translate('Your ID'),
            value: _myId.isEmpty ? '—' : _myId,
            trailing: isChangeIdDisabled()
                ? null
                : Tooltip(
                    message: translate('Change ID'),
                    child: IconButton(
                      onPressed: _rotateMyId,
                      icon: const Icon(Icons.autorenew_rounded),
                      iconSize: 16,
                      padding: EdgeInsets.zero,
                      color: Theme.of(context).colorScheme.primary,
                      constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                      ),
                    ),
                  ),
          ),
          rowGap,
          _buildStatusRow(
            icon: Icons.shield_outlined,
            color: Theme.of(context).colorScheme.primary,
            title: translate('Security'),
            value: translate('Encrypted channels'),
          ),
          rowGap,
          _buildStatusRow(
            icon: Icons.tune,
            color: muted,
            title: translate('Relay'),
            value: translate('Auto routing'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusRow({
    required IconData icon,
    required Color color,
    required String title,
    required String value,
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 32),
      child: Row(
        children: [
          SizedBox(width: 18, child: Icon(icon, size: 16, color: color)),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _camelliaOutfit(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _camelliaOutfit(
                fontSize: 13,
                color: AppVisual.subduedText(context),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 24,
            child: Align(alignment: Alignment.centerRight, child: trailing),
          ),
        ],
      ),
    );
  }

  Widget _buildRibbon({
    required double width,
    required double height,
    required Color colorA,
    required Color colorB,
    required double angle,
  }) {
    return Transform.rotate(
      angle: angle,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(36),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [colorA, colorB],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
        ),
      ),
    );
  }

  Widget _buildConnectionSection(bool isNarrow) {
    return CamelliaSection(
      padding: const EdgeInsets.all(20),
      accent: CamelliaColors.coral,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            translate('Connect to a device'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            translate('Enter a Remote ID to start a session.'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppVisual.subduedText(context),
            ),
          ),
          const SizedBox(height: 16),
          _buildRemoteIdField(),
          const SizedBox(height: 12),
          _buildQuickActions(isNarrow),
        ],
      ),
    );
  }

  Widget _buildRemoteIdField() {
    return AnimatedContainer(
      duration: AppMotion.duration(context, AppMotion.stateChange),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppVisual.inset(context),
        borderRadius: BorderRadius.circular(AppVisual.radius),
        border: Border.all(
          color: _isFieldFocused
              ? CamelliaColors.azure
              : AppVisual.border(context),
          width: _isFieldFocused ? 1.4 : 1.0,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: RawAutocomplete<Peer>(
              optionsBuilder: (TextEditingValue textEditingValue) {
                if (textEditingValue.text == '') {
                  _autocompleteOpts = const Iterable<Peer>.empty();
                } else if (_allPeersLoader.peers.isEmpty &&
                    !_allPeersLoader.isPeersLoaded) {
                  Peer emptyPeer = Peer(
                    id: '',
                    username: '',
                    hostname: '',
                    alias: '',
                    platform: '',
                    tags: [],
                    hash: '',
                    password: '',
                    forceAlwaysRelay: false,
                    rdpPort: '',
                    rdpUsername: '',
                    loginName: '',
                    device_group_name: '',
                    note: '',
                  );
                  _autocompleteOpts = [emptyPeer];
                } else {
                  String textWithoutSpaces = textEditingValue.text.replaceAll(
                    " ",
                    "",
                  );
                  if (int.tryParse(textWithoutSpaces) != null) {
                    textEditingValue = TextEditingValue(
                      text: textWithoutSpaces,
                      selection: textEditingValue.selection,
                    );
                  }
                  String textToFind = textEditingValue.text.toLowerCase();
                  _autocompleteOpts = _allPeersLoader.peers
                      .where(
                        (peer) =>
                            peer.id.toLowerCase().contains(textToFind) ||
                            peer.username.toLowerCase().contains(textToFind) ||
                            peer.hostname.toLowerCase().contains(textToFind) ||
                            peer.alias.toLowerCase().contains(textToFind),
                      )
                      .toList();
                }
                return _autocompleteOpts;
              },
              focusNode: _idFocusNode,
              textEditingController: _idEditingController,
              fieldViewBuilder:
                  (
                    BuildContext context,
                    TextEditingController fieldTextEditingController,
                    FocusNode fieldFocusNode,
                    VoidCallback onFieldSubmitted,
                  ) {
                    updateTextAndPreserveSelection(
                      fieldTextEditingController,
                      _idController.text,
                    );
                    return AutoSizeTextField(
                      controller: fieldTextEditingController,
                      focusNode: fieldFocusNode,
                      minFontSize: 18,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.visiblePassword,
                      onChanged: (String text) {
                        _idController.id = text;
                      },
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      decoration: InputDecoration(
                        labelText: translate('Remote ID'),
                        border: InputBorder.none,
                        labelStyle: Theme.of(context).textTheme.labelMedium,
                      ),
                      inputFormatters: [IDTextInputFormatter()],
                      onSubmitted: (_) {
                        _onConnect();
                      },
                    );
                  },
              onSelected: (option) {
                setState(() {
                  _idController.id = option.id;
                  FocusScope.of(context).unfocus();
                });
              },
              optionsViewBuilder:
                  (
                    BuildContext context,
                    AutocompleteOnSelected<Peer> onSelected,
                    Iterable<Peer> options,
                  ) {
                    options = _autocompleteOpts;
                    double maxHeight = options.length * 50.0;
                    if (options.length == 1) {
                      maxHeight = 52;
                    } else if (options.length == 3) {
                      maxHeight = 146;
                    } else if (options.length == 4) {
                      maxHeight = 193;
                    }
                    maxHeight = maxHeight.clamp(0, 220);
                    return Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(AppVisual.radius),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: maxHeight,
                            maxWidth: 360,
                          ),
                          child:
                              _allPeersLoader.peers.isEmpty &&
                                  !_allPeersLoader.isPeersLoaded
                              ? const SizedBox(
                                  height: 80,
                                  child: Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : ListView(
                                  padding: const EdgeInsets.only(top: 6),
                                  children: options
                                      .map(
                                        (peer) => AutocompletePeerTile(
                                          onSelect: () => onSelected(peer),
                                          peer: peer,
                                        ),
                                      )
                                      .toList(),
                                ),
                        ),
                      ),
                    );
                  },
            ),
          ),
          if (!_idEmpty)
            IconButton(
              onPressed: () {
                setState(() {
                  _idController.clear();
                });
              },
              icon: const Icon(Icons.clear),
              color: AppVisual.subduedText(context),
              tooltip: translate('Clear'),
            ),
          const SizedBox(width: 6),
          _ActionButton(
            label: translate('Connect'),
            icon: Icons.desktop_windows_outlined,
            onPressed: _idEmpty ? null : () => _onConnect(),
            isPrimary: true,
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(bool isNarrow) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _ActionButton(
          label: translate('Remote Control'),
          icon: Icons.connected_tv,
          onPressed: _idEmpty ? null : () => _onConnect(),
        ),
        _ActionButton(
          label: translate('File Transfer'),
          icon: Icons.folder_copy_outlined,
          onPressed: _idEmpty ? null : () => _onConnect(isFileTransfer: true),
        ),
        _ActionButton(
          label: translate('Terminal'),
          icon: Icons.terminal,
          onPressed: _idEmpty ? null : () => _onConnect(isTerminal: true),
        ),
        _ActionButton(
          label: translate('View Camera'),
          icon: Icons.videocam_outlined,
          onPressed: _idEmpty ? null : () => _onConnect(isViewCamera: true),
        ),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildFeatureSection(bool isNarrow) {
    final cards = [
      _FeatureCard(
        title: translate('Trusted access'),
        body: translate('Connect across devices with the same security model.'),
        foot: translate('Zero config on the client'),
        icon: Icons.verified_outlined,
        color: _camelliaRose,
      ),
      _FeatureCard(
        title: translate('Fast file moves'),
        body: translate('Drag files directly into the remote session.'),
        foot: translate('Optimized transfer streams'),
        icon: Icons.swap_vert,
        color: _camelliaGold,
      ),
      _FeatureCard(
        title: translate('Multi-session ready'),
        body: translate('Switch between recent, favorite, and LAN devices.'),
        foot: translate('Smart peer discovery'),
        icon: Icons.layers_outlined,
        color: _camelliaSlate,
      ),
      _FeatureCard(
        title: translate('Camellia controls'),
        body: translate('Use keyboard shortcuts and terminal tools.'),
        foot: translate('Desktop-grade features'),
        icon: Icons.settings_input_component,
        color: _camelliaRoseDark,
      ),
    ];
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isNarrow ? 16 : 24,
        vertical: 10,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const spacing = 14.0;
          final width = constraints.maxWidth;
          final columns = width >= 1120
              ? 4
              : width >= 760
              ? 2
              : 1;
          final cardWidth = (width - (columns - 1) * spacing) / columns;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: cards
                .map((card) => SizedBox(width: cardWidth, child: card))
                .toList(),
          );
        },
      ),
    );
  }

  Widget _buildPeersPanel(bool isNarrow) {
    final viewportHeight = MediaQuery.of(context).size.height;
    final peersPanelHeight = viewportHeight < 760 ? 340.0 : 420.0;
    return AppSurface(
      padding: const EdgeInsets.all(20),
      elevated: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            translate('Your devices'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            translate('Recent, favorites, LAN, and address book peers.'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppVisual.subduedText(context),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(height: peersPanelHeight, child: PeerTabPage()),
        ],
      ),
    );
  }

  Widget _buildChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: _camelliaOutfit(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.isPrimary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    final labelWidget = Text(
      label,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
      animationDuration: AppMotion.duration(context, AppMotion.feedback),
    );
    if (isPrimary) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: labelWidget,
        style: style,
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: labelWidget,
      style: style,
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.title,
    required this.body,
    required this.foot,
    required this.icon,
    required this.color,
  });

  final String title;
  final String body;
  final String foot;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 218,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _camelliaLine.withValues(alpha: 0.9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: _camelliaOutfit(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _camelliaInk,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: _camelliaOutfit(
              fontSize: 12,
              height: 1.4,
              color: _camelliaSlate,
            ),
          ),
          const Spacer(),
          const SizedBox(height: 8),
          Text(
            foot,
            style: _camelliaOutfit(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
