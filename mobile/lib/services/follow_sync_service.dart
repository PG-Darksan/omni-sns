import 'dart:convert';
import 'dart:io';
import '../models/service_models.dart';

const String kGistFilename = 'omnisns-follow-sync.json';

class GistSyncResult {
  const GistSyncResult({
    required this.gistId,
    required this.mergedLedger,
    required this.localChanged,
  });

  final String gistId;
  final FollowSyncLedger mergedLedger;
  final bool localChanged;
}

/// PC ⇄ スマホ間でコピー＆ペースト共有できる同期設定文字列を生成・解析する。
String encodeSharedSyncConfig(String token, String gistId) {
  return 'OMNISNS_SYNC_V1:${jsonEncode({
        'token': token.trim(),
        'gistId': gistId.trim(),
      })}';
}

({String token, String gistId})? parseSharedSyncConfig(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final jsonPart = trimmed.startsWith('OMNISNS_SYNC_V1:')
      ? trimmed.substring('OMNISNS_SYNC_V1:'.length).trim()
      : trimmed;
  if (!jsonPart.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(jsonPart);
    if (decoded is! Map) return null;
    final token = (decoded['token'] as String?)?.trim() ?? '';
    final gistId = (decoded['gistId'] as String?)?.trim() ?? '';
    if (token.isEmpty && gistId.isEmpty) return null;
    return (token: token, gistId: gistId);
  } catch (_) {
    return null;
  }
}

/// GitHub 非公開 Gist クラウド同期サービス。
class FollowSyncService {
  static Future<(int, String)> _githubJsonRequest({
    required String method,
    required String path,
    required String token,
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final uri = Uri.https('api.github.com', path);
      final req = await client.openUrl(method, uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'OmniSNS-Android/1.5.1');
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set('X-GitHub-Api-Version', '2022-11-28');
      if (body != null) {
        req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
        req.write(jsonEncode(body));
      }
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final text = await resp.transform(utf8.decoder).join();
      return (resp.statusCode, text);
    } finally {
      client.close(force: true);
    }
  }

  /// GitHub 非公開 Gist クラウド同期（空 Gist ID 時は非公開 Gist を自動作成）。
  static Future<GistSyncResult> syncWithGitHubGist({
    required String token,
    required String gistId,
    required FollowSyncLedger localLedger,
    required String today,
  }) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) {
      throw Exception('GitHub Personal Access Token（gist 権限）を入力してください');
    }

    final merged = localLedger.clone();
    final cleanId = gistId.trim();

    if (cleanId.isEmpty) {
      final contentStr = const JsonEncoder.withIndent('  ').convert(merged.toJson());
      final (status, respBody) = await _githubJsonRequest(
        method: 'POST',
        path: '/gists',
        token: cleanToken,
        body: {
          'description': 'OmniSNS Follow Counter Sync (Private)',
          'public': false,
          'files': {
            kGistFilename: {'content': contentStr},
          },
        },
      );
      if (status < 200 || status >= 300) {
        throw Exception('GitHub Gist の作成に失敗しました (HTTP $status)');
      }
      final parsed = jsonDecode(respBody) as Map<String, dynamic>;
      final createdId = (parsed['id'] as String?)?.trim() ?? '';
      if (createdId.isEmpty) {
        throw Exception('作成された Gist ID を取得できませんでした');
      }
      return GistSyncResult(
        gistId: createdId,
        mergedLedger: merged,
        localChanged: false,
      );
    }

    final path = '/gists/$cleanId';
    final (getStatus, getBody) = await _githubJsonRequest(
      method: 'GET',
      path: path,
      token: cleanToken,
    );
    if (getStatus == 404) {
      throw Exception('指定された Gist ID が見つかりません（空欄で自動作成できます）');
    }
    if (getStatus < 200 || getStatus >= 300) {
      throw Exception('GitHub Gist の取得に失敗しました (HTTP $getStatus)');
    }

    final parsedGet = jsonDecode(getBody) as Map<String, dynamic>;
    final files = parsedGet['files'];
    String? remoteContent;
    if (files is Map && files[kGistFilename] is Map) {
      remoteContent = (files[kGistFilename] as Map)['content'] as String?;
    }

    var remoteLedger = FollowSyncLedger();
    var localChanged = false;
    if (remoteContent != null && remoteContent.isNotEmpty) {
      try {
        final decodedLedger = jsonDecode(remoteContent);
        if (decodedLedger is Map) {
          remoteLedger = FollowSyncLedger.fromJson(
            Map<String, dynamic>.from(decodedLedger),
          );
          localChanged = merged.mergeFrom(remoteLedger, today);
        }
      } catch (_) {}
    }

    if (merged.hasNewerDataThan(remoteLedger, today) || remoteContent == null) {
      final contentStr = const JsonEncoder.withIndent('  ').convert(merged.toJson());
      final (patchStatus, _) = await _githubJsonRequest(
        method: 'PATCH',
        path: path,
        token: cleanToken,
        body: {
          'files': {
            kGistFilename: {'content': contentStr},
          },
        },
      );
      if (patchStatus < 200 || patchStatus >= 300) {
        throw Exception('GitHub Gist の更新に失敗しました (HTTP $patchStatus)');
      }
    }

    return GistSyncResult(
      gistId: cleanId,
      mergedLedger: merged,
      localChanged: localChanged,
    );
  }
}
