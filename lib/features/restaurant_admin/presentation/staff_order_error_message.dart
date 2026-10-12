import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts a failed staff order read into safe wording.
///
/// The database's refusals are fixed identifiers rather than prose, and each one is
/// mapped here. A raw postgrest error is never shown: it can name tables, columns,
/// constraints and internals of a function the caller is not meant to be able to
/// read, and nothing about this project is worth showing a restaurant member.
///
/// [error] may be anything a repository throws, not only a [PostgrestException]:
/// a screen that passes an arbitrary failure in gets the same safe fallback.
String staffOrderListErrorMessage(Object error) {
  if (error is PostgrestException) {
    if (error.code == '28000') {
      return 'Your session has ended. Please sign in again.';
    }
    // staff_order_access_denied: not an active member of that restaurant, or a
    // restaurant that does not exist. Both are one answer, and the wording does not
    // say which, because the database does not.
    if (error.code == '42501') {
      return 'You do not have permission to view these orders.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('authentication')) {
      return 'Your session has ended. Please sign in again.';
    }
    if (message.contains('row-level security')) {
      return 'You do not have permission to view these orders.';
    }
  }

  return 'We could not load these orders. Please try again.';
}

/// Converts a refused staff order status change into safe wording.
///
/// The two refusals that share code `42501` are told apart by the database's fixed
/// message, because they are different problems with different fixes: the order is not
/// this staff member's to move, or their role does not make that move. A move the
/// lifecycle refuses is reported as a move the order cannot make, never as a permission
/// problem, because it is not one — an owner refused a jump from pending to served was
/// refused by the rule about orders, not by their role.
String staffOrderStatusErrorMessage(Object error) {
  if (error is PostgrestException) {
    if (error.code == '28000') {
      return 'Your session has ended. Please sign in again.';
    }

    final message = error.message.toLowerCase();

    // The transition message is checked first: it starts with the same words as the
    // unknown-status message, so the other order would report an impossible move as a
    // status that does not exist.
    if (message.contains('invalid_order_status_transition')) {
      return 'This order cannot move to that status.';
    }
    if (message.contains('invalid_order_status')) {
      return 'That is not a status this order can be in.';
    }
    if (message.contains('staff_order_status_not_permitted')) {
      return 'Your role cannot make that status change.';
    }
    if (error.code == '42501') {
      return 'You do not have permission to change this order.';
    }
    // A missing id or status: a malformed request rather than a refusal.
    if (error.code == '22023') {
      return 'Choose an order and a status first.';
    }

    if (message.contains('authentication')) {
      return 'Your session has ended. Please sign in again.';
    }
    if (message.contains('row-level security')) {
      return 'You do not have permission to change this order.';
    }
  }

  return 'We could not change this order. Please try again.';
}