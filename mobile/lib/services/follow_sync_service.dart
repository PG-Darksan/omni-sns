import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../models/service_models.dart';

const String kGistFilename = 'omnisns-follow-sync.json';
const int _kMaxResponseBytes = 4 * 1024 * 1024;
const Duration _kRequestTimeout = Duration(seconds: 20);

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

/// GitHub Personal Access Token にヘッダーインジェクション文字や空白・制御文字が含まれないか検証する。
bool isValidGitHubToken(String raw) {
  final t = raw.trim();
  return RegExp(r'^[\x21-\x7E]{1,512}$').hasMatch(t);
}

/// Gist ID が空または安全な `[A-Za-z0-9_-]{1,64}` のみか検証する（パストラバーサル・クエリ注入防止）。
bool isValidGistId(String raw) {
  final id = raw.trim();
  return id.isEmpty || RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id);
}

/// 同期エラー文字列からトークン漏洩や低レベル例外詳細を除いた安全なユーザー向けメッセージを返す。
String formatSafeSyncError(Object err) {
  if (err is SyncUserException) return err.message;
  if (err is TimeoutException) return 'GitHub Gist への接続がタイムアウトしました';
  if (err is SocketException) return 'ネットワークに接続できませんでした';
  if (err is HandshakeException || err is TlsException) {
    return 'GitHub との安全な HTTPS 接続を確立できませんでした';
  }
  if (err is HttpException) return 'GitHub との通信で HTTP エラーが発生しました';
  if (err is FormatException) return '同期データの形式が不正です';
  return '同期処理中にエラーが発生しました';
}

class SyncUserException implements Exception {
  const SyncUserException(this.message);
  final String message;

  @override
  String toString() => message;
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
    final token = (decoded['token'] is String ? decoded['token'] as String : '').trim();
    final gistId = (decoded['gistId'] is String ? decoded['gistId'] as String : '').trim();
    if (token.isEmpty && gistId.isEmpty) return null;
    if (token.isNotEmpty && !isValidGitHubToken(token)) return null;
    if (!isValidGistId(gistId)) return null;
    return (token: token, gistId: gistId);
  } catch (_) {
    return null;
  }
}

/// GitHub 非公開 Gist クラウド同期サービス。
class FollowSyncService {
  static Future<String> _readBoundedUtf8(HttpClientResponse resp) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in resp.timeout(_kRequestTimeout)) {
      total += chunk.length;
      if (total > _kMaxResponseBytes) {
        throw const SyncUserException('リモート同期データのサイズが上限(4MB)を超えています');
      }
      builder.add(chunk);
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: false);
  }

  static Future<(int, String)> _githubJsonRequest({
    required String method,
    required String path,
    required String token,
    Map<String, dynamic>? body,
  }) async {
    if (!isValidGitHubToken(token)) {
      throw const SyncUserException(
        'GitHub Token の形式が不正です（空白や改行を含めないでください）',
      );
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final uri = Uri.https('api.github.com', path);
      final req = await client.openUrl(method, uri).timeout(_kRequestTimeout);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, 'OmniSNS-Android/1.6.0');
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set('X-GitHub-Api-Version', '2022-11-28');
      if (body != null) {
        req.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        final encoded = utf8.encode(jsonEncode(body));
        req.contentLength = encoded.length;
        req.add(encoded);
      }
      final resp = await req.close().timeout(_kRequestTimeout);
      final text = await _readBoundedUtf8(resp);
      return (resp.statusCode, text);
    } on SyncUserException {
      rethrow;
    } catch (e) {
      throw SyncUserException(formatSafeSyncError(e));
    } finally {
      client.close(force: true);
    }
  }

  /// GitHub API が `truncated: true` を返した場合のみ、`gist.githubusercontent.com` の raw_url から全文を取得する。
  static Future<String> _fetchTruncatedRawContent({
    required String rawUrl,
    required String gistId,
  }) async {
    final uri = Uri.tryParse(rawUrl.trim());
    final expectedSegment = '/$gistId/raw/';
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.toLowerCase() != 'gist.githubusercontent.com' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        uri.path.isEmpty ||
        !uri.path.contains(expectedSegment)) {
      throw const SyncUserException('リモート Gist の raw_url が不正なため同期を中止しました');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client.getUrl(uri).timeout(_kRequestTimeout);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, 'OmniSNS-Android/1.6.0');
      // gist.githubusercontent.com の raw_url は署名済み/機能 URL であり API トークン不要。
      // CDN ドメインへ GitHub PAT を送信しない。
      final resp = await req.close().timeout(_kRequestTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw SyncUserException(
          '省略されたリモート Gist の取得に失敗しました (HTTP ${resp.statusCode})',
        );
      }
      return await _readBoundedUtf8(resp);
    } on SyncUserException {
      rethrow;
    } catch (e) {
      throw SyncUserException(formatSafeSyncError(e));
    } finally {
      client.close(force: true);
    }
  }

  /// リモート Gist の JSON 本文をフェイルクローズで解析する（破損 JSON 時に上書きしない）。
  static FollowSyncLedger parseRemoteLedgerStrict(String remoteContent) {
    dynamic decoded;
    try {
      decoded = jsonDecode(remoteContent);
    } catch (_) {
      throw const SyncUserException(
        'リモート Gist の同期データが破損しているため上書きを中止しました',
      );
    }
    if (decoded is! Map) {
      throw const SyncUserException(
        'リモート Gist の同期データ形式が不正なため上書きを中止しました',
      );
    }
    return FollowSyncLedger.fromJson(Map<String, dynamic>.from(decoded));
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
      throw const SyncUserException(
        'GitHub Personal Access Token（gist 権限）を入力してください',
      );
    }
    if (!isValidGitHubToken(cleanToken)) {
      throw const SyncUserException(
        'GitHub Token の形式が不正です（空白や改行を含めないでください）',
      );
    }

    final cleanId = gistId.trim();
    if (!isValidGistId(cleanId)) {
      throw const SyncUserException(
        'Gist ID の形式が不正です（半角英数字・ハイフン・アンダースコアのみ有効）',
      );
    }

    final merged = localLedger.clone();

    if (cleanId.isEmpty) {
      final contentStr =
          const JsonEncoder.withIndent('  ').convert(merged.toJson());
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
      if (status == 401 || status == 403) {
        throw SyncUserException(
          'GitHub 認証エラー (HTTP $status): Token と gist 権限を確認してください',
        );
      }
      if (status < 200 || status >= 300) {
        throw SyncUserException('GitHub Gist の作成に失敗しました (HTTP $status)');
      }
      dynamic decodedPost;
      try {
        decodedPost = jsonDecode(respBody);
      } catch (_) {
        throw const SyncUserException('GitHub からの応答 JSON を解析できませんでした');
      }
      final createdId = (decodedPost is Map && decodedPost['id'] is String)
          ? (decodedPost['id'] as String).trim()
          : '';
      if (createdId.isEmpty || !isValidGistId(createdId)) {
        throw const SyncUserException('作成された Gist ID を取得できませんでした');
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
      throw const SyncUserException(
        '指定された Gist ID が見つかりません（空欄で自動作成できます）',
      );
    }
    if (getStatus == 401 || getStatus == 403) {
      throw SyncUserException(
        'GitHub 認証エラー (HTTP $getStatus): Token と gist 権限を確認してください',
      );
    }
    if (getStatus < 200 || getStatus >= 300) {
      throw SyncUserException('GitHub Gist の取得に失敗しました (HTTP $getStatus)');
    }

    dynamic decodedGet;
    try {
      decodedGet = jsonDecode(getBody);
    } catch (_) {
      throw const SyncUserException('GitHub Gist の応答 JSON を解析できませんでした');
    }
    if (decodedGet is! Map) {
      throw const SyncUserException('GitHub Gist の応答形式が不正です');
    }

    final files = decodedGet['files'];
    String? remoteContent;
    if (files is Map && files[kGistFilename] is Map) {
      final fileObj = files[kGistFilename] as Map;
      final isTruncated = fileObj['truncated'] == true;
      if (isTruncated) {
        final rawUrl = fileObj['raw_url'];
        if (rawUrl is! String || rawUrl.trim().isEmpty) {
          throw const SyncUserException(
            'リモート Gist が省略されていますが raw_url が取得できないため同期を中止しました',
          );
        }
        remoteContent = await _fetchTruncatedRawContent(
          rawUrl: rawUrl,
          gistId: cleanId,
        );
      } else {
        final rawContent = fileObj['content'];
        if (rawContent is String) {
          remoteContent = rawContent;
        }
      }
    }

    var remoteLedger = FollowSyncLedger();
    var localChanged = false;
    if (remoteContent != null && remoteContent.trim().isNotEmpty) {
      // 破損 JSON や不正構造を空データとして上書きせずフェイルクローズで中断する
      remoteLedger = parseRemoteLedgerStrict(remoteContent);
      localChanged = merged.mergeFrom(remoteLedger, today);
    }

    if (merged.hasNewerDataThan(remoteLedger, today) || remoteContent == null) {
      final contentStr =
          const JsonEncoder.withIndent('  ').convert(merged.toJson());
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
        throw SyncUserException('GitHub Gist の更新に失敗しました (HTTP $patchStatus)');
      }
    }

    return GistSyncResult(
      gistId: cleanId,
      mergedLedger: merged,
      localChanged: localChanged,
    );
  }
}
