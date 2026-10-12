import 'dart:convert';

import 'package:menukg_flutter/features/customer/cart/data/models/cart_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';

/// An order as the restaurant that took it sees it.
///
/// Built from the payload `staff_list_orders` sends, which is the guest's payload
/// plus what only staff need. The differences are deliberate, and each one is a
/// capability the guest read withholds:
///
///   * the branch and the ordered table are named, by id and by label, because a
///     waiter works one branch and brings an order to one table. The guest payload
///     names neither, so a guest cannot learn which restaurant or table an id belongs
///     to from their own order;
///   * `updatedAt` is carried, so a screen can show that what it is looking at is
///     the current state of the order rather than what was true when it loaded.
///
/// What is not here is the point: there is no guest access token, no `order_access`
/// row and no status history anywhere in this model or in the payload it is parsed
/// from. A staff screen can see where an order has got to; it holds no credential
/// for reading the order as the guest who placed it, and this class offers no field
/// in which such a credential could be kept.
///
/// Every amount is a snapshot taken when the guest ordered, exactly as in
/// [OrderLineModel], so a dish renamed or repriced afterwards cannot rewrite what
/// was ordered or what it cost. The totals are read from the stored values rather
/// than summed from the lines, because the database totals are the authoritative
/// ones.
///
/// The status is the shared [OrderStatus], not a staff copy of it: this app has one
/// lifecycle and one set of names for it, and a staff screen and a guest screen
/// cannot be allowed to disagree about what [OrderStatus.accepted] means.
class StaffOrderModel {
  const StaffOrderModel({
    required this.id,
    required this.orderNumber,
    required this.status,
    required this.currency,
    required this.totalMinorUnits,
    required this.itemCount,
    required this.branchId,
    required this.lines,
    required this.createdAt,
    required this.updatedAt,
    this.tableId,
    this.tableNumber,
    this.tableName,
  }) : assert(lines.length > 0, 'An order always has at least one line.');

  /// Id of this order, and the only thing `staff_set_order_status` needs to move it:
  /// the restaurant is read from the order, so a caller cannot name one.
  final String id;

  /// The short number read out at the table and written on a receipt.
  final int orderNumber;

  /// Where the order is in its life, as the database holds it.
  final OrderStatus status;

  /// ISO currency code snapshotted with the order, for example `KGS`.
  final String currency;

  final int totalMinorUnits;
  final int itemCount;

  /// Branch that took the order. Staff work one branch, so this is named.
  final String branchId;

  /// The ordered table, or `null` for an order placed without one.
  ///
  /// The column allows it for a takeaway order that no step has defined, and such an
  /// order is still listed rather than hidden, so all three fields are nullable
  /// together and [tableLabel] has to cope.
  final String? tableId;
  final String? tableNumber;
  final String? tableName;

  /// The ordered lines, in the order the guest placed them.
  final List<OrderLineModel> lines;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// The number as staff read it out, for example `#1043`.
  String get numberLabel => '#$orderNumber';

  /// The stored total, formatted, for example `900.00 KGS`.
  String get totalLabel => formatCartAmount(totalMinorUnits, currency);

  /// The table to bring the order to, for example `12 · Window`.
  ///
  /// Falls back to the number when the table has no name, and to `No table` when the
  /// order has no table at all, so a label is never shown empty.
  String get tableLabel {
    final number = tableNumber?.trim() ?? '';
    final name = tableName?.trim() ?? '';
    if (number.isEmpty) {
      return 'No table';
    }
    return name.isEmpty ? number : '$number · $name';
  }

  factory StaffOrderModel.fromJson(Map<String, dynamic> json) {
    final rawLines = json['items'] as List? ?? const [];
    final table = json['table'];
    return StaffOrderModel(
      id: json['id'] as String,
      orderNumber: (json['order_number'] as num).toInt(),
      status: OrderStatus.fromDatabase(json['status'] as String),
      currency: json['currency'] as String,
      totalMinorUnits: toMinorUnits((json['total'] as num).toDouble()),
      itemCount: (json['item_count'] as num).toInt(),
      branchId: json['branch_id'] as String,
      tableId: table is Map<String, dynamic> ? table['id'] as String? : null,
      tableNumber: table is Map<String, dynamic> ? table['number'] as String? : null,
      tableName: table is Map<String, dynamic> ? table['name'] as String? : null,
      lines: rawLines
          .whereType<Map<String, dynamic>>()
          .map(OrderLineModel.fromJson)
          .toList(),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  /// The same order in a new state, for after a successful status change.
  ///
  /// Only the status and the moment it changed are replaced: the lines, the totals
  /// and the table are what the order already holds, and re-reading the whole order
  /// after moving it would be a second request for information nothing changed. A
  /// status change cannot make an order change its amounts, so nothing else can
  /// disagree with what is kept here.
  ///
  /// [updatedAt] defaults to now, which is what the database returned anyway; pass the
  /// database's own value when a screen wants to show the server's clock rather than
  /// the phone's.
  StaffOrderModel withStatus(OrderStatus status, {DateTime? updatedAt}) {
    return StaffOrderModel(
      id: id,
      orderNumber: orderNumber,
      status: status,
      currency: currency,
      totalMinorUnits: totalMinorUnits,
      itemCount: itemCount,
      branchId: branchId,
      tableId: tableId,
      tableNumber: tableNumber,
      tableName: tableName,
      lines: lines,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }
}

/// The answer to a successful status change: the order's id, the state it is now in,
/// and when the row changed.
///
/// Deliberately not a whole order. `staff_set_order_status` changes nothing but the
/// status, so returning anything else would invite a screen to overwrite what it
/// already has with a payload that says less about it than the copy it holds.
class StaffOrderStatusUpdate {
  const StaffOrderStatusUpdate({
    required this.orderId,
    required this.status,
    required this.updatedAt,
  });

  final String orderId;
  final OrderStatus status;
  final DateTime updatedAt;

  factory StaffOrderStatusUpdate.fromJson(Map<String, dynamic> json) {
    return StaffOrderStatusUpdate(
      orderId: json['id'] as String,
      status: OrderStatus.fromDatabase(json['status'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }
}

/// Where a page of order history ended: the `(created_at, order_number)` of the last
/// row the database returned.
///
/// This is the database's own cursor, not one the client builds from an order it
/// parsed. The two are the same in the ordinary case, but if a screen skips an order
/// it cannot read the server's cursor still points exactly where the database stopped,
/// so the next page never repeats or drops a row because of a parsing failure.
///
/// Both halves are one key: the database applies the cursor only when it is given
/// both, so a cursor is never constructed from one half alone.
class StaffOrderHistoryCursor {
  const StaffOrderHistoryCursor({
    required this.createdAt,
    required this.orderNumber,
  });

  /// When the order the cursor names was placed, in UTC as the database stores it.
  final DateTime createdAt;

  /// The short per-restaurant order number, which breaks a `created_at` tie.
  final int orderNumber;

  factory StaffOrderHistoryCursor.fromJson(Map<String, dynamic> json) {
    return StaffOrderHistoryCursor(
      createdAt: DateTime.parse(json['created_at'] as String),
      orderNumber: (json['order_number'] as num).toInt(),
    );
  }
}

/// One page of order history: the orders, whether another page follows, and the
/// cursor that asks for it.
///
/// [hasMore] is true only when the database both said there is more and supplied a
/// cursor to read it with, so a page with [hasMore] true always has a non-null
/// [nextCursor] and a screen can never be asked to fetch a page it has no position
/// for.
class StaffOrderHistoryPage {
  const StaffOrderHistoryPage({
    required this.orders,
    required this.hasMore,
    this.nextCursor,
  });

  /// A page that reads nothing: an unreadable response, a response for another
  /// restaurant, or a genuine end of history.
  const StaffOrderHistoryPage.empty()
      : orders = const [],
        hasMore = false,
        nextCursor = null;

  /// The orders of this page, in the order the database sent them.
  final List<StaffOrderModel> orders;

  /// Whether another page exists after this one.
  final bool hasMore;

  /// The position to read the next page from, or `null` on the last page.
  final StaffOrderHistoryCursor? nextCursor;
}

/// Decodes an `rpc` response that may arrive as a decoded value or as a string.
///
/// Shared shape with the guest order parser: postgrest sends a json-returning
/// function's answer as a string unless the client asks otherwise, and a client that
/// cannot read either shape has no order to show.
Object? _decodeResponse(Object? response) {
  Object? decoded = response;
  if (decoded is String) {
    if (decoded.trim().isEmpty) {
      return null;
    }
    try {
      decoded = jsonDecode(decoded);
    } on FormatException {
      return null;
    }
  }
  return decoded;
}

/// Parses the `staff_list_orders` response for [restaurantId].
///
/// [restaurantId] is checked against the payload rather than only passed in, and a
/// payload that names another restaurant is reported as no orders at all. A response
/// that arrived from somewhere else, or that a client attached to the wrong request,
/// therefore cannot be shown as another restaurant's orders; being strict here costs
/// a reload and a wrong list costs a staff member their morning.
///
/// An order this client cannot read is skipped rather than failing the whole read, so
/// one payload it does not understand cannot hide the orders around it. An order whose
/// status it does not know is skipped by [StaffOrderModel.fromJson] throwing, which is
/// the same fail-safe the guest history applies: an unknown state is never shown as a
/// state this app understands.
List<StaffOrderModel> tryParseStaffOrders(
  Object? response, {
  required String restaurantId,
}) {
  final decoded = _decodeResponse(response);
  if (decoded is! Map<String, dynamic>) {
    return const [];
  }
  if (decoded['restaurant_id'] != restaurantId) {
    return const [];
  }
  return _parseOrderList(decoded['orders']);
}

/// Reads an `orders` array, skipping anything that is not an order this client can
/// understand.
///
/// Shared by the unpaginated read and the history read, which send the same order
/// shape, so the two cannot drift apart in what they accept. A single unreadable entry
/// is skipped rather than failing the whole list, and an entry whose status this client
/// does not know is skipped by [StaffOrderModel.fromJson] throwing.
List<StaffOrderModel> _parseOrderList(Object? raw) {
  if (raw is! List) {
    return const [];
  }
  final orders = <StaffOrderModel>[];
  for (final entry in raw) {
    if (entry is! Map<String, dynamic>) {
      continue;
    }
    try {
      orders.add(StaffOrderModel.fromJson(entry));
    } on Object {
      continue;
    }
  }
  return orders;
}

/// Parses the `staff_list_order_history` response for [restaurantId].
///
/// The envelope is `staff_list_orders`' plus `has_more` and `next_cursor`. A payload
/// that is not readable, or that names another restaurant, is an empty page with no
/// cursor, exactly as the unpaginated read reports nothing; being strict here costs a
/// reload and a wrong restaurant's history costs a staff member their morning.
///
/// [StaffOrderHistoryPage.hasMore] is true only when the database said there is more
/// *and* supplied a cursor to ask for it. A server that claimed more without a usable
/// cursor, or one whose cursor this client cannot parse, is treated as the end of the
/// history: a client that kept asking without a position would page forever.
StaffOrderHistoryPage tryParseStaffOrderHistory(
  Object? response, {
  required String restaurantId,
}) {
  final decoded = _decodeResponse(response);
  if (decoded is! Map<String, dynamic>) {
    return const StaffOrderHistoryPage.empty();
  }
  if (decoded['restaurant_id'] != restaurantId) {
    return const StaffOrderHistoryPage.empty();
  }

  StaffOrderHistoryCursor? cursor;
  final rawCursor = decoded['next_cursor'];
  if (rawCursor is Map<String, dynamic>) {
    try {
      cursor = StaffOrderHistoryCursor.fromJson(rawCursor);
    } on Object {
      cursor = null;
    }
  }

  return StaffOrderHistoryPage(
    orders: _parseOrderList(decoded['orders']),
    hasMore: decoded['has_more'] == true && cursor != null,
    nextCursor: cursor,
  );
}

/// Parses the `staff_set_order_status` response.
///
/// Returns `null` for anything that is not a readable status change, so a payload
/// this client does not understand is reported as "nothing changed" instead of a move
/// the screen then claims to have made.
StaffOrderStatusUpdate? tryParseStaffOrderStatusUpdate(Object? response) {
  final decoded = _decodeResponse(response);
  if (decoded is! Map<String, dynamic>) {
    return null;
  }
  if (decoded['id'] is! String || decoded['updated_at'] is! String) {
    return null;
  }
  try {
    return StaffOrderStatusUpdate.fromJson(decoded);
  } on Object {
    return null;
  }
}