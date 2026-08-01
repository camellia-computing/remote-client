// main window right pane

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/widgets/adaptive_layout.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:window_manager/window_manager.dart';
import 'package:camellia_remote_app/models/peer_model.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../common/widgets/peer_tab_page.dart';
import '../../common/widgets/autocomplete.dart';
import '../../models/platform_model.dart';

enum _ConnectionMode { desktop, files, camera, terminal }

Color _connectionModeTone(_ConnectionMode mode) => switch (mode) {
  _ConnectionMode.desktop => CamelliaColors.coral,
  _ConnectionMode.files => CamelliaColors.azure,
  _ConnectionMode.camera => CamelliaColors.aqua,
  _ConnectionMode.terminal => CamelliaColors.orchid,
};

class OnlineStatusWidget extends StatefulWidget {
  const OnlineStatusWidget({
    Key? key,
    this.onSvcStatusChanged,
    this.compact = false,
  }) : super(key: key);

  final VoidCallback? onSvcStatusChanged;
  final bool compact;

  @override
  State<OnlineStatusWidget> createState() => _OnlineStatusWidgetState();
}

/// State for the connection page.
class _OnlineStatusWidgetState extends State<OnlineStatusWidget> {
  final _svcStopped = Get.find<RxBool>(tag: 'stop-service');
  final _svcIsUsingPublicServer = true.obs;
  Timer? _updateTimer;

  double get em => 14.0;
  double? get height => bind.isIncomingOnly() || widget.compact ? null : em * 3;

  void onUsePublicServerGuide() {
    const url = "https://github.com/camellia-computing/remote-client";
    canLaunchUrlString(url).then((can) {
      if (can) {
        launchUrlString(url);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _updateTimer = periodic_immediate(Duration(seconds: 1), () async {
      updateStatus();
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isIncomingOnly = bind.isIncomingOnly();
    startServiceWidget() => Offstage(
      offstage: !_svcStopped.value,
      child: TextButton.icon(
        onPressed: () async {
          await start_service(true);
        },
        icon: const Icon(Icons.play_arrow_rounded, size: 17),
        label: Text(translate("Start service")),
      ).marginOnly(left: 8),
    );

    setupServerWidget() => Flexible(
      child: Offstage(
        offstage:
            !(!_svcStopped.value &&
                stateGlobal.svcStatus.value == SvcStatus.ready &&
                _svcIsUsingPublicServer.value),
        child: TextButton(
          onPressed: onUsePublicServerGuide,
          child: Text(
            translate('setup_server_tip'),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );

    basicWidget() => Padding(
      padding: widget.compact
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(12, 5, isIncomingOnly ? 0 : 12, 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: AppStatusPill(
              label: _connStatusText(),
              color: _statusColor(),
              icon: stateGlobal.svcStatus.value == SvcStatus.ready
                  ? Icons.check_circle_rounded
                  : Icons.circle_rounded,
            ),
          ),
          if (!isIncomingOnly) startServiceWidget(),
          if (!isIncomingOnly && !isCustomClient) setupServerWidget(),
        ],
      ),
    );

    return SizedBox(
      height: height,
      child: Obx(
        () => isIncomingOnly
            ? Column(
                children: [
                  basicWidget(),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: startServiceWidget(),
                  ),
                ],
              )
            : basicWidget(),
      ),
    ).paddingOnly(right: isIncomingOnly ? 8 : 0);
  }

  Color _statusColor() {
    if (_svcStopped.value ||
        stateGlobal.svcStatus.value == SvcStatus.connecting) {
      return AppVisual.tone(context, AppTone.warning);
    }
    if (stateGlobal.svcStatus.value == SvcStatus.ready) {
      return AppVisual.tone(context, AppTone.success);
    }
    return AppVisual.tone(context, AppTone.danger);
  }

  String _connStatusText() {
    widget.onSvcStatusChanged?.call();
    return _svcStopped.value
        ? translate("Service is not running")
        : stateGlobal.svcStatus.value == SvcStatus.connecting
        ? translate("connecting_status")
        : stateGlobal.svcStatus.value == SvcStatus.notReady
        ? translate("not_ready_status")
        : translate('Ready');
  }

  updateStatus() async {
    final status =
        jsonDecode(await bind.mainGetConnectStatus()) as Map<String, dynamic>;
    final statusNum = status['status_num'] as int;
    if (statusNum == 0) {
      stateGlobal.svcStatus.value = SvcStatus.connecting;
    } else if (statusNum == -1) {
      stateGlobal.svcStatus.value = SvcStatus.notReady;
    } else if (statusNum == 1) {
      stateGlobal.svcStatus.value = SvcStatus.ready;
    } else {
      stateGlobal.svcStatus.value = SvcStatus.notReady;
    }
    _svcIsUsingPublicServer.value = await bind.mainIsUsingPublicServer();
    try {
      stateGlobal.videoConnCount.value = status['video_conn_count'] as int;
    } catch (_) {}
  }
}

/// Connection page for connecting to a remote peer.
class ConnectionPage extends StatefulWidget {
  const ConnectionPage({Key? key, this.showDevices = true}) : super(key: key);

  final bool showDevices;

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

/// State for the connection page.
class _ConnectionPageState extends State<ConnectionPage>
    with SingleTickerProviderStateMixin, WindowListener {
  /// Controller for the id input bar.
  final _idController = IDTextEditingController();

  final RxBool _idInputFocused = false.obs;
  final FocusNode _idFocusNode = FocusNode();
  final TextEditingController _idEditingController = TextEditingController();

  _ConnectionMode _connectionMode = _ConnectionMode.desktop;

  bool isWindowMinimized = false;

  final AllPeersLoader _allPeersLoader = AllPeersLoader();

  // https://github.com/flutter/flutter/issues/157244
  Iterable<Peer> _autocompleteOpts = [];

  @override
  void initState() {
    super.initState();
    _allPeersLoader.init(setState);
    _idFocusNode.addListener(onFocusChanged);
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
    Get.put<TextEditingController>(_idEditingController);
    Get.put<IDTextEditingController>(_idController);
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    _idController.dispose();
    windowManager.removeListener(this);
    _allPeersLoader.clear();
    _idFocusNode.removeListener(onFocusChanged);
    _idFocusNode.dispose();
    _idEditingController.dispose();
    if (Get.isRegistered<IDTextEditingController>()) {
      Get.delete<IDTextEditingController>();
    }
    if (Get.isRegistered<TextEditingController>()) {
      Get.delete<TextEditingController>();
    }
    super.dispose();
  }

  @override
  void onWindowEvent(String eventName) {
    super.onWindowEvent(eventName);
    if (eventName == 'minimize') {
      isWindowMinimized = true;
    } else if (eventName == 'maximize' || eventName == 'restore') {
      if (isWindowMinimized && isWindows) {
        // windows can't update when minimized.
        Get.forceAppUpdate();
      }
      isWindowMinimized = false;
    }
  }

  @override
  void onWindowEnterFullScreen() {
    // Remove edge border by setting the value to zero.
    stateGlobal.resizeEdgeSize.value = 0;
  }

  @override
  void onWindowLeaveFullScreen() {
    // Restore edge border to default edge size.
    stateGlobal.resizeEdgeSize.value = stateGlobal.isMaximized.isTrue
        ? kMaximizeEdgeSize
        : windowResizeEdgeSize;
  }

  @override
  void onWindowClose() {
    super.onWindowClose();
    bind.mainOnMainWindowClose();
  }

  void onFocusChanged() {
    _idInputFocused.value = _idFocusNode.hasFocus;
    if (_idFocusNode.hasFocus) {
      if (_allPeersLoader.needLoad) {
        _allPeersLoader.getAllPeers();
      }

      final textLength = _idEditingController.value.text.length;
      // Select all to facilitate removing text, just following the behavior of address input of chrome.
      _idEditingController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: textLength,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final split = widget.showDevices && constraints.maxWidth >= 860;
        final padding = compact ? 14.0 : 24.0;
        final devices = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  translate('Devices'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Divider(height: 1, color: AppVisual.border(context)),
            const SizedBox(height: 10),
            const Expanded(child: PeerTabPage()),
          ],
        );
        return CamelliaBackdrop(
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(padding, padding, padding, 0),
                  child: !widget.showDevices
                      ? Align(
                          alignment: Alignment.topCenter,
                          child: SingleChildScrollView(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 680),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _buildRemoteIDTextField(
                                    context,
                                    maxWidth: 680,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      : split
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: 360,
                              child: SingleChildScrollView(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _buildRemoteIDTextField(
                                      context,
                                      maxWidth: 360,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 24),
                            VerticalDivider(
                              width: 1,
                              color: AppVisual.border(context),
                            ),
                            const SizedBox(width: 24),
                            Expanded(child: devices),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildRemoteIDTextField(
                              context,
                              maxWidth: compact ? 620 : 760,
                            ),
                            const SizedBox(height: 22),
                            Expanded(child: devices),
                          ],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Callback for the connect button.
  /// Connects to the selected peer.
  void onConnect({
    bool isFileTransfer = false,
    bool isViewCamera = false,
    bool isTerminal = false,
  }) {
    var id = _idController.id;
    connect(
      context,
      id,
      isFileTransfer: isFileTransfer,
      isViewCamera: isViewCamera,
      isTerminal: isTerminal,
    );
  }

  void _connectSelectedMode() {
    onConnect(
      isFileTransfer: _connectionMode == _ConnectionMode.files,
      isViewCamera: _connectionMode == _ConnectionMode.camera,
      isTerminal: _connectionMode == _ConnectionMode.terminal,
    );
  }

  /// UI for the remote ID TextField.
  /// Search for a peer.
  Widget _buildRemoteIDTextField(
    BuildContext context, {
    double maxWidth = 680,
  }) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          final showStatus = !bind.isOutgoingOnly();
          return CamelliaSection(
            title: translate('Connect'),
            description: translate(
              'Choose a mode and enter a trusted device ID',
            ),
            trailing: showStatus && !compact
                ? const OnlineStatusWidget(compact: true)
                : null,
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
            accent: _connectionModeTone(_connectionMode),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showStatus && compact) ...[
                  const OnlineStatusWidget(compact: true),
                  const SizedBox(height: 10),
                ],
                LayoutBuilder(
                  builder: (context, constraints) {
                    final showLabels = constraints.maxWidth >= 560;
                    return SegmentedButton<_ConnectionMode>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: _ConnectionMode.desktop,
                          icon: const Icon(Icons.desktop_windows_outlined),
                          label: showLabels ? Text(translate('Desktop')) : null,
                          tooltip: translate('Control Remote Desktop'),
                        ),
                        ButtonSegment(
                          value: _ConnectionMode.files,
                          icon: const Icon(Icons.folder_copy_outlined),
                          label: showLabels ? Text(translate('Files')) : null,
                          tooltip: translate('Transfer file'),
                        ),
                        ButtonSegment(
                          value: _ConnectionMode.camera,
                          icon: const Icon(Icons.videocam_outlined),
                          label: showLabels ? Text(translate('Camera')) : null,
                          tooltip: translate('View camera'),
                        ),
                        ButtonSegment(
                          value: _ConnectionMode.terminal,
                          icon: const Icon(Icons.terminal_rounded),
                          label: showLabels
                              ? Text(translate('Terminal'))
                              : null,
                          tooltip: translate('Terminal'),
                        ),
                      ],
                      selected: {_connectionMode},
                      onSelectionChanged: (selection) {
                        setState(() => _connectionMode = selection.first);
                      },
                    );
                  },
                ),
                const SizedBox(height: 14),
                Obx(
                  () => AnimatedContainer(
                    duration: AppMotion.duration(
                      context,
                      AppMotion.stateChange,
                    ),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppVisual.inset(context),
                      borderRadius: BorderRadius.circular(AppVisual.radius),
                      border: Border.all(
                        color: _idInputFocused.value
                            ? CamelliaColors.azure
                            : AppVisual.border(context),
                        width: _idInputFocused.value ? 1.4 : 1,
                      ),
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final compact = constraints.maxWidth < 460;
                        final optionsWidth =
                            (constraints.maxWidth - (compact ? 72.0 : 146.0))
                                .clamp(220.0, 620.0)
                                .toDouble();
                        return Row(
                          children: [
                            Expanded(
                              child: _buildAutocomplete(context, optionsWidth),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              height: 42,
                              child: compact
                                  ? FilledButton(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: _connectionModeTone(
                                          _connectionMode,
                                        ),
                                      ),
                                      onPressed: _connectSelectedMode,
                                      child: const Icon(
                                        Icons.arrow_forward_rounded,
                                        size: 18,
                                      ),
                                    )
                                  : FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: _connectionModeTone(
                                          _connectionMode,
                                        ),
                                      ),
                                      onPressed: _connectSelectedMode,
                                      icon: const Icon(
                                        Icons.arrow_forward_rounded,
                                        size: 18,
                                      ),
                                      label: Text(translate("Connect")),
                                    ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildAutocomplete(BuildContext context, double optionsWidth) {
    return RawAutocomplete<Peer>(
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
          String textWithoutSpaces = textEditingValue.text.replaceAll(" ", "");
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
          _allPeersLoader.queryOnlines(_autocompleteOpts);
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
            return Obx(
              () => TextField(
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                focusNode: fieldFocusNode,
                style: const TextStyle(
                  fontFamily: 'WorkSans',
                  fontSize: 22,
                  height: 1.35,
                ),
                maxLines: 1,
                cursorColor: Theme.of(context).textTheme.titleLarge?.color,
                decoration: InputDecoration(
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  counterText: '',
                  hintText: _idInputFocused.value
                      ? null
                      : translate('Enter Remote ID'),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 9,
                  ),
                ),
                controller: fieldTextEditingController,
                inputFormatters: [IDTextInputFormatter()],
                onChanged: (v) {
                  _idController.id = v;
                },
                onSubmitted: (_) {
                  _connectSelectedMode();
                },
              ).workaroundFreezeLinuxMint(),
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
            double maxHeight = options.length * 50;
            if (options.length == 1) {
              maxHeight = 52;
            } else if (options.length == 3) {
              maxHeight = 146;
            } else if (options.length == 4) {
              maxHeight = 193;
            }
            maxHeight = maxHeight.clamp(0, 200);

            return Align(
              alignment: Alignment.topLeft,
              child: Container(
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.24),
                      blurRadius: 14,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppVisual.radius),
                  child: Material(
                    elevation: 0,
                    color: Theme.of(context).colorScheme.surface,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: maxHeight,
                        maxWidth: optionsWidth.clamp(280, 620).toDouble(),
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
                          : Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: ListView(
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
                  ),
                ),
              ),
            );
          },
    );
  }
}
