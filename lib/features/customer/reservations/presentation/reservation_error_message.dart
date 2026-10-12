import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts reservation failures into safe, guest-facing messages.
///
/// A guest must never see database internals, constraint names, tokens or raw
/// error text, so every branch maps to a fixed sentence. The messages also avoid
/// promising anything: reservations are stored, never sent to a restaurant and
/// never confirmed by one.
String reservationErrorMessage(Object error) {
  if (error is PostgrestException) {
    switch (error.code) {
      // unique_violation: the exact slot on that table is already booked.
      case '23505':
        return 'That time is already taken. Please pick another time.';
      // raise_exception: a day in the past, an empty name, or a party larger
      // than the table seats.
      case 'P0001':
        return 'Please check the date, time, name and number of guests.';
      // insufficient_privilege or an unexpected authorization state: the public
      // functions are revoked or misconfigured.
      case '42501':
      case '28000':
        return 'Reservations are not available right now.';
      // invalid_text_representation: the token was not a uuid.
      case '22P02':
        return 'This QR code is not valid.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('jwt') || message.contains('authorization')) {
      // The public functions must never require a session.
      return 'Reservations are not available right now.';
    }
    if (message.contains('syntax') || message.contains('uuid')) {
      return 'This QR code is not valid.';
    }
  }

  return 'We could not save your reservation. Please try again.';
}

/// Shown when a guest's own list cannot be loaded.
String reservationListErrorMessage(Object error) {
  if (error is PostgrestException) {
    if (error.code == '42501' || error.code == '28000') {
      return 'Your reservations are not available right now.';
    }
  }

  return 'We could not load your reservations. Please try again.';
}

/// Shown when a QR code cannot be used to make a reservation, for example
/// because it is unknown, inactive, or the restaurant has closed the table.
const String reservationQrUnavailableMessage =
    'This table cannot be reserved right now.';

/// Shown when a reservation is called off.
const String reservationCancelledMessage = 'This reservation was cancelled.';
