import 'dart:async';

import 'package:auto_size_text_field/auto_size_text_field.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/formatter/id_formatter.dart';
import 'package:camellia_remote_app/common/widgets/connection_page_title.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:camellia_remote_app/models/peer_model.dart';

import '../../common.dart';
import '../../common/widgets/peer_tab_page.dart';
import '../../common/widgets/autocomplete.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import 'home_page.dart';

/// Connection page for connecting to a remote peer.
class ConnectionPage extends StatefulWidget implements PageShape {
  ConnectionPage({Key? key, required this.appBarActions, this.shareSection})
    : super(key: key);

  @override
  final icon = const Icon(Icons.connected_tv_outlined);

  @override
  final title = translate("Connection");

  @override
  final List<Widget> appBarActions;
  final Widget? shareSection;

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

/// State for the connection page.
class _ConnectionPageState extends State<ConnectionPage> {
  /// Controller for the id input bar.
  final _idController = IDTextEditingController();
  final RxBool _idEmpty = true.obs;
  final RxBool _idFocused = false.obs;

  final FocusNode _idFocusNode = FocusNode();
  final TextEditingController _idEditingController = TextEditingController();

  final AllPeersLoader _allPeersLoader = AllPeersLoader();

  StreamSubscription? _uniLinksSubscription;

  // https://github.com/flutter/flutter/issues/157244
  Iterable<Peer> _autocompleteOpts = [];

  _ConnectionPageState() {
    if (!isWeb) _uniLinksSubscription = listenUniLinks();
    _idController.addListener(() {
      _idEmpty.value = _idController.text.isEmpty;
    });
    Get.put<IDTextEditingController>(_idController);
  }

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
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<FfiModel>(context);
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _buildRemoteIDTextField(),
              if (widget.shareSection != null) ...[
                const SizedBox(height: 12),
                CamelliaPageHeader(
                  title: translate('Share screen'),
                  subtitle: translate('Your Device'),
                  leading: const AppIconBadge(
                    icon: Icons.screen_share_rounded,
                    colors: AppVisual.securityGradient,
                    size: 36,
                    iconSize: 19,
                  ),
                ),
                const SizedBox(height: 10),
                widget.shareSection!,
              ],
            ]),
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CamelliaPageHeader(
                  title: translate('Devices'),
                  subtitle: translate('Recent and trusted connections'),
                  leading: const AppIconBadge(
                    icon: Icons.devices_other_rounded,
                    colors: AppVisual.identityGradient,
                    size: 36,
                    iconSize: 19,
                  ),
                ),
                const SizedBox(height: 10),
                const Expanded(child: PeerTabPage()),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Callback for the connect button.
  /// Connects to the selected peer.
  void onConnect() {
    var id = _idController.id;
    connect(context, id);
  }

  void onFocusChanged() {
    _idEmpty.value = _idEditingController.text.isEmpty;
    _idFocused.value = _idFocusNode.hasFocus;
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

  /// UI for the remote ID TextField.
  /// Search for a peer and connect to it if the id exists.
  Widget _buildRemoteIDTextField() {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: kMobilePageConstraints,
        child: CamelliaSection(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          accent: CamelliaColors.coral,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isWebDesktop)
                getConnectionPageTitle(
                  context,
                  true,
                ).marginOnly(bottom: 12, left: 2),
              if (!isWebDesktop)
                Row(
                  children: [
                    const CamelliaAnimatedBrandMark(size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            translate('Control Remote Desktop'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            translate('Remote ID'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: AppVisual.subduedText(context),
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ).marginOnly(bottom: 14),
              Obx(
                () => AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppVisual.inset(context),
                    borderRadius: BorderRadius.circular(AppVisual.radius),
                    border: Border.all(
                      color: _idFocused.value
                          ? CamelliaColors.azure
                          : AppVisual.border(context),
                      width: _idFocused.value ? 1.4 : 1,
                    ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final optionsWidth = (constraints.maxWidth - 96)
                          .clamp(220, 420)
                          .toDouble();
                      return Row(
                        children: <Widget>[
                          Expanded(child: _buildAutocomplete(optionsWidth)),
                          Obx(
                            () => Offstage(
                              offstage: _idEmpty.value,
                              child: IconButton(
                                tooltip: translate('Clear'),
                                onPressed: () {
                                  setState(() {
                                    _idController.clear();
                                  });
                                },
                                icon: Icon(
                                  Icons.clear_rounded,
                                  color: AppVisual.subduedText(context),
                                ),
                              ),
                            ),
                          ),
                          Tooltip(
                            message: translate('Connect'),
                            child: SizedBox.square(
                              dimension: 46,
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  backgroundColor: CamelliaColors.azure,
                                ),
                                onPressed: onConnect,
                                child: const Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 23,
                                ),
                              ),
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
        ),
      ),
    );
  }

  Widget _buildAutocomplete(double optionsWidth) {
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
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 28,
                color: CamelliaColors.azure,
              ),
              decoration: InputDecoration(
                labelText: translate('Remote ID'),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
                labelStyle: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  letterSpacing: 0,
                  color: AppVisual.subduedText(context),
                ),
              ),
              inputFormatters: [IDTextInputFormatter()],
              onSubmitted: (_) {
                onConnect();
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
                        maxWidth: optionsWidth,
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
                              padding: const EdgeInsets.only(top: 5),
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
            );
          },
    );
  }

  @override
  void dispose() {
    _uniLinksSubscription?.cancel();
    _idController.dispose();
    _idFocusNode.removeListener(onFocusChanged);
    _allPeersLoader.clear();
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
}
