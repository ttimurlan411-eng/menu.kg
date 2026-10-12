import 'dart:convert';

import 'package:menukg_flutter/features/customer/cart/data/models/cart_model.dart';
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';

/// Where a placed order is in its life.
///
/// The database allows exactly these values and refuses anything else, and
/// `public.guard_order_status_transition` refuses any move between them that the
/// restaurant workflow does not have. This enum is the client-side name for that
/// same lifecycle, so a status this app can show and a status the database can
/// store cannot drift apart.
///
/// The normal path is the single forward chain pending -> accepted -> preparing ->
/// ready -> served. Cancellation is reachable while the food is still on its way
/// and from nowhere else: [served] and [cancelled] are terminal, so nothing leaves
/// them, not even back to [pending]. See [allowedNextStatuses].
///
/// Nothing in this app moves an order: there is no staff screen yet, and a guest
/// must not be able to advance or cancel one either. These are the states and
/// moves the database will accept, so the workflow can be built on top of a
/// lifecycle that already exists rather than one invented later.
///
/// An unknown value is a [FormatException] rather than a silent fallback, so a
/// payload this client does not understand can never be shown to a guest as a
/// status this app understands. [tryParseOrders] turns that exception into a
/// skipped order, so a future state cannot crash the guest's history or be
/// mistranslated into a promise the database cannot keep.
enum OrderStatus {
  /// Placed by the guest and not yet looked at by the restaurant. The only state
  /// an order can be created in, and the only state any order is in today.
  pending(
    'PENDING',
    'Pending',
    allowedNextStatuses: {accepted, cancelled},
  ),

  /// The restaurant has taken the order. No dish changes here; it is the point at
  /// which the order stops being the guest's alone.
  accepted(
    'ACCEPTED',
    'Accepted',
    allowedNextStatuses: {preparing, cancelled},
  ),

  /// Being made. The dish is in the kitchen rather than on a plate.
  preparing(
    'PREPARING',
    'Preparing',
    allowedNextStatuses: {ready, cancelled},
  ),

  /// Finished and waiting to be brought to the table. Cancelling stops here on
  /// purpose: the food exists by now, so cancelling is no longer a free decision.
  ready(
    'READY',
    'Ready',
    allowedNextStatuses: {served},
  ),

  /// At the guest's table. Terminal: a served order is finished, so nothing moves
  /// it again and a mistake with it is corrected by a new order.
  served('SERVED', 'Served'),

  /// Called off before the food was served. Terminal, and reachable only from
  /// [pending], [accepted] or [preparing].
  cancelled('CANCELLED', 'Cancelled');

  const OrderStatus(this.databaseValue, this.displayLabel, {this.allowedNextStatuses = const {}});

  /// The value stored in the `status` column.
  final String databaseValue;

  /// The wording shown to a guest, for example `Pending`.
  ///
  /// Lives next to [databaseValue] so the two cannot drift apart: a state is only
  /// read and shown if the client can name it. Each label describes only what the
  /// database reports — no "on its way", no ETA and no promise about when — so the
  /// screen cannot claim something the lifecycle does not guarantee.
  final String displayLabel;

  /// The states this one may move to, exactly as `guard_order_status_transition`
  /// allows in the database.
  ///
  /// Empty for [served] and [cancelled], which is what [isTerminal] reports. This
  /// list is the whole lifecycle: everything not in it is refused, so a client
  /// cannot be tempted to assume a move the database will reject.
  final Set<OrderStatus> allowedNextStatuses;

  /// Whether nothing can follow this state.
  bool get isTerminal => allowedNextStatuses.isEmpty;

  /// Whether the restaurant may move an order from here to [next].
  ///
  /// Mirrors the database rule and is not a substitute for it: the guard trigger
  /// refuses an invalid transition whatever a client believes, which is why this
  /// exists to keep a future staff screen from offering a move the database will
  /// throw away, not to decide whether it may.
  bool canTransitionTo(OrderStatus next) => allowedNextStatuses.contains(next);

  static OrderStatus fromDatabase(String value) {
    for (final status in values) {
      if (status.databaseValue == value) {
        return status;
      }
    }
    throw FormatException('Unknown order status: $value');
  }
}

/// One ordered line, as the guest may see it.
///
/// Every amount here is a snapshot the database took when the order was placed,
/// not a value read from the live menu now. Renaming a dish or changing its price
/// cannot rewrite what the guest ordered, so this model deliberately holds no
/// reference the live menu would be able to refresh it from.
class OrderLineModel {
  const OrderLineModel({
    required this.productName,
    required this.unitPriceMinorUnits,
    required this.quantity,
    required this.lineTotalMinorUnits,
    this.menuItemId,
  }) : assert(quantity >= minimumCartQuantity, 'An order line holds at least one item.');

  /// The product as it was named when the guest ordered it.
  final String productName;

  /// The price of one item as it was when the guest ordered it, in whole minor
  /// units. Converted from the `numeric` the database returned with the same
  /// [toMinorUnits] used for the cart, so a cart total and an order total of the
  /// same basket agree.
  final int unitPriceMinorUnits;

  final int quantity;

  /// `unit_price * quantity`, stored by the database rather than recomputed here,
  /// so a line cannot be shown with a total that disagrees with its own numbers.
  final int lineTotalMinorUnits;

  /// The product this line was ordered from, or `null` when that product has
  /// since been deleted. The snapshot above is what the order depends on, so the
  /// order stays readable either way.
  final String? menuItemId;

  /// One line for a receipt, for example `2 × Beshbarmak · 900.00 KGS`.
  String get label => '$quantity × $productName';

  factory OrderLineModel.fromJson(Map<String, dynamic> json) {
    return OrderLineModel(
      menuItemId: json['menu_item_id'] as String?,
      productName: json['product_name'] as String,
      unitPriceMinorUnits: toMinorUnits(
        (json['unit_price'] as num?)?.toDouble() ?? 0,
      ),
      quantity: (json['quantity'] as num).toInt(),
      lineTotalMinorUnits: toMinorUnits(
        (json['line_total'] as num?)?.toDouble() ?? 0,
      ),
    );
  }
}

/// A customer order, as the guest may see it.
///
/// The payload is built by the `create_table_order` and `guest_orders` database
/// functions, which send display labels only. No restaurant, branch or table id
/// reaches this model, exactly as in the public menu and the reservations: [id] is
/// the guest's own order id and the restaurant, branch and table are names.
/// Reading an order back and seeing the order just placed therefore produce the
/// same model from the same fields.
class OrderModel {
  const OrderModel({
    required this.id,
    required this.orderNumber,
    required this.status,
    required this.currency,
    required this.totalMinorUnits,
    required this.itemCount,
    required this.restaurantName,
    required this.branchName,
    required this.table,
    required this.lines,
    required this.createdAt,
  }) : assert(lines.length > 0, 'An order always has at least one line.');

  /// Id of this order. Used for display and for the guest's own order history.
  final String id;

  /// The short number the guest reads out and staff write on a receipt, unique
  /// within the restaurant. See [numberLabel].
  final int orderNumber;

  final OrderStatus status;

  /// ISO currency code snapshotted with the order, for example `KGS`.
  final String currency;

  /// The order total in whole minor units, as stored by the database from the sum
  /// of its own line totals.
  final int totalMinorUnits;

  /// How many items the order holds across all lines.
  final int itemCount;

  final String restaurantName;
  final String branchName;

  /// The ordered table, as a display label.
  final PublicTableInfo table;

  /// The ordered lines, in the order the guest placed them.
  final List<OrderLineModel> lines;

  final DateTime createdAt;

  /// The number as a guest sees it, for example `#1043`.
  String get numberLabel => '#$orderNumber';

  /// The stored total, formatted for the guest, for example `1500.50 KGS`.
  ///
  /// Read from [totalMinorUnits] rather than summed from [lines]: the database
  /// total is the authoritative one, and using it here keeps a display total from
  /// disagreeing with what the server will bill.
  String get totalLabel => formatCartAmount(totalMinorUnits, currency);

  factory OrderModel.fromJson(Map<String, dynamic> json) {
    final rawLines = json['items'] as List? ?? const [];
    return OrderModel(
      id: json['id'] as String,
      orderNumber: (json['order_number'] as num).toInt(),
      status: OrderStatus.fromDatabase(json['status'] as String),
      currency: json['currency'] as String,
      totalMinorUnits: toMinorUnits((json['total'] as num).toDouble()),
      itemCount: (json['item_count'] as num).toInt(),
      restaurantName: json['restaurant_name'] as String,
      branchName: json['branch_name'] as String,
      table: PublicTableInfo.fromJson(json['table'] as Map<String, dynamic>),
      lines: rawLines
          .whereType<Map<String, dynamic>>()
          .map(OrderLineModel.fromJson)
          .toList(),
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// A newly placed order together with the access token that proves it belongs to
/// this guest.
///
/// The token is the guest's only credential, so it is returned exactly once, by
/// the call that created the order, and afterwards the guest keeps it on their
/// own device. It is a separate credential from the reservation token on purpose:
/// the two capabilities can be revoked apart, which is why a token that opens an
/// order history is not the token that opens a reservation history.
class CreatedOrderModel {
  const CreatedOrderModel({required this.accessToken, required this.order});

  final String accessToken;
  final OrderModel order;

  factory CreatedOrderModel.fromJson(Map<String, dynamic> json) {
    return CreatedOrderModel(
      accessToken: json['access_token'] as String,
      order: OrderModel.fromJson(json['order'] as Map<String, dynamic>),
    );
  }
}

/// Decodes an `rpc` response that may arrive as a decoded value or as a string.
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

/// Parses the `create_table_order` response.
///
/// Returns `null` when the database resolved nothing, which is how an unknown,
/// deleted or inactive QR code is reported. It never invents a token, and a
/// payload without an order is not treated as an order, so a malformed response
/// cannot be shown to a guest as a placed order.
CreatedOrderModel? tryParseCreatedOrder(Object? response) {
  final decoded = _decodeResponse(response);
  if (decoded is! Map<String, dynamic>) {
    return null;
  }
  final accessToken = decoded['access_token'];
  final order = decoded['order'];
  if (accessToken is! String ||
      accessToken.isEmpty ||
      order is! Map<String, dynamic>) {
    return null;
  }
  try {
    return CreatedOrderModel.fromJson(decoded);
  } on Object {
    // A payload this client cannot read is reported as "no order" rather than
    // thrown, so a future database state cannot crash the guest's flow.
    return null;
  }
}

/// Parses the `guest_orders` response, which is how a guest reads their own
/// orders back.
///
/// Returns an empty list when the token is unknown or when the payload is not a
/// list of orders, which is exactly how the database reports "no orders for this
/// token": an invalid or expired token and a guest who never ordered are the same
/// answer, so neither can be told apart from the other by a caller probing for
/// tokens that exist.
///
/// A single unreadable order is skipped rather than failing the whole read, so one
/// payload this client does not understand cannot hide the orders around it. An
/// order whose status this client cannot read is skipped by [OrderModel.fromJson]
/// throwing, which is the same rule the confirmation applies.
List<OrderModel> tryParseOrders(Object? response) {
  final decoded = _decodeResponse(response);
  if (decoded is! Map<String, dynamic>) {
    return const [];
  }
  final raw = decoded['orders'];
  if (raw is! List) {
    return const [];
  }
  final orders = <OrderModel>[];
  for (final entry in raw) {
    if (entry is! Map<String, dynamic>) {
      continue;
    }
    try {
      orders.add(OrderModel.fromJson(entry));
    } on Object {
      continue;
    }
  }
  return orders;
}

const List<String> _weekdayNames = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const List<String> _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Formats when an order was placed, for example `Mon, 5 Oct 2026 · 14:22`.
///
/// The database stores an absolute instant, so it is shown in the guest's own
/// timezone: "today at 14:22" has to mean the hour the guest actually saw on the
/// clock, and an order read back in a different timezone has to read as the moment
/// it happened there. The reservation formatters are not reused because their
/// input is a wall-clock reservation slot, which must never be shifted.
String formatOrderPlacedAt(DateTime createdAt) {
  final local = createdAt.toLocal();
  final weekday = _weekdayNames[local.weekday - 1];
  final month = _monthNames[local.month - 1];
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$weekday, ${local.day} $month ${local.year} · $hour:$minute';
}
