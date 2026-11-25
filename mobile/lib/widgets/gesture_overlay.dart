import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/gesture_models.dart';

const Color kGestureTeal = Color(0xFF159CAB);
const Color kGestureTealBright = Color(0xFF38D9E8);
const Color kGestureAmber = Color(0xFFF59E0B);

/// 12方向ジェスチャーの軌跡アイコン（始点ドット + 折れ線 + 矢印）を描画するウィジェット。
class GestureShapeIcon extends StatelessWidget {
  const GestureShapeIcon({
    super.key,
    required this.shape,
    this.size = 34,
    this.color = kGestureTeal,
  });

  final String shape;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _GestureShapeIconPainter(shape: shape, color: color),
    );
  }
}

class _GestureShapeIconPainter extends CustomPainter {
  _GestureShapeIconPainter({required this.shape, required this.color});

  final String shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = _pointsForShape(shape, size);
    if (pts.length < 2) return;

    final stroke = Paint()
      ..color = color
      ..strokeWidth = max(2.2, size.width * 0.085)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    canvas.drawPath(path, stroke);

    // 始点ドット
    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(pts.first, max(2.8, size.width * 0.1), dotPaint);

    // 終点矢印
    final tail = pts[pts.length - 2];
    final tip = pts.last;
    final angle = atan2(tip.dy - tail.dy, tip.dx - tail.dx);
    final headLen = max(5.5, size.width * 0.22);
    final spread = 0.55;
    final left = Offset(
      tip.dx - headLen * cos(angle - spread),
      tip.dy - headLen * sin(angle - spread),
    );
    final right = Offset(
      tip.dx - headLen * cos(angle + spread),
      tip.dy - headLen * sin(angle + spread),
    );
    final headPath = Path()
      ..moveTo(left.dx, left.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(right.dx, right.dy);
    canvas.drawPath(headPath, stroke);
  }

  List<Offset> _pointsForShape(String s, Size size) {
    final w = size.width;
    final h = size.height;
    final pad = w * 0.20;
    final midX = w * 0.5;
    final midY = h * 0.5;
    final l = pad;
    final r = w - pad;
    final t = pad;
    final b = h - pad;

    return switch (s) {
      'L' => [Offset(r, midY), Offset(l, midY)],
      'R' => [Offset(l, midY), Offset(r, midY)],
      'U' => [Offset(midX, b), Offset(midX, t)],
      'D' => [Offset(midX, t), Offset(midX, b)],
      'LU' => [Offset(r, b), Offset(l, b), Offset(l, t)],
      'LD' => [Offset(r, t), Offset(l, t), Offset(l, b)],
      'RU' => [Offset(l, b), Offset(r, b), Offset(r, t)],
      'RD' => [Offset(l, t), Offset(r, t), Offset(r, b)],
      'UL' => [Offset(r, b), Offset(r, t), Offset(l, t)],
      'UR' => [Offset(l, b), Offset(l, t), Offset(r, t)],
      'DL' => [Offset(r, t), Offset(r, b), Offset(l, b)],
      'DR' => [Offset(l, t), Offset(l, b), Offset(r, b)],
      _ => [Offset(l, midY), Offset(r, midY)],
    };
  }

  @override
  bool shouldRepaint(covariant _GestureShapeIconPainter oldDelegate) {
    return oldDelegate.shape != shape || oldDelegate.color != color;
  }
}

/// モバイル版 12方向タッチジェスチャーオーバーレイ。
/// WebView の通常スクロールや OS の画面端スワイプ戻るを一切邪魔せず、
/// 画面端の半透明ジェスチャーボタンから任意の方向へドラッグして即座に操作できる。
class MobileGestureOverlay extends StatefulWidget {
  const MobileGestureOverlay({
    super.key,
    required this.settings,
    required this.onAction,
    required this.onLiveScroll,
    required this.onHandleMoved,
    required this.onOpenSettings,
  });

  final MobileGestureSettings settings;
  final void Function(String action, String shape) onAction;
  final void Function(double dx, double dy) onLiveScroll;
  final void Function(double xFrac, double yFrac) onHandleMoved;
  final VoidCallback onOpenSettings;

  @override
  State<MobileGestureOverlay> createState() => MobileGestureOverlayState();
}

class MobileGestureOverlayState extends State<MobileGestureOverlay> {
  final GlobalKey _layerKey = GlobalKey();
  final GesturePath _path = GesturePath();

  int? _activePointer;
  Offset? _downLocal;
  Offset? _currentLocal;
  bool _isDraggingGesture = false;
  bool _isMovingHandle = false;
  bool _isLiveScrolling = false;
  String _liveScrollAction = '';

  Timer? _longPressTimer;
  Timer? _liveScrollArmTimer;
  Timer? _liveScrollTickTimer;
  Timer? _noticeTimer;
  String? _noticeText;
  bool _noticeIsError = false;
  DateTime? _lastTapAt;

  double? _previewXFrac;
  double? _previewYFrac;

  void showNotice(String text, {bool isError = false}) {
    if (!widget.settings.showFeedback || !mounted) return;
    _noticeTimer?.cancel();
    setState(() {
      _noticeText = text;
      _noticeIsError = isError;
    });
    _noticeTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) {
        setState(() {
          _noticeText = null;
        });
      }
    });
  }

  void _resetActiveGesture() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _stopLiveScroll();
    _activePointer = null;
    _downLocal = null;
    _currentLocal = null;
    _isDraggingGesture = false;
    _isMovingHandle = false;
    _previewXFrac = null;
    _previewYFrac = null;
  }

  @override
  void didUpdateWidget(covariant MobileGestureOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.settings.enabled ||
        oldWidget.settings.triggerSide != widget.settings.triggerSide) {
      _resetActiveGesture();
    }
  }

  @override
  void deactivate() {
    _resetActiveGesture();
    super.deactivate();
  }

  @override
  void dispose() {
    _resetActiveGesture();
    _noticeTimer?.cancel();
    super.dispose();
  }

  Offset? _toLocal(Offset global) {
    final box = _layerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.globalToLocal(global);
  }

  Size _layerSize() {
    final box = _layerKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.size ?? Size.zero;
  }

  void _stopLiveScroll() {
    _liveScrollArmTimer?.cancel();
    _liveScrollArmTimer = null;
    _liveScrollTickTimer?.cancel();
    _liveScrollTickTimer = null;
    _isLiveScrolling = false;
    _liveScrollAction = '';
  }

  void _maybeArmLiveScroll() {
    if (_isLiveScrolling) return;
    final shape = _path.shape;
    if (shape.length != 1) {
      _liveScrollArmTimer?.cancel();
      _liveScrollArmTimer = null;
      return;
    }
    final act = widget.settings.actionFor(shape);
    if (!isLiveScrollAction(act)) {
      _liveScrollArmTimer?.cancel();
      _liveScrollArmTimer = null;
      return;
    }
    if (_liveScrollArmTimer != null) return;
    _liveScrollArmTimer = Timer(const Duration(milliseconds: 190), () {
      _liveScrollArmTimer = null;
      if (!mounted || !_isDraggingGesture || _path.invalidated) return;
      final curShape = _path.shape;
      if (curShape.length != 1) return;
      final curAct = widget.settings.actionFor(curShape);
      if (!isLiveScrollAction(curAct)) return;
      HapticFeedback.selectionClick();
      setState(() {
        _isLiveScrolling = true;
        _liveScrollAction = curAct;
      });
      _liveScrollTickTimer?.cancel();
      _liveScrollTickTimer = Timer.periodic(
        const Duration(milliseconds: 24),
        (_) {
          if (!mounted || !_isLiveScrolling || _currentLocal == null) {
            _stopLiveScroll();
            return;
          }
          final dy = computeLiveScrollStep(
            action: _liveScrollAction,
            origin: _path.origin,
            current: _currentLocal!,
          );
          widget.onLiveScroll(0, dy);
        },
      );
    });
  }

  void _handlePointerDown(PointerDownEvent e) {
    if (_activePointer != null) return;
    final local = _toLocal(e.position);
    if (local == null) return;

    _activePointer = e.pointer;
    _downLocal = local;
    _currentLocal = local;
    _isDraggingGesture = false;
    _isMovingHandle = false;
    _stopLiveScroll();
    _path.reset(local);

    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 460), () {
      if (_activePointer != e.pointer || _isDraggingGesture || !mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _isMovingHandle = true;
      });
    });
    if (mounted) setState(() {});
  }

  void _handlePointerMove(PointerMoveEvent e) {
    if (_activePointer != e.pointer || _downLocal == null) return;
    final local = _toLocal(e.position);
    if (local == null) return;
    _currentLocal = local;

    if (_isMovingHandle) {
      final sz = _layerSize();
      if (sz.width > 0 && sz.height > 0) {
        setState(() {
          if (widget.settings.triggerSide != 'both') {
            _previewXFrac = (local.dx / sz.width).clamp(0.06, 0.94);
          }
          _previewYFrac = (local.dy / sz.height).clamp(0.14, 0.88);
        });
      }
      return;
    }

    if (!_isDraggingGesture) {
      final moved = (local - _downLocal!).distance;
      if (moved >= widget.settings.tremor.toDouble()) {
        _longPressTimer?.cancel();
        _longPressTimer = null;
        _isDraggingGesture = true;
        _path.reset(_downLocal!);
      } else {
        return;
      }
    }

    if (_isLiveScrolling) {
      // ライブスクロール中は縦方向の距離変化だけで速度更新（軌跡再描画のみ）
      if (mounted) setState(() {});
      return;
    }

    _path.push(local);
    _maybeArmLiveScroll();
    if (mounted) setState(() {});
  }

  void _handlePointerUpOrCancel(int pointer, {required bool cancelled}) {
    if (_activePointer != pointer) return;
    _longPressTimer?.cancel();
    _longPressTimer = null;

    final wasMoving = _isMovingHandle;
    final wasDragging = _isDraggingGesture;
    final wasLiveScroll = _isLiveScrolling;
    final finalShape = _path.shape;
    final wasInvalid = _path.invalidated;

    _stopLiveScroll();
    _activePointer = null;
    _downLocal = null;
    _currentLocal = null;
    _isDraggingGesture = false;
    _isMovingHandle = false;

    if (wasMoving) {
      final nextX = _previewXFrac ?? widget.settings.handleXFraction;
      final nextY = _previewYFrac ?? widget.settings.handleYFraction;
      _previewXFrac = null;
      _previewYFrac = null;
      if (mounted) setState(() {});
      if (!cancelled) {
        widget.onHandleMoved(nextX, nextY);
        showNotice('ジェスチャーボタン位置を保存しました');
      }
      return;
    }

    if (mounted) setState(() {});

    if (cancelled) return;

    if (wasDragging) {
      if (wasLiveScroll) {
        return;
      }
      if (!wasInvalid && finalShape.isNotEmpty) {
        final action = widget.settings.actionFor(finalShape);
        if (isLiveScrollAction(action)) {
          // 素早い上下フリック時は半画面ぶんスクロール
          final sz = _layerSize();
          final jump = max(240.0, sz.height * 0.52);
          HapticFeedback.lightImpact();
          widget.onLiveScroll(0, action == 'scroll:up' ? -jump : jump);
          showNotice('${shapeArrows(finalShape)} ${actionLabelJa(action)}');
          return;
        }
        if (action != 'none') {
          HapticFeedback.lightImpact();
          widget.onAction(action, finalShape);
          return;
        }
        showNotice('${shapeArrows(finalShape)} 未割り当て');
      }
      return;
    }

    // 短タップ: ダブルタップで設定画面、シングルタップで操作ガイド表示
    final now = DateTime.now();
    if (_lastTapAt != null &&
        now.difference(_lastTapAt!) < const Duration(milliseconds: 340)) {
      _lastTapAt = null;
      HapticFeedback.lightImpact();
      widget.onOpenSettings();
    } else {
      _lastTapAt = now;
      showNotice('ドラッグでジェスチャー · 長押しで移動 · 2回タップで設定');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    if (!settings.enabled) return const SizedBox.shrink();

    return LayoutBuilder(
      key: _layerKey,
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        if (w < 48.0 || h < 56.0) {
          // 画面分割や横向きキーボード展開で描画領域が極端に狭くなった場合は
          // clamp() の ArgumentError を防ぎつつ進行中のジェスチャー／タイマーを安全に停止
          if (_activePointer != null ||
              _isDraggingGesture ||
              _isMovingHandle ||
              _isLiveScrolling) {
            _resetActiveGesture();
          }
          return const SizedBox.shrink();
        }

        final orbSize = 42.0;
        final yFrac = _previewYFrac ?? settings.handleYFraction;
        final xFrac = _previewXFrac ?? settings.handleXFraction;
        final minY = min(28.0, h / 2);
        final maxY = max(h - 28.0, minY);
        final minX = min(24.0, w / 2);
        final maxX = max(w - 24.0, minX);
        final clampedY = (yFrac * h).clamp(minY, maxY).toDouble();
        final orbCenters = <Offset>[];

        if (settings.triggerSide == 'both') {
          orbCenters.add(Offset(min(26.0, w / 2), clampedY));
          orbCenters.add(Offset(max(w - 26.0, w / 2), clampedY));
        } else {
          orbCenters.add(
            Offset(
              (xFrac * w).clamp(minX, maxX).toDouble(),
              clampedY,
            ),
          );
        }

        final shape = _path.shape;
        final mappedAction =
            shape.isNotEmpty ? settings.actionFor(shape) : 'none';

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // フルビューポート軌跡 & ガイド HUD（非ドラッグ時はタッチ完全透過）
            if (_isDraggingGesture)
              Positioned.fill(
                child: IgnorePointer(
                  child: Stack(
                    children: [
                      if (settings.showTrail)
                        CustomPaint(
                          size: Size(w, h),
                          painter: _GestureTrailPainter(
                            points: _path.points,
                            invalidated: _path.invalidated,
                            isLiveScroll: _isLiveScrolling,
                            liveOrigin: _path.origin,
                            liveCurrent: _currentLocal,
                          ),
                        ),
                      if (settings.showFeedback)
                        Positioned(
                          top: 18,
                          left: 16,
                          right: 16,
                          child: Center(
                            child: _buildLiveHudPill(
                              shape: shape,
                              action: _isLiveScrolling
                                  ? _liveScrollAction
                                  : mappedAction,
                              invalidated: _path.invalidated,
                              isLiveScroll: _isLiveScrolling,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

            // 移動モード中のガイド
            if (_isMovingHandle)
              Positioned(
                top: 18,
                left: 16,
                right: 16,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xE60F172A),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: kGestureAmber, width: 1.4),
                      ),
                      child: const Text(
                        'ドラッグして好きな位置に配置できます',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // 実行結果トースト通知
            if (!_isDraggingGesture && !_isMovingHandle && _noticeText != null)
              Positioned(
                bottom: 16,
                left: 20,
                right: 20,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: _noticeIsError
                            ? const Color(0xEB991B1B)
                            : const Color(0xE60F172A),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: _noticeIsError
                              ? Colors.redAccent
                              : kGestureTeal.withValues(alpha: 0.75),
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x44000000),
                            blurRadius: 10,
                            offset: Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Text(
                        _noticeText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // ジェスチャー開始用フローティングオーブ（WebView上に軽量配置）
            for (var i = 0; i < orbCenters.length; i++)
              Positioned(
                left: orbCenters[i].dx - orbSize / 2,
                top: orbCenters[i].dy - orbSize / 2,
                width: orbSize,
                height: orbSize,
                child: Listener(
                  key: ValueKey('mobile-gesture-orb-$i'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _handlePointerDown,
                  onPointerMove: _handlePointerMove,
                  onPointerUp: (e) =>
                      _handlePointerUpOrCancel(e.pointer, cancelled: false),
                  onPointerCancel: (e) =>
                      _handlePointerUpOrCancel(e.pointer, cancelled: true),
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 140),
                    opacity: (_isDraggingGesture || _isMovingHandle)
                        ? 0.95
                        : 0.64,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isMovingHandle
                            ? const Color(0xEB92400E)
                            : (_isDraggingGesture
                                ? const Color(0xEB0E7490)
                                : const Color(0xCC0F172A)),
                        border: Border.all(
                          color: _isMovingHandle
                              ? kGestureAmber
                              : kGestureTealBright.withValues(alpha: 0.85),
                          width: _isDraggingGesture || _isMovingHandle
                              ? 2.0
                              : 1.35,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x55000000),
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: _isMovingHandle
                          ? const Icon(
                              Icons.open_with_rounded,
                              size: 19,
                              color: Colors.white,
                            )
                          : const GestureShapeIcon(
                              shape: 'DR',
                              size: 22,
                              color: kGestureTealBright,
                            ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildLiveHudPill({
    required String shape,
    required String action,
    required bool invalidated,
    required bool isLiveScroll,
  }) {
    final String label;
    final Color borderColor;
    if (invalidated) {
      label = 'キャンセル（そのまま離すと中止）';
      borderColor = Colors.grey;
    } else if (shape.isEmpty) {
      label = '上下左右へドラッグしてジェスチャー';
      borderColor = kGestureTeal.withValues(alpha: 0.7);
    } else if (action == 'none') {
      label = '${shapeArrows(shape)}  未割り当て';
      borderColor = kGestureAmber;
    } else if (isLiveScroll) {
      label = '${shapeArrows(shape)}  ${actionLabelJa(action)}（スクロール中）';
      borderColor = kGestureTealBright;
    } else {
      label = '${shapeArrows(shape)}  ${actionLabelJa(action)}';
      borderColor = kGestureTealBright;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xEB0F172A),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor, width: 1.4),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!invalidated && shape.isNotEmpty) ...[
            GestureShapeIcon(
              shape: shape,
              size: 18,
              color: action == 'none' ? kGestureAmber : kGestureTealBright,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GestureTrailPainter extends CustomPainter {
  _GestureTrailPainter({
    required this.points,
    required this.invalidated,
    required this.isLiveScroll,
    required this.liveOrigin,
    required this.liveCurrent,
  });

  final List<Offset> points;
  final bool invalidated;
  final bool isLiveScroll;
  final Offset liveOrigin;
  final Offset? liveCurrent;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final baseColor = invalidated
        ? const Color(0xFF94A3B8)
        : (isLiveScroll ? kGestureTealBright : kGestureTeal);

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    if (isLiveScroll && liveCurrent != null) {
      path.lineTo(liveCurrent!.dx, liveCurrent!.dy);
    } else {
      for (var i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
    }

    // グロー外枠
    final glow = Paint()
      ..color = baseColor.withValues(alpha: 0.28)
      ..strokeWidth = 10.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, glow);

    // 本体ライン
    final line = Paint()
      ..color = baseColor
      ..strokeWidth = 4.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, line);

    // 始点マーカー
    canvas.drawCircle(
      liveOrigin,
      5.5,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      liveOrigin,
      3.5,
      Paint()
        ..color = baseColor
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _GestureTrailPainter oldDelegate) => true;
}
