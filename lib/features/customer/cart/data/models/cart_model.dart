import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';

/// The smallest number of items a cart line can hold.
///
/// The minus control stops here and [CartLineModel] clamps to it, so a line can
/// never be added or edited down to zero.
const int minimumCartQuantity = 1;

/// Converts a public menu price into whole minor units.
///
/// The public menu carries prices as doubles, so a price is converted exactly
/// once, here, and every cart amount from that point on is an integer. Totals
/// therefore stay exact instead of drifting the way `0.1 + 0.2` does, and a
/// dish at 19.99 taken three times is 5997 rather than 5996.999999999999.
int toMinorUnits(double amount) => (amount * 100).round();

/// Formats whole [minorUnits] for a guest, for example `5997` becomes
/// `59.97 KGS`.
///
/// Only integer arithmetic is used, so a total is never passed back through a
/// double on its way to the screen and cannot pick up a rounding artefact.
String formatCartAmount(int minorUnits, String currency) {
  assert(minorUnits >= 0, 'A cart amount cannot be negative.');
  final units = minorUnits ~/ 100;
  final remainder = (minorUnits % 100).toString().padLeft(2, '0');
  return '$units.$remainder ${currency.toUpperCase()}';
}

/// Keeps a quantity inside what a cart line can hold.
int clampCartQuantity(int quantity) =>
    quantity < minimumCartQuantity ? minimumCartQuantity : quantity;

/// One line in the local cart: a dish, its price and how many the guest wants.
///
/// The line is a snapshot of the menu item taken when it was added, so the cart
/// renders without reading the menu again. It stores the minimum needed to show
/// the dish — id, name, price, image and quantity — and deliberately no
/// restaurant, branch or table id: the cart is grouped by the QR token the dish
/// was added from instead.
class CartLineModel {
  const CartLineModel({
    required this.itemId,
    required this.name,
    required this.unitPriceMinorUnits,
    required this.quantity,
    this.imageUrl,
  }) : assert(
         quantity >= minimumCartQuantity,
         'A cart line holds at least $minimumCartQuantity item.',
       );

  /// Snapshots an available dish of the resolved public menu.
  ///
  /// Only a [PublicMenuItemModel] can become a line, which is why an
  /// unavailable dish cannot be added: it is not in the resolved menu, so there
  /// is no model to name it with.
  factory CartLineModel.fromMenuItem(
    PublicMenuItemModel item, {
    int quantity = 1,
  }) {
    return CartLineModel(
      itemId: item.id,
      name: item.name,
      unitPriceMinorUnits: toMinorUnits(item.price),
      quantity: clampCartQuantity(quantity),
      imageUrl: item.mainImageUrl,
    );
  }

  /// Id of the menu item, used to match a line against the menu again.
  final String itemId;

  final String name;

  /// Price of one item, in whole minor units.
  final int unitPriceMinorUnits;

  final int quantity;

  final String? imageUrl;

  /// Price times quantity, in whole minor units.
  int get lineTotalMinorUnits => unitPriceMinorUnits * quantity;

  /// The same dish with a different quantity, never below
  /// [minimumCartQuantity].
  CartLineModel withQuantity(int newQuantity) => CartLineModel(
    itemId: itemId,
    name: name,
    unitPriceMinorUnits: unitPriceMinorUnits,
    quantity: clampCartQuantity(newQuantity),
    imageUrl: imageUrl,
  );
}
