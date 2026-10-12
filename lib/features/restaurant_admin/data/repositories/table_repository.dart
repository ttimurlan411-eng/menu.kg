import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/table_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads and mutates tables for a single restaurant.
///
/// Every query is scoped with `restaurant_id` so the UI can never target
/// another restaurant. Row Level Security remains the final security boundary:
/// an authenticated member can only see rows for restaurants they belong to,
/// and only OWNER/MANAGER members can create, update, or delete tables.
///
/// `qr_token` is never written here. The database generates it with
/// `gen_random_uuid()` behind a unique index, so a table keeps a stable QR code
/// for its whole lifetime and a printed code never silently breaks.
class TableRepository {
  /// Creates a repository backed by [SupabaseService]'s shared client.
  const TableRepository() : _client = null;

  /// Creates a repository with [client] for isolated tests.
  @visibleForTesting
  const TableRepository.withClient(SupabaseClient client)
    : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _supabaseClient => _client ?? SupabaseService.client;

  /// Returns all tables for [restaurantId], optionally narrowed to one branch.
  Future<List<TableModel>> getTables(
    String restaurantId, {
    String? branchId,
  }) async {
    if (_supabaseClient.auth.currentUser == null) {
      return [];
    }

    var query = _supabaseClient
        .from('tables')
        .select()
        .eq('restaurant_id', restaurantId);

    if (branchId != null) {
      query = query.eq('branch_id', branchId);
    }

    final rows = await query
        .order('table_number', ascending: true)
        .order('name', ascending: true);

    return rows.map((row) => TableModel.fromJson(row)).toList();
  }

  /// Creates a new table for [restaurantId] in [branchId].
  ///
  /// Returns `null` without calling the database when no user is signed in.
  /// The database rejects a `branchId` that belongs to another restaurant
  /// because of the composite foreign key on `(branch_id, restaurant_id)`.
  Future<TableModel?> createTable({
    required String restaurantId,
    required String branchId,
    required String tableNumber,
    int capacity = 1,
    String? name,
    String? zone,
  }) async {
    if (_supabaseClient.auth.currentUser == null) {
      return null;
    }

    final row = await _supabaseClient
        .from('tables')
        .insert({
          'restaurant_id': restaurantId,
          'branch_id': branchId,
          'table_number': tableNumber,
          'name': name,
          'capacity': capacity,
          'zone': zone,
        })
        .select()
        .single();

    return TableModel.fromJson(row);
  }

  /// Updates an existing table, scoped to [restaurantId].
  ///
  /// `qr_token` is intentionally left untouched so printed QR codes keep
  /// working after a rename.
  Future<TableModel?> updateTable({
    required String restaurantId,
    required String tableId,
    required String tableNumber,
    required int capacity,
    String? name,
    String? zone,
    bool isActive = true,
  }) async {
    if (_supabaseClient.auth.currentUser == null) {
      return null;
    }

    final row = await _supabaseClient
        .from('tables')
        .update({
          'table_number': tableNumber,
          'name': name,
          'capacity': capacity,
          'zone': zone,
          'is_active': isActive,
        })
        .eq('id', tableId)
        .eq('restaurant_id', restaurantId)
        .select()
        .maybeSingle();

    return row == null ? null : TableModel.fromJson(row);
  }

  /// Updates the live status of a table, scoped to [restaurantId].
  Future<TableModel?> updateTableStatus({
    required String restaurantId,
    required String tableId,
    required String status,
  }) async {
    if (_supabaseClient.auth.currentUser == null) {
      return null;
    }

    final row = await _supabaseClient
        .from('tables')
        .update({'status': status})
        .eq('id', tableId)
        .eq('restaurant_id', restaurantId)
        .select()
        .maybeSingle();

    return row == null ? null : TableModel.fromJson(row);
  }

  /// Deletes an existing table, scoped to [restaurantId].
  ///
  /// Returns without calling the database when no user is signed in.
  Future<void> deleteTable({
    required String restaurantId,
    required String tableId,
  }) async {
    if (_supabaseClient.auth.currentUser == null) {
      return;
    }

    await _supabaseClient
        .from('tables')
        .delete()
        .eq('id', tableId)
        .eq('restaurant_id', restaurantId);
  }
}
