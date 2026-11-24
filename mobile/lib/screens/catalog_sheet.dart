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
  });

  final String serviceId;
  final String name;
  final String? accountLabel;
  final String category;
  final String url;
  final String colorHex;
  final String badge;
  final String? openExistingInstanceId;
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    super.key,
    required this.categories,
    required this.catalog,
    required this.existingInstances,
    required this.multiProfileSupported,
  });

  final List<CategoryMeta> categories;
  final List<CatalogService> catalog;
  final List<ServiceInstance> existingInstances;
  final bool multiProfileSupported;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  String _selectedCategory = 'all';
  String _searchQuery = '';

  final _customNameController = TextEditingController();
  final _customUrlController = TextEditingController();
  String _customCategory = 'custom';

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
            child: _selectedCategory == 'custom'
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
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  canAddAnother
                                      ? FilledButton(
                                          style: FilledButton.styleFrom(
                                            visualDensity:
                                                VisualDensity.compact,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 6,
                                            ),
                                            minimumSize: const Size(0, 32),
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          onPressed: () {
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
