import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'desktop_oauth.dart';

/// Drive file scope — read/write only files this app created.
const _kDriveScope = 'https://www.googleapis.com/auth/drive.file';
const _kEmailScope = 'https://www.googleapis.com/auth/userinfo.email';

class AuthUser {
  final String? email;
  final String? displayName;
  final String? photoUrl;
  AuthUser({this.email, this.displayName, this.photoUrl});
}

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

/// Handles Google sign-in on both mobile (`google_sign_in`) and desktop
/// (loopback OAuth + PKCE). The desktop refresh token is persisted to the OS
/// keystore via `flutter_secure_storage` and used to silently restore the
/// session and to refresh the ~1h access token proactively.
class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  static const _kDesktopClientId =
      String.fromEnvironment('GOOGLE_CLIENT_ID', defaultValue: '');
  static const _kDesktopClientSecret =
      String.fromEnvironment('GOOGLE_CLIENT_SECRET', defaultValue: '');
  static const _kRefreshTokenKey = 'omninote_drive_refresh_token';

  final account = ValueNotifier<AuthUser?>(null);
  final signingIn = ValueNotifier<bool>(false);
  final lastError = ValueNotifier<String?>(null);

  final _secure = const FlutterSecureStorage();

  GoogleSignInAccount? _googleAccount;
  GoogleSignIn? _googleSignIn;

  // Desktop token state.
  String? _desktopAccessToken;
  String? _desktopRefreshToken;
  DateTime? _desktopExpiry;
  Future<bool>? _refreshInFlight;

  bool _initialized = false;

  bool get isSignedIn => account.value != null;
  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      if (_isMobile) {
        _googleSignIn = GoogleSignIn(scopes: [_kDriveScope, _kEmailScope]);
        _googleSignIn!.onCurrentUserChanged.listen(_onGoogleUser);
        await _googleSignIn!.signInSilently();
      } else {
        await _restoreDesktopSession();
      }
    } catch (e, st) {
      debugPrint('Auth init error: $e\n$st');
    }
  }

  void _onGoogleUser(GoogleSignInAccount? acct) {
    _googleAccount = acct;
    account.value = acct == null
        ? null
        : AuthUser(
            email: acct.email,
            displayName: acct.displayName,
            photoUrl: acct.photoUrl,
          );
  }

  // ── Sign in / out ──────────────────────────────────────────────────────────

  Future<AuthUser?> signIn() async {
    lastError.value = null;
    signingIn.value = true;
    try {
      if (_isMobile) {
        _googleSignIn ??= GoogleSignIn(scopes: [_kDriveScope, _kEmailScope]);
        final acct = await _googleSignIn!.signIn();
        if (acct != null) {
          _onGoogleUser(acct);
          return account.value;
        }
        lastError.value = 'Sign-in was cancelled';
      } else {
        final token = await DesktopOAuth.signIn(
          clientId: _kDesktopClientId,
          clientSecret: _kDesktopClientSecret,
          scopes: [_kDriveScope, _kEmailScope],
        );
        if (token != null && token['access_token'] != null) {
          await _applyDesktopToken(token, persistRefresh: true);
          return account.value;
        }
        lastError.value = 'Desktop sign-in did not complete.';
      }
    } catch (e, st) {
      debugPrint('Sign-in exception: $e\n$st');
      lastError.value = _friendlyError(e.toString());
    } finally {
      signingIn.value = false;
    }
    return null;
  }

  Future<void> signOut() async {
    if (_isMobile) {
      await _googleSignIn?.signOut();
    } else {
      await _secure.delete(key: _kRefreshTokenKey);
      _desktopAccessToken = null;
      _desktopRefreshToken = null;
      _desktopExpiry = null;
    }
    _googleAccount = null;
    account.value = null;
  }

  // ── Desktop token lifecycle ─────────────────────────────────────────────────

  Future<void> _restoreDesktopSession() async {
    final refresh = await _secure.read(key: _kRefreshTokenKey);
    if (refresh == null || refresh.isEmpty) return;
    _desktopRefreshToken = refresh;
    final ok = await _refreshDesktopToken();
    if (!ok) {
      // Token dead (revoked / 7-day testing expiry). Stay signed out; the user
      // can reconnect. Do not delete the refresh token — a transient network
      // failure shouldn't force a full re-consent.
      return;
    }
    final email = _desktopAccessToken == null
        ? null
        : await DesktopOAuth.fetchEmail(_desktopAccessToken!);
    account.value = AuthUser(email: email, displayName: email);
  }

  Future<void> _applyDesktopToken(
    Map<String, dynamic> token, {
    required bool persistRefresh,
  }) async {
    _desktopAccessToken = token['access_token'] as String?;
    final expiresIn = (token['expires_in'] as num?)?.toInt() ?? 3600;
    _desktopExpiry = DateTime.now().add(Duration(seconds: expiresIn));
    final refresh = token['refresh_token'] as String?;
    if (refresh != null && refresh.isNotEmpty) {
      _desktopRefreshToken = refresh;
      if (persistRefresh) {
        await _secure.write(key: _kRefreshTokenKey, value: refresh);
      }
    }
    final email = _desktopAccessToken == null
        ? null
        : await DesktopOAuth.fetchEmail(_desktopAccessToken!);
    account.value = AuthUser(email: email, displayName: email ?? 'Google Drive');
  }

  /// Refreshes the desktop access token. Returns true on success.
  Future<bool> _refreshDesktopToken() {
    // Collapse concurrent refreshes (many Drive requests can race).
    return _refreshInFlight ??= _doRefreshDesktopToken()
      ..whenComplete(() => _refreshInFlight = null);
  }

  Future<bool> _doRefreshDesktopToken() async {
    final refresh = _desktopRefreshToken;
    if (refresh == null) return false;
    final token = await DesktopOAuth.refresh(
      clientId: _kDesktopClientId,
      clientSecret: _kDesktopClientSecret,
      refreshToken: refresh,
    );
    if (token == null || token['access_token'] == null) return false;
    _desktopAccessToken = token['access_token'] as String?;
    final expiresIn = (token['expires_in'] as num?)?.toInt() ?? 3600;
    _desktopExpiry = DateTime.now().add(Duration(seconds: expiresIn));
    return true;
  }

  // ── Auth headers (called per Drive request) ─────────────────────────────────

  Future<Map<String, String>> getAuthHeaders() async {
    if (_isMobile) {
      if (_googleAccount == null) throw AuthException('Not signed in');
      return _googleAccount!.authHeaders;
    }
    // Desktop: refresh proactively 5 min before expiry (and reactively if we
    // somehow have no token yet).
    final soon = DateTime.now().add(const Duration(minutes: 5));
    if (_desktopAccessToken == null ||
        _desktopExpiry == null ||
        _desktopExpiry!.isBefore(soon)) {
      final ok = await _refreshDesktopToken();
      if (!ok) throw AuthException('Drive session expired — please reconnect');
    }
    return {'Authorization': 'Bearer $_desktopAccessToken'};
  }

  String _friendlyError(String raw) {
    if (raw.contains('network_error') || raw.contains('SocketException')) {
      return 'No internet connection';
    }
    if (raw.contains('canceled') ||
        raw.contains('cancelled') ||
        raw.contains('sign_in_canceled')) {
      return 'Sign-in was cancelled';
    }
    return 'Sign-in failed — please try again';
  }
}
