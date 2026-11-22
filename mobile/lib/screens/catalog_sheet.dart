import 'package:flutter/material.dart';
import '../models/service_models.dart';

class NewInstanceRequest {
  const NewInstanceRequest({
    required this.serviceId,
    required this.name,
    required this.category,
    required this.url,
    required this.colorHex,
    required this.badge,
    required this.uaMode,
  });

  final String serviceId;
  final String name;
  final String category;
  final String url;
  final String colorHex;
  final String badge;
  final UserAgentMode uaMode;
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    super.key,
    required this.categories,
    required this.catalog,
    required this.existingInstances,
  });

  final List<CategoryMeta> categories;
  final List<CatalogService> catalog;
  final List<ServiceInstance> existingInstances;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  String _selectedCategory = 'all';
  String _searchQuery = '';

  final _customNameController = TextEditingController();
  final _customUrlController = TextEditingController();
  String _customCategory = 'custom';
  UserAgentMode _customUa = UserAgentMode.mobile;

  @override
  void dispose() {
    _customNameController.dispose();
    _customUrlController.dispose();
    super.dispose();
  }

  int _addedCountFor(String serviceId) {
    return widget.existingInstances.where((i) => i.serviceId == serviceId).length;
  }

  Future<void> _openDetailedAddDialog(CatalogService svc, int existingCount) async {
    final nameCtrl = TextEditingController(
      text: existingCount > 0 ? '${svc.name} (${existingCount + 1})' : svc.name,
    );
    final urlCtrl = TextEditingController(text: svc.url);
    var uaMode = svc.recommendedAndroidUa;

    final result = await showDialog<NewInstanceRequest>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text('${svc.name} を詳細追加'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: '表示名',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: urlCtrl,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: '初期URL (https://...)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<UserAgentMode>(
                      initialValue: uaMode,
                      decoration: const InputDecoration(
                        labelText: 'User-Agent',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: UserAgentMode.mobile,
                          child: Text('スマホ版 (Android Chrome)'),
                        ),
                        DropdownMenuItem(
                          value: UserAgentMode.desktop,
                          child: Text('PC版 (Windows Chrome)'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) setDialogState(() => uaMode = v);
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  onPressed: () {
                    final normalized = normalizeServiceUrl(urlCtrl.text);
                    if (normalized == null) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text('有効な http:// または https:// URL を入力してください'),
                        ),
                      );
                      return;
                    }
                    final finalName =
                        nameCtrl.text.trim().isEmpty ? svc.name : nameCtrl.text.trim();
                    Navigator.of(ctx).pop(
                      NewInstanceRequest(
                        serviceId: svc.id,
                        name: finalName,
                        category: svc.category,
                        url: normalized,
                        colorHex: svc.colorHex,
                        badge: svc.badge,
                        uaMode: uaMode,
                      ),
                    );
                  },
                  child: const Text('追加して開く'),
                ),
              ],
            );
          },
        );
      },
    );

    nameCtrl.dispose();
    urlCtrl.dispose();

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

    Navigator.of(context).pop(
      NewInstanceRequest(
        serviceId: 'custom',
        name: name,
        category: _customCategory,
        url: normalized,
        colorHex: '#3B82F6',
        badge: makeBadgeText(name),
        uaMode: _customUa,
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
                hintText: 'サービス名・別名で検索 (例: Pairs, Tinder, mixi2, SMS...)',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                  if (_selectedCategory == 'custom' && value.trim().isNotEmpty) {
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
                    onSelected: (_) => setState(() => _selectedCategory = 'all'),
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
                                onPressed: () =>
                                    setState(() => _selectedCategory = 'custom'),
                                child: const Text('カスタムURLを追加する'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final svc = filtered[index];
                          final count = _addedCountFor(svc.id);
                          final color = parseHexColor(svc.colorHex);

                          return Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color: color,
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        alignment: Alignment.center,
                                        child: Text(
                                          svc.badge,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Flexible(
                                                  child: Text(
                                                    svc.name,
                                                    style: const TextStyle(
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: 15,
                                                    ),
                                                  ),
                                                ),
                                                if (count > 0) ...[
                                                  const SizedBox(width: 6),
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      color: Colors.green
                                                          .withValues(alpha: 0.2),
                                                      borderRadius:
                                                          BorderRadius.circular(99),
                                                    ),
                                                    child: Text(
                                                      count == 1
                                                          ? '追加済み'
                                                          : '$count個追加済み',
                                                      style: const TextStyle(
                                                        color: Colors.green,
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                            Text(
                                              svc.url,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    svc.description,
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                  if (svc.note != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      '※ ${svc.note!}',
                                      style: const TextStyle(
                                        color: Colors.amber,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: FilledButton(
                                          onPressed: () {
                                            if (svc.requiresCustomUrl) {
                                              _openDetailedAddDialog(svc, count);
                                              return;
                                            }
                                            final label = count > 0
                                                ? '${svc.name} (${count + 1})'
                                                : svc.name;
                                            Navigator.of(context).pop(
                                              NewInstanceRequest(
                                                serviceId: svc.id,
                                                name: label,
                                                category: svc.category,
                                                url: svc.url,
                                                colorHex: svc.colorHex,
                                                badge: svc.badge,
                                                uaMode: svc.recommendedAndroidUa,
                                              ),
                                            );
                                          },
                                          child: Text(
                                            count > 0 ? '＋ 別枠で追加' : '＋ 追加して開く',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      OutlinedButton(
                                        onPressed: () =>
                                            _openDetailedAddDialog(svc, count),
                                        child: const Text('詳細'),
                                      ),
                                    ],
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
            DropdownMenuItem(value: 'matching-jp', child: Text('国内マッチング・婚活')),
            DropdownMenuItem(value: 'matching-global', child: Text('海外マッチング')),
            DropdownMenuItem(value: 'matching-dating', child: Text('国内メッセージ・出会い系')),
            DropdownMenuItem(value: 'business-creative', child: Text('ビジネス・創作・趣味')),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _customCategory = v);
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<UserAgentMode>(
          initialValue: _customUa,
          decoration: const InputDecoration(
            labelText: 'User-Agent',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(
              value: UserAgentMode.mobile,
              child: Text('スマホ版 (Android Chrome)'),
            ),
            DropdownMenuItem(
              value: UserAgentMode.desktop,
              child: Text('PC版 (Windows Chrome)'),
            ),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _customUa = v);
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
