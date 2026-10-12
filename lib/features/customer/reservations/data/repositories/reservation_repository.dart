import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Creates, reads and cancels the reservations of one guest.
///
/// Like the public menu repository this works for a signed-out guest, because
/// guests have no account in this project. It therefore never checks
/// `auth.currentUser`: ownership is proved by the opaque access token instead,
/// and the database is the only thing that decides what that token may see.
///
/// The repository never receives or sends a restaurant, branch or table id. A
/// reservation is always created for the table that [qrToken] resolves to, and
/// every read is scoped to the guest's own token, so a caller cannot reach
/// another guest or another restaurant.
class ReservationRepository {
  /// Creates a repository backed by [SupabaseService]'s shared client.
  const ReservationRepository() : _client = null;

  /// Creates a repository with [client] for isolated tests.
  @visibleForTesting
  const ReservationRepository.withClient(SupabaseClient client)
    : _client = client;

  /// Creates a reservation and returns it with the guest's access token.
  static const String createFunctionName = 'create_table_reservation';

  /// Returns the reservations belonging to one access token.
  static const String listFunctionName = 'guest_reservations';

  /// Cancels one of the guest's own reservations.
  static const String cancelFunctionName = 'cancel_guest_reservation';

  final SupabaseClient? _client;

  SupabaseClient get _supabaseClient => _client ?? SupabaseService.client;

  /// Books the table that [qrToken] resolves to for [date] at [hour]:[minute].
  ///
  /// [accessToken] is the guest's existing token when they have one, so a
  /// returning guest's new reservation joins the same "My Reservations" list.
  ///
  /// Returns `null` when the token is empty, malformed, unknown, or belongs to a
  /// table, branch or restaurant that is no longer active: the same set of cases
  /// the public menu reports as "no menu", and deliberately indistinguishable to
  /// a guest.
  ///
  /// Throws on a genuine failure, which the page turns into a safe message: an
  /// already booked slot, a day in the past, or a party larger than the table
  /// seats.
  Future<CreatedReservationModel?> createReservation({
    required String qrToken,
    required DateTime date,
    required int hour,
    required int minute,
    required String guestName,
    required int guestCount,
    String? accessToken,
  }) async {
    final token = qrToken.trim();
    final name = guestName.trim();
    if (token.isEmpty || name.isEmpty || guestCount < 1) {
      return null;
    }

    final response = await _supabaseClient.rpc(
      createFunctionName,
      params: {
        'p_qr_token': token,
        'p_reserved_date': formatReservationDateParam(date),
        'p_reserved_time': formatReservationClock(hour: hour, minute: minute),
        'p_guest_name': name,
        'p_guest_count': guestCount,
        // Omitted when the guest has no token yet, so the database mints one.
        if (accessToken != null && accessToken.trim().isNotEmpty)
          'p_access_token': accessToken.trim(),
      },
    );

    return tryParseCreatedReservation(response);
  }

  /// Loads the reservations created with [accessToken].
  ///
  /// An absent or empty token never reaches the database: there is nothing to
  /// ask for, and the guest simply has no reservations on this device yet.
  Future<List<ReservationModel>> getMyReservations(String? accessToken) async {
    final token = accessToken?.trim() ?? '';
    if (token.isEmpty) {
      return const [];
    }

    final response = await _supabaseClient.rpc(
      listFunctionName,
      params: {'p_access_token': token},
    );

    return tryParseReservations(response);
  }

  /// Cancels one of the guest's own reservations.
  ///
  /// Returns `false` when the database changed nothing, which is what a
  /// reservation id belonging to another guest looks like.
  Future<bool> cancelReservation({
    required String accessToken,
    required String reservationId,
  }) async {
    final token = accessToken.trim();
    if (token.isEmpty || reservationId.trim().isEmpty) {
      return false;
    }

    final response = await _supabaseClient.rpc(
      cancelFunctionName,
      params: {
        'p_access_token': token,
        'p_reservation_id': reservationId.trim(),
      },
    );

    return response == true;
  }
}

/// Formats a day as the `date` parameter the database expects, `2026-10-05`.
String formatReservationDateParam(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
