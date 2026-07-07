import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Loopback OAuth (PKCE) for desktop (Windows/macOS/Linux).
///
/// Opens the system browser to Google's consent screen, captures the
/// authorization code on a `http://127.0.0.1:<port>` loopback, and exchanges it
/// (with the PKCE verifier) for tokens. The returned map includes
/// `refresh_token`, which the caller persists to secure storage.
class DesktopOAuth {
  static const _authUrl = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenUrl = 'https://oauth2.googleapis.com/token';

  /// Interactive sign-in. Returns the token map, or null if cancelled/failed.
  static Future<Map<String, dynamic>?> signIn({
    required String clientId,
    required String clientSecret,
    required List<String> scopes,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}';
    final verifier = _randomString(64);
    final challenge = _s256(verifier);

    final authUri = Uri.parse(_authUrl).replace(queryParameters: {
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': scopes.join(' '),
      'access_type': 'offline',
      'prompt': 'consent',
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });

    if (!await launchUrl(authUri, mode: LaunchMode.externalApplication)) {
      await server.close(force: true);
      return null;
    }

    try {
      final request = await server.first.timeout(const Duration(minutes: 3));
      final code = request.uri.queryParameters['code'];
      final error = request.uri.queryParameters['error'];

      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(_closePage(error == null));
      await request.response.close();
      await server.close(force: true);

      if (code == null) return null;

      final resp = await http.post(
        Uri.parse(_tokenUrl),
        body: {
          'client_id': clientId,
          'client_secret': clientSecret,
          'code': code,
          'code_verifier': verifier,
          'grant_type': 'authorization_code',
          'redirect_uri': redirectUri,
        },
      );
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      await server.close(force: true);
      return null;
    }
  }

  /// Exchanges a stored refresh token for a fresh access token.
  /// Returns null on `invalid_grant` (token revoked/expired) or network error.
  static Future<Map<String, dynamic>?> refresh({
    required String clientId,
    required String clientSecret,
    required String refreshToken,
  }) async {
    try {
      final resp = await http.post(
        Uri.parse(_tokenUrl),
        body: {
          'client_id': clientId,
          'client_secret': clientSecret,
          'refresh_token': refreshToken,
          'grant_type': 'refresh_token',
        },
      );
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Fetches the signed-in user's email using an access token.
  static Future<String?> fetchEmail(String accessToken) async {
    try {
      final resp = await http.get(
        Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        return j['email'] as String?;
      }
    } catch (_) {}
    return null;
  }

  // ── PKCE helpers ───────────────────────────────────────────────────────────

  static String _randomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)])
        .join();
  }

  static String _s256(String input) {
    final digest = sha256.convert(utf8.encode(input));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  static String _closePage(bool ok) => '<!doctype html><html><head>'
      '<meta charset="utf-8"><title>Omininote</title></head>'
      '<body style="font-family:system-ui;text-align:center;padding-top:80px">'
      '<h2>${ok ? 'Signed in to Omininote' : 'Sign-in failed'}</h2>'
      '<p>You can close this window and return to the app.</p>'
      '<script>window.close();</script></body></html>';
}
