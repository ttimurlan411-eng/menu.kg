import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/menu_item_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads and mutates menu items for a single restaurant.
///
/// Every query is scoped with `restaurant_id` so the UI can never target
/// another restaurant. Row Level Security remains the final security boundary:
/// an authenticated member can only see rows for restaurants they belong to,
/// and only OWNER/MANAGER members can create, update, or delete menu items.
class MenuItemRepository {
  /// Creates a repository backed by [SupabaseService]'s shared client.
  const MenuItemRepository() : _client = null;

  /// Creates a repository with [client] for isolated tests.
  @visibleForTesting
  const MenuItemRepository.withClient(SupabaseClient client)
    : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _supabaseClient => _client ?? SupabaseService.client;

  /// Returns all menu items for [restaurantId], sorted by their display order.
  Future<List<MenuItemModel>> getMenuItems(String restaurantId) async {
    if (_supabaseClient.auth.currentUser == null) {
      return [];
    }

    final rows = await _supabaseClient
        .from('menu_items')
        .select()
        .eq('restaurant_id', restaurantId)
        .order('sort_order', ascending: true)
        .order('name', ascending: true);

    return rows.map((row) => MenuItemModel.fromJson(row)).toList();
  }

  /// Creates a new menu item for [restaurantId] under [categoryId].
  ///
  /// Returns `null` without calling the database when no user is signed in.
  Future<MenuItemModel?> createMenuItem({
    required String restaurantId,
    required String categoryId,
    required String name,
    required double price,
    bool isAvailable = true,
  }) async {
    if (_supabaseClient.auth.currentUser == null) {
      return null;
    }

    final row = await _supabaseClient
        .from('menu_items')
        .insert({
          'restaurant_id': restaurantId,
          'category_id': categoryId,
          'name': name,
          'price': price,
          'is_available': isAvailable,
        })
        .select()
        .single();

    return MenuItemModel.fromJson(row);
  }

  /// Updates an existing menu item, scoped to [restaurantId].
  Future<MenuItemModel?> updateMenuItem({
    required String restaurantId,
    required String menuItemId,
    required String categoryId,
    required String name,
    required double price,
    required bool isAvailable,
  }) async {
    if (_supabaseClient.auth.currentUser == null) {
      return null;
    }

    final row = await _supabaseClient
        .from('menu_items')
        .update({
          'category_id': categoryId,
          'name': name,
          'price': price,
          'is_available': isAvailable,
        })
        .eq('id', menuItemId)
        .eq('restaurant_id', restaurantId)
        .select()
        .maybeSingle();

    return row == null ? null : MenuItemModel.fromJson(row);
  }

  /// Deletes an existing menu item, scoped to [restaurantId].
  ///
  /// Deleting also removes related images, because `menu_item_images`
  /// reference `menu_items` with `on delete cascade`.
  Future<void> deleteMenuItem({
    required String restaurantId,
    required String menuItemId,
  }) async {
    if (_supabaseClient.auth.currentUser == null) {
      return;
    }

    await _supabaseClient
        .from('menu_items')
        .delete()
        .eq('id', menuItemId)
        .eq('restaurant_id', restaurantId);
  }
}