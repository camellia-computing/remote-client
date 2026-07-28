import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:camellia_remote_app/web/platform_ffi_web.dart';
import 'package:web/web.dart' as web;

class WebVideoSurface extends StatefulWidget {
  final String peerId;

  const WebVideoSurface({super.key, required this.peerId});

  @override
  State<WebVideoSurface> createState() => _WebVideoSurfaceState();
}

class _WebVideoSurfaceState extends State<WebVideoSurface> {
  late final String _elementId;
  late final String _viewType;
  bool _attached = false;

  @override
  void initState() {
    super.initState();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    _elementId = 'camellia-web-video-${widget.peerId}-$stamp';
    _viewType = 'camellia-web-video-view-${widget.peerId}-$stamp';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _viewId) {
      final element = web.HTMLDivElement()
        ..id = _elementId
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.margin = '0'
        ..style.padding = '0'
        ..style.overflow = 'hidden'
        ..style.backgroundColor = '#000'
        ..style.pointerEvents = 'none'
        ..style.position = 'relative'
        ..style.transform = 'translateZ(0)';
      return element;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attachToRuntime();
    });
  }

  @override
  void dispose() {
    if (_attached) {
      PlatformFFI.setByName('detach_video_surface', _elementId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }

  void _attachToRuntime() {
    if (!mounted || _attached) {
      return;
    }
    PlatformFFI.setByName('attach_video_surface', _elementId);
    _attached = true;
  }
}
