import 'package:flutter/material.dart';
import '../models/gesture_models.dart';
import '../widgets/gesture_overlay.dart';

/// モバイル版 12方向タッチジェスチャー設定画面（PC版 HisatorNotebook ボード準拠）。
class GestureSettingsScreen extends StatefulWidget {
  const GestureSettingsScreen({
    super.key,
    required this.initialSettings,
    required this.onChanged,
  });

  final MobileGestureSettings initialSettings;
  final ValueChanged<MobileGestureSettings> onChanged;

  @override
  State<GestureSettingsScreen> createState() => _GestureSettingsScreenState();
}

class _GestureSettingsScreenState extends State<GestureSettingsScreen> {
  late MobileGestureSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
  }

  void _update(MobileGestureSettings next) {
    setState(() {
      _settings = next;
    });
    widget.onChanged(next);
  }

  Future<void> _pickActionForShape(String shape) async {
    final currentAction = _settings.actionFor(shape);
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ActionPickerSheet(
        shape: shape,
        currentAction: currentAction,
        gestures: _settings.gestures,
      ),
    );
    if (!mounted || selected == null) return;

    final nextMap = Map<String, String>.from(_settings.gestures);
    if (!_settings.allowDup && selected != 'none') {
      for (final key in kGestureShapes) {
        if (key != shape && nextMap[key] == selected) {
          nextMap[key] = 'none';
        }
      }
    }
    nextMap[shape] = selected;
    _update(_settings.copyWith(gestures: nextMap));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final gestures = _settings.gestures;

    return Scaffold(
      appBar: AppBar(
        title: const Text('タッチジェスチャー設定'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'reset') {
                _update(
                  _settings.copyWith(
                    gestures: defaultMobileGestures(),
                    handleXFraction:
                        _settings.triggerSide == 'left' ? 0.10 : 0.90,
                    handleYFraction: 0.62,
                    tremor: 10,
                  ),
                );
              } else if (v == 'clear') {
                _update(
                  _settings.copyWith(
                    gestures: {for (final s in kGestureShapes) s: 'none'},
                  ),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'reset', child: Text('初期値に戻す')),
              PopupMenuItem(value: 'clear', child: Text('割り当てを全部外す')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: SwitchListTile(
              key: const ValueKey('gesture-enabled-switch'),
              title: const Text(
                'タッチジェスチャーを有効にする',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: const Text(
                '画面端のジェスチャーボタンから上下左右・斜めにドラッグして操作。ボタン長押しで好きな位置へ移動できます。',
                style: TextStyle(fontSize: 12),
              ),
              value: _settings.enabled,
              onChanged: (v) => _update(_settings.copyWith(enabled: v)),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'ジェスチャーボタン配置',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'right', label: Text('右（自由移動）')),
              ButtonSegment(value: 'left', label: Text('左（自由移動）')),
              ButtonSegment(value: 'both', label: Text('両端')),
            ],
            selected: {_settings.triggerSide},
            onSelectionChanged: (sel) {
              final nextSide = sel.first;
              _update(
                _settings.copyWith(
                  triggerSide: nextSide,
                  handleXFraction: nextSide == 'left' ? 0.10 : 0.90,
                ),
              );
            },
          ),
          const SizedBox(height: 18),
          Text(
            '1方向（← → ↑ ↓）',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          _buildShapeGrid(kSingleGestureShapes, gestures, colorScheme),
          const SizedBox(height: 18),
          Text(
            '斜め（↖ ↗ ↙ ↘）',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          _buildShapeGrid(kDiagonalGestureShapes, gestures, colorScheme),
          const SizedBox(height: 18),
          Text(
            '2方向（直角に1回曲げる 8通り）',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          _buildShapeGrid(kDoubleGestureShapes, gestures, colorScheme),
          const SizedBox(height: 18),
          Text(
            '詳細オプション',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('タブの端でループ'),
                  subtitle: const Text(
                    '最初／最後のSNS・アカウント切替時に端を跨いでループします',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _settings.wrapTabs,
                  onChanged: (v) => _update(_settings.copyWith(wrapTabs: v)),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('軌跡を表示'),
                  value: _settings.showTrail,
                  onChanged: (v) => _update(_settings.copyWith(showTrail: v)),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('ガイド・通知を表示'),
                  value: _settings.showFeedback,
                  onChanged: (v) =>
                      _update(_settings.copyWith(showFeedback: v)),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('同じ操作を複数方向へ許可'),
                  value: _settings.allowDup,
                  onChanged: (v) => _update(_settings.copyWith(allowDup: v)),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            '手ぶれ補正（開始時の無視距離）',
                            style: TextStyle(fontSize: 13.5),
                          ),
                          Text(
                            '${_settings.tremor}px',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: kGestureTeal,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: _settings.tremor.toDouble(),
                        min: 4,
                        max: 36,
                        divisions: 32,
                        onChanged: (v) => setState(
                          () => _settings = _settings.copyWith(tremor: v.round()),
                        ),
                        onChangeEnd: (v) =>
                            _update(_settings.copyWith(tremor: v.round())),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShapeGrid(
    List<String> shapes,
    Map<String, String> gestures,
    ColorScheme colorScheme,
  ) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: shapes.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.35,
      ),
      itemBuilder: (context, idx) {
        final shape = shapes[idx];
        final action = gestures[shape] ?? 'none';
        final assigned = action != 'none';
        return InkWell(
          key: ValueKey('gesture-card-$shape'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => _pickActionForShape(shape),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: assigned
                  ? kGestureTeal.withValues(alpha: 0.11)
                  : colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: assigned
                    ? kGestureTeal.withValues(alpha: 0.55)
                    : colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              children: [
                GestureShapeIcon(
                  shape: shape,
                  size: 32,
                  color: assigned
                      ? kGestureTeal
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${shapeArrows(shape)} (${shapeNameJa(shape)})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        actionLabelJa(action),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              assigned ? FontWeight.bold : FontWeight.normal,
                          color: assigned
                              ? colorScheme.onSurface
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ActionPickerSheet extends StatelessWidget {
  const _ActionPickerSheet({
    required this.shape,
    required this.currentAction,
    required this.gestures,
  });

  final String shape;
  final String currentAction;
  final Map<String, String> gestures;

  @override
  Widget build(BuildContext context) {
    final sections = <String, List<GestureActionDef>>{};
    for (final def in kMobileGestureActions) {
      sections.putIfAbsent(def.section, () => []).add(def);
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      builder: (ctx, scrollCtrl) => SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  GestureShapeIcon(shape: shape, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${shapeArrows(shape)} (${shapeNameJa(shape)}) の割り当て',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '現在: ${actionLabelJa(currentAction)}',
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                children: [
                  ListTile(
                    leading: const Icon(Icons.block_outlined),
                    title: const Text('割り当てなし'),
                    trailing: currentAction == 'none'
                        ? const Icon(Icons.check, color: kGestureTeal)
                        : null,
                    onTap: () => Navigator.of(ctx).pop('none'),
                  ),
                  for (final entry in sections.entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        entry.key,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(ctx).colorScheme.primary,
                        ),
                      ),
                    ),
                    for (final def in entry.value)
                      ListTile(
                        dense: true,
                        title: Text(def.label),
                        subtitle: def.subtitle != null
                            ? Text(
                                def.subtitle!,
                                style: const TextStyle(fontSize: 11.5),
                              )
                            : null,
                        trailing: currentAction == def.id
                            ? const Icon(Icons.check, color: kGestureTeal)
                            : () {
                                final usedBy = gestures.entries
                                    .where((e) =>
                                        e.key != shape && e.value == def.id)
                                    .map((e) => shapeArrows(e.key))
                                    .join(' ');
                                if (usedBy.isEmpty) return null;
                                return Text(
                                  usedBy,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(ctx)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                );
                              }(),
                        onTap: () => Navigator.of(ctx).pop(def.id),
                      ),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
