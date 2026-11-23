import 'dart:math';
import 'dart:ui';

/// 12方向ジェスチャーの形状キー（1方向4種 + 直角に1回曲げる2方向8種）
const List<String> kGestureShapes = <String>[
  'L',
  'R',
  'U',
  'D',
  'LU',
  'LD',
  'RU',
  'RD',
  'UL',
  'UR',
  'DL',
  'DR',
];

const List<String> kSingleGestureShapes = <String>['L', 'R', 'U', 'D'];
const List<String> kDoubleGestureShapes = <String>[
  'LU',
  'LD',
  'RU',
  'RD',
  'UL',
  'UR',
  'DL',
  'DR',
];

enum GestureDirection { l, r, u, d }

extension GestureDirectionExt on GestureDirection {
  String get code => switch (this) {
        GestureDirection.l => 'L',
        GestureDirection.r => 'R',
        GestureDirection.u => 'U',
        GestureDirection.d => 'D',
      };

  GestureDirection get opposite => switch (this) {
        GestureDirection.l => GestureDirection.r,
        GestureDirection.r => GestureDirection.l,
        GestureDirection.u => GestureDirection.d,
        GestureDirection.d => GestureDirection.u,
      };
}

class GestureActionDef {
  const GestureActionDef({
    required this.id,
    required this.label,
    required this.section,
    this.subtitle,
  });

  final String id;
  final String label;
  final String section;
  final String? subtitle;
}

const List<GestureActionDef> kMobileGestureActions = <GestureActionDef>[
  GestureActionDef(
    id: 'go-back',
    label: '前のページへ戻る',
    section: 'ページ操作',
  ),
  GestureActionDef(
    id: 'go-forward',
    label: '次のページへ進む',
    section: 'ページ操作',
  ),
  GestureActionDef(
    id: 'reload',
    label: 'ページを再読み込み',
    section: 'ページ操作',
  ),
  GestureActionDef(
    id: 'home',
    label: 'DM / ホーム画面へ戻る',
    section: 'ページ操作',
  ),
  GestureActionDef(
    id: 'previous-service',
    label: '前のSNSへ切替',
    section: 'SNS・アカウント切替',
  ),
  GestureActionDef(
    id: 'next-service',
    label: '次のSNSへ切替',
    section: 'SNS・アカウント切替',
  ),
  GestureActionDef(
    id: 'previous-account',
    label: '前のアカウントへ切替',
    section: 'SNS・アカウント切替',
  ),
  GestureActionDef(
    id: 'next-account',
    label: '次のアカウントへ切替',
    section: 'SNS・アカウント切替',
  ),
  GestureActionDef(
    id: 'scroll:up',
    label: '上へ連続スクロール',
    section: 'スクロール',
    subtitle: 'ドラッグ中リアルタイムに上へスクロール',
  ),
  GestureActionDef(
    id: 'scroll:down',
    label: '下へ連続スクロール',
    section: 'スクロール',
    subtitle: 'ドラッグ中リアルタイムに下へスクロール',
  ),
  GestureActionDef(
    id: 'scroll-top',
    label: '一番上へスクロール',
    section: 'スクロール',
  ),
  GestureActionDef(
    id: 'scroll-bottom',
    label: '一番下へスクロール',
    section: 'スクロール',
  ),
  GestureActionDef(
    id: 'toggle-gmail',
    label: 'アプリ内Gmailを開閉',
    section: 'ツール・表示',
  ),
  GestureActionDef(
    id: 'open-follow-counter',
    label: 'フォローカウンターを開く',
    section: 'ツール・表示',
  ),
  GestureActionDef(
    id: 'toggle-header',
    label: 'ヘッダーを折り畳み / 展開',
    section: 'ツール・表示',
  ),
  GestureActionDef(
    id: 'toggle-bottom-tabs',
    label: '下部タブを折り畳み / 展開',
    section: 'ツール・表示',
  ),
  GestureActionDef(
    id: 'open-catalog',
    label: 'サービスカタログを開く',
    section: 'ツール・表示',
  ),
  GestureActionDef(
    id: 'sleep-tab',
    label: 'タブを休止（メモリ解放）',
    section: 'ツール・表示',
  ),
  GestureActionDef(
    id: 'open-external',
    label: '外部ブラウザで開く',
    section: 'ツール・表示',
  ),
  GestureActionDef(
    id: 'gesture:settings',
    label: 'ジェスチャー設定を開く',
    section: 'ツール・表示',
  ),
];

Map<String, String> defaultMobileGestures() {
  return <String, String>{
    'L': 'go-back',
    'R': 'go-forward',
    'U': 'scroll:up',
    'D': 'scroll:down',
    'LU': 'previous-service',
    'RU': 'next-service',
    'LD': 'previous-account',
    'RD': 'next-account',
    'UL': 'scroll-top',
    'UR': 'reload',
    'DL': 'toggle-gmail',
    'DR': 'scroll-bottom',
  };
}

String shapeArrows(String shape) {
  final buf = StringBuffer();
  for (final ch in shape.split('')) {
    switch (ch) {
      case 'L':
        buf.write('←');
      case 'R':
        buf.write('→');
      case 'U':
        buf.write('↑');
      case 'D':
        buf.write('↓');
    }
  }
  return buf.toString();
}

String shapeNameJa(String shape) {
  return switch (shape) {
    'L' => '左',
    'R' => '右',
    'U' => '上',
    'D' => '下',
    'LU' => '左→上',
    'LD' => '左→下',
    'RU' => '右→上',
    'RD' => '右→下',
    'UL' => '上→左',
    'UR' => '上→右',
    'DL' => '下→左',
    'DR' => '下→右',
    _ => shape,
  };
}

String actionLabelJa(String action) {
  if (action.isEmpty || action == 'none') return '割り当てなし';
  for (final def in kMobileGestureActions) {
    if (def.id == action) return def.label;
  }
  return action;
}

bool isValidMobileGestureAction(String action) {
  if (action == 'none') return true;
  return kMobileGestureActions.any((d) => d.id == action);
}

bool isLiveScrollAction(String action) {
  return action == 'scroll:up' || action == 'scroll:down';
}

/// タブ／アカウント／SNS 切替時の次インデックス計算（wrap対応）。
int? stepTabIndex(int len, int cur, int delta, bool wrap) {
  if (len <= 1) return null;
  final next = cur + delta;
  if (next < 0) {
    return wrap ? len - 1 : null;
  }
  if (next >= len) {
    return wrap ? 0 : null;
  }
  return next;
}

class MobileGestureSettings {
  const MobileGestureSettings({
    this.enabled = true,
    this.wrapTabs = true,
    this.showTrail = true,
    this.showFeedback = true,
    this.allowDup = false,
    this.tremor = 10,
    this.triggerSide = 'right',
    this.handleXFraction = 0.90,
    this.handleYFraction = 0.62,
    Map<String, String>? gestures,
  }) : _gestures = gestures;

  final bool enabled;
  final bool wrapTabs;
  final bool showTrail;
  final bool showFeedback;
  final bool allowDup;
  final int tremor;
  final String triggerSide; // 'right' | 'left' | 'both'
  final double handleXFraction; // 0.06..0.94
  final double handleYFraction; // 0.14..0.88
  final Map<String, String>? _gestures;

  Map<String, String> get gestures {
    final base = _gestures ?? defaultMobileGestures();
    final out = <String, String>{};
    for (final shape in kGestureShapes) {
      final act = base[shape] ?? 'none';
      out[shape] = isValidMobileGestureAction(act) ? act : 'none';
    }
    return out;
  }

  String actionFor(String shape) => gestures[shape] ?? 'none';

  MobileGestureSettings copyWith({
    bool? enabled,
    bool? wrapTabs,
    bool? showTrail,
    bool? showFeedback,
    bool? allowDup,
    int? tremor,
    String? triggerSide,
    double? handleXFraction,
    double? handleYFraction,
    Map<String, String>? gestures,
  }) {
    final nextSide = triggerSide ?? this.triggerSide;
    final safeSide =
        (nextSide == 'left' || nextSide == 'both' || nextSide == 'right')
            ? nextSide
            : 'right';
    return MobileGestureSettings(
      enabled: enabled ?? this.enabled,
      wrapTabs: wrapTabs ?? this.wrapTabs,
      showTrail: showTrail ?? this.showTrail,
      showFeedback: showFeedback ?? this.showFeedback,
      allowDup: allowDup ?? this.allowDup,
      tremor: (tremor ?? this.tremor).clamp(4, 36),
      triggerSide: safeSide,
      handleXFraction: (handleXFraction ?? this.handleXFraction).clamp(0.06, 0.94),
      handleYFraction: (handleYFraction ?? this.handleYFraction).clamp(0.14, 0.88),
      gestures: gestures ?? this.gestures,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'enabled': enabled,
      'wrapTabs': wrapTabs,
      'showTrail': showTrail,
      'showFeedback': showFeedback,
      'allowDup': allowDup,
      'tremor': tremor,
      'triggerSide': triggerSide,
      'handleXFraction': handleXFraction,
      'handleYFraction': handleYFraction,
      'gestures': gestures,
    };
  }

  factory MobileGestureSettings.fromJson(Map<String, dynamic> json) {
    final rawSide = (json['triggerSide'] as String?)?.trim() ?? 'right';
    final side =
        (rawSide == 'left' || rawSide == 'both' || rawSide == 'right')
            ? rawSide
            : 'right';
    final rawGestures = json['gestures'];
    final map = <String, String>{};
    if (rawGestures is Map) {
      final defaults = defaultMobileGestures();
      for (final shape in kGestureShapes) {
        final v = rawGestures[shape]?.toString();
        if (v != null && isValidMobileGestureAction(v)) {
          map[shape] = v;
        } else {
          map[shape] = defaults[shape] ?? 'none';
        }
      }
    } else {
      map.addAll(defaultMobileGestures());
    }

    return MobileGestureSettings(
      enabled: json['enabled'] as bool? ?? true,
      wrapTabs: json['wrapTabs'] as bool? ?? true,
      showTrail: json['showTrail'] as bool? ?? true,
      showFeedback: json['showFeedback'] as bool? ?? true,
      allowDup: json['allowDup'] as bool? ?? false,
      tremor: ((json['tremor'] as num?)?.toInt() ?? 10).clamp(4, 36),
      triggerSide: side,
      handleXFraction:
          ((json['handleXFraction'] as num?)?.toDouble() ?? 0.90).clamp(0.06, 0.94),
      handleYFraction:
          ((json['handleYFraction'] as num?)?.toDouble() ?? 0.62).clamp(0.14, 0.88),
      gestures: map,
    );
  }
}

/// HisatorNotebook / PC版 OmniSNS 準拠の12方向ジェスチャー幾何認識エンジン。
class GesturePath {
  GesturePath({
    this.firstStepPx = 22.0,
    this.cornerStepPx = 26.0,
    this.axisRatio = 1.65,
    this.minTurnSpanPx = 30.0,
  });

  final double firstStepPx;
  final double cornerStepPx;
  final double axisRatio;
  final double minTurnSpanPx;

  final List<Offset> _points = <Offset>[];
  Offset _origin = Offset.zero;
  Offset _pivot = Offset.zero;
  Offset _extreme = Offset.zero;
  final List<GestureDirection> _dirs = <GestureDirection>[];
  bool _invalidated = false;

  List<Offset> get points => List<Offset>.unmodifiable(_points);
  bool get invalidated => _invalidated;
  Offset get origin => _origin;

  String get shape {
    if (_invalidated || _dirs.isEmpty) return '';
    return _dirs.map((d) => d.code).join();
  }

  void reset(Offset start) {
    _points
      ..clear()
      ..add(start);
    _origin = start;
    _pivot = start;
    _extreme = start;
    _dirs.clear();
    _invalidated = false;
  }

  void push(Offset pt) {
    if (_points.isEmpty) {
      reset(pt);
      return;
    }
    final last = _points.last;
    if ((pt - last).distance >= 2.0) {
      _points.add(pt);
      if (_points.length > 240) {
        _points.removeAt(1);
      }
    }
    if (_invalidated) return;

    if (_dirs.isEmpty) {
      final dx = pt.dx - _origin.dx;
      final dy = pt.dy - _origin.dy;
      final dist = sqrt(dx * dx + dy * dy);
      if (dist < firstStepPx) return;
      final dir = _pickCardinal(dx, dy);
      if (dir == null) return;
      _dirs.add(dir);
      _pivot = _origin;
      _extreme = pt;
      return;
    }

    final curDir = _dirs.last;
    // 現在方向への最大到達点（折り返し基準）を更新
    if (_progressAlong(pt, _extreme, curDir) > 0) {
      _extreme = pt;
    }

    final dx = pt.dx - _extreme.dx;
    final dy = pt.dy - _extreme.dy;
    final distFromExtreme = sqrt(dx * dx + dy * dy);
    if (distFromExtreme < cornerStepPx) return;

    final nextDir = _pickCardinal(dx, dy);
    if (nextDir == null || nextDir == curDir) return;

    // 180度逆戻りはキャンセル扱い
    if (nextDir == curDir.opposite) {
      _invalidated = true;
      return;
    }

    // 2方向まで（3方向目へ曲がったら無効化）
    if (_dirs.length >= 2) {
      _invalidated = true;
      return;
    }

    // 1本目のストロークが短すぎるままのブレは無視
    final firstSpan = _progressAlong(_extreme, _pivot, curDir);
    if (firstSpan < minTurnSpanPx * 0.65) {
      return;
    }

    _dirs.add(nextDir);
    _pivot = _extreme;
    _extreme = pt;
  }

  GestureDirection? _pickCardinal(double dx, double dy) {
    final ax = dx.abs();
    final ay = dy.abs();
    if (ax >= ay * axisRatio) {
      return dx < 0 ? GestureDirection.l : GestureDirection.r;
    }
    if (ay >= ax * axisRatio) {
      return dy < 0 ? GestureDirection.u : GestureDirection.d;
    }
    return null;
  }

  double _progressAlong(Offset pt, Offset ref, GestureDirection dir) {
    return switch (dir) {
      GestureDirection.l => ref.dx - pt.dx,
      GestureDirection.r => pt.dx - ref.dx,
      GestureDirection.u => ref.dy - pt.dy,
      GestureDirection.d => pt.dy - ref.dy,
    };
  }
}

/// 連続スクロール（scroll:up / scroll:down）時の1フレーム当たりスクロール量(px)を算出する。
double computeLiveScrollStep({
  required String action,
  required Offset origin,
  required Offset current,
}) {
  final dy = (current.dy - origin.dy).abs();
  final excess = max(0.0, dy - 18.0);
  final speed = (8.0 + pow(excess / 18.0, 1.32) * 7.5).clamp(8.0, 96.0);
  return action == 'scroll:up' ? -speed : speed;
}
