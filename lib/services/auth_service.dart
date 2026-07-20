import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path_provider/path_provider.dart';
import 'desktop_oauth.dart';

/// Drive file scope — read/write only files this app created.
const _kDriveScope = 'https://www.googleapis.com/auth/drive.file';
const _kEmailScope = 'https://www.googleapis.com/auth/userinfo.email';

/// A connected Google account. [id] is the OIDC `sub` — stable across devices
/// for the same Google account, so it's what a notebook's `syncTarget` stores
/// (Phase 2). email/name/photo are for display only.
class Account {
  final String id; // Google `sub`
  final String? email;
  final String? displayName;
  final String? photoUrl;
  const Account({
    required this.id,
    this.email,
    this.displayName,
    this.photoUrl,
  });

  Account copyWith({String? email, String? displayName, String? photoUrl}) =>
      Account(
        id: id,
        email: email ?? this.email,
        displayName: displayName ?? this.displayName,
        photoUrl: photoUrl ?? this.photoUrl,
      );
}

/// Back-compat display shape for the single-account UI/notifier. Mirrors the
/// **default** account so existing call sites (sync status icon, Drive/Sync
/// "is there an account?" checks) keep working while Phase 2 lands.
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

/// In-memory + persisted token state for one account. The `refresh` token is
/// long-lived (persisted, secret); the access token + expiry are short-lived
/// and kept in memory only (re-derived via refresh on demand).
class _TokenState {
  String refresh;
  String? access;
  DateTime? expiry;
  Future<bool>? refreshInFlight;
  _TokenState(this.refresh);
}

/// Handles Google sign-in across Android (`google_sign_in` — **A-hybrid**: the
/// native picker returns a `serverAuthCode` we exchange for a refresh token we
/// own) and desktop Linux/Windows/macOS (loopback OAuth + PKCE). Either way we
/// end up owning a **refresh token per account**, so several accounts can stay
/// connected and sync simultaneously (google_sign_in's single-current-user
/// model can't do that — hence owning the tokens ourselves).
///
/// Refresh tokens live in `flutter_secure_storage` under one JSON blob
/// (`_kAccountsKey`) that also carries each account's display metadata + the
/// default account id. Access tokens are never persisted.
class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  // Desktop (Linux/Windows/macOS) OAuth client.
  static const _kDesktopClientId =
      String.fromEnvironment('GOOGLE_CLIENT_ID', defaultValue: '');
  static const _kDesktopClientSecret =
      String.fromEnvironment('GOOGLE_CLIENT_SECRET', defaultValue: '');
  // Web OAuth client — used on Android to exchange google_sign_in's
  // serverAuthCode and to refresh the resulting token.
  static const _kWebClientId =
      String.fromEnvironment('WEB_CLIENT_ID', defaultValue: '');
  static const _kWebClientSecret =
      String.fromEnvironment('WEB_CLIENT_SECRET', defaultValue: '');

  static const _kAccountsKey = 'omninote_accounts';
  // Legacy single-account desktop refresh token (pre-multi-account). Migrated
  // into [_kAccountsKey] on first launch, then deleted.
  static const _kLegacyRefreshKey = 'omninote_drive_refresh_token';

  /// All connected accounts (first = default unless [_defaultId] says otherwise).
  final accounts = ValueNotifier<List<Account>>([]);

  /// Compat: mirrors the **default** account (or null). Existing widgets and
  /// services listen to this.
  final account = ValueNotifier<AuthUser?>(null);
  final signingIn = ValueNotifier<bool>(false);
  final lastError = ValueNotifier<String?>(null);

  final _secure = const FlutterSecureStorage();

  final Map<String, _TokenState> _tokens = {};
  String? _defaultId;
  GoogleSignIn? _googleSignIn;
  bool _initialized = false;

  bool get isSignedIn => accounts.value.isNotEmpty;
  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  // Which OAuth client this *device* uses for token ops. Android accounts were
  // authorized via the web client; desktop via the desktop client. The refresh
  // token is device-local, so the platform decides the client unambiguously.
  String get _clientId => _isMobile ? _kWebClientId : _kDesktopClientId;
  String get _clientSecret => _isMobile ? _kWebClientSecret : _kDesktopClientSecret;

  String? get defaultAccountId => _defaultId;
  Account? get defaultAccount {
    final list = accounts.value;
    if (list.isEmpty) return null;
    return list.firstWhere(
      (a) => a.id == _defaultId,
      orElse: () => list.first,
    );
  }

  // ── Init ────────────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _load();
      if (accounts.value.isEmpty) {
        await _migrateLegacyDesktopToken();
      }
      _updateCompat();
    } catch (e, st) {
      debugPrint('Auth init error: $e\n$st');
    }
  }

  GoogleSignIn _ensureGoogleSignIn() {
    return _googleSignIn ??= GoogleSignIn(
      scopes: [_kDriveScope, _kEmailScope],
      // Requesting a serverAuthCode for the web client → we can exchange it for
      // a refresh token we own (the A-hybrid crux).
      serverClientId: _kWebClientId.isEmpty ? null : _kWebClientId,
      // Force a refresh-token-yielding code on EVERY sign-in, not just the
      // first. Without this, a second device signing into the same account gets
      // a code with no refresh token, and the only workaround (disconnect +
      // re-consent) *revokes* the grant — breaking the first device. This flag
      // makes each device get its own refresh token without revoking others.
      forceCodeForRefreshToken: true,
    );
  }

  // ── Add / remove accounts ─────────────────────────────────────────────────

  /// Compat single-account entry point: adds an account and returns the (now)
  /// default account as an [AuthUser].
  Future<AuthUser?> signIn() async {
    final added = await addAccount();
    return added == null ? null : account.value;
  }

  /// Interactive add-account. Returns the added [Account], or null on
  /// cancel/failure ([lastError] set).
  Future<Account?> addAccount() async {
    lastError.value = null;
    signingIn.value = true;
    try {
      final Account? added =
          _isMobile ? await _addMobileAccount() : await _addDesktopAccount();
      if (added != null) {
        _upsertAccount(added, makeDefaultIfFirst: true);
        await _persist();
        _updateCompat();
      }
      return added;
    } catch (e, st) {
      debugPrint('Add-account exception: $e\n$st');
      lastError.value = _friendlyError(e.toString());
      return null;
    } finally {
      signingIn.value = false;
    }
  }

  Future<Account?> _addMobileAccount() async {
    final gsi = _ensureGoogleSignIn();
    // Local sign-out so the picker always shows (lets you add a *different*
    // account than the one currently remembered). This is local only — it does
    // NOT revoke the grant, so other devices signed into the same account keep
    // working. `forceCodeForRefreshToken` guarantees a refresh token regardless.
    await _safeSignOut(gsi);

    final acct = await gsi.signIn();
    if (acct == null) {
      lastError.value = 'Sign-in was cancelled';
      return null;
    }
    final token = await _exchangeServerCode(acct);
    if (token == null || token['access_token'] == null) {
      // _exchangeServerCode already set a specific lastError.
      lastError.value ??= 'Sign-in did not complete.';
      return null;
    }
    return _accountFromToken(token, fallbackEmail: acct.email);
  }

  /// Exchanges an account's `serverAuthCode` for tokens (web client). Sets
  /// [lastError] and returns null on a missing code / failed exchange.
  Future<Map<String, dynamic>?> _exchangeServerCode(
      GoogleSignInAccount acct) async {
    final code = acct.serverAuthCode;
    if (code == null || code.isEmpty) {
      lastError.value = 'Could not get authorization from Google — try again.';
      return null;
    }
    return DesktopOAuth.exchangeAuthCode(
      clientId: _kWebClientId,
      clientSecret: _kWebClientSecret,
      code: code,
      redirectUri: '', // serverAuthCode exchange requires empty redirect_uri
    );
  }

  Future<void> _safeSignOut(GoogleSignIn gsi) async {
    try {
      await gsi.signOut();
    } catch (_) {}
  }

  Future<Account?> _addDesktopAccount() async {
    final token = await DesktopOAuth.signIn(
      clientId: _kDesktopClientId,
      clientSecret: _kDesktopClientSecret,
      scopes: [_kDriveScope, _kEmailScope],
    );
    if (token == null || token['access_token'] == null) {
      lastError.value = 'Desktop sign-in did not complete.';
      return null;
    }
    return _accountFromToken(token, fallbackEmail: null);
  }

  /// Builds an [Account] from a fresh token response: fetches userinfo for the
  /// stable `sub` id + profile, and registers the token state. The refresh
  /// token must be present (both our flows request offline access).
  Future<Account?> _accountFromToken(
    Map<String, dynamic> token, {
    String? fallbackEmail,
  }) async {
    final access = token['access_token'] as String?;
    final refresh = token['refresh_token'] as String?;
    if (access == null) return null;
    if (refresh == null || refresh.isEmpty) {
      // No refresh token → we can't sync in the background for this account.
      // Happens if Google already granted this app before without offline
      // access; re-consent (our flows force prompt) normally fixes it.
      lastError.value =
          'Google didn\'t return a refresh token — remove and re-add the account.';
      return null;
    }
    final info = await DesktopOAuth.fetchUserInfo(access);
    final sub = info?['sub'] as String?;
    if (sub == null) {
      lastError.value = 'Could not read the Google account id.';
      return null;
    }
    final acct = Account(
      id: sub,
      email: (info?['email'] as String?) ?? fallbackEmail,
      displayName: (info?['name'] as String?) ??
          (info?['email'] as String?) ??
          fallbackEmail,
      photoUrl: info?['picture'] as String?,
    );
    final ts = _TokenState(refresh)
      ..access = access
      ..expiry = DateTime.now()
          .add(Duration(seconds: (token['expires_in'] as num?)?.toInt() ?? 3600));
    _tokens[sub] = ts;
    return acct;
  }

  void _upsertAccount(Account a, {bool makeDefaultIfFirst = false}) {
    final list = List<Account>.from(accounts.value);
    final i = list.indexWhere((e) => e.id == a.id);
    if (i >= 0) {
      list[i] = a; // refresh metadata (re-adding the same account)
    } else {
      list.add(a);
    }
    accounts.value = list;
    if (_defaultId == null || (makeDefaultIfFirst && list.length == 1)) {
      _defaultId = a.id;
    }
  }

  /// Removes one account: drops its token + metadata. If it was the default,
  /// the first remaining account becomes default (or none). Does **not** touch
  /// sync state — the caller (Settings) runs any purge/repair flow.
  Future<void> removeAccount(String id) async {
    final list = List<Account>.from(accounts.value)
      ..removeWhere((a) => a.id == id);
    accounts.value = list;
    _tokens.remove(id);
    if (_defaultId == id) {
      _defaultId = list.isEmpty ? null : list.first.id;
    }
    if (_isMobile) {
      // Best-effort: clear google_sign_in's remembered current user too.
      try {
        await _googleSignIn?.signOut();
      } catch (_) {}
    }
    await _persist();
    _updateCompat();
  }

  // ── Auth headers (called per Drive request) ─────────────────────────────────

  /// Fresh auth headers for [accountId] (defaults to the default account).
  /// Refreshes the access token proactively (5 min pre-expiry) and reactively.
  Future<Map<String, String>> getAuthHeaders([String? accountId]) async {
    final id = accountId ?? _defaultId;
    if (id == null) throw AuthException('Not signed in');
    final ts = _tokens[id];
    if (ts == null) throw AuthException('Account not connected');
    final soon = DateTime.now().add(const Duration(minutes: 5));
    if (ts.access == null || ts.expiry == null || ts.expiry!.isBefore(soon)) {
      final ok = await _refresh(id);
      if (!ok) throw AuthException('Drive session expired — please reconnect');
    }
    return {'Authorization': 'Bearer ${ts.access}'};
  }

  Future<bool> _refresh(String id) {
    final ts = _tokens[id];
    if (ts == null) return Future.value(false);
    // Collapse concurrent refreshes (many Drive requests can race).
    return ts.refreshInFlight ??= _doRefresh(id)
      ..whenComplete(() => ts.refreshInFlight = null);
  }

  Future<bool> _doRefresh(String id) async {
    final ts = _tokens[id];
    if (ts == null) return false;
    final token = await DesktopOAuth.refresh(
      clientId: _clientId,
      clientSecret: _clientSecret,
      refreshToken: ts.refresh,
    );
    if (token == null || token['access_token'] == null) return false;
    ts.access = token['access_token'] as String?;
    ts.expiry = DateTime.now()
        .add(Duration(seconds: (token['expires_in'] as num?)?.toInt() ?? 3600));
    // Google may (rarely) rotate the refresh token.
    final newRefresh = token['refresh_token'] as String?;
    if (newRefresh != null && newRefresh.isNotEmpty && newRefresh != ts.refresh) {
      ts.refresh = newRefresh;
      unawaited(_persist());
    }
    return true;
  }

  // ── Persistence (secure storage) ────────────────────────────────────────────

  Future<void> _load() async {
    String? raw;
    try {
      raw = await _secure.read(key: _kAccountsKey);
    } catch (e) {
      // A locked/unavailable keyring (common on Linux — see _writeBackstop)
      // throws here; fall through to the backstop rather than losing the session.
      debugPrint('Auth secure read failed, trying backstop: $e');
      raw = null;
    }
    final fromSecure = raw != null && raw.isNotEmpty;
    if (!fromSecure && Platform.isLinux) {
      raw = await _readBackstop();
    }
    if (raw == null || raw.isEmpty) return;
    // A successful keyring read seeds/refreshes the Linux backstop so a later
    // locked-keyring startup can still restore this same session (no re-login).
    if (fromSecure && Platform.isLinux) await _writeBackstop(raw);
    final data = jsonDecode(raw) as Map<String, dynamic>;
    _defaultId = data['default'] as String?;
    final rawAccts = (data['accounts'] as List? ?? const []);
    final list = <Account>[];
    for (final e in rawAccts) {
      final m = e as Map<String, dynamic>;
      final id = m['id'] as String?;
      final refresh = m['refresh'] as String?;
      if (id == null || refresh == null) continue;
      list.add(Account(
        id: id,
        email: m['email'] as String?,
        displayName: m['name'] as String?,
        photoUrl: m['photo'] as String?,
      ));
      _tokens[id] = _TokenState(refresh);
    }
    accounts.value = list;
    if (_defaultId == null && list.isNotEmpty) _defaultId = list.first.id;
  }

  Future<void> _persist() async {
    final list = accounts.value
        .map((a) => {
              'id': a.id,
              'email': a.email,
              'name': a.displayName,
              'photo': a.photoUrl,
              'refresh': _tokens[a.id]?.refresh,
            })
        .where((m) => m['refresh'] != null)
        .toList();
    final blob = jsonEncode({'default': _defaultId, 'accounts': list});
    try {
      await _secure.write(key: _kAccountsKey, value: blob);
    } catch (e) {
      // A locked keyring can also reject writes; the backstop below still
      // captures the session so it survives regardless.
      debugPrint('Auth secure write failed: $e');
    }
    if (Platform.isLinux) {
      if (list.isEmpty) {
        await _deleteBackstop();
      } else {
        await _writeBackstop(blob);
      }
    }
  }

  // ── Linux keyring backstop ───────────────────────────────────────────────
  // gnome-keyring on some Linux setups (e.g. a socket-activated daemon whose
  // keyring isn't the PAM-unlocked "login" keyring, as on Hyprland/Omarchy)
  // boots LOCKED with no prompter, so flutter_secure_storage reads return
  // nothing at startup — the session looks signed-out even though the refresh
  // token is safely on disk in the (locked) keyring. To stop that from dropping
  // the login every restart, on Linux we mirror the accounts blob to a private
  // 0600 file in the app-support dir. Secure storage stays the PRIMARY store on
  // every platform; this file is written only on Linux and read only when the
  // keyring yields nothing. Other platforms never touch it.

  File? _backstopFileCached;
  Future<File> _backstopFile() async {
    if (_backstopFileCached != null) return _backstopFileCached!;
    final dir = await getApplicationSupportDirectory();
    return _backstopFileCached = File('${dir.path}/.auth_accounts.json');
  }

  Future<String?> _readBackstop() async {
    try {
      final f = await _backstopFile();
      if (!await f.exists()) return null;
      final s = await f.readAsString();
      return s.isEmpty ? null : s;
    } catch (e) {
      debugPrint('Auth backstop read failed: $e');
      return null;
    }
  }

  Future<void> _writeBackstop(String blob) async {
    try {
      final f = await _backstopFile();
      await f.writeAsString(blob, flush: true);
      // Best-effort: keep the token file owner-only.
      try {
        await Process.run('chmod', ['600', f.path]);
      } catch (_) {}
    } catch (e) {
      debugPrint('Auth backstop write failed: $e');
    }
  }

  Future<void> _deleteBackstop() async {
    try {
      final f = await _backstopFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// One-time migration of the pre-multi-account desktop refresh token into the
  /// new keyed blob. Android had no stored refresh token (google_sign_in
  /// managed it), so those users re-add the account once — the A-hybrid cost.
  Future<void> _migrateLegacyDesktopToken() async {
    if (_isMobile) return;
    final refresh = await _secure.read(key: _kLegacyRefreshKey);
    if (refresh == null || refresh.isEmpty) return;
    final token = await DesktopOAuth.refresh(
      clientId: _kDesktopClientId,
      clientSecret: _kDesktopClientSecret,
      refreshToken: refresh,
    );
    if (token == null || token['access_token'] == null) return;
    final access = token['access_token'] as String;
    final info = await DesktopOAuth.fetchUserInfo(access);
    final sub = info?['sub'] as String?;
    if (sub == null) return;
    final acct = Account(
      id: sub,
      email: info?['email'] as String?,
      displayName: (info?['name'] ?? info?['email']) as String?,
      photoUrl: info?['picture'] as String?,
    );
    _tokens[sub] = _TokenState(refresh)
      ..access = access
      ..expiry = DateTime.now()
          .add(Duration(seconds: (token['expires_in'] as num?)?.toInt() ?? 3600));
    _upsertAccount(acct, makeDefaultIfFirst: true);
    await _persist();
    await _secure.delete(key: _kLegacyRefreshKey);
  }

  // ── Compat notifier ──────────────────────────────────────────────────────────

  String? _compatId;

  /// Refreshes the compat [account] notifier — but only when the **default**
  /// account actually changes identity (or appears/disappears). Adding a
  /// *secondary* account must not fire it, or Drive/Sync (which listen here)
  /// would needlessly rebuild + re-bootstrap.
  void _updateCompat() {
    final d = defaultAccount;
    final sameId = d?.id == _compatId;
    final sameNullness = (d == null) == (account.value == null);
    if (sameId && sameNullness) return;
    _compatId = d?.id;
    account.value = d == null
        ? null
        : AuthUser(
            email: d.email,
            displayName: d.displayName,
            photoUrl: d.photoUrl,
          );
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
