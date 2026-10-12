import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Where the guest's order access token is kept between app runs.
///
/// The token is the guest's only credential for their orders: it is what
/// `create_table_order` reuses when a guest orders a second time, so a second
/// order lands under the same identity instead of minting a new one. This is not
/// an account and not a session — there is nothing to sign in with, no
/// server-side identity, and no way to reach an order without the token. Keeping
/// it on the device means a guest who clears app data, or who uses another
/// device, has no access to past orders, which is the honest limit of an
/// anonymous design.
///
/// Unlike the reservation access store, which holds one token for the whole
/// guest, this store keeps a token per [contextKey], which is the QR token of the
/// menu the order was placed from. A guest who scans several tables therefore gets
/// one token per table, and a token from one restaurant or table can never be sent
/// while ordering from another. The two stores are entirely separate: different
/// keys, different capability, and neither can read or overwrite the other.
abstract interface class OrderAccessStore {
  /// The stored token for [contextKey], or `null` when this device has never
  /// ordered from that menu.
  ///
  /// Returns `null` for a blank [contextKey] rather than reading or writing an
  /// unscoped token, so a missing context can never collapse into one shared
  /// credential.
  Future<String?> readToken({required String contextKey});

  /// Stores [token] as the guest's token for [contextKey], replacing any earlier
  /// one for that context and touching no other context.
  Future<void> writeToken({required String contextKey, required String token});

  /// Forgets the token for [contextKey], which leaves only those orders
  /// unreachable from this device.
  Future<void> clearToken({required String contextKey});
}

/// Keeps the tokens in the platform's local preferences for this app.
///
/// The tokens never leave the device in a readable form: they are only sent back
/// to the database, which matches them against the orders they own.
class DeviceOrderAccessStore implements OrderAccessStore {
  const DeviceOrderAccessStore();

  /// Namespaced so it can never collide with another preference.
  ///
  /// One key holds a whole map of context to token, rather than one key per
  /// context. That keeps the number of preferences constant no matter how many
  /// tables a guest scans, keeps every token under a single name a reviewer can
  /// check, and means the reservation token's own key cannot be affected by any
  /// of this.
  static const String tokensKey = 'customer.orders.access_tokens';

  Future<SharedPreferences> get _preferences =>
      SharedPreferences.getInstance();

  @override
  Future<String?> readToken({required String contextKey}) async {
    final scope = orderAccessContextKey(contextKey);
    if (scope == null) {
      return null;
    }
    return _readScope(await _preferences, scope);
  }

  @override
  Future<void> writeToken({
    required String contextKey,
    required String token,
  }) async {
    final scope = orderAccessContextKey(contextKey);
    final value = token.trim();
    // A blank token is not stored at all, so it cannot overwrite a real one with
    // something that would authenticate nothing.
    if (scope == null || value.isEmpty) {
      return;
    }

    final preferences = await _preferences;
    final scopes = await _readAll(preferences);
    scopes[scope] = value;
    await preferences.setString(tokensKey, jsonEncode(scopes));
  }

  @override
  Future<void> clearToken({required String contextKey}) async {
    final scope = orderAccessContextKey(contextKey);
    if (scope == null) {
      return;
    }

    final preferences = await _preferences;
    final scopes = await _readAll(preferences);
    if (scopes.remove(scope) == null) {
      return;
    }
    await preferences.setString(tokensKey, jsonEncode(scopes));
  }

  /// Reads the stored token for an already normalized [scope].
  Future<String?> _readScope(SharedPreferences preferences, String scope) async {
    final scopes = await _readAll(preferences);
    final token = scopes[scope]?.trim() ?? '';
    return token.isEmpty ? null : token;
  }

  /// Every stored scope and token, ignoring anything unreadable.
  ///
  /// A value that is not a map of strings, or one entry of which is not a string,
  /// is dropped rather than thrown on: preferences are a local cache, and a
  /// corrupted one must not make ordering impossible.
  Future<Map<String, String>> _readAll(SharedPreferences preferences) async {
    final stored = preferences.getString(tokensKey);
    if (stored == null || stored.trim().isEmpty) {
      return <String, String>{};
    }

    Object? decoded;
    try {
      decoded = jsonDecode(stored);
    } on FormatException {
      return <String, String>{};
    }

    if (decoded is! Map) {
      return <String, String>{};
    }

    return <String, String>{
      for (final entry in decoded.entries)
        if (entry.key is String &&
            entry.value is String &&
            (entry.value! as String).trim().isNotEmpty)
          entry.key! as String: (entry.value! as String).trim(),
    };
  }
}

/// Normalizes a QR context into the key a token is stored under.
///
/// Returns `null` for a blank context, which is the only value refused: a context
/// is an opaque QR token the database mints, so there is no shape to validate here
/// and inventing one would refuse contexts the database itself accepts. The
/// database still checks the token against the table it resolves to, so a
/// mismatched pair cannot be used for anything.
///
/// The context is used verbatim rather than hashed. It is not a secret the app
/// needs to hide from its own preferences — it is the same value already in the
/// scanned link, and the thing being protected here is the *token*, which is
/// stored under this key and never in a key name of its own.
String? orderAccessContextKey(String contextKey) {
  final trimmed = contextKey.trim();
  return trimmed.isEmpty ? null : trimmed;
}