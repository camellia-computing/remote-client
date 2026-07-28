import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/hbbs/hbbs.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:get/get.dart';
import 'package:bot_toast/bot_toast.dart';

import '../utils/http_service.dart' as http;
import '../common.dart';

final syncAbOption = 'sync-ab-with-recent-sessions';
bool shouldSyncAb() {
  return bind.mainGetLocalOption(key: syncAbOption) == 'Y';
}

final sortAbTagsOption = 'sync-ab-tags';
bool shouldSortTags() {
  return bind.mainGetLocalOption(key: sortAbTagsOption) == 'Y';
}

final filterAbTagOption = 'filter-ab-by-intersection';
bool filterAbTagByIntersection() {
  return bind.mainGetLocalOption(key: filterAbTagOption) == 'Y';
}

const _personalAddressBookName = "My address book";

const kUntagged = "Untagged";

bool _isPersonalGuid(String? guid) {
  if (guid == null) {
    return false;
  }
  return guid.startsWith('personal-');
}

enum ForcePullAb { listAndCurrent, current }

class AbModel {
  final addressbooks = Map<String, BaseAb>.fromEntries([]).obs;
  final RxString _currentName = ''.obs;
  RxString get currentName => _currentName;
  final _dummyAb = DummyAb();
  BaseAb get current => addressbooks[_currentName.value] ?? _dummyAb;

  RxList<Peer> get currentAbPeers => current.peers;
  RxList<String> get currentAbTags => current.tags;
  RxList<String> get selectedTags => current.selectedTags;

  RxBool get currentAbLoading => current.abLoading;
  bool get currentAbEmpty => current.peers.isEmpty && current.tags.isEmpty;
  final _listPullError = ''.obs;
  RxString get abPullError =>
      _listPullError.value.isNotEmpty ? _listPullError : current.pullError;
  RxString get currentAbPushError => current.pushError;
  String? _personalAbGuid;
  String _personalAbName = _personalAddressBookName;

  // Only handles peers add/remove
  final Map<String, VoidCallback> _peerIdUpdateListeners = {};

  final sortTags = shouldSortTags().obs;
  final filterByIntersection = filterAbTagByIntersection().obs;

  var _syncAllFromRecent = true;
  var _syncFromRecentLock = false;
  var _timerCounter = 0;
  var _cacheLoadOnceFlag = false;
  var _pulledOnce = false;
  var listInitialized = false;
  var _maxPeerOneAb = 0;

  late final Peers peersModel;

  WeakReference<FFI> parent;

  AbModel(this.parent) {
    addressbooks.clear();
    peersModel = Peers(
      name: PeersModelName.addressBook,
      getInitPeers: () => currentAbPeers,
      loadEvent: LoadEvent.addressBook,
    );
    if (desktopType == DesktopType.main) {
      Timer.periodic(Duration(milliseconds: 500), (timer) async {
        if (_timerCounter++ % 6 == 0) {
          if (!gFFI.userModel.isLogin) return;
          if (!listInitialized) return;
          if (!current.initialized || !current.canWrite()) return;
          _syncFromRecent();
        }
      });
    }
  }

  reset() async {
    print("reset ab model");
    addressbooks.clear();
    _currentName.value = '';
    _listPullError.value = '';
    _pulledOnce = false;
    await bind.mainClearAb();
    listInitialized = false;
  }

  void clearPullErrors() {
    _listPullError.value = '';
    current.pullError.value = '';
  }

  // #region ab
  /// Pulls the address book data from the server.
  ///
  /// If `force` is `ForcePullAb.listAndCurrent`, the function will pull the list of address books, current address book, and try initialize personal address book.
  /// If `force` is `ForcePullAb.current`, the function will only pull the current address book.
  /// If `quiet` is true, the function will not display any notifications or errors.
  var _pulling = false;
  Future<void> pullAb({
    required ForcePullAb? force,
    required bool quiet,
  }) async {
    if (!gFFI.userModel.isLogin) return;
    if (gFFI.userModel.networkError.isNotEmpty) return;
    if (_pulling) return;
    if (force == null && _pulledOnce) {
      return;
    }
    _pulling = true;
    if (!quiet) {
      _listPullError.value = '';
      current.pullError.value = '';
    }
    try {
      await _pullAb(force: force, quiet: quiet);
      _refreshTab();
    } catch (_) {}
    _pulling = false;
    _pulledOnce = true;
  }

  Future<void> _pullAb({
    required ForcePullAb? force,
    required bool quiet,
  }) async {
    if (force == null && listInitialized && current.initialized) return;
    debugPrint("pullAb, force: $force, quiet: $quiet");
    if (!listInitialized || force == ForcePullAb.listAndCurrent) {
      try {
        // Refresh personal address book metadata on each list pull.
        _personalAbGuid = null;
        _personalAbName = _personalAddressBookName;
        // `true`: continue init. `false`: stop, error already recorded.
        if (!await _getPersonalAbGuid(quiet: quiet)) {
          return;
        }
        if (_maxPeerOneAb == 0) {
          await _getAbSettings(quiet: quiet);
        }
        debugPrint("pull ab list");
        List<AbProfile> abProfiles = List.empty(growable: true);
        abProfiles.add(
          AbProfile(
            _personalAbGuid!,
            _personalAbName,
            gFFI.userModel.userName.value,
            null,
            ShareRule.read.value,
            null,
          ),
        );
        // get all address book name
        if (!await _getSharedAbProfiles(abProfiles, quiet: quiet)) {
          return;
        }
        addressbooks.removeWhere(
          (key, value) =>
              abProfiles.firstWhereOrNull((e) => e.name == key) == null,
        );
        for (int i = 0; i < abProfiles.length; i++) {
          AbProfile p = abProfiles[i];
          if (addressbooks.containsKey(p.name)) {
            addressbooks[p.name]?.setSharedProfile(p);
          } else {
            addressbooks[p.name] = Ab(p, p.guid == _personalAbGuid);
          }
        }
        // set current address book name
        if (!listInitialized) {
          listInitialized = true;
          trySetCurrentToLast();
        }
        if (!addressbooks.containsKey(_currentName.value)) {
          setCurrentName(_personalAbName);
        }
        // pull current address book
        await current.pullAb(quiet: quiet);
        // try initialize personal address book
        if (!current.isPersonal()) {
          final personalAb = addressbooks[_personalAbName];
          if (personalAb != null && !personalAb.initialized) {
            await personalAb.pullAb(quiet: quiet);
          }
        }
      } catch (e) {
        debugPrint("pull ab list error: $e");
        _setListPullError(e, quiet: quiet);
      }
    } else if (listInitialized &&
        (!current.initialized || force == ForcePullAb.current)) {
      try {
        await current.pullAb(quiet: quiet);
      } catch (e) {
        debugPrint("pull current Ab error: $e");
      }
    }
    _callbackPeerUpdate();
    if (listInitialized && current.initialized) {
      _saveCache();
    }
  }

  void _setListPullError(Object err, {required bool quiet, int? statusCode}) {
    if (!quiet) {
      _listPullError.value =
          '${translate('pull_ab_failed_tip')}: ${translate(err.toString())}';
    }
    if (statusCode == 401) {
      gFFI.userModel.reset(resetOther: true);
    }
  }

  Future<bool> _getAbSettings({required bool quiet}) async {
    int? statusCode;
    try {
      final api = "${await bind.mainGetApiServer()}/api/ab/settings";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      _setEmptyBody(headers);
      final resp = await http.post(Uri.parse(api), headers: headers);
      statusCode = resp.statusCode;
      if (statusCode == 404) {
        debugPrint("HTTP 404, api server doesn't support shared address book");
        return false;
      }
      Map<String, dynamic> json = _jsonDecodeRespMap(
        decode_http_response(resp),
        resp.statusCode,
      );
      if (json.containsKey('error')) {
        throw json['error'];
      }
      if (statusCode != 200) {
        throw 'HTTP $statusCode';
      }
      _maxPeerOneAb = json['max_peer_one_ab'] ?? 0;
      return true;
    } catch (err) {
      debugPrint('get ab settings err: ${err.toString()}');
      _setListPullError(err, quiet: quiet, statusCode: statusCode);
    }
    return false;
  }

  /// Loads `/api/ab/personal`.
  /// Returns `true` to continue init, `false` to stop after a real error.
  Future<bool> _getPersonalAbGuid({required bool quiet}) async {
    int? statusCode;
    try {
      final api = "${await bind.mainGetApiServer()}/api/ab/personal";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      _setEmptyBody(headers);
      final resp = await http.post(Uri.parse(api), headers: headers);
      statusCode = resp.statusCode;
      if (statusCode == 404) {
        throw 'HTTP 404';
      }
      Map<String, dynamic> json = _jsonDecodeRespMap(
        decode_http_response(resp),
        resp.statusCode,
      );
      if (json.containsKey('error')) {
        throw json['error'];
      }
      if (statusCode != 200) {
        throw 'HTTP $statusCode';
      }
      final guid = json['guid'];
      if (guid is! String || guid.trim().isEmpty) {
        throw 'invalid personal address book guid';
      }
      _personalAbGuid = guid.trim();
      final name = json['name'];
      if (name is String && name.trim().isNotEmpty) {
        _personalAbName = name.trim();
      } else {
        _personalAbName = _personalAddressBookName;
      }
      return true;
    } catch (err) {
      debugPrint('get personal ab err: ${err.toString()}');
      _setListPullError(err, quiet: quiet, statusCode: statusCode);
    }
    // Real error: stop the current pull.
    return false;
  }

  Future<bool> _getSharedAbProfiles(
    List<AbProfile> profiles, {
    required bool quiet,
  }) async {
    final api = "${await bind.mainGetApiServer()}/api/ab/shared/profiles";
    int? statusCode;
    try {
      var uri0 = Uri.parse(api);
      final pageSize = 100;
      var total = 0;
      int current = 0;
      do {
        current += 1;
        var uri = Uri(
          scheme: uri0.scheme,
          host: uri0.host,
          path: uri0.path,
          port: uri0.port,
          queryParameters: {
            'current': current.toString(),
            'pageSize': pageSize.toString(),
          },
        );
        var headers = getHttpHeaders();
        headers['Content-Type'] = "application/json";
        _setEmptyBody(headers);
        final resp = await http.post(uri, headers: headers);
        statusCode = resp.statusCode;
        if (statusCode == 404) {
          throw 'HTTP 404';
        }
        Map<String, dynamic> json = _jsonDecodeRespMap(
          decode_http_response(resp),
          resp.statusCode,
        );
        if (json.containsKey('error')) {
          throw json['error'];
        }
        if (statusCode != 200) {
          throw 'HTTP $statusCode';
        }
        if (json.containsKey('total')) {
          if (total == 0) total = json['total'];
          if (json.containsKey('data')) {
            final data = json['data'];
            if (data is List) {
              for (final profile in data) {
                final u = AbProfile.fromJson(profile);
                int index = profiles.indexWhere((e) => e.name == u.name);
                if (index < 0) {
                  profiles.add(u);
                } else {
                  profiles[index] = u;
                }
              }
            }
          }
        }
      } while (current * pageSize < total);
      return true;
    } catch (err) {
      debugPrint('_getSharedAbProfiles err: ${err.toString()}');
      _setListPullError(err, quiet: quiet, statusCode: statusCode);
    }
    return false;
  }

  // #endregion

  // #region rule
  List<String> addressBooksCanWrite() {
    List<String> list = [];
    addressbooks.forEach((key, value) async {
      if (value.canWrite()) {
        list.add(key);
      }
    });
    return list;
  }

  // #endregion

  // #region peer
  Future<String?> addIdToCurrent(
    String id,
    String alias,
    String password,
    List<dynamic> tags,
    String note,
  ) async {
    if (currentAbPeers.where((element) => element.id == id).isNotEmpty) {
      return "$id already exists in address book $_currentName";
    }
    Map<String, dynamic> peer = {'id': id, 'alias': alias, 'tags': tags};
    // avoid set existing password to empty
    if (password.isNotEmpty) {
      peer['password'] = password;
    }
    if (note.isNotEmpty) {
      peer['note'] = note;
    }
    final ret = await addPeersTo([peer], _currentName.value);
    _syncAllFromRecent = true;
    return ret;
  }

  // Use Map<String, dynamic> rather than Peer to distinguish between empty and null
  Future<String?> addPeersTo(List<Map<String, dynamic>> ps, String name) async {
    final ab = addressbooks[name];
    if (ab == null) {
      return 'no such addressbook: $name';
    }
    for (var p in ps) {
      ab.removeNonExistentTags(p);
    }
    String? errMsg = await ab.addPeers(ps);
    await pullNonLegacyAfterChange(name: name);
    if (name == _currentName.value) {
      _refreshTab();
    }
    _syncAllFromRecent = true;
    _saveCache();
    return errMsg;
  }

  Future<bool> changeTagForPeers(List<String> ids, List<dynamic> tags) async {
    bool ret = await current.changeTagForPeers(ids, tags);
    await pullNonLegacyAfterChange();
    currentAbPeers.refresh();
    _saveCache();
    return ret;
  }

  Future<bool> changeAlias({required String id, required String alias}) async {
    bool res = await current.changeAlias(id: id, alias: alias);
    await pullNonLegacyAfterChange();
    currentAbPeers.refresh();
    _saveCache();
    return res;
  }

  Future<bool> changeNote({required String id, required String note}) async {
    bool res = await current.changeNote(id: id, note: note);
    await pullNonLegacyAfterChange();
    currentAbPeers.refresh();
    // no need to save cache
    return res;
  }

  Future<bool> changePersonalHashPassword(String id, String hash) async {
    var ret = false;
    final personalAb = addressbooks[_personalAbName];
    if (personalAb != null) {
      ret = await personalAb.changePersonalHashPassword(id, hash);
      await personalAb.pullAb(quiet: true);
    }
    _saveCache();
    return ret;
  }

  Future<bool> changeSharedPassword(
    String abName,
    String id,
    String password,
  ) async {
    final ab = addressbooks[abName];
    if (ab == null) return false;
    final ret = await ab.changeSharedPassword(id, password);
    await ab.pullAb(quiet: true);
    return ret;
  }

  Future<bool> deletePeers(List<String> ids) async {
    final ret = await current.deletePeers(ids);
    await pullNonLegacyAfterChange();
    currentAbPeers.refresh();
    _refreshTab();
    _saveCache();
    _callbackPeerUpdate();
    return ret;
  }

  // #endregion

  // #region tags
  Future<bool> addTags(List<String> tagList) async {
    tagList.removeWhere((e) => e == kUntagged);
    final ret = await current.addTags(tagList, {});
    await pullNonLegacyAfterChange();
    _saveCache();
    return ret;
  }

  Future<bool> renameTag(String oldTag, String newTag) async {
    final ret = await current.renameTag(oldTag, newTag);
    await pullNonLegacyAfterChange();
    selectedTags.value = selectedTags.map((e) {
      if (e == oldTag) {
        return newTag;
      } else {
        return e;
      }
    }).toList();
    _saveCache();
    return ret;
  }

  Future<bool> setTagColor(String tag, Color color) async {
    final ret = await current.setTagColor(tag, color);
    await pullNonLegacyAfterChange();
    _saveCache();
    return ret;
  }

  Future<bool> deleteTag(String tag) async {
    final ret = await current.deleteTag(tag);
    await pullNonLegacyAfterChange();
    _saveCache();
    return ret;
  }

  // #endregion

  // #region sync from recent
  Future<void> _syncFromRecent({bool push = true}) async {
    if (!_syncFromRecentLock) {
      _syncFromRecentLock = true;
      await _syncFromRecentWithoutLock(push: push);
      _syncFromRecentLock = false;
    }
  }

  Future<void> _syncFromRecentWithoutLock({bool push = true}) async {
    Future<List<Peer>> getRecentPeers() async {
      try {
        List<String> filteredPeerIDs;
        if (_syncAllFromRecent) {
          _syncAllFromRecent = false;
          filteredPeerIDs = [];
        } else {
          final new_stored_str = await bind.mainGetNewStoredPeers();
          if (new_stored_str.isEmpty) return [];
          filteredPeerIDs = (jsonDecode(new_stored_str) as List<dynamic>)
              .map((e) => e.toString())
              .toList();
          if (filteredPeerIDs.isEmpty) return [];
        }
        final loadStr = await bind.mainLoadRecentPeersForAb(
          filter: jsonEncode(filteredPeerIDs),
        );
        if (loadStr.isEmpty) {
          return [];
        }
        List<dynamic> mapPeers = jsonDecode(loadStr);
        List<Peer> recents = List.empty(growable: true);
        for (var m in mapPeers) {
          if (m is Map<String, dynamic>) {
            recents.add(Peer.fromJson(m));
          }
        }
        return recents;
      } catch (e) {
        debugPrint('getRecentPeers: $e');
      }
      return [];
    }

    try {
      if (!shouldSyncAb()) return;
      final recents = await getRecentPeers();
      if (recents.isEmpty) return;
      debugPrint("sync from recent, len: ${recents.length}");
      if (current.canWrite() && current.initialized) {
        await current.syncFromRecent(recents);
      }
    } catch (e) {
      debugPrint('_syncFromRecentWithoutLock: $e');
    }
  }

  void setShouldAsync(bool v) async {
    await bind.mainSetLocalOption(
      key: syncAbOption,
      value: v ? 'Y' : defaultOptionNo,
    );
    _syncAllFromRecent = true;
    _timerCounter = 0;
  }

  // #endregion

  // #region cache
  _saveCache() {
    try {
      var ab_entries = _serializeCache();
      Map<String, dynamic> m = <String, dynamic>{
        "access_token": bind.mainGetLocalOption(key: 'access_token'),
        "ab_entries": ab_entries,
      };
      bind.mainSaveAb(json: jsonEncode(m));
    } catch (e) {
      debugPrint('ab save:$e');
    }
  }

  List<dynamic> _serializeCache() {
    var res = [];
    addressbooks.forEach((key, value) {
      if (!value.isPersonal() && key != current.name()) return;
      res.add({
        "guid": value.sharedProfile()?.guid ?? '',
        "name": key,
        "tags": value.tags,
        "peers": value.peers
            .map((e) => e.toCustomJson(includingHash: value.isPersonal()))
            .toList(),
        "tag_colors": jsonEncode(value.tagColors),
      });
    });
    return res;
  }

  trySetCurrentToLast() {
    final name = bind.getLocalFlutterOption(k: kOptionCurrentAbName);
    if (addressbooks.containsKey(name)) {
      _currentName.value = name;
    }
  }

  Future<void> loadCache() async {
    try {
      if (_cacheLoadOnceFlag || currentAbLoading.value) return;
      _cacheLoadOnceFlag = true;
      final access_token = bind.mainGetLocalOption(key: 'access_token');
      if (access_token.isEmpty) return;
      final cache = await bind.mainLoadAb();
      if (currentAbLoading.value) return;
      final data = jsonDecode(cache);
      if (data == null || data['access_token'] != access_token) return;
      _deserializeCache(data);
      trySetCurrentToLast();
    } catch (e) {
      debugPrint("load ab cache: $e");
    }
  }

  _deserializeCache(dynamic data) {
    if (data == null) return;
    reset();
    final abEntries = data['ab_entries'];
    if (abEntries is List) {
      for (var i = 0; i < abEntries.length; i++) {
        var abEntry = abEntries[i];
        if (abEntry is Map<String, dynamic>) {
          var guid = abEntry['guid'];
          var name = abEntry['name'];
          if (name == null) {
            continue;
          }
          final nameStr = name.toString();
          if (guid == null) {
            continue;
          }
          final guidStr = guid.toString();
          final isPersonal = _isPersonalGuid(guidStr);
          if (isPersonal) {
            _personalAbName = nameStr;
          }
          final BaseAb ab = Ab(
            AbProfile(guidStr, nameStr, '', '', ShareRule.read.value, null),
            isPersonal,
          );
          addressbooks[nameStr] = ab;
          if (abEntry['tags'] is List) {
            ab.tags.value = (abEntry['tags'] as List)
                .map((e) => e.toString())
                .toList();
          }
          if (abEntry['peers'] is List) {
            for (var peer in abEntry['peers']) {
              ab.peers.add(Peer.fromJson(peer));
            }
          }
          if (abEntry['tag_colors'] is String) {
            Map<String, dynamic> map = jsonDecode(abEntry['tag_colors']);
            ab.tagColors.value = Map<String, int>.from(map);
          }
        }
      }
      if (abEntries.isNotEmpty) {
        _callbackPeerUpdate();
      }
    }
  }

  // #endregion

  // #region tools
  Peer? find(String id) {
    return currentAbPeers.firstWhereOrNull((e) => e.id == id);
  }

  bool idContainByCurrent(String id) {
    return currentAbPeers.where((element) => element.id == id).isNotEmpty;
  }

  void unsetSelectedTags() {
    selectedTags.clear();
  }

  List<dynamic> getPeerTags(String id) {
    final it = currentAbPeers.where((p0) => p0.id == id);
    if (it.isEmpty) {
      return [];
    } else {
      return it.first.tags;
    }
  }

  String getPeerNote(String id) {
    final it = currentAbPeers.where((p0) => p0.id == id);
    if (it.isEmpty) {
      return '';
    } else {
      return it.first.note;
    }
  }

  Color getCurrentAbTagColor(String tag) {
    if (tag == kUntagged) {
      return MyTheme.accent;
    }
    int? colorValue = current.tagColors[tag];
    if (colorValue != null) {
      return Color(colorValue);
    }
    return str2color2(tag, existing: current.tagColors.values.toList());
  }

  List<String> addressBookNames() {
    return addressbooks.keys.toList();
  }

  String personalAddressBookName() {
    return _personalAbName;
  }

  Future<void> setCurrentName(String name) async {
    final oldName = _currentName.value;
    if (addressbooks.containsKey(name)) {
      _currentName.value = name;
    } else {
      if (addressbooks.containsKey(_personalAbName)) {
        _currentName.value = _personalAbName;
      } else {
        _currentName.value = '';
      }
    }
    if (!current.initialized) {
      await current.pullAb(quiet: false);
    }
    _refreshTab();
    if (oldName != _currentName.value) {
      _syncAllFromRecent = true;
      _saveCache();
    }
  }

  bool isCurrentAbFull(bool warn) {
    final res = current.isFull();
    if (res && warn) {
      BotToast.showText(
        contentColor: Colors.red,
        text: translate('exceed_max_devices'),
      );
    }
    return res;
  }

  void _refreshTab() {
    platformFFI.tryHandle({'name': LoadEvent.addressBook});
  }

  // should not call this function in a loop call stack
  Future<void> pullNonLegacyAfterChange({String? name}) async {
    if (name == null) {
      return await current.pullAb(quiet: true);
    }
    final ab = addressbooks[name];
    if (ab != null) {
      return await ab.pullAb(quiet: true);
    }
  }

  List<String> idExistIn(String id) {
    List<String> v = [];
    addressbooks.forEach((key, value) {
      if (value.peers.any((e) => e.id == id)) {
        v.add(key);
      }
    });
    return v;
  }

  List<Peer> allPeers() {
    List<Peer> v = [];
    addressbooks.forEach((key, value) {
      v.addAll(value.peers.map((e) => Peer.copy(e)).toList());
    });
    return v;
  }

  String translatedName(String name) {
    if (name == _personalAbName) {
      return translate(name);
    } else {
      return name;
    }
  }

  void _callbackPeerUpdate() {
    for (var listener in _peerIdUpdateListeners.values) {
      listener();
    }
  }

  void addPeerUpdateListener(String key, VoidCallback listener) {
    _peerIdUpdateListeners[key] = listener;
  }

  void removePeerUpdateListener(String key) {
    _peerIdUpdateListeners.remove(key);
  }

  String? getdefaultSharedPassword() {
    if (current.isPersonal()) {
      return null;
    }
    final profile = current.sharedProfile();
    if (profile == null) {
      return null;
    }
    try {
      if (profile.info is Map) {
        final password = (profile.info as Map)['password'];
        if (password is String && password.isNotEmpty) {
          return password;
        }
      }
      return null;
    } catch (e) {
      debugPrint("getdefaultSharedPassword: $e");
      return null;
    }
  }

  // #endregion
}

abstract class BaseAb {
  final peers = List<Peer>.empty(growable: true).obs;
  final RxList<String> tags = <String>[].obs;
  final RxMap<String, int> tagColors = Map<String, int>.fromEntries([]).obs;
  final selectedTags = List<String>.empty(growable: true).obs;

  final pullError = "".obs;
  final pushError = "".obs;
  final abLoading = false
      .obs; // Indicates whether the UI should show a loading state for the address book.
  var abPulling =
      false; // Tracks whether a pull operation is currently in progress to prevent concurrent pulls. Unlike abLoading, this is not tied to UI updates.
  bool initialized = false;

  String name();

  bool isPersonal() {
    return false;
  }

  Future<void> pullAb({quiet = false}) async {
    if (abPulling) return;
    abPulling = true;
    if (!quiet) {
      abLoading.value = true;
      pullError.value = "";
    }
    initialized = false;
    debugPrint("pull ab \"${name()}\"");
    try {
      initialized = await pullAbImpl(quiet: quiet);
    } catch (e) {
      debugPrint("Error occurred while pulling address book: $e");
    } finally {
      abLoading.value = false;
      abPulling = false;
    }
  }

  Future<bool> pullAbImpl({quiet = false});

  Future<String?> addPeers(List<Map<String, dynamic>> ps);
  removeHash(Map<String, dynamic> p) {
    p.remove('hash');
  }

  removePassword(Map<String, dynamic> p) {
    p.remove('password');
  }

  removeNonExistentTags(Map<String, dynamic> p) {
    try {
      final oldTags = p.remove('tags');
      if (oldTags is List) {
        final newTags = oldTags.where((e) => tagContainBy(e)).toList();
        p['tags'] = newTags;
      }
    } catch (e) {
      print("removeNonExistentTags: $e");
    }
  }

  Future<bool> changeTagForPeers(List<String> ids, List<dynamic> tags);

  Future<bool> changeAlias({required String id, required String alias});

  Future<bool> changeNote({required String id, required String note});

  Future<bool> changePersonalHashPassword(String id, String hash);

  Future<bool> changeSharedPassword(String id, String password);

  Future<bool> deletePeers(List<String> ids);

  Future<bool> addTags(List<String> tagList, Map<String, int> tagColorMap);

  bool tagContainBy(String tag) {
    return tags.where((element) => element == tag).isNotEmpty;
  }

  Future<bool> renameTag(String oldTag, String newTag);

  Future<bool> setTagColor(String tag, Color color);

  Future<bool> deleteTag(String tag);

  bool isFull();

  void setSharedProfile(AbProfile profile);

  AbProfile? sharedProfile();

  bool canWrite();

  bool fullControl();

  Future<void> syncFromRecent(List<Peer> recents);
}

class Ab extends BaseAb {
  AbProfile profile;
  late final bool personal;
  bool get emtpy => peers.isEmpty && tags.isEmpty;

  Ab(this.profile, this.personal);

  @override
  String name() {
    if (profile.name.isNotEmpty) {
      return profile.name;
    }
    return _personalAddressBookName;
  }

  @override
  bool isPersonal() {
    return personal;
  }

  @override
  AbProfile? sharedProfile() {
    return profile;
  }

  @override
  void setSharedProfile(AbProfile profile) {
    this.profile = profile;
  }

  @override
  bool isFull() {
    return gFFI.abModel._maxPeerOneAb > 0 &&
        peers.length >= gFFI.abModel._maxPeerOneAb;
  }

  @override
  bool canWrite() {
    if (personal) {
      return true;
    } else {
      return profile.rule == ShareRule.readWrite.value ||
          profile.rule == ShareRule.fullControl.value;
    }
  }

  @override
  bool fullControl() {
    if (personal) {
      return true;
    } else {
      return profile.rule == ShareRule.fullControl.value;
    }
  }

  @override
  Future<bool> pullAbImpl({quiet = false}) async {
    // Only adopt a result the server actually delivered. A transient failure
    // used to publish the partial list anyway, and every caller persists what
    // it sees, so one dropped request could blank the address book on screen
    // and overwrite the offline cache with an empty book.
    bool ret = true;
    List<Peer> tmpPeers = [];
    if (await _fetchPeers(tmpPeers, quiet: quiet)) {
      peers.value = tmpPeers;
    } else {
      ret = false;
    }
    List<AbTag> tmpTags = [];
    if (await _fetchTags(tmpTags, quiet: quiet)) {
      tags.value = tmpTags.map((e) => e.name).toList();
      tagColors.value = {for (final t in tmpTags) t.name: t.color};
    } else {
      ret = false;
    }
    return ret;
  }

  Future<bool> _fetchPeers(List<Peer> tmpPeers, {quiet = false}) async {
    final api = "${await bind.mainGetApiServer()}/api/ab/peers";
    int? statusCode;
    try {
      var uri0 = Uri.parse(api);
      final pageSize = 100;
      var total = 0;
      int current = 0;
      do {
        current += 1;
        var uri = Uri(
          scheme: uri0.scheme,
          host: uri0.host,
          path: uri0.path,
          port: uri0.port,
          queryParameters: {
            'current': current.toString(),
            'pageSize': pageSize.toString(),
            'ab': profile.guid,
          },
        );
        var headers = getHttpHeaders();
        headers['Content-Type'] = "application/json";
        _setEmptyBody(headers);
        final resp = await http.post(uri, headers: headers);
        statusCode = resp.statusCode;
        Map<String, dynamic> json = _jsonDecodeRespMap(
          decode_http_response(resp),
          resp.statusCode,
        );
        if (json.containsKey('error')) {
          throw json['error'];
        }
        if (resp.statusCode != 200) {
          throw 'HTTP ${resp.statusCode}';
        }
        if (json.containsKey('total')) {
          if (total == 0) total = json['total'];
          if (json.containsKey('data')) {
            final data = json['data'];
            if (data is List) {
              for (final profile in data) {
                if (profile is! Map<String, dynamic>) {
                  debugPrint('Ignoring invalid address book peer payload');
                  continue;
                }
                final u = Peer.fromJson(profile);
                if (u.id.trim().isEmpty) {
                  debugPrint('Ignoring address book peer without an id');
                  continue;
                }
                int index = tmpPeers.indexWhere((e) => e.id == u.id);
                if (index < 0) {
                  tmpPeers.add(u);
                } else {
                  tmpPeers[index] = u;
                }
              }
            }
          }
        }
      } while (current * pageSize < total);
      return true;
    } catch (err) {
      if (!quiet) {
        pullError.value =
            '${translate('pull_ab_failed_tip')}: ${translate(err.toString())}';
      }
    } finally {
      // An expired or revoked token has to sign the user out however the pull
      // was started. Gating this on pullError skipped it for background pulls,
      // which are the ones that run after every edit - so the session stayed
      // half-alive, showing an empty book with no way back to the login form.
      if (statusCode == 401) {
        gFFI.userModel.reset(resetOther: true);
      }
    }
    return false;
  }

  Future<bool> _fetchTags(List<AbTag> tmpTags, {quiet = false}) async {
    final api = "${await bind.mainGetApiServer()}/api/ab/tags/${profile.guid}";
    int? statusCode;
    try {
      var uri0 = Uri.parse(api);
      var uri = Uri(
        scheme: uri0.scheme,
        host: uri0.host,
        path: uri0.path,
        port: uri0.port,
      );
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      _setEmptyBody(headers);
      final resp = await http.post(uri, headers: headers);
      statusCode = resp.statusCode;
      List<dynamic> json = _jsonDecodeRespList(
        decode_http_response(resp),
        resp.statusCode,
      );
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode}';
      }

      for (final d in json) {
        final t = AbTag.fromJson(d);
        int index = tmpTags.indexWhere((e) => e.name == t.name);
        if (index < 0) {
          tmpTags.add(t);
        } else {
          tmpTags[index] = t;
        }
      }
      return true;
    } catch (err) {
      if (!quiet) {
        pullError.value =
            '${translate('pull_ab_failed_tip')}: ${translate(err.toString())}';
      }
    } finally {
      // An expired or revoked token has to sign the user out however the pull
      // was started. Gating this on pullError skipped it for background pulls,
      // which are the ones that run after every edit - so the session stayed
      // half-alive, showing an empty book with no way back to the login form.
      if (statusCode == 401) {
        gFFI.userModel.reset(resetOther: true);
      }
    }
    return false;
  }

  // #region Peers
  @override
  Future<String?> addPeers(List<Map<String, dynamic>> ps) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/peer/add/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      for (var p in ps) {
        if (peers.firstWhereOrNull((e) => e.id == p['id']) != null) {
          continue;
        }
        if (isFull()) {
          return translate("exceed_max_devices");
        }
        if (personal) {
          removePassword(p);
        } else {
          removeHash(p);
        }
        String body = jsonEncode(p);
        final resp = await http.post(
          Uri.parse(api),
          headers: headers,
          body: body,
        );
        final errMsg = _jsonDecodeActionResp(resp);
        if (errMsg.isNotEmpty) {
          return errMsg;
        }
      }
    } catch (err) {
      return err.toString();
    }
    return null;
  }

  @override
  Future<bool> changeTagForPeers(List<String> ids, List<dynamic> tags) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/peer/update/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      var ret = true;
      for (var id in ids) {
        final body = jsonEncode({"id": id, "tags": tags});
        final resp = await http.put(
          Uri.parse(api),
          headers: headers,
          body: body,
        );
        final errMsg = _jsonDecodeActionResp(resp);
        if (errMsg.isNotEmpty) {
          BotToast.showText(contentColor: Colors.red, text: errMsg);
          ret = false;
          break;
        }
      }
      return ret;
    } catch (err) {
      debugPrint('changeTagForPeers err: ${err.toString()}');
      return false;
    }
  }

  @override
  Future<bool> changeAlias({required String id, required String alias}) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/peer/update/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode({"id": id, "alias": alias});
      final resp = await http.put(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        BotToast.showText(contentColor: Colors.red, text: errMsg);
        return false;
      }
      return true;
    } catch (err) {
      debugPrint('changeAlias err: ${err.toString()}');
      return false;
    }
  }

  @override
  Future<bool> changeNote({required String id, required String note}) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/peer/update/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode({"id": id, "note": note});
      final resp = await http.put(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        BotToast.showText(contentColor: Colors.red, text: errMsg);
        return false;
      }
      return true;
    } catch (err) {
      debugPrint('changeNote err: ${err.toString()}');
      return false;
    }
  }

  Future<bool> _setPassword(Object bodyContent) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/peer/update/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode(bodyContent);
      final resp = await http.put(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        BotToast.showText(contentColor: Colors.red, text: errMsg);
        return false;
      }
      return true;
    } catch (err) {
      debugPrint('changeSharedPassword err: ${err.toString()}');
      return false;
    }
  }

  @override
  Future<bool> changePersonalHashPassword(String id, String hash) async {
    if (!personal) return false;
    if (!peers.any((e) => e.id == id)) return true;
    return await _setPassword({"id": id, "hash": hash});
  }

  @override
  Future<bool> changeSharedPassword(String id, String password) async {
    if (personal) return false;
    return await _setPassword({"id": id, "password": password});
  }

  @override
  Future<void> syncFromRecent(List<Peer> recents) async {
    bool uiUpdate = false;
    bool saveCache = false;
    final api =
        "${await bind.mainGetApiServer()}/api/ab/peer/update/${profile.guid}";
    var headers = getHttpHeaders();
    headers['Content-Type'] = "application/json";

    Future<bool> trySyncOnePeer(Peer p, Peer r) async {
      var map = Map<String, String>.fromEntries([]);
      if (p.sameServer != true &&
          r.username.isNotEmpty &&
          p.username != r.username) {
        p.username = r.username;
        map['username'] = r.username;
      }
      if (p.sameServer != true &&
          r.hostname.isNotEmpty &&
          p.hostname != r.hostname) {
        p.hostname = r.hostname;
        map['hostname'] = r.hostname;
      }
      if (p.sameServer != true &&
          r.platform.isNotEmpty &&
          p.platform != r.platform) {
        p.platform = r.platform;
        map['platform'] = r.platform;
      }
      if (personal && r.hash.isNotEmpty && p.hash != r.hash) {
        p.hash = r.hash;
        map['hash'] = r.hash;
        saveCache = true;
      }
      if (map.isEmpty) {
        // no need to sync
        return false;
      }
      map['id'] = p.id;
      final body = jsonEncode(map);
      final resp = await http.put(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        debugPrint('syncOnePeer errMsg: $errMsg');
        return false;
      }
      uiUpdate = true;
      return true;
    }

    try {
      // Not add new peers because IDs that are not on the server can't be synced, then sync will happen every startup.
      for (var p in peers) {
        Peer? r = recents.firstWhereOrNull((e) => e.id == p.id);
        if (r != null) {
          await trySyncOnePeer(p, r);
        }
      }
      // Pull cannot be used for sync to avoid cyclic sync.
      if (uiUpdate && gFFI.abModel.currentName.value == profile.name) {
        peers.refresh();
      }
      if (saveCache) {
        gFFI.abModel._saveCache();
      }
    } catch (err) {
      debugPrint('syncFromRecent err: ${err.toString()}');
    }
  }

  @override
  Future<bool> deletePeers(List<String> ids) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/peer/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode(ids);
      final resp = await http.delete(
        Uri.parse(api),
        headers: headers,
        body: body,
      );
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        BotToast.showText(contentColor: Colors.red, text: errMsg);
        return false;
      }
      return true;
    } catch (err) {
      debugPrint('deletePeers err: ${err.toString()}');
      return false;
    }
  }
  // #endregion

  // #region Tags
  @override
  Future<bool> addTags(
    List<String> tagList,
    Map<String, int> tagColorMap,
  ) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/tag/add/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      for (var t in tagList) {
        final body = jsonEncode({
          "name": t,
          "color":
              tagColorMap[t] ??
              str2color2(t, existing: tagColors.values.toList()).value,
        });
        final resp = await http.post(
          Uri.parse(api),
          headers: headers,
          body: body,
        );
        final errMsg = _jsonDecodeActionResp(resp);
        if (errMsg.isNotEmpty) {
          BotToast.showText(contentColor: Colors.red, text: errMsg);
          return false;
        }
      }
      return true;
    } catch (err) {
      debugPrint('addTags err: ${err.toString()}');
      return false;
    }
  }

  @override
  Future<bool> renameTag(String oldTag, String newTag) async {
    if (tags.contains(newTag)) {
      BotToast.showText(
        contentColor: Colors.red,
        text: 'Tag $newTag already exists',
      );
      return false;
    }
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/tag/rename/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode({"old": oldTag, "new": newTag});
      final resp = await http.put(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        BotToast.showText(contentColor: Colors.red, text: errMsg);
        return false;
      }
      return true;
    } catch (err) {
      debugPrint('renameTag err: ${err.toString()}');
      return false;
    }
  }

  @override
  Future<bool> setTagColor(String tag, Color color) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/tag/update/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode({"name": tag, "color": color.value});
      final resp = await http.put(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        BotToast.showText(contentColor: Colors.red, text: errMsg);
        return false;
      }
      return true;
    } catch (err) {
      debugPrint('setTagColor err: ${err.toString()}');
      return false;
    }
  }

  @override
  Future<bool> deleteTag(String tag) async {
    try {
      final api = "${await bind.mainGetApiServer()}/api/ab/tag/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode([tag]);
      final resp = await http.delete(
        Uri.parse(api),
        headers: headers,
        body: body,
      );
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        BotToast.showText(contentColor: Colors.red, text: errMsg);
        return false;
      }
      return true;
    } catch (err) {
      debugPrint('deleteTag err: ${err.toString()}');
      return false;
    }
  }

  // #endregion
}

// DummyAb is for current ab is null
class DummyAb extends BaseAb {
  @override
  bool isFull() {
    return false;
  }

  @override
  Future<String?> addPeers(List<Map<String, dynamic>> ps) async {
    return "dummpy";
  }

  @override
  Future<bool> addTags(
    List<String> tagList,
    Map<String, int> tagColorMap,
  ) async {
    return false;
  }

  @override
  bool canWrite() {
    return false;
  }

  @override
  bool fullControl() {
    return false;
  }

  @override
  Future<bool> changeAlias({required String id, required String alias}) async {
    return false;
  }

  @override
  Future<bool> changeNote({required String id, required String note}) async {
    return false;
  }

  @override
  Future<bool> changePersonalHashPassword(String id, String hash) async {
    return false;
  }

  @override
  Future<bool> changeSharedPassword(String id, String password) async {
    return false;
  }

  @override
  Future<bool> changeTagForPeers(List<String> ids, List tags) async {
    return false;
  }

  @override
  Future<bool> deletePeers(List<String> ids) async {
    return false;
  }

  @override
  Future<bool> deleteTag(String tag) async {
    return false;
  }

  @override
  String name() {
    return "dummpy";
  }

  @override
  Future<bool> pullAbImpl({quiet = false}) async {
    return false;
  }

  @override
  Future<bool> renameTag(String oldTag, String newTag) async {
    return false;
  }

  @override
  Future<bool> setTagColor(String tag, Color color) async {
    return false;
  }

  @override
  AbProfile? sharedProfile() {
    return null;
  }

  @override
  void setSharedProfile(AbProfile profile) {}

  @override
  Future<void> syncFromRecent(List<Peer> recents) async {}
}

Map<String, dynamic> _jsonDecodeRespMap(String body, int statusCode) {
  try {
    Map<String, dynamic> json = jsonDecode(body);
    return json;
  } catch (e) {
    final err = body.isNotEmpty && body.length < 128 ? body : e.toString();
    if (statusCode != 200) {
      throw 'HTTP $statusCode, $err';
    }
    throw err;
  }
}

List<dynamic> _jsonDecodeRespList(String body, int statusCode) {
  try {
    List<dynamic> json = jsonDecode(body);
    return json;
  } catch (e) {
    final err = body.isNotEmpty && body.length < 128 ? body : e.toString();
    if (statusCode != 200) {
      throw 'HTTP $statusCode, $err';
    }
    throw err;
  }
}

String _jsonDecodeActionResp(http.Response resp) {
  var errMsg = '';
  if (resp.statusCode == 200 && resp.body.isEmpty) {
    // ok
  } else {
    try {
      errMsg = jsonDecode(resp.body)['error'].toString();
    } catch (_) {}
    if (errMsg.isEmpty) {
      if (resp.statusCode != 200) {
        errMsg = 'HTTP ${resp.statusCode}';
      }
      if (resp.body.isNotEmpty) {
        if (errMsg.isNotEmpty) {
          errMsg += ', ';
        }
        errMsg += resp.body;
      }
      if (errMsg.isEmpty) {
        errMsg = "unknown error";
      }
    }
  }
  return errMsg;
}

// https://github.com/seanmonstar/reqwest/issues/838
void _setEmptyBody(Map<String, String> headers) {
  headers['Content-Length'] = '0';
}
