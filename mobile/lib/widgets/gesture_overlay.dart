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
      'NW' => [Offset(r, b), Offset(l, t)],
      'NE' => [Offset(l, b), Offset(r, t)],
      'SW' => [Offset(r, t), Offset(l, b)],
      'SE' => [Offset(l, t), Offset(r, b)],
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
    this.onDockToHeader,
    this.onHandleMoveDragChanged,
  });

  final MobileGestureSettings settings;
  final void Function(String action, String shape) onAction;
  final void Function(double dx, double dy) onLiveScroll;
  final void Function(double xFrac, double yFrac) onHandleMoved;
  final VoidCallback onOpenSettings;
  final VoidCallback? onDockToHeader;
  final void Function(Offset? globalPosition, bool isOverHeaderDock)?
      onHandleMoveDragChanged;

  @override
  State<MobileGestureOverlay> createState() => MobileGestureOverlayState();
}

class MobileGestureOverlayState extends State<MobileGestureOverlay> {
  static const double _headerDockThresholdY = 34.0;
  static const double _dragDockThresholdY = 44.0;

  final GlobalKey _layerKey = GlobalKey();
  final GesturePath _path = GesturePath();

  int? _activePointer;
  Offset? _downLocal;
  Offset? _currentLocal;
  Offset? _lastGlobal;
  bool _isDraggingGesture = false;
  bool _isMovingHandle = false;
  bool _isDraggingToHeaderDock = false;
  bool _abortedHeaderDock = false;
  bool _isOverHeaderDock = false;
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

  void _resetActiveGesture({bool notifyParent = false}) {
    final wasOverlayGhost = _isMovingHandle || _isDraggingToHeaderDock;
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _stopLiveScroll();
    _activePointer = null;
    _downLocal = null;
    _currentLocal = null;
    _lastGlobal = null;
    _isDraggingGesture = false;
    _isMovingHandle = false;
    _isDraggingToHeaderDock = false;
    _abortedHeaderDock = false;
    _isOverHeaderDock = false;
    _previewXFrac = null;
    _previewYFrac = null;
    if (notifyParent &&
        wasOverlayGhost &&
        widget.onHandleMoveDragChanged != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onHandleMoveDragChanged?.call(null, false);
      });
    }
  }

  @override
  void didUpdateWidget(covariant MobileGestureOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.settings.enabled ||
        widget.settings.dockedInHeader != oldWidget.settings.dockedInHeader ||
        oldWidget.settings.triggerSide != widget.settings.triggerSide) {
      _resetActiveGesture(notifyParent: true);
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

  bool _isLocalInHeaderDockZone(Offset local) {
    return widget.onDockToHeader != null && local.dy <= _headerDockThresholdY;
  }

  double _effectiveDragDockThresholdY() {
    final startY = _downLocal?.dy ?? 120.0;
    if (startY >= 84.0) return _dragDockThresholdY;
    return min(24.0, startY - 20.0);
  }

  /// 長押しなしの直接ドラッグでヘッダー収納ゾーンへ到達したか判定する。
  /// 上方向へ一定距離ドラッグしたときのみ発動し、上端配置オーブの横・下ジェスチャー誤作動を防ぐ。
  bool _isDragInHeaderDockZone(Offset local) {
    if (widget.onDockToHeader == null || _downLocal == null) return false;
    final startY = _downLocal!.dy;
    if (local.dy >= startY - 16.0) return false;
    return local.dy <= _effectiveDragDockThresholdY();
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
    if (_isLiveScrolling || _isDraggingToHeaderDock || _abortedHeaderDock) return;
    if (widget.onDockToHeader != null &&
        _currentLocal != null &&
        _downLocal != null &&
        _currentLocal!.dy <= 96.0 &&
        _currentLocal!.dy < _downLocal!.dy - 24.0) {
      // 上端のヘッダー収納ゾーンへ近づいている最中は連続スクロールを開始しない
      _liveScrollArmTimer?.cancel();
      _liveScrollArmTimer = null;
      return;
    }
    final shape = _path.shape;
    if (!isSingleStrokeShape(shape)) {
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
      if (!isSingleStrokeShape(curShape)) return;
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
    _lastGlobal = e.position;
    _isDraggingGesture = false;
    _isMovingHandle = false;
    _isDraggingToHeaderDock = false;
    _abortedHeaderDock = false;
    _isOverHeaderDock = false;
    _stopLiveScroll();
    _path.reset(local, tremor: widget.settings.tremor.toDouble());

    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 380), () {
      if (_activePointer != e.pointer || _isDraggingGesture || !mounted) return;
      HapticFeedback.mediumImpact();
      final curLocal = _currentLocal ?? local;
      final overDock = _isLocalInHeaderDockZone(curLocal);
      setState(() {
        _isMovingHandle = true;
        _isOverHeaderDock = overDock;
      });
      widget.onHandleMoveDragChanged?.call(_lastGlobal ?? e.position, overDock);
    });
    if (mounted) setState(() {});
  }

  void _handlePointerMove(PointerMoveEvent e) {
    if (_activePointer != e.pointer || _downLocal == null) return;
    final local = _toLocal(e.position);
    if (local == null) return;
    _currentLocal = local;
    _lastGlobal = e.position;

    if (_isMovingHandle) {
      final sz = _layerSize();
      final overDock = _isLocalInHeaderDockZone(local);
      if (overDock != _isOverHeaderDock) {
        HapticFeedback.selectionClick();
      }
      if (sz.width > 0 && sz.height > 0) {
        setState(() {
          _isOverHeaderDock = overDock;
          if (widget.settings.triggerSide != 'both') {
            _previewXFrac = (local.dx / sz.width).clamp(0.06, 0.94);
          }
          _previewYFrac = (local.dy / sz.height).clamp(0.14, 0.88);
        });
      } else {
        setState(() {
          _isOverHeaderDock = overDock;
        });
      }
      widget.onHandleMoveDragChanged?.call(e.position, overDock);
      return;
    }

    if (!_isDraggingGesture) {
      final moved = (local - _downLocal!).distance;
      if (moved >= widget.settings.tremor.toDouble()) {
        _longPressTimer?.cancel();
        _longPressTimer = null;
        _isDraggingGesture = true;
        _path.reset(_downLocal!, tremor: widget.settings.tremor.toDouble());
      } else {
        return;
      }
    }

    // 長押しなしの直接ドラッグで上部ヘッダー収納ゾーンへ到達したら即座に収納モードへ切替
    if (_isDraggingToHeaderDock) {
      final leaveThreshold = _effectiveDragDockThresholdY() + 24.0;
      if (local.dy <= leaveThreshold && local.dy < _downLocal!.dy - 12.0) {
        if (!_isOverHeaderDock) {
          HapticFeedback.selectionClick();
          setState(() {
            _isOverHeaderDock = true;
          });
        }
        widget.onHandleMoveDragChanged?.call(e.position, true);
      } else {
        setState(() {
          _isDraggingToHeaderDock = false;
          _isOverHeaderDock = false;
          _abortedHeaderDock = true;
        });
        widget.onHandleMoveDragChanged?.call(null, false);
      }
      return;
    }

    if (_isDragInHeaderDockZone(local)) {
      _stopLiveScroll();
      HapticFeedback.selectionClick();
      setState(() {
        _isDraggingToHeaderDock = true;
        _isOverHeaderDock = true;
        _abortedHeaderDock = false;
      });
      widget.onHandleMoveDragChanged?.call(e.position, true);
      return;
    }

    if (_abortedHeaderDock) {
      if (mounted) setState(() {});
      return;
    }

    if (_isLiveScrolling) {
      // ライブスクロール中は縦方向の直線長さと速度のみ更新（自由曲線は描かない）
      _path.advanceLiveScroll(local);
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
    final wasDockDragging = _isDraggingToHeaderDock;
    final wasAbortedDock = _abortedHeaderDock;
    final wasOverDock = _isOverHeaderDock;
    final wasDragging = _isDraggingGesture;
    final wasLiveScroll = _isLiveScrolling;
    final finalShape = cancelled ? '' : _path.release();
    final wasInvalid = _path.invalidated;

    _stopLiveScroll();
    _activePointer = null;
    _downLocal = null;
    _currentLocal = null;
    _lastGlobal = null;
    _isDraggingGesture = false;
    _isMovingHandle = false;
    _isDraggingToHeaderDock = false;
    _abortedHeaderDock = false;
    _isOverHeaderDock = false;

    if (wasMoving) {
      final nextX = _previewXFrac ?? widget.settings.handleXFraction;
      final nextY = _previewYFrac ?? widget.settings.handleYFraction;
      _previewXFrac = null;
      _previewYFrac = null;
      widget.onHandleMoveDragChanged?.call(null, false);
      if (mounted) setState(() {});
      if (!cancelled) {
        if (wasOverDock && widget.onDockToHeader != null) {
          HapticFeedback.mediumImpact();
          widget.onDockToHeader!();
        } else {
          widget.onHandleMoved(nextX, nextY);
          showNotice('ジェスチャーボタン位置を保存しました');
        }
      }
      return;
    }

    if (wasDockDragging) {
      widget.onHandleMoveDragChanged?.call(null, false);
      if (mounted) setState(() {});
      if (!cancelled && wasOverDock && widget.onDockToHeader != null) {
        HapticFeedback.mediumImpact();
        widget.onDockToHeader!();
      }
      return;
    }

    if (mounted) setState(() {});

    if (cancelled || wasAbortedDock) return;

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
      showNotice(
        widget.onDockToHeader != null
            ? '上へドラッグで収納 · 長押しで位置移動 · 2回タップで設定'
            : 'ドラッグでジェスチャー · 長押しで移動 · 2回タップで設定',
      );
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
            _resetActiveGesture(notifyParent: true);
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

        if (!settings.dockedInHeader) {
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
        }

        final shape = _path.shape;
        final mappedAction =
            shape.isNotEmpty ? settings.actionFor(shape) : 'none';
        final hideLocalOrbWhileMoving =
            (_isMovingHandle || _isDraggingToHeaderDock) &&
                widget.onHandleMoveDragChanged != null;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // フルビューポート軌跡 & ガイド HUD（非ドラッグ時はタッチ完全透過）
            if (_isDraggingGesture && !_isDraggingToHeaderDock)
              Positioned.fill(
                child: IgnorePointer(
                  child: Stack(
                    children: [
                      if (settings.showTrail &&
                          !_abortedHeaderDock &&
                          _path.everRecognized &&
                          !_path.invalidated &&
                          _path.vertices.length >= 2)
                        CustomPaint(
                          size: Size(w, h),
                          painter: _GestureTrailPainter(
                            vertices: _path.vertices,
                            isLiveScroll: _isLiveScrolling,
                          ),
                        ),
                      if (settings.showFeedback)
                        Positioned(
                          top: 18,
                          left: 16,
                          right: 16,
                          child: Center(
                            child: _buildLiveHudPill(
                              shape: _abortedHeaderDock ? '' : shape,
                              action: _isLiveScrolling
                                  ? _liveScrollAction
                                  : mappedAction,
                              invalidated:
                                  _abortedHeaderDock || _path.invalidated,
                              isLiveScroll: _isLiveScrolling,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

            // 移動・ヘッダー収納モード中のガイド
            if (_isMovingHandle || _isDraggingToHeaderDock)
              Positioned(
                top: 18,
                left: 16,
                right: 16,
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: _isOverHeaderDock
                            ? const Color(0xEB0E7490)
                            : const Color(0xE60F172A),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: _isOverHeaderDock
                              ? kGestureTealBright
                              : kGestureAmber,
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isOverHeaderDock) ...[
                            const Icon(
                              Icons.vertical_align_top_rounded,
                              size: 15,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 5),
                          ],
                          Flexible(
                            child: Text(
                              _isOverHeaderDock
                                  ? '離すとヘッダーに収納します'
                                  : (widget.onDockToHeader != null
                                      ? 'ドラッグで配置 · 上のヘッダーへ持っていくと収納'
                                      : 'ドラッグして好きな位置に配置できます'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
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
                    opacity: hideLocalOrbWhileMoving
                        ? 0.0
                        : ((_isDraggingGesture || _isMovingHandle)
                            ? 0.95
                            : 0.64),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isMovingHandle
                            ? (_isOverHeaderDock
                                ? const Color(0xEB0E7490)
                                : const Color(0xEB92400E))
                            : (_isDraggingGesture
                                ? const Color(0xEB0E7490)
                                : const Color(0xCC0F172A)),
                        border: Border.all(
                          color: _isMovingHandle
                              ? (_isOverHeaderDock
                                  ? kGestureTealBright
                                  : kGestureAmber)
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
                          ? Icon(
                              _isOverHeaderDock
                                  ? Icons.vertical_align_top_rounded
                                  : Icons.open_with_rounded,
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
      label = '上下左右・斜めへドラッグしてジェスチャー';
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
    required this.vertices,
    required this.isLiveScroll,
  });

  /// 直線セグメントの頂点列のみ（始点 → [直角コーナー] → 終点）。自由曲線は描画しない。
  final List<Offset> vertices;
  final bool isLiveScroll;

  @override
  void paint(Canvas canvas, Size size) {
    if (vertices.length < 2) return;

    final baseColor = isLiveScroll ? kGestureTealBright : kGestureTeal;
    final path = Path()..moveTo(vertices.first.dx, vertices.first.dy);
    for (var i = 1; i < vertices.length; i++) {
      path.lineTo(vertices[i].dx, vertices[i].dy);
    }

    // 白縁取り（HisatorNotebook / Windows版 _W246TrailPainter 準拠の直線ライン）
    final halo = Paint()
      ..color = const Color(0xF0FFFFFF)
      ..strokeWidth = 7.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, halo);

    // 本体直線ライン
    final line = Paint()
      ..color = baseColor
      ..strokeWidth = 4.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, line);

    // 始点マーカー
    final origin = vertices.first;
    canvas.drawCircle(
      origin,
      6.0,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      origin,
      4.0,
      Paint()
        ..color = baseColor
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _GestureTrailPainter oldDelegate) => true;
}
