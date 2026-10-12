import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts order placement failures into safe, guest-facing messages.
///
/// A guest must never see database internals, constraint names, tokens or raw
/// error text, so every branch maps to a fixed sentence. The wording also never
/// claims the kitchen has been told or that the order is on its way: what the
/// database confirmed is that the order was stored, and nothing more.
String orderErrorMessage(Object error) {
  if (error is PostgrestException) {
    switch (error.code) {
      // raise_exception: an empty or malformed item list, a quantity outside the
      // accepted range, the same dish on two lines, or a dish that is switched
      // off or belongs to another restaurant or branch. All of them mean the
      // cart as it stands cannot be ordered, and none of them tells the guest
      // which restaurant or dish was involved.
      case 'P0001':
        return 'We could not place your order as it stands. Please review your '
            'cart and try again.';
      // invalid_text_representation: the token was not a uuid.
      case '22P02':
        return 'This QR code is not valid.';
      // insufficient_privilege or an unexpected authorization state: the public
      // function is revoked or misconfigured.
      case '42501':
      case '28000':
        return 'Ordering is not available right now.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('jwt') || message.contains('authorization')) {
      // The public function must never require a session.
      return 'Ordering is not available right now.';
    }
    if (message.contains('syntax') || message.contains('uuid')) {
      return 'This QR code is not valid.';
    }
  }

  return 'We could not place your order. Please try again.';
}

/// Shown when a QR code cannot be used to order, for example because it is
/// unknown, expired, or the restaurant has closed the table.
///
/// The database answers an unresolvable token with no order at all, which is
/// deliberately the same answer the public menu and the reservations give, so
/// nothing here reveals whether a token ever existed.
const String orderQrUnavailableMessage =
    'This table cannot take orders right now.';

/// Shown when a guest's own order history cannot be loaded.
///
/// Kept separate from [orderErrorMessage] because the two failures mean different
/// things to a guest: placing an order failed, or the past ones could not be read.
/// Both still map to a fixed sentence, so no database text, constraint name or
/// token can reach the screen.
String orderListErrorMessage(Object error) {
  if (error is PostgrestException) {
    if (error.code == '42501' || error.code == '28000') {
      return 'Your orders are not available right now.';
    }
  }

  return 'We could not load your orders. Please try again.';
}
