import 'dart:async';
import 'dart:convert';

import 'package:menukg_flutter/features/customer/cart/data/models/cart_model.dart';
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/order_access_store.dart';
import 'package:menukg_flutter/features/customer/orders/data/repositories/order_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A token shaped like the two uuids the database mints into one.
const String guestOrderAccessToken =
    'a1b2c3d4-1111-4111-8111-111111111111e5f60718-2222-4333-8444-555555555555';

/// The token of a second guest, who never sees the first guest's orders.
const String otherGuestOrderAccessToken =
    'b2c3d4e5-1111-4111-8111-111111111111f6071822-3333-4444-8555-666666666666';

/// The token of a guest at another table, which must stay a separate context.
const String otherContextOrderAccessToken =
    'c3d4e5f6-1111-4111-8111-11111111111107182933-4444-4555-8666-777777777777';

/// Builds one entry of the `create_table_order` payload.
Map<String, dynamic> buildOrderLineJson({
  String menuItemId = '77777777-7777-7777-7777-777777777777',
  String productName = 'Beshbarmak',
  num unitPrice = 450,
  int quantity = 2,
  num? lineTotal,
}) {
  return {
    'menu_item_id': menuItemId,
    'product_name': productName,
    'unit_price': unitPrice,
    'quantity': quantity,
    'line_total': lineTotal ?? unitPrice * quantity,
  };
}

/// Builds the `order` object inside the `create_table_order` payload.
///
/// Exactly the fields the database function sends: display labels, the guest's
/// own order id, the snapshotted amounts, and no restaurant, branch or table id.
Map<String, dynamic> buildOrderJson({
  String id = '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136',
  int orderNumber = 1043,
  String status = 'PENDING',
  String currency = 'KGS',
  num total = 900,
  int itemCount = 2,
  String restaurantName = 'Ala-Too',
  String branchName = 'Center',
  String tableNumber = '12',
  String? tableName = 'Window',
  String createdAt = '2026-10-05T14:22:31.504534+00:00',
  List<Map<String, dynamic>>? items,
}) {
  return {
    'id': id,
    'order_number': orderNumber,
    'status': status,
    'currency': currency,
    'total': total,
    'item_count': itemCount,
    'restaurant_name': restaurantName,
    'branch_name': branchName,
    'table': {'number': tableNumber, 'name': tableName},
    'items': items ?? [buildOrderLineJson()],
    'created_at': createdAt,
  };
}

/// Builds the whole `create_table_order` rpc payload.
Map<String, dynamic> buildCreatedOrderJson({
  String accessToken = guestOrderAccessToken,
  Map<String, dynamic>? order,
}) {
  return {'access_token': accessToken, 'order': order ?? buildOrderJson()};
}

/// Wraps a payload the way postgrest does for a json-returning function.
String encodeOrderRpcResult(Object? payload) => jsonEncode(payload);

/// Builds the whole `guest_orders` rpc payload, which is the order history of one
/// token.
///
/// Exactly the fields `guest_orders` sends: the same `order` object
/// `create_table_order` returns, so one model reads both. No access token and no
/// restaurant, branch or table id.
Map<String, dynamic> buildGuestOrdersJson({
  List<Map<String, dynamic>>? orders,
}) {
  return {'orders': orders ?? [buildOrderJson()]};
}

/// An order model built without going through json, for page-level tests.
OrderModel buildOrderModel({
  String id = '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136',
  int orderNumber = 1043,
  String status = 'PENDING',
  String currency = 'KGS',
  num total = 900,
  int itemCount = 2,
  String restaurantName = 'Ala-Too',
  String branchName = 'Center',
  String tableNumber = '12',
  String? tableName = 'Window',
  String createdAt = '2026-10-05T14:22:31.504534+00:00',
  List<OrderLineModel>? lines,
}) {
  return OrderModel(
    id: id,
    orderNumber: orderNumber,
    status: OrderStatus.fromDatabase(status),
    currency: currency,
    totalMinorUnits: (total * 100).round(),
    itemCount: itemCount,
    restaurantName: restaurantName,
    branchName: branchName,
    table: PublicTableInfo(number: tableNumber, name: tableName),
    lines: lines ?? buildOrderLinesModel(),
    createdAt: DateTime.parse(createdAt),
  );
}

/// The default ordered lines: one dish, twice, at the snapshotted price.
List<OrderLineModel> buildOrderLinesModel() => const [
  OrderLineModel(
    menuItemId: '77777777-7777-7777-7777-777777777777',
    productName: 'Beshbarmak',
    unitPriceMinorUnits: 45000,
    quantity: 2,
    lineTotalMinorUnits: 90000,
  ),
];

/// An order model of another guest, in another restaurant, at another table.
///
/// Used to prove that nothing about another context can end up on this one's list.
OrderModel buildForeignOrderModel() => buildOrderModel(
  id: '1b0d6f0e-0000-4000-8000-000000000009',
  orderNumber: 7,
  total: 100,
  itemCount: 1,
  restaurantName: 'Beshkempir',
  branchName: 'Airport',
  tableNumber: '1',
  tableName: null,
  lines: const [
    OrderLineModel(
      menuItemId: '99999999-9999-9999-9999-999999999999',
      productName: 'Foreign Dish',
      unitPriceMinorUnits: 10000,
      quantity: 1,
      lineTotalMinorUnits: 10000,
    ),
  ],
);

const PublicTableInfo orderTestTable = PublicTableInfo(
  number: '12',
  name: 'Window',
);

/// Builds an order model without going through json, for page-level tests.
CreatedOrderModel buildCreatedOrderModel({
  String accessToken = guestOrderAccessToken,
  int orderNumber = 1043,
  num total = 900,
  List<OrderLineModel>? lines,
}) {
  return CreatedOrderModel(
    accessToken: accessToken,
    order: OrderModel(
      id: '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136',
      orderNumber: orderNumber,
      status: OrderStatus.pending,
      currency: 'KGS',
      totalMinorUnits: (total * 100).round(),
      itemCount: 2,
      restaurantName: 'Ala-Too',
      branchName: 'Center',
      table: orderTestTable,
      lines: lines ??
          const [
            OrderLineModel(
              menuItemId: '77777777-7777-7777-7777-777777777777',
              productName: 'Beshbarmak',
              unitPriceMinorUnits: 45000,
              quantity: 2,
              lineTotalMinorUnits: 90000,
            ),
          ],
      createdAt: DateTime.parse('2026-10-05T14:22:31.504534+00:00'),
    ),
  );
}

/// An order repository that answers from memory and records every call.
///
/// Used by the page tests, where the interesting behaviour is what the page does
/// with an answer, not the request postgrest would send.
class FakeOrderRepository extends OrderRepository {
  FakeOrderRepository({this.created, this.error, this.listError, Map<String, List<OrderModel>>? ordersByToken})
    : ordersByToken = ordersByToken ?? const {};

  /// Returned by [createOrder]; `null` models a QR token the database could not
  /// resolve, which is the same answer an unknown or inactive table gets.
  CreatedOrderModel? created;

  /// Thrown by [createOrder], modelling a failed rpc.
  Object? error;

  /// Thrown by [getMyOrders], modelling a failed read.
  Object? listError;

  /// The orders each token owns, keyed by the token the database minted.
  ///
  /// Keyed rather than a flat list so the fake behaves like the database: an
  /// unknown, empty or other guest's token answers with nothing at all, which is
  /// what makes it usable for proving that a page only ever sees its own orders.
  final Map<String, List<OrderModel>> ordersByToken;

  final List<Map<String, Object?>> calls = [];
  final List<String?> listCalls = [];

  @override
  Future<CreatedOrderModel?> createOrder({
    required String qrToken,
    required List<CartLineModel> lines,
    String? accessToken,
  }) async {
    calls.add({
      'qrToken': qrToken,
      'lines': [
        for (final line in lines)
          {'item_id': line.itemId, 'quantity': line.quantity},
      ],
      'accessToken': accessToken,
    });
    if (error != null) {
      throw error!;
    }
    return created;
  }

  @override
  Future<List<OrderModel>> getMyOrders(String? accessToken) async {
    listCalls.add(accessToken);
    if (listError != null) {
      throw listError!;
    }
    final token = accessToken?.trim() ?? '';
    if (token.isEmpty) {
      return const [];
    }
    return ordersByToken[token] ?? const [];
  }
}

/// An order repository that never completes, for exercising the sending state.
class PendingOrderRepository extends OrderRepository {
  PendingOrderRepository(this.completer);

  final Completer<CreatedOrderModel?> completer;
  int calls = 0;

  @override
  Future<CreatedOrderModel?> createOrder({
    required String qrToken,
    required List<CartLineModel> lines,
    String? accessToken,
  }) {
    calls++;
    return completer.future;
  }
}

/// An in-memory order access store, so page tests never touch the platform
/// channel.
///
/// Stores per context, like the device store, and counts every call so a test can
/// assert the token was read once and written once without reaching into private
/// state.
class MemoryOrderAccessStore implements OrderAccessStore {
  MemoryOrderAccessStore([String? contextKey, String? token])
    : _tokens = {
        if (contextKey != null && token != null) contextKey: token,
      };

  final Map<String, String> _tokens;
  int reads = 0;
  int writes = 0;
  int clears = 0;

  /// The token stored for [contextKey], or `null`.
  String? tokenFor(String contextKey) => _tokens[contextKey];

  /// Every context that currently holds a token.
  Iterable<String> get contexts => _tokens.keys;

  @override
  Future<String?> readToken({required String contextKey}) async {
    reads++;
    return _tokens[contextKey];
  }

  @override
  Future<void> writeToken({
    required String contextKey,
    required String token,
  }) async {
    writes++;
    _tokens[contextKey] = token;
  }

  @override
  Future<void> clearToken({required String contextKey}) async {
    clears++;
    _tokens.remove(contextKey);
  }
}

/// Builds the `PostgrestException` postgrest throws for a failed rpc, so error
/// mapping can be tested against the real shape the app sees.
PostgrestException orderPostgrestError(
  String code, {
  String message = '',
}) {
  return PostgrestException(message: message, code: code);
}


