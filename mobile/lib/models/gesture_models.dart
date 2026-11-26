import 'dart:math';
import 'dart:ui';

/// 16方向ジェスチャーの形状キー（1方向4種 + 斜め4種 + 直角に1回曲げる2方向8種）
const List<String> kGestureShapes = <String>[
  'L',
  'R',
  'U',
  'D',
  'NW',
  'NE',
  'SW',
  'SE',
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
const List<String> kDiagonalGestureShapes = <String>['NW', 'NE', 'SW', 'SE'];
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

bool isSingleStrokeShape(String shape) =>
    kSingleGestureShapes.contains(shape) ||
    kDiagonalGestureShapes.contains(shape);

enum GestureDirection { l, r, u, d, nw, ne, sw, se }

extension GestureDirectionExt on GestureDirection {
  bool get isDiagonal =>
      this == GestureDirection.nw ||
      this == GestureDirection.ne ||
      this == GestureDirection.sw ||
      this == GestureDirection.se;

  String get code => switch (this) {
        GestureDirection.l => 'L',
        GestureDirection.r => 'R',
        GestureDirection.u => 'U',
        GestureDirection.d => 'D',
        GestureDirection.nw => 'NW',
        GestureDirection.ne => 'NE',
        GestureDirection.sw => 'SW',
        GestureDirection.se => 'SE',
      };

  GestureDirection get opposite => switch (this) {
        GestureDirection.l => GestureDirection.r,
        GestureDirection.r => GestureDirection.l,
        GestureDirection.u => GestureDirection.d,
        GestureDirection.d => GestureDirection.u,
        GestureDirection.nw => GestureDirection.se,
        GestureDirection.se => GestureDirection.nw,
        GestureDirection.ne => GestureDirection.sw,
        GestureDirection.sw => GestureDirection.ne,
      };

  (double, double) get diagUnit {
    const s = 0.7071067811865475; // 1 / sqrt(2)
    return switch (this) {
      GestureDirection.nw => (-s, -s),
      GestureDirection.ne => (s, -s),
      GestureDirection.sw => (-s, s),
      GestureDirection.se => (s, s),
      _ => (0.0, 0.0),
    };
  }
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
    id: 'previous-tab',
    label: '前のタブへ',
    section: 'タブ操作',
    subtitle: '現在のアカウント内のタブのみ切替（他SNSへは移動しません）',
  ),
  GestureActionDef(
    id: 'next-tab',
    label: '次のタブへ',
    section: 'タブ操作',
    subtitle: '現在のアカウント内のタブのみ切替（他SNSへは移動しません）',
  ),
  GestureActionDef(
    id: 'new-tab',
    label: '新しいタブを開く',
    section: 'タブ操作',
  ),
  GestureActionDef(
    id: 'close-tab',
    label: '現在のタブを閉じる',
    section: 'タブ操作',
  ),
  GestureActionDef(
    id: 'previous-service',
    label: '上の項目へ（前のSNS）',
    section: 'SNS・アカウント切替',
  ),
  GestureActionDef(
    id: 'next-service',
    label: '下の項目へ（次のSNS）',
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
    'NW': 'none',
    'NE': 'none',
    'SW': 'none',
    'SE': 'none',
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
  switch (shape) {
    case 'NW':
      return '↖';
    case 'NE':
      return '↗';
    case 'SW':
      return '↙';
    case 'SE':
      return '↘';
  }
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
    'NW' => '左上',
    'NE' => '右上',
    'SW' => '左下',
    'SE' => '右下',
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

/// HisatorNotebook / PC版 OmniSNS (`W246GesturePath`) 準拠の直線専用12方向ジェスチャー幾何認識エンジン。
/// 自由曲線の軌跡は描画せず、厳密な水平・垂直の直線セグメント（始点 → 角 → 終点）のみを認識・描画する。
class GesturePath {
  GesturePath({
    this.tremorPx = 10.0,
    this.axisRatio = 1.8,
    this.releaseAxisRatio = 1.3,
    this.releaseMinLen = 16.0,
    this.releaseTailRatio = 0.25,
    this.releaseTailMin = 20.0,
    this.releaseTailMax = 40.0,
  });

  double tremorPx;
  final double axisRatio;
  final double releaseAxisRatio;
  final double releaseMinLen;
  final double releaseTailRatio;
  final double releaseTailMin;
  final double releaseTailMax;

  Offset _origin = Offset.zero;
  Offset _pivot = Offset.zero;
  Offset _last = Offset.zero;
  Offset _end = Offset.zero;
  Offset? _corner;
  final List<GestureDirection> _dirs = <GestureDirection>[];
  double _maxLen = 0.0;
  int _count = 0;
  bool _invalidated = false;
  bool _pending = false;
  bool _everRecognized = false;

  double get tolerance =>
      max(tremorPx, min(_maxLen * 0.15, max(6.0, tremorPx * 1.1)));

  bool get invalidated => _invalidated;
  bool get pending => _pending;
  bool get everRecognized => _everRecognized;
  Offset get origin => _origin;

  /// 直線セグメントの頂点列（始点 → [直角コーナー] → 終点）。自由曲線（ちょろちょろ線）は生成しない。
  List<Offset> get vertices {
    final pts = <Offset>[_origin];
    if (_corner != null) {
      pts.add(_corner!);
    }
    if (_dirs.isNotEmpty) {
      pts.add(_end);
    }
    return pts;
  }

  /// 後方互換ゲッター（常に直線頂点列を返す）。
  List<Offset> get points => vertices;

  String get shape {
    if (_invalidated || _pending || _dirs.isEmpty) return '';
    return _dirs.map((d) => d.code).join();
  }

  void reset(Offset start, {double? tremor}) {
    if (tremor != null) {
      tremorPx = tremor.clamp(4.0, 36.0);
    }
    _origin = start;
    _pivot = start;
    _last = start;
    _end = start;
    _corner = null;
    _dirs.clear();
    _maxLen = 0.0;
    _count = 1;
    _invalidated = false;
    _pending = false;
    _everRecognized = false;
  }

  void push(Offset pt) {
    if (_count == 0) {
      reset(pt);
      return;
    }
    if (_invalidated) return;
    if (!pt.dx.isFinite || !pt.dy.isFinite) {
      _invalidated = true;
      return;
    }
    if ((pt.dx - _last.dx).abs() < 1e-6 && (pt.dy - _last.dy).abs() < 1e-6) {
      return;
    }
    _last = pt;
    _count++;
    if (_count > 200000) {
      _invalidated = true;
      return;
    }

    final tol = tolerance;
    final dx = pt.dx - _pivot.dx;
    final dy = pt.dy - _pivot.dy;

    if (_dirs.isNotEmpty && _dirs.first.isDiagonal) {
      final firstDir = _dirs.first;
      final (ux, uy) = firstDir.diagUnit;
      final along = dx * ux + dy * uy;
      final perp = (dx * (-uy) + dy * ux).abs();
      if (max(along.abs(), perp) <= tol) {
        _pending = false;
        return;
      }
      if (along > tol && along > perp * axisRatio) {
        _pending = false;
        _advanceDiagonal(pt, firstDir, tol);
      } else if (along < -tol || perp > tol * 2.4) {
        _invalidated = true;
        _pending = false;
      } else {
        _pending = true;
      }
      return;
    }

    final ax = dx.abs();
    final ay = dy.abs();
    if (max(ax, ay) <= tol) {
      _pending = false;
      return;
    }

    if (_dirs.isEmpty) {
      final dir = _classifyFirstDir(dx, dy, tol);
      if (dir == null) {
        _pending = true;
        return;
      }
      _pending = false;
      _step(pt, dir, tol);
      return;
    }

    final dir = _classifyDir(dx, dy, axisRatio);
    if (dir == null) {
      _pending = true;
      return;
    }
    _pending = false;
    _step(pt, dir, tol);
  }

  /// 連続スクロール中は軌跡終点を始点と同一軸上の純粋な直線に固定して更新する。
  void advanceLiveScroll(Offset pt) {
    if (_invalidated || _dirs.isEmpty) return;
    final dir = _dirs.last;
    final start = _corner ?? _origin;
    if (dir.isDiagonal) {
      final (ux, uy) = dir.diagUnit;
      final proj = max(0.0, (pt.dx - start.dx) * ux + (pt.dy - start.dy) * uy);
      _end = Offset(start.dx + proj * ux, start.dy + proj * uy);
    } else if (dir == GestureDirection.l || dir == GestureDirection.r) {
      _end = Offset(pt.dx, start.dy);
    } else {
      _end = Offset(start.dx, pt.dy);
    }
  }

  /// 指を離した時点の保留状態を解決し、確定した直線ジェスチャー形状を返す。
  String release() {
    if (_pending && !_invalidated) {
      _resolvePendingAtRelease();
    }
    return shape;
  }

  void _step(Offset pt, GestureDirection dir, double tol) {
    if (_dirs.isEmpty) {
      _dirs.add(dir);
      if (dir.isDiagonal) {
        _advanceDiagonal(pt, dir, tol);
      } else {
        _advance(pt, dir, tol);
      }
    } else if (_dirs.last == dir) {
      if (dir.isDiagonal) {
        _advanceDiagonal(pt, dir, tol);
      } else {
        _advance(pt, dir, tol);
      }
    } else if (dir.isDiagonal ||
        _dirs.first.isDiagonal ||
        _dirs.last == dir.opposite ||
        _dirs.length >= 2) {
      // 180度逆戻り・斜め後の曲げ・3方向目への曲がりは無効化
      _invalidated = true;
      return;
    } else {
      _corner = _end;
      _dirs.add(dir);
      _advance(pt, dir, tol);
    }
    if (shape.isNotEmpty) {
      _everRecognized = true;
    }
  }

  void _resolvePendingAtRelease() {
    final dx = _last.dx - _pivot.dx;
    final dy = _last.dy - _pivot.dy;
    final ax = dx.abs();
    final ay = dy.abs();
    final len = max(ax, ay);
    final dist = sqrt(dx * dx + dy * dy);
    final tol = tolerance;

    if (_dirs.isEmpty) {
      if (dist < releaseMinLen) return;
      final dir = _classifyOctantDir(dx, dy);
      _pending = false;
      _step(_last, dir, tol);
      return;
    }

    if (_dirs.first.isDiagonal) {
      final tail =
          (_maxLen * releaseTailRatio).clamp(releaseTailMin, releaseTailMax);
      if (dist <= tail) {
        _pending = false;
        final (ux, uy) = _dirs.first.diagUnit;
        if (dx * ux + dy * uy > 0) {
          _advanceDiagonal(_last, _dirs.first, tol);
        }
      }
      return;
    }

    final dir = _classifyDir(dx, dy, releaseAxisRatio);
    final tail =
        (_maxLen * releaseTailRatio).clamp(releaseTailMin, releaseTailMax);
    if (len <= tail) {
      _pending = false;
      if (dir != null && dir == _dirs.last) {
        _advance(_last, dir, tol);
      }
      return;
    }

    if (dir == null || len < releaseMinLen) {
      return;
    }
    _pending = false;
    _step(_last, dir, tol);
  }

  void _advance(Offset pt, GestureDirection dir, double tol) {
    final horizontal = dir == GestureDirection.l || dir == GestureDirection.r;
    final start = _corner ?? _origin;
    if (horizontal) {
      final y = pt.dy - (pt.dy - _pivot.dy).clamp(-tol, tol);
      _pivot = Offset(pt.dx, y);
      _end = Offset(pt.dx, start.dy);
      _maxLen = max(_maxLen, (pt.dx - start.dx).abs());
    } else {
      final x = pt.dx - (pt.dx - _pivot.dx).clamp(-tol, tol);
      _pivot = Offset(x, pt.dy);
      _end = Offset(start.dx, pt.dy);
      _maxLen = max(_maxLen, (pt.dy - start.dy).abs());
    }
  }

  void _advanceDiagonal(Offset pt, GestureDirection dir, double tol) {
    final (ux, uy) = dir.diagUnit;
    final px = -uy;
    final py = ux;
    final dpx = pt.dx - _pivot.dx;
    final dpy = pt.dy - _pivot.dy;
    final along = dpx * ux + dpy * uy;
    final perp = dpx * px + dpy * py;
    final clampedPerp = perp - perp.clamp(-tol, tol);
    _pivot = Offset(
      _pivot.dx + along * ux + clampedPerp * px,
      _pivot.dy + along * uy + clampedPerp * py,
    );
    final proj =
        max(0.0, (pt.dx - _origin.dx) * ux + (pt.dy - _origin.dy) * uy);
    _end = Offset(_origin.dx + proj * ux, _origin.dy + proj * uy);
    _maxLen = max(_maxLen, proj);
  }

  GestureDirection? _classifyDir(double dx, double dy, double ratio) {
    final ax = dx.abs();
    final ay = dy.abs();
    if (ax > ay * ratio) {
      return dx < 0 ? GestureDirection.l : GestureDirection.r;
    }
    if (ay > ax * ratio) {
      return dy < 0 ? GestureDirection.u : GestureDirection.d;
    }
    return null;
  }

  GestureDirection _classifyDiagQuadrant(double dx, double dy) {
    if (dx < 0 && dy < 0) return GestureDirection.nw;
    if (dx >= 0 && dy < 0) return GestureDirection.ne;
    if (dx < 0 && dy >= 0) return GestureDirection.sw;
    return GestureDirection.se;
  }

  GestureDirection? _classifyFirstDir(double dx, double dy, double tol) {
    final ax = dx.abs();
    final ay = dy.abs();
    if (ax > ay * 2.4) {
      return dx < 0 ? GestureDirection.l : GestureDirection.r;
    }
    if (ay > ax * 2.4) {
      return dy < 0 ? GestureDirection.u : GestureDirection.d;
    }
    final dist = sqrt(dx * dx + dy * dy);
    if (ax >= ay * 0.52 && ay >= ax * 0.52 && dist > tol * 1.4) {
      return _classifyDiagQuadrant(dx, dy);
    }
    return null;
  }

  GestureDirection _classifyOctantDir(double dx, double dy) {
    const octantRatio = 2.414213562373095;
    final ax = dx.abs();
    final ay = dy.abs();
    if (ax >= ay * octantRatio) {
      return dx < 0 ? GestureDirection.l : GestureDirection.r;
    }
    if (ay >= ax * octantRatio) {
      return dy < 0 ? GestureDirection.u : GestureDirection.d;
    }
    return _classifyDiagQuadrant(dx, dy);
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
