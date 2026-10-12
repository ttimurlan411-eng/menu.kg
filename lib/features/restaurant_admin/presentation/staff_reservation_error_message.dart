import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts a failed staff reservation read into safe wording.
///
/// The database's refusals are fixed identifiers rather than prose, and each one
/// is mapped here. A raw postgrest error is never shown: it can name tables,
/// columns, constraints and internals of a function the caller is not meant to
/// be able to read, and nothing about this project is worth showing a restaurant
/// member.
///
/// [error] may be anything a repository throws, not only a [PostgrestException]:
/// a screen that passes an arbitrary failure in gets the same safe fallback.
String staffReservationListErrorMessage(Object error) {
  if (error is PostgrestException) {
    if (error.code == '28000') {
      return 'Your session has ended. Please sign in again.';
    }
    // staff_reservation_access_denied: not an active member of that restaurant,
    // a role with no reservation duties, or a restaurant that does not exist.
    // All are one answer, and the wording does not say which, because the
    // database does not.
    if (error.code == '42501') {
      return 'You do not have permission to view these reservations.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('authentication')) {
      return 'Your session has ended. Please sign in again.';
    }
    if (message.contains('row-level security')) {
      return 'You do not have permission to view these reservations.';
    }
  }

  return 'We could not load these reservations. Please try again.';
}

/// Converts a refused staff reservation status change into safe wording.
///
/// The two lifecycle refusals share code `P0001` and are told apart by the
/// database's fixed message, in the same order and for the same reason as the
/// orders: a move the lifecycle refuses is reported as a move the reservation
/// cannot make, never as a permission problem, because it is not one — an owner
/// refused a move this phase has not defined was refused by the rule about
/// reservations, not by their role.
String staffReservationStatusErrorMessage(Object error) {
  if (error is PostgrestException) {
    if (error.code == '28000') {
      return 'Your session has ended. Please sign in again.';
    }

    final message = error.message.toLowerCase();

    // The transition message is checked first: it starts with the same words as
    // the unknown-status message, so the other order would report an impossible
    // move as a status that does not exist.
    if (message.contains('invalid_reservation_status_transition')) {
      return 'This reservation cannot move to that status.';
    }
    if (message.contains('invalid_reservation_status')) {
      return 'That is not a status this reservation can be in.';
    }
    if (error.code == '42501') {
      return 'You do not have permission to change this reservation.';
    }
    // A missing id or status: a malformed request rather than a refusal.
    if (error.code == '22023') {
      return 'Choose a reservation and a status first.';
    }

    if (message.contains('authentication')) {
      return 'Your session has ended. Please sign in again.';
    }
    if (message.contains('row-level security')) {
      return 'You do not have permission to change this reservation.';
    }
  }

  return 'We could not change this reservation. Please try again.';
}
