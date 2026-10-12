import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_order_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads and moves the orders of a restaurant, for its signed-in staff.
///
/// Unlike the guest [OrderRepository] this needs a session: staff are identified by
/// the Supabase Auth user and their membership of the restaurant, so there is no
/// token a screen could hold instead. Everything a request is scoped by is checked
/// in the database, where it cannot be forgotten:
///
///   * a read names a restaurant and is answered only for an active member of it;
///   * a status change names only an order, and the restaurant is read from the order
///     itself, so there is no restaurant argument for a caller to get wrong.
///
/// Like [TableRepository], this checks `auth.currentUser` first and answers without
/// calling the database when nobody is signed in: there is no staff order to read
/// without a staff identity, and a request sent with no session would only be
/// refused by the database.
///
/// This step adds no screen. The repository exists so the waiter, kitchen and owner
/// screens are built on a read path and a status change that are already authorized,
/// rather than adding those screens to a direct query on the orders table, which has
/// no grant and no policy for any client role.
class StaffOrderRepository {
  /// Creates a repository backed by [SupabaseService]'s shared client.
  const StaffOrderRepository() : _client = null;

  /// Creates a repository with [client] for isolated tests.
  @visibleForTesting
  const StaffOrderRepository.withClient(SupabaseClient client) : _client = client;

  /// The database function that lists a restaurant's orders.
  ///
  /// This is the history read: newest first, every status, and a small window. The
  /// live working list uses [activeListFunctionName] instead, which is the read that
  /// cannot be crowded out by completed orders.
  static const String listFunctionName = 'staff_list_orders';

  /// The database function that lists a restaurant's active orders only.
  ///
  /// Returns the orders whose status still needs a person — PENDING, ACCEPTED,
  /// PREPARING or READY — and never SERVED or CANCELLED, so an older active order
  /// stays visible however much history has piled up behind it.
  static const String activeListFunctionName = 'staff_list_active_orders';

  /// The database function that lists a restaurant's order history, one page at a
  /// time.
  ///
  /// This is the paginated history read: every status, newest first, found by cursor
  /// rather than by OFFSET. The live working list uses [activeListFunctionName], which
  /// is the read that cannot be crowded out by completed orders.
  static const String historyListFunctionName = 'staff_list_order_history';

  /// The database function that moves one order.
  static const String setStatusFunctionName = 'staff_set_order_status';

  /// How many orders a read asks for when the caller names no limit.
  static const int defaultLimit = 100;

  /// The most orders a read may return.
  ///
  /// The same ceiling the database clamps to, so a screen cannot ask for more by
  /// passing a larger number and receive a page that silently ignores it.
  static const int maxLimit = 200;

  /// How many active orders an active read asks for when the caller names no limit.
  static const int defaultActiveLimit = 500;

  /// The most active orders an active read may return.
  ///
  /// The same ceiling `staff_list_active_orders` clamps to. It is deliberately much
  /// higher than [maxLimit]: the active set is the actionable set and must not be
  /// truncated by a history-sized window. It is still a safety bound, not a guarantee
  /// that an arbitrarily large active backlog is returned in one read.
  static const int maxActiveLimit = 1000;

  /// How many orders one history page asks for when the caller names no page size.
  static const int defaultHistoryLimit = 50;

  /// The most orders one history page may return.
  ///
  /// The same ceiling `staff_list_order_history` clamps to, so a screen cannot ask for
  /// a larger page and receive one that silently ignores the number it sent.
  static const int maxHistoryLimit = 200;

  final SupabaseClient? _client;

  SupabaseClient get _supabaseClient => _client ?? SupabaseService.client;

  /// Loads the orders of [restaurantId], newest first.
  ///
  /// [branchId] narrows the read to one branch, and is omitted from the request
  /// entirely when it is not given so the database answers for the whole restaurant.
  /// A blank [branchId] is treated as no branch rather than as a branch that matches
  /// nothing.
  ///
  /// [limit] is clamped to 1..[maxLimit] here for the same reason.
  ///
  /// Returns an empty list without calling the database when nobody is signed in or
  /// [restaurantId] is blank. Otherwise a payload that cannot be read is an empty
  /// list too, which is how [tryParseStaffOrders] reports a response belonging to
  /// another restaurant; a genuine failure throws, which the page turns into a safe
  /// message with [staffOrderListErrorMessage].
  Future<List<StaffOrderModel>> getOrders({
    required String restaurantId,
    String? branchId,
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
        // Omitted rather than sent as null, so the database's "every branch" default
        // is what answers instead of a filter that matches nothing.
        if (branch.isNotEmpty) 'p_branch_id': branch,
      },
    );

    return tryParseStaffOrders(response, restaurantId: restaurant);
  }

  /// Loads the active orders of [restaurantId], newest first.
  ///
  /// "Active" is the database's answer, not this class's: only PENDING, ACCEPTED,
  /// PREPARING and READY come back, and SERVED and CANCELLED never do. This is the
  /// live working list for the staff and kitchen screens, because it cannot be
  /// crowded out by completed orders the way the history read can.
  ///
  /// [branchId] and [limit] behave exactly as in [getOrders]: a blank branch is
  /// treated as no branch, and [limit] is clamped to 1..[maxActiveLimit]. The same
  /// no-session and blank-restaurant short-circuit, and the same parsing and error
  /// handling, apply. The payload is the same shape as [getOrders]', so
  /// [tryParseStaffOrders] reads it unchanged.
  Future<List<StaffOrderModel>> getActiveOrders({
    required String restaurantId,
    String? branchId,
    int limit = defaultActiveLimit,
  }) async {
    final restaurant = restaurantId.trim();
    final branch = branchId?.trim() ?? '';

    if (_supabaseClient.auth.currentUser == null || restaurant.isEmpty) {
      return const [];
    }

    final response = await _supabaseClient.rpc(
      activeListFunctionName,
      params: {
        'p_restaurant_id': restaurant,
        'p_limit': limit.clamp(1, maxActiveLimit),
        // Omitted rather than sent as null, so the database's "every branch" default
        // is what answers instead of a filter that matches nothing.
        if (branch.isNotEmpty) 'p_branch_id': branch,
      },
    );

    return tryParseStaffOrders(response, restaurantId: restaurant);
  }

  /// Loads one page of [restaurantId]'s order history, newest first.
  ///
  /// Every status is in the history, the terminal SERVED and CANCELLED included; this
  /// is the chronological read, not the live working list. Paging is by cursor: leave
  /// [cursor] null to ask for the first page, then pass the previous page's
  /// [StaffOrderHistoryPage.nextCursor] to ask for the one after it. The cursor is sent
  /// only when it is given, so a first page names no position and the database answers
  /// from the newest order.
  ///
  /// [branchId] and [limit] behave as in the other reads: a blank branch is treated as
  /// no branch, and [limit] is clamped to 1..[maxHistoryLimit]. The same no-session and
  /// blank-restaurant short-circuit applies, answering an empty page without calling
  /// the database. A payload that cannot be read, or that belongs to another
  /// restaurant, is an empty page too, which is how [tryParseStaffOrderHistory] reports
  /// it; a genuine failure throws, which the page turns into a safe message with
  /// [staffOrderListErrorMessage].
  Future<StaffOrderHistoryPage> getOrderHistory({
    required String restaurantId,
    String? branchId,
    int limit = defaultHistoryLimit,
    StaffOrderHistoryCursor? cursor,
  }) async {
    final restaurant = restaurantId.trim();
    final branch = branchId?.trim() ?? '';

    if (_supabaseClient.auth.currentUser == null || restaurant.isEmpty) {
      return const StaffOrderHistoryPage.empty();
    }

    final response = await _supabaseClient.rpc(
      historyListFunctionName,
      params: {
        'p_restaurant_id': restaurant,
        'p_limit': limit.clamp(1, maxHistoryLimit),
        // Omitted rather than sent as null, so the database's "every branch" default
        // is what answers instead of a filter that matches nothing.
        if (branch.isNotEmpty) 'p_branch_id': branch,
        // The cursor is two halves of one key and is sent only as a pair. A first-page
        // request names neither, which is what the database reads as "from the newest".
        if (cursor != null) ...{
          'p_before_created_at': cursor.createdAt.toUtc().toIso8601String(),
          'p_before_order_number': cursor.orderNumber,
        },
      },
    );

    return tryParseStaffOrderHistory(response, restaurantId: restaurant);
  }

  /// Moves [orderId] to [status] and reports what the database stored.
  ///
  /// Only the order id and the target status are sent. There is deliberately no
  /// restaurant argument: the database reads the restaurant from the order and checks
  /// the caller's membership of that, so a screen cannot send a restaurant it does not
  /// belong to and a client cannot be the thing that decides which orders are in
  /// reach. The status is sent as its stored value, and the lifecycle decides whether
  /// the move is legal — this class does not filter by [OrderStatus.allowedNextStatuses]
  /// before sending, because a screen that hides an impossible move is a convenience
  /// and the database refusing it is the rule.
  ///
  /// Returns `null` without calling the database when nobody is signed in or
  /// [orderId] is blank, and also when the answer is not a readable status change, so
  /// a screen shows nothing moved rather than claiming a move it cannot prove.
  ///
  /// Throws on a refusal from the database, which carries the reason: an order this
  /// staff member does not have, a move their role does not make, or a move the
  /// lifecycle refuses. [staffOrderStatusErrorMessage] turns each into safe wording.
  Future<StaffOrderStatusUpdate?> setOrderStatus({
    required String orderId,
    required OrderStatus status,
  }) async {
    final order = orderId.trim();

    if (_supabaseClient.auth.currentUser == null || order.isEmpty) {
      return null;
    }

    final response = await _supabaseClient.rpc(
      setStatusFunctionName,
      params: {
        'p_order_id': order,
        'p_new_status': status.databaseValue,
      },
    );

    return tryParseStaffOrderStatusUpdate(response);
  }
}