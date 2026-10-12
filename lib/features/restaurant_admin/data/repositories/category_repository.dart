import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/category_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads and mutates categories for a single restaurant.
///
/// Every query is scoped with `restaurant_id` so the UI can never target
/// another restaurant. Row Level Security remains the final security boundary:
/// an authenticated member can only see rows for restaurants they belong to,
/// and only OWNER/MANAGER members can create, update, or delete categories.
class CategoryRepository {
  /// Creates a repository backed by [SupabaseService]'s shared client.
  const CategoryRepository() : _client = null;

  /// Creates a repository with [client] for isolated tests.
  @visibleForTesting
  const CategoryRepository.withClient(SupabaseClient client)
    : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _supabaseClient => _client ?? SupabaseService.client;

  /// Returns all categories for [restaurantId], sorted by their display order.
  Future<List<CategoryModel>> getCategories(String restaurantId) async {
    if (_supabaseClient.auth.currentUser == null) {
      return [];
    }

    final rows = await _supabaseClient
        .from('categories')
        .select()
        .eq('restaurant_id', restaurantId)
        .order('sort_order', ascending: true)
        .order('name', ascending: true);

    return rows
        .map((row) => CategoryModel.fromJson(row))
        .toList();
  }

  /// Creates a new category for [restaurantId].
  ///
  /// Returns `null` without calling the database when no user is signed in.
  Future<CategoryModel?> createCategory({
    required String restaurantId,
    required String name,
    int sortOrder = 0,
    bool isActive = true,
  }) async {
    if (_supabaseClient.auth.currentUser == null) {
      return null;
    }

    final row = await _supabaseClient
        .from('categories')
        .insert({
          'restaurant_id': restaurantId,
          'name': name,
          'sort_order': sortOrder,
          'is_active': isActive,
        })
        .select()
        .single();

    return CategoryModel.fromJson(row);
  }

  /// Updates an existing category, scoped to [restaurantId].
  Future<CategoryModel?> updateCategory({
    required String restaurantId,
    required String categoryId,
    required String name,
    required int sortOrder,
    required bool isActive,
  }) async {
    if (_supabaseClient.auth.currentUser == null) {
      return null;
    }

    final row = await _supabaseClient
        .from('categories')
        .update({
          'name': name,
          'sort_order': sortOrder,
          'is_active': isActive,
        })
        .eq('id', categoryId)
        .eq('restaurant_id', restaurantId)
        .select()
        .maybeSingle();

    return row == null ? null : CategoryModel.fromJson(row);
  }

  /// Deletes an existing category, scoped to [restaurantId].
  ///
  /// Returns without calling the database when no user is signed in.
  ///
  /// Deleting is rejected by the database when related records exist, because
  /// `menu_items` reference categories with `on delete restrict`.
  Future<void> deleteCategory({
    required String restaurantId,
    required String categoryId,
  }) async {
    if (_supabaseClient.auth.currentUser == null) {
      return;
    }

    await _supabaseClient
        .from('categories')
        .delete()
        .eq('id', categoryId)
        .eq('restaurant_id', restaurantId);
  }
}
