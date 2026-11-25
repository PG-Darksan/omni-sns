import 'package:flutter/material.dart';
import '../models/service_models.dart';

class NewInstanceRequest {
  const NewInstanceRequest({
    required this.serviceId,
    required this.name,
    this.accountLabel,
    required this.category,
    required this.url,
    required this.colorHex,
    required this.badge,
    this.openExistingInstanceId,
    this.restoreArchivedInstanceId,
  });

  final String serviceId;
  final String name;
  final String? accountLabel;
  final String category;
  final String url;
  final String colorHex;
  final String badge;
  final String? openExistingInstanceId;
  final String? restoreArchivedInstanceId;
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    super.key,
    required this.categories,
    required this.catalog,
    required this.existingInstances,
    required this.multiProfileSupported,
    this.archivedInstances = const [],
    this.initialCategory = 'all',
    this.onPurgeArchived,
    this.onPurgeAllArchived,
  });

  final List<CategoryMeta> categories;
  final List<CatalogService> catalog;
  final List<ServiceInstance> existingInstances;
  final bool multiProfileSupported;
  final List<ArchivedInstance> archivedInstances;
  final String initialCategory;
  final Future<void> Function(String instanceId)? onPurgeArchived;
  final Future<void> Function()? onPurgeAllArchived;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  late String _selectedCategory;
  late List<ArchivedInstance> _archived;
  String _searchQuery = '';

  final _customNameController = TextEditingController();
  final _customUrlController = TextEditingController();
  String _customCategory = 'custom';

  @override
  void initState() {
    super.initState();
    _selectedCategory = widget.initialCategory;
    _archived = List<ArchivedInstance>.from(widget.archivedInstances);
  }

  @override
  void dispose() {
    _customNameController.dispose();
    _customUrlController.dispose();
    super.dispose();
  }

  List<ServiceInstance> _existingFor(String serviceId) {
    return widget.existingInstances
        .where((i) => i.serviceId == serviceId)
        .toList();
  }

  List<ArchivedInstance> _archivedFor(String serviceId) {
    return _archived.where((a) => a.instance.serviceId == serviceId).toList();
  }

  String _formatArchivedTitle(ServiceInstance inst) {
    final label = inst.accountLabel?.trim();
    final base = (label != null && label.isNotEmpty && label != inst.name)
        ? '${inst.name} · $label'
        : inst.name;
    final h = inst.detectedHandle?.trim();
    return (h != null && h.isNotEmpty) ? '$base (@$h)' : base;
  }

  String _formatArchivedTime(int unixSecs) {
    if (unixSecs <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000).toLocal();
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$y/$m/$d $hh:$mm';
  }

  void _restoreArchived(ArchivedInstance entry) {
    final inst = entry.instance;
    Navigator.of(context).pop(
      NewInstanceRequest(
        serviceId: inst.serviceId,
        name: inst.name,
        accountLabel: inst.accountLabel,
        category: inst.category,
        url: inst.url,
        colorHex: inst.colorHex,
        badge: inst.badge,
        restoreArchivedInstanceId: inst.instanceId,
      ),
    );
  }

  Future<void> _confirmPurgeArchived(ArchivedInstance entry) async {
    final title = _formatArchivedTitle(entry.instance);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ログイン記憶を完全削除'),
        content: Text(
          '「$title」のログイン記憶（Cookie・プロファイル）を完全に消去しますか？\n※ この操作は取り消せません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('完全削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.onPurgeArchived?.call(entry.instance.instanceId);
    if (!mounted) return;
    setState(() {
      _archived.removeWhere((a) => a.instance.instanceId == entry.instance.instanceId);
    });
  }

  Future<void> _confirmPurgeAllArchived() async {
    if (_archived.isEmpty) return;
    final count = _archived.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ログイン記憶をすべて完全削除'),
        content: Text(
          '保存されている $count 件のログイン記憶（Cookie・プロファイル）をすべて完全削除しますか？\n※ この操作は取り消せません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('すべて完全削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.onPurgeAllArchived?.call();
    if (!mounted) return;
    setState(() {
      _archived.clear();
    });
  }

  Future<void> _openRestoreOrAddSheet(
    CatalogService svc,
    List<ArchivedInstance> saved,
    VoidCallback onCreateNew,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '「${svc.name}」のログイン記憶があります',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                '削除時に保持したログイン状態のまま呼び出すか、新しく追加できます。',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: saved.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (_, idx) {
                    final entry = saved[idx];
                    final t = _formatArchivedTime(entry.archivedAt);
                    return ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: Theme.of(ctx).dividerColor.withValues(alpha: 0.4),
                        ),
                      ),
                      title: Text(
                        _formatArchivedTitle(entry.instance),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        t.isNotEmpty ? '保存: $t' : entry.instance.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: FilledButton(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _restoreArchived(entry);
                        },
                        child: const Text('呼び出す'),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  onCreateNew();
                },
                icon: const Icon(Icons.add),
                label: const Text('新規アカウント（まっさらなログイン）を作成'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _nextAccountLabelFor(CatalogService svc) {
    final existing = _existingFor(svc.id);
    final labels = List.generate(
      existing.length,
      (idx) => accountDisplayLabel(
        existing[idx],
        idx,
        baseServiceName: svc.name,
      ),
    );
    return nextDefaultAccountLabel(labels);
  }

  Future<void> _openDetailedAddDialog(CatalogService svc) async {
    final suggestedLabel = _nextAccountLabelFor(svc);
    final result = await showDialog<NewInstanceRequest>(
      context: context,
      builder: (ctx) => _DetailedAddServiceDialog(
        service: svc,
        suggestedLabel: suggestedLabel,
        multiProfileSupported: widget.multiProfileSupported,
      ),
    );

    if (result != null && mounted) {
      Navigator.of(context).pop(result);
    }
  }

  void _submitCustomService() {
    final normalized = normalizeServiceUrl(_customUrlController.text);
    if (normalized == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('有効な http:// または https:// URL を入力してください'),
        ),
      );
      return;
    }

    final rawName = _customNameController.text.trim();
    final name = rawName.isEmpty ? 'カスタムSNS' : rawName;
    final parsedHost = Uri.tryParse(normalized)?.host.toLowerCase() ?? '';
    final targetGroupKey = parsedHost.isNotEmpty ? 'custom:$parsedHost' : '';
    final existingSameHost = targetGroupKey.isEmpty
        ? const <ServiceInstance>[]
        : widget.existingInstances
            .where((i) => serviceGroupKey(i) == targetGroupKey)
            .toList();
    final existingLabels = List.generate(
      existingSameHost.length,
      (idx) => accountDisplayLabel(
        existingSameHost[idx],
        idx,
        baseServiceName: name,
      ),
    );
    final nextLabel = nextDefaultAccountLabel(existingLabels);

    Navigator.of(context).pop(
      NewInstanceRequest(
        serviceId: 'custom',
        name: name,
        accountLabel: nextLabel,
        category: _customCategory,
        url: normalized,
        colorHex: '#3B82F6',
        badge: makeBadgeText(name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _searchQuery.trim().toLowerCase();
    final filtered = widget.catalog.where((svc) {
      if (_selectedCategory != 'all' && svc.category != _selectedCategory) {
        return false;
      }
      if (q.isEmpty) return true;
      return svc.name.toLowerCase().contains(q) ||
          svc.id.toLowerCase().contains(q) ||
          svc.description.toLowerCase().contains(q) ||
          svc.aliases.any((a) => a.toLowerCase().contains(q));
    }).toList();

    final visibleCategories = widget.categories;
    final totalAvailable = widget.catalog.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('サービス カタログ'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: TextField(
              decoration: InputDecoration(
                hintText:
                    'サービス名・別名で検索 (例: Instagram, Discord, Tinder, mixi2, SMS...)',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                  if (_selectedCategory == 'custom' &&
                      value.trim().isNotEmpty) {
                    _selectedCategory = 'all';
                  }
                });
              },
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text('すべて ($totalAvailable)'),
                    selected: _selectedCategory == 'all',
                    onSelected: (_) =>
                        setState(() => _selectedCategory = 'all'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(
                      'ログイン記憶 (${_archived.length})',
                      style: _archived.isNotEmpty && _selectedCategory != 'archived'
                          ? const TextStyle(
                              color: Colors.amber,
                              fontWeight: FontWeight.bold,
                            )
                          : null,
                    ),
                    selected: _selectedCategory == 'archived',
                    onSelected: (_) =>
                        setState(() => _selectedCategory = 'archived'),
                  ),
                ),
                for (final cat in visibleCategories)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(
                        cat.id == 'custom'
                            ? cat.label
                            : '${cat.label} (${widget.catalog.where((s) => s.category == cat.id).length})',
                      ),
                      selected: _selectedCategory == cat.id,
                      onSelected: (_) =>
                          setState(() => _selectedCategory = cat.id),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _selectedCategory == 'archived'
                ? _buildArchivedList()
                : _selectedCategory == 'custom'
                    ? _buildCustomForm()
                    : filtered.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.search_off, size: 42),
                              const SizedBox(height: 10),
                              const Text(
                                '該当するサービスがありません。\n「カスタム追加」から任意のURLを登録できます。',
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              FilledButton.tonal(
                                onPressed: () => setState(
                                    () => _selectedCategory = 'custom'),
                                child: const Text('カスタムURLを追加する'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (context, index) {
                          final svc = filtered[index];
                          final existing = _existingFor(svc.id);
                          final savedArchived = _archivedFor(svc.id);
                          final count = existing.length;
                          final color = parseHexColor(svc.colorHex);
                          final canAddAnother =
                              count == 0 || widget.multiProfileSupported;

                          return Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      color: color,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      svc.badge,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            svc.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ),
                                        if (count > 0) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 1.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.green
                                                  .withValues(alpha: 0.2),
                                              borderRadius:
                                                  BorderRadius.circular(99),
                                            ),
                                            child: Text(
                                              count == 1 ||
                                                      !widget
                                                          .multiProfileSupported
                                                  ? '済'
                                                  : '$count垢',
                                                style: const TextStyle(
                                                  color: Colors.green,
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ],
                                          if (savedArchived.isNotEmpty) ...[
                                            const SizedBox(width: 4),
                                            InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(99),
                                              onTap: () {
                                                setState(() {
                                                  _selectedCategory = 'archived';
                                                  _searchQuery = svc.name;
                                                });
                                              },
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 6,
                                                  vertical: 1.5,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.amber
                                                      .withValues(alpha: 0.2),
                                                  borderRadius:
                                                      BorderRadius.circular(99),
                                                ),
                                                child: Text(
                                                  savedArchived.length == 1
                                                      ? '記憶あり'
                                                      : '記憶${savedArchived.length}',
                                                  style: const TextStyle(
                                                    color: Colors.amber,
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    canAddAnother
                                        ? FilledButton(
                                            style: FilledButton.styleFrom(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 6,
                                              ),
                                              minimumSize: const Size(0, 32),
                                              tapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                            ),
                                            onPressed: () {
                                              void createNew() {
                                                if (svc.requiresCustomUrl) {
                                                  _openDetailedAddDialog(svc);
                                                  return;
                                                }
                                                final accLabel =
                                                    _nextAccountLabelFor(svc);
                                                Navigator.of(context).pop(
                                                  NewInstanceRequest(
                                                    serviceId: svc.id,
                                                    name: svc.name,
                                                    accountLabel: accLabel,
                                                    category: svc.category,
                                                    url: svc.url,
                                                    colorHex: svc.colorHex,
                                                    badge: svc.badge,
                                                  ),
                                                );
                                              }
                                              if (savedArchived.isNotEmpty) {
                                                _openRestoreOrAddSheet(
                                                  svc,
                                                  savedArchived,
                                                  createNew,
                                                );
                                                return;
                                              }
                                              createNew();
                                            },
                                          child: Text(
                                            count > 0 ? '＋別垢' : '＋追加',
                                            style:
                                                const TextStyle(fontSize: 12),
                                          ),
                                        )
                                      : FilledButton.tonal(
                                          style: FilledButton.styleFrom(
                                            visualDensity:
                                                VisualDensity.compact,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 6,
                                            ),
                                            minimumSize: const Size(0, 32),
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          onPressed: () {
                                            Navigator.of(context).pop(
                                              NewInstanceRequest(
                                                serviceId: svc.id,
                                                name: svc.name,
                                                category: svc.category,
                                                url: svc.url,
                                                colorHex: svc.colorHex,
                                                badge: svc.badge,
                                                openExistingInstanceId: existing
                                                    .first.instanceId,
                                              ),
                                            );
                                          },
                                          child: const Text(
                                            '開く',
                                            style: TextStyle(fontSize: 12),
                                          ),
                                        ),
                                  if (canAddAnother)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.tune_rounded,
                                        size: 18,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 32,
                                        minHeight: 32,
                                      ),
                                      tooltip: '詳細設定',
                                      onPressed: () =>
                                          _openDetailedAddDialog(svc),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildArchivedList() {
    final q = _searchQuery.trim().toLowerCase();
    final filtered = _archived.where((entry) {
      if (q.isEmpty) return true;
      final inst = entry.instance;
      return inst.name.toLowerCase().contains(q) ||
          (inst.accountLabel ?? '').toLowerCase().contains(q) ||
          (inst.detectedHandle ?? '').toLowerCase().contains(q) ||
          inst.serviceId.toLowerCase().contains(q) ||
          inst.url.toLowerCase().contains(q);
    }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'タブを削除してもログイン状態をここに記憶しています。「呼び出す」でログイン済みのまま復元できます。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (_archived.isNotEmpty) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _confirmPurgeAllArchived,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('全削除'),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _archived.isEmpty
                          ? '保存済みのログイン記憶はまだありません。\nアカウントやサービスを削除すると自動的にここへ保存されます。'
                          : '検索条件に一致するログイン記憶がありません。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (_, idx) {
                    final entry = filtered[idx];
                    final inst = entry.instance;
                    final color = parseHexColor(inst.colorHex);
                    final timeStr = _formatArchivedTime(entry.archivedAt);
                    return Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: color,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                inst.badge,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11.5,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _formatArchivedTitle(inst),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13.5,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    timeStr.isNotEmpty
                                        ? '保存: $timeStr'
                                        : inst.url,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                minimumSize: const Size(0, 32),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () => _restoreArchived(entry),
                              child: const Text(
                                '呼び出す',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 19,
                                color: Colors.redAccent,
                              ),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              tooltip: 'ログイン記憶を完全削除',
                              onPressed: () => _confirmPurgeArchived(entry),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildCustomForm() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'カスタムSNS / 分散サーバー / 任意URLを追加',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          'Mastodon・Misskeyの独自インスタンスや、その他のWeb版SNS・チャットを自由に追加できます。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _customNameController,
          decoration: const InputDecoration(
            labelText: '表示名',
            hintText: '例: Misskey (個人サーバー)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _customUrlController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '初期URL (https://...)',
            hintText: 'https://misskey.io/',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _customCategory,
          decoration: const InputDecoration(
            labelText: 'カテゴリ',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 'custom', child: Text('カスタム追加')),
            DropdownMenuItem(value: 'major-sns', child: Text('メジャーSNS')),
            DropdownMenuItem(value: 'messaging', child: Text('チャット・メッセージ')),
            DropdownMenuItem(value: 'matching-global', child: Text('マッチング')),
            DropdownMenuItem(
              value: 'business-creative',
              child: Text('ビジネス・創作・趣味'),
            ),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _customCategory = v);
          },
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _submitCustomService,
          child: const Text('このサービスを追加して開く'),
        ),
      ],
    );
  }
}

class _DetailedAddServiceDialog extends StatefulWidget {
  const _DetailedAddServiceDialog({
    required this.service,
    required this.suggestedLabel,
    required this.multiProfileSupported,
  });

  final CatalogService service;
  final String suggestedLabel;
  final bool multiProfileSupported;

  @override
  State<_DetailedAddServiceDialog> createState() =>
      _DetailedAddServiceDialogState();
}

class _DetailedAddServiceDialogState extends State<_DetailedAddServiceDialog> {
  late final TextEditingController _accountCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;

  @override
  void initState() {
    super.initState();
    _accountCtrl = TextEditingController(text: widget.suggestedLabel);
    _nameCtrl = TextEditingController(text: widget.service.name);
    _urlCtrl = TextEditingController(text: widget.service.url);
  }

  @override
  void dispose() {
    _accountCtrl.dispose();
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.service;
    return AlertDialog(
      title: Text('${svc.name} を詳細追加'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.multiProfileSupported) ...[
              TextField(
                controller: _accountCtrl,
                decoration: const InputDecoration(
                  labelText: 'アカウント名（ヘッダー表示名）',
                  hintText: '例: メイン / サブ / 仕事用',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'サービス表示名',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '初期URL (https://...)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () {
            final normalized = normalizeServiceUrl(_urlCtrl.text);
            if (normalized == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('有効な http:// または https:// URL を入力してください'),
                ),
              );
              return;
            }
            final finalName = _nameCtrl.text.trim().isEmpty
                ? svc.name
                : _nameCtrl.text.trim();
            final finalAcc = widget.multiProfileSupported
                ? (_accountCtrl.text.trim().isEmpty
                    ? widget.suggestedLabel
                    : _accountCtrl.text.trim())
                : 'メイン';
            Navigator.of(context).pop(
              NewInstanceRequest(
                serviceId: svc.id,
                name: finalName,
                accountLabel: finalAcc,
                category: svc.category,
                url: normalized,
                colorHex: svc.colorHex,
                badge: svc.badge,
              ),
            );
          },
          child: const Text('追加して開く'),
        ),
      ],
    );
  }
}
