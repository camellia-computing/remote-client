import 'dart:convert';

const remoteCommandBarLayoutOption = 'remote-command-bar-layout-v1';
const remoteCommandBarStateOption = 'remote-command-bar-state-v1';

enum RemoteCommandBarEdge {
  top,
  right,
  bottom,
  left;

  bool get isHorizontal => this == top || this == bottom;

  static RemoteCommandBarEdge parse(Object? value) => switch (value) {
    'right' => right,
    'bottom' => bottom,
    'left' => left,
    _ => top,
  };
}

enum RemoteCommandBarTier {
  core,
  input,
  collaboration,
  full;

  static RemoteCommandBarTier forExtent(double extent) {
    if (!extent.isFinite) return full;
    if (extent < 420) return core;
    if (extent < 560) return input;
    if (extent < 720) return collaboration;
    return full;
  }

  bool includes(RemoteCommandBarTier minimum) => index >= minimum.index;
}

abstract final class RemoteCommandMenuMetrics {
  static const double rowHeight = 36;
  static const double compactHandleExtent = 64;

  static double _availableExtent(double viewportExtent, double maximum) {
    if (!viewportExtent.isFinite) return maximum;
    return (viewportExtent - 24).clamp(0.0, maximum).toDouble();
  }

  static double menuWidth(double viewportWidth) =>
      _availableExtent(viewportWidth, 232);

  static double statusMenuWidth(double viewportWidth) =>
      _availableExtent(viewportWidth, 260);

  static double menuHeight(double viewportHeight) =>
      _availableExtent(viewportHeight, 720);

  static double statusPanelWidth(double viewportWidth) =>
      (statusMenuWidth(viewportWidth) - 24).clamp(0.0, 236.0).toDouble();

  static double statusMetricWidth(double viewportWidth) {
    final contentWidth = (statusPanelWidth(viewportWidth) - 24)
        .clamp(0.0, 212.0)
        .toDouble();
    return contentWidth >= 190 ? (contentWidth - 6) / 2 : contentWidth;
  }
}

/// Persisted, application-wide placement of the remote session command bar.
///
/// The client has not shipped yet, so this schema intentionally has no legacy
/// migration branch. Invalid or unknown data resets to a safe top-center dock.
class RemoteCommandBarPreferences {
  const RemoteCommandBarPreferences({
    this.edge = RemoteCommandBarEdge.top,
    this.fraction = 0.5,
  });

  static const schemaVersion = 1;
  static const defaults = RemoteCommandBarPreferences();

  final RemoteCommandBarEdge edge;
  final double fraction;

  RemoteCommandBarPreferences normalized() => RemoteCommandBarPreferences(
    edge: edge,
    fraction: fraction.isFinite ? fraction.clamp(0, 1).toDouble() : 0.5,
  );

  RemoteCommandBarPreferences copyWith({
    RemoteCommandBarEdge? edge,
    double? fraction,
  }) => RemoteCommandBarPreferences(
    edge: edge ?? this.edge,
    fraction: fraction ?? this.fraction,
  ).normalized();

  Map<String, Object> toJson() {
    final value = normalized();
    return {
      'version': schemaVersion,
      'edge': value.edge.name,
      'fraction': value.fraction,
    };
  }

  String encode() => jsonEncode(toJson());

  static RemoteCommandBarPreferences decode(String? source) {
    if (source == null || source.trim().isEmpty) return defaults;
    try {
      final json = jsonDecode(source);
      if (json is! Map<String, dynamic> || json['version'] != schemaVersion) {
        return defaults;
      }
      final rawFraction = json['fraction'];
      return RemoteCommandBarPreferences(
        edge: RemoteCommandBarEdge.parse(json['edge']),
        fraction: rawFraction is num ? rawFraction.toDouble() : 0.5,
      ).normalized();
    } on FormatException {
      return defaults;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteCommandBarPreferences &&
      edge == other.edge &&
      fraction == other.fraction;

  @override
  int get hashCode => Object.hash(edge, fraction);
}

/// Presentation-safe snapshot for the status chip and details panel.
class SessionStatusSnapshot {
  const SessionStatusSnapshot({
    this.secure,
    this.direct,
    this.streamType,
    this.speed,
    this.fps,
    this.delay,
    this.targetBitrate,
    this.codec,
    this.chroma,
  });

  final bool? secure;
  final bool? direct;
  final String? streamType;
  final String? speed;
  final String? fps;
  final String? delay;
  final String? targetBitrate;
  final String? codec;
  final String? chroma;

  String get delayValue => _withUnit(delay, 'ms');

  String get bitrateValue => _withUnit(targetBitrate, 'kbps');

  static String _withUnit(String? source, String unit) {
    final value = _display(source);
    if (value == '—') return value;
    final suffix = RegExp('\\s${RegExp.escape(unit)}\$', caseSensitive: false);
    return suffix.hasMatch(value) ? value : '$value $unit';
  }

  static String _display(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? '—' : trimmed;
  }

  String display(String? value) => _display(value);
}
