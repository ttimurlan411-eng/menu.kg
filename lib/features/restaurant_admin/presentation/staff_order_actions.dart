import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';

/// Which statuses a role may move an order to.
///
/// This is the client-side copy of the role matrix in
/// `private.can_manage_restaurant_orders` from
/// `20261002040000_create_staff_order_access.sql`, and it exists for one purpose: so a
/// screen never *offers* a move the database is going to refuse. It is not a second
/// source of authority, and it must never be treated as one:
///
///   * `staff_set_order_status` re-derives the caller's role from
///     `restaurant_members` on every call and refuses a move this list would have
///     hidden. A membership revoked five minutes ago, a role changed on another
///     device, or a caller editing a local copy cannot widen what they may do;
///   * the lifecycle guard is still the only thing that decides whether a move is
///     legal at all, so this list is deliberately built out of
///     [OrderStatus.allowedNextStatuses] rather than a second copy of the lifecycle
///     written out here. Nothing outside the lifecycle can be offered because the
///     lifecycle is where the candidates come from.
///
/// The one thing this cannot mirror is a role the project later adds, so an
/// unrecognised role — including `CASHIER`, which has no order duties defined, and
/// anything a future role is called — is offered nothing rather than something
/// guessed. A wrong offer costs a staff member a confusing refusal; a missing offer
/// costs one reload.
const Map<String, Set<OrderStatus>> _targetsByRole = {
  // Management is not restricted to a list of moves in the database: it may attempt
  // any move and the guard decides. Allowing every status here gives OWNER and MANAGER
  // exactly the moves the lifecycle has, which is what "all allowed transitions"
  // means, and no move that would be refused.
  'OWNER': {
    OrderStatus.pending,
    OrderStatus.accepted,
    OrderStatus.preparing,
    OrderStatus.ready,
    OrderStatus.served,
    OrderStatus.cancelled,
  },
  'MANAGER': {
    OrderStatus.pending,
    OrderStatus.accepted,
    OrderStatus.preparing,
    OrderStatus.ready,
    OrderStatus.served,
    OrderStatus.cancelled,
  },
  // A waiter takes the order, starts it and carries it to the table. Cancelling is
  // every order role's business; where an order may be cancelled is the lifecycle's
  // question and is not narrowed here.
  'WAITER': {
    OrderStatus.accepted,
    OrderStatus.preparing,
    OrderStatus.served,
    OrderStatus.cancelled,
  },
  // A cook starts and finishes the food, and does not take orders or serve them.
  'KITCHEN': {
    OrderStatus.preparing,
    OrderStatus.ready,
    OrderStatus.cancelled,
  },
};

/// The statuses [role] may move an order to, in lifecycle order.
///
/// An unknown or blank role gets an empty set. This says nothing about whether the
/// caller may *read* orders: that is `can_read_restaurant_orders` in the database, and
/// this function is only ever asked what to offer a move for.
Set<OrderStatus> staffOrderTargetsForRole(String role) {
  return _targetsByRole[role.trim().toUpperCase()] ?? const <OrderStatus>{};
}

/// The moves to offer for an order in [status] to a member with [role].
///
/// Returned in [OrderStatus.values] order rather than in the order of any set, so a
/// screen renders the actions the same way every time and a test can assert the exact
/// list. Empty for a terminal status — [OrderStatus.served] and
/// [OrderStatus.cancelled] — because nothing follows them, and for a role that makes
/// no move from there.
List<OrderStatus> staffOrderActionsFor({
  required String role,
  required OrderStatus status,
}) {
  final targets = staffOrderTargetsForRole(role);
  return [
    for (final candidate in OrderStatus.values)
      if (targets.contains(candidate) && status.canTransitionTo(candidate))
        candidate,
  ];
}

/// Whether [role] is a role this app knows how to work orders with.
///
/// Shown as a note before a read is attempted, so a `CASHIER` learns why the orders
/// list is refused without the screen having to guess at the reason. The database
/// still refuses the read itself, which is what actually keeps orders private.
bool staffRoleWorksOrders(String role) {
  return _targetsByRole.containsKey(role.trim().toUpperCase());
}

/// The wording on the button that offers [target].
///
/// Phrased as what happens next, so a button reads as an action rather than as a
/// status: `Cancel order` rather than `Cancelled`.
String staffOrderActionLabel(OrderStatus target) {
  return switch (target) {
    OrderStatus.accepted => 'Accept order',
    OrderStatus.preparing => 'Start preparing',
    OrderStatus.ready => 'Mark ready',
    OrderStatus.served => 'Mark served',
    OrderStatus.cancelled => 'Cancel order',
    // Nothing transitions back to PENDING, so this is never offered. The case exists
    // because the switch must answer for every status, and it is worded honestly
    // rather than pretending a move that does not exist.
    OrderStatus.pending => 'Move to pending',
  };
}

/// The widget key of the control that offers [status].
///
/// Shared by the orders list and the order details page so a test can find the same
/// move on either screen, and so the two screens cannot drift apart in what they
/// call a status. Lowercased because the constant is a database value, and a key that
/// reads `accepted` is easier to write and to read in a failure message.
Key staffOrderActionKey(OrderStatus status) {
  return Key('staffOrderAction_${status.databaseValue.toLowerCase()}');
}