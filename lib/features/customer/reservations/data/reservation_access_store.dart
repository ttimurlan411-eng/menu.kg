import 'package:shared_preferences/shared_preferences.dart';

/// Where the guest's reservation access token is kept between app runs.
///
/// The token is the guest's only credential: it is what "My Reservations" reads,
/// so it has to outlive a single page. This is not an account and not a session
/// — there is nothing to sign in with, no server-side identity, and no way to
/// reach a reservation without the token. Keeping it on the device means a
/// guest who clears app data, or who uses another device, has no access to past
/// reservations, which is the honest limit of an anonymous design and the reason
/// a real customer account would be needed to cross devices.
abstract interface class ReservationAccessStore {
  /// The stored token, or `null` when this device has never made a reservation.
  Future<String?> readToken();

  /// Stores [token] as the guest's token, replacing any earlier one.
  Future<void> writeToken(String token);

  /// Forgets the token, which leaves the reservations in the database
  /// unreachable from this device.
  Future<void> clearToken();
}

/// Keeps the token in the platform's local preferences for this app.
///
/// The token never leaves the device in a readable form: it is only sent back to
/// the database, which matches it against the reservations it owns.
class DeviceReservationAccessStore implements ReservationAccessStore {
  const DeviceReservationAccessStore();

  /// Namespaced so it can never collide with another preference.
  static const String tokenKey = 'customer.reservations.access_token';

  Future<SharedPreferences> get _preferences =>
      SharedPreferences.getInstance();

  @override
  Future<String?> readToken() async {
    final token = (await _preferences).getString(tokenKey);
    final trimmed = token?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<void> writeToken(String token) async {
    await (await _preferences).setString(tokenKey, token.trim());
  }

  @override
  Future<void> clearToken() async {
    await (await _preferences).remove(tokenKey);
  }
}
