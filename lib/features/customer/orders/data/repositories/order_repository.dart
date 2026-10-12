import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:menukg_flutter/features/customer/cart/data/cart_controller.dart';
import 'package:menukg_flutter/features/customer/cart/data/models/cart_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Places customer orders from a table's cart.
///
/// Like [PublicMenuRepository] and the reservation repository this works for a
/// signed-out guest, because guests have no account in this project. It therefore
/// never checks `auth.currentUser`: the QR token of the table is the only
/// restaurant, branch and table context a caller supplies, and the database
/// resolves what that token may reach.
///
/// The repository never receives or sends a restaurant, branch or table id, and
/// never sends a price or a product name. It sends menu item ids and quantities
/// only, and the database reads every amount from the live menu of the restaurant
/// the token resolved to. That is what stops one restaurant reaching another's
/// order data, and it is enforced in the database rather than trusted from here.
class OrderRepository {
  /// Creates a repository backed by [SupabaseService]'s shared client.
  const OrderRepository() : _client = null;

  /// Creates a repository with [client] for isolated tests.
  @visibleForTesting
  const OrderRepository.withClient(SupabaseClient client) : _client = client;

  /// Places an order for the table whose QR code the guest scanned.
  static const String createFunctionName = 'create_table_order';

  /// Returns the orders belonging to one guest order access token.
  static const String listFunctionName = 'guest_orders';

  /// Orders everything the guest currently has in [cart] for [contextKey].
  ///
  /// This is the entry point for turning the live cart into a stored order, so a
  /// caller does not have to read the lines out of the controller itself and
  /// cannot forget to use the context the cart was built for. The QR token is
  /// passed separately because the cart deliberately does not know it is a
  /// restaurant, branch or table: [contextKey] and [qrToken] are the same value
  /// for the guest flow, and naming them separately keeps the cart free of that
  /// meaning.
  ///
  /// [offeredItemIds] is the set the already loaded menu still offers, and a line
  /// outside it is left out rather than failed on, so a dish switched off after it
  /// was added does not block the rest of the order. When it is null nothing is
  /// known about availability and every line is sent, which the database still
  /// checks against the live menu.
  ///
  /// Nothing is read back out of the cart to be stored. The cart supplies item ids
  /// and quantities; every price and name comes back from the database, which is
  /// what makes [createOrder] the only thing that has to be trusted.
  ///
  /// Returns `null` for an empty or fully unavailable cart, or a blank token,
  /// without touching the database, exactly as [createOrder] does, and throws on a
  /// genuine failure.
  Future<CreatedOrderModel?> createOrderFromCart({
    required String qrToken,
    required CartController cart,
    required String contextKey,
    Set<String>? offeredItemIds,
    String? accessToken,
  }) {
    final lines = cart.linesFor(contextKey).where(
      (CartLineModel line) => offeredItemIds?.contains(line.itemId) ?? true,
    );

    return createOrder(
      qrToken: qrToken,
      lines: lines.toList(),
      accessToken: accessToken,
    );
  }

  final SupabaseClient? _client;

  SupabaseClient get _supabaseClient => _client ?? SupabaseService.client;

  /// Orders every line of [lines], which must be the cart of one table.
  ///
  /// [lines] is the existing local cart, reused as is rather than translated into
  /// a second structure: the only thing this needs from a cart line is the menu
  /// item id and the quantity, because the price and the name are the database's
  /// to snapshot. [qrToken] is the table the cart was built from.
  ///
  /// [accessToken] is the guest's existing order token when they have one, so a
  /// second order lands under the same identity a later read or cancel will scope
  /// by. It is omitted from the request when absent, and the database mints one.
  ///
  /// Returns `null` without touching the database when there is nothing to order
  /// or the token is blank, so an empty cart can never become an order, and when
  /// the QR token resolves to nothing: an unknown, deleted or inactive table is
  /// deliberately indistinguishable to a guest from any other unresolvable code.
  ///
  /// Throws on a genuine failure, which the page turns into a safe message: a
  /// dish that has since been switched off, or one this restaurant does not serve.
  Future<CreatedOrderModel?> createOrder({
    required String qrToken,
    required List<CartLineModel> lines,
    String? accessToken,
  }) async {
    final token = qrToken.trim();
    final items = buildOrderItemPayload(lines);

    if (token.isEmpty || items.isEmpty) {
      return null;
    }

    final response = await _supabaseClient.rpc(
      createFunctionName,
      params: {
        'p_qr_token': token,
        'p_items': items,
        // Omitted when the guest has no token yet, so the database mints one.
        if (accessToken != null && accessToken.trim().isNotEmpty)
          'p_access_token': accessToken.trim(),
      },
    );

    return tryParseCreatedOrder(response);
  }

  /// Loads the orders created with [accessToken].
  ///
  /// This is the read side of the same credential [createOrder] writes: the token
  /// the database returned once and the app has kept on this device is the only
  /// thing sent, so every order this device placed from this QR context comes back
  /// under the one identity, newest first, exactly as the database ordered them.
  ///
  /// Nothing about a restaurant, branch, table or order is sent, so a caller cannot
  /// ask for another guest's orders or another restaurant's: the database filters
  /// by the token alone. Reading back never reveals the token in the answer — the
  /// payload holds the guest's own orders and nothing else.
  ///
  /// An absent or empty token never reaches the database: there is nothing to ask
  /// for, and a device that never ordered from this menu simply has no orders.
  /// Throws on a genuine failure, which the page turns into a safe message.
  Future<List<OrderModel>> getMyOrders(String? accessToken) async {
    final token = accessToken?.trim() ?? '';
    if (token.isEmpty) {
      return const [];
    }

    final response = await _supabaseClient.rpc(
      listFunctionName,
      params: {'p_access_token': token},
    );

    return tryParseOrders(response);
  }
}

/// Turns cart lines into the `p_items` array the database expects.
///
/// Each entry is `{"item_id": ..., "quantity": ...}` and nothing else. A line at
/// or below [minimumCartQuantity] is dropped rather than sent, and duplicates are
/// collapsed by keeping the highest quantity, because the database treats the
/// same dish on two lines as a malformed request — the cart merges a dish into a
/// single line, so this only guards a hand-built list.
///
/// The result is a `List<Map<String, Object>>` rather than a json string because
/// postgrest encodes it: sending a pre-encoded string would double-encode it.
List<Map<String, Object>> buildOrderItemPayload(List<CartLineModel> lines) {
  final quantitiesByItemId = <String, int>{};

  for (final line in lines) {
    final itemId = line.itemId.trim();
    if (itemId.isEmpty || line.quantity < minimumCartQuantity) {
      continue;
    }
    final existing = quantitiesByItemId[itemId];
    quantitiesByItemId[itemId] =
        existing == null || existing > line.quantity ? existing ?? line.quantity : line.quantity;
  }

  return quantitiesByItemId.entries
      .map(
        (MapEntry<String, int> entry) => <String, Object>{
          'item_id': entry.key,
          'quantity': entry.value,
        },
      )
      .toList();
}
