import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_member_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads the members of a restaurant, for its signed-in owners and managers.
///
/// Unlike the guest reads this needs a session: staff are identified by the
/// Supabase Auth user, so there is no token a screen could hold instead. What a
/// request is scoped by is checked in the database, where it cannot be forgotten:
/// the read names a restaurant and is answered only for an active OWNER or MANAGER
/// of it. A caller with any other role, a deactivated member and a non-member are
/// refused by the database, not by this class.
///
/// Like [StaffOrderRepository] and [StaffReservationRepository], this checks
/// `auth.currentUser` first and answers without calling the database when nobody is
/// signed in: there is no staff list without a staff identity, and a request sent
/// with no session would only be refused by the database.
///
/// This is the foundation of staff management. It only lists; it creates no member,
/// changes no role and activates or deactivates nobody.
class StaffMemberRepository {
  /// Creates a repository backed by [SupabaseService]'s shared client.
  const StaffMemberRepository() : _client = null;

  /// Creates a repository with [client] for isolated tests.
  @visibleForTesting
  const StaffMemberRepository.withClient(SupabaseClient client)
    : _client = client;

  /// The database function that lists a restaurant's members.
  static const String listFunctionName = 'staff_list_restaurant_members';

  final SupabaseClient? _client;

  SupabaseClient get _supabaseClient => _client ?? SupabaseService.client;

  /// Loads the members of [restaurantId].
  ///
  /// Returns an empty list without calling the database when nobody is signed in or
  /// [restaurantId] is blank. Otherwise a payload that cannot be read is an empty
  /// list too, which is how [tryParseStaffMembers] reports a response belonging to
  /// another restaurant; a genuine failure throws, which the screen turns into a
  /// safe message with [staffMemberListErrorMessage].
  Future<List<StaffMemberModel>> getMembers({
    required String restaurantId,
  }) async {
    final restaurant = restaurantId.trim();

    if (_supabaseClient.auth.currentUser == null || restaurant.isEmpty) {
      return const [];
    }

    final response = await _supabaseClient.rpc(
      listFunctionName,
      params: {'p_restaurant_id': restaurant},
    );

    return tryParseStaffMembers(response, restaurantId: restaurant);
  }
}
