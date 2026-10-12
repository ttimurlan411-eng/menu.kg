import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:menukg_flutter/features/auth/data/models/restaurant_bootstrap_result_model.dart';
import 'package:menukg_flutter/features/auth/data/models/restaurant_summary_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Creates a restaurant through the database's secure bootstrap RPC.
class RestaurantRepository {
  /// Creates a repository backed by [SupabaseService]'s shared client.
  const RestaurantRepository() : _client = null;

  /// Creates a repository with [client] for isolated tests.
  @visibleForTesting
  const RestaurantRepository.withClient(SupabaseClient client)
    : _client = client;

  static const _createRestaurantRpc = 'create_restaurant_with_owner';

  final SupabaseClient? _client;

  SupabaseClient get _supabaseClient => _client ?? SupabaseService.client;

  /// Returns the restaurant and one active branch visible to the current user.
  Future<RestaurantSummaryModel?> getRestaurantSummary(
    String restaurantId,
  ) async {
    if (_supabaseClient.auth.currentUser == null) {
      return null;
    }

    final restaurant = await _supabaseClient
        .from('restaurants')
        .select('id, name, branches(id, name, is_active)')
        .eq('id', restaurantId)
        .maybeSingle();

    return restaurant == null ? null : RestaurantSummaryModel.fromJson(restaurant);
  }

  /// Creates a restaurant, its first branch, and an OWNER membership.
  ///
  /// Returns `null` without making an RPC call when no user is authenticated.
  /// The database derives the membership user from `auth.uid()`.
  Future<RestaurantBootstrapResultModel?> createRestaurant({
    required String name,
    required String slug,
    required String branchName,
    String? description,
    String? phone,
    String? address,
    double? latitude,
    double? longitude,
    String currency = 'KGS',
    String defaultLanguage = 'ky',
  }) async {
    final normalizedName = _requiredText(name, 'name');
    final normalizedSlug = _requiredText(slug, 'slug');
    final normalizedBranchName = _requiredText(branchName, 'branchName');

    if (_supabaseClient.auth.currentUser == null) {
      return null;
    }

    final params = <String, dynamic>{
      'p_name': normalizedName,
      'p_slug': normalizedSlug,
      'p_branch_name': normalizedBranchName,
      'p_currency': currency.trim(),
      'p_default_language': defaultLanguage.trim(),
      'p_description': ?description,
      'p_phone': ?phone,
      'p_address': ?address,
      'p_latitude': ?latitude,
      'p_longitude': ?longitude,
    };

    final response = await _supabaseClient.rpc(
      _createRestaurantRpc,
      params: params,
    );

    if (response is! List || response.length != 1 || response.single is! Map) {
      throw StateError('Restaurant bootstrap RPC returned an invalid result.');
    }

    return RestaurantBootstrapResultModel.fromJson(
      Map<String, dynamic>.from(response.single as Map),
    );
  }

  static String _requiredText(String value, String fieldName) {
    final normalizedValue = value.trim();
    if (normalizedValue.isEmpty) {
      throw ArgumentError.value(value, fieldName, 'must not be empty');
    }
    return normalizedValue;
  }
}
