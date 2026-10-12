import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:menukg_flutter/features/auth/data/models/restaurant_membership_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads restaurant memberships available to the authenticated user.
class RestaurantMembershipRepository {
  /// Creates a repository backed by [SupabaseService]'s shared client.
  const RestaurantMembershipRepository() : _client = null;

  /// Creates a repository with [client] for isolated tests.
  @visibleForTesting
  const RestaurantMembershipRepository.withClient(SupabaseClient client)
    : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _supabaseClient => _client ?? SupabaseService.client;

  /// Returns the current user's active restaurant memberships.
  Future<List<RestaurantMembershipModel>> getMyMemberships() async {
    final userId = _supabaseClient.auth.currentUser?.id;
    if (userId == null) {
      return [];
    }

    final memberships = await _supabaseClient
        .from('restaurant_members')
        .select()
        .eq('user_id', userId)
        .eq('is_active', true)
        .order('created_at');

    return memberships
        .map((membership) => RestaurantMembershipModel.fromJson(membership))
        .toList();
  }

  /// Returns the current user's active membership for [restaurantId].
  Future<RestaurantMembershipModel?> getMembershipForRestaurant(
    String restaurantId,
  ) async {
    final userId = _supabaseClient.auth.currentUser?.id;
    if (userId == null) {
      return null;
    }

    final membership = await _supabaseClient
        .from('restaurant_members')
        .select()
        .eq('restaurant_id', restaurantId)
        .eq('user_id', userId)
        .eq('is_active', true)
        .maybeSingle();

    return membership == null
        ? null
        : RestaurantMembershipModel.fromJson(membership);
  }
}
