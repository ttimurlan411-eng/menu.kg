import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';
import 'package:menukg_flutter/features/customer/reservations/data/repositories/reservation_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_reservation_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads and cancels the reservations of a restaurant, for its signed-in staff.
///
/// Unlike the guest [ReservationRepository] this needs a session: staff are
/// identified by the Supabase Auth user and their membership of the restaurant,
/// so there is no token a screen could hold instead. Everything a request is
/// scoped by is checked in the database, where it cannot be forgotten:
///
///   * a read names a restaurant and is answered only for an active member of it;
///   * a status change names only a reservation, and the restaurant is read from
///     the reservation itself, so there is no restaurant argument for a caller to
///     get wrong.
///
/// Like [StaffOrderRepository], this checks `auth.currentUser` first and answers
/// without calling the database when nobody is signed in: there is no staff
/// reservation to read without a staff identity, and a request sent with no
/// session would only be refused by the database.
///
/// This step adds no screen. The repository exists so the Bookings screen is
/// built on a read path and a cancellation that are already authorized, rather
/// than adding that screen to a direct query on the reservations table, which
/// has no grant and no policy for any client role.
class StaffReservationRepository {
  /// Creates a repository backed by [SupabaseService]'s shared client.
  const StaffReservationRepository() : _client = null;

  /// Creates a repository with [client] for isolated tests.
  @visibleForTesting
  const StaffReservationRepository.withClient(SupabaseClient client)
    : _client = client;

  /// The database function that lists a restaurant's reservations.
  static const String listFunctionName = 'staff_list_reservations';

  /// The database function that cancels one reservation.
  static const String setStatusFunctionName = 'staff_set_reservation_status';

  /// How many reservations a read asks for when the caller names no limit.
  static const int defaultLimit = 100;

  /// The most reservations a read may return.
  ///
  /// The same ceiling the database clamps to, so a screen cannot ask for more by
  /// passing a larger number and receive a page that silently ignores it.
  static const int maxLimit = 100;

  final SupabaseClient? _client;

  SupabaseClient get _supabaseClient => _client ?? SupabaseService.client;

  /// Loads the reservations of [restaurantId], oldest booking first.
  ///
  /// [branchId] narrows the read to one branch and [date] to one day; each is
  /// omitted from the request entirely when it is not given, so the database
  /// answers for the whole restaurant and for every day it has bookings. A blank
  /// [branchId] is treated as no branch rather than as a branch that matches
  /// nothing.
  ///
  /// [limit] is clamped to 1..[maxLimit] here for the same reason.
  ///
  /// Returns an empty list without calling the database when nobody is signed in
  /// or [restaurantId] is blank. Otherwise a payload that cannot be read is an
  /// empty list too, which is how [tryParseStaffReservations] reports a response
  /// belonging to another restaurant; a genuine failure throws, which the screen
  /// turns into a safe message with [staffReservationListErrorMessage].
  Future<List<StaffReservationModel>> getReservations({
    required String restaurantId,
    String? branchId,
    DateTime? date,
    int limit = defaultLimit,
  }) async {
    final restaurant = restaurantId.trim();
    final branch = branchId?.trim() ?? '';

    if (_supabaseClient.auth.currentUser == null || restaurant.isEmpty) {
      return const [];
    }

    final response = await _supabaseClient.rpc(
      listFunctionName,
      params: {
        'p_restaurant_id': restaurant,
        'p_limit': limit.clamp(1, maxLimit),
        // Omitted rather than sent as null, so the database's "every branch" and
        // "every day" defaults are what answer instead of a filter that matches
        // nothing.
        if (branch.isNotEmpty) 'p_branch_id': branch,
        if (date != null) 'p_date': formatReservationDateParam(date),
      },
    );

    return tryParseStaffReservations(response, restaurantId: restaurant);
  }

  /// Cancels [reservationId] and reports what the database stored.
  ///
  /// Only the reservation id and the target status are sent. There is
  /// deliberately no restaurant argument: the database reads the restaurant from
  /// the reservation and checks the caller's membership of that, so a screen
  /// cannot send a restaurant it does not belong to and a client cannot be the
  /// thing that decides which reservations are in reach. The status is sent as
  /// its stored value; the lifecycle decides whether the move is legal, and this
  /// class does not filter before sending, because a screen that hides an
  /// impossible move is a convenience and the database refusing it is the rule.
  ///
  /// Returns `null` without calling the database when nobody is signed in or
  /// [reservationId] is blank, and also when the answer is not a readable status
  /// change, so a screen shows nothing changed rather than claiming a move it
  /// cannot prove.
  ///
  /// Throws on a refusal from the database, which carries the reason: a
  /// reservation this staff member does not have, a role with no reservation
  /// duties, or a move the lifecycle refuses.
  /// [staffReservationStatusErrorMessage] turns each into safe wording.
  Future<StaffReservationStatusUpdate?> setReservationStatus({
    required String reservationId,
    required ReservationStatus status,
  }) async {
    final reservation = reservationId.trim();

    if (_supabaseClient.auth.currentUser == null || reservation.isEmpty) {
      return null;
    }

    final response = await _supabaseClient.rpc(
      setStatusFunctionName,
      params: {
        'p_reservation_id': reservation,
        'p_new_status': status.databaseValue,
      },
    );

    return tryParseStaffReservationStatusUpdate(response);
  }
}
