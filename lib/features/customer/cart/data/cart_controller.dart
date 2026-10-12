import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/features/customer/cart/data/models/cart_model.dart';
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';

/// The guest's cart for the public menu.
///
/// The cart is local. Everything it holds lives in memory for as long as the
/// app runs: there is no Supabase client here, no table, no write of any kind
/// and no customer account, and nothing is written to disk either. Closing the
/// app empties it.
///
/// A cart becomes an order only when the guest asks for one, and even then this
/// class writes nothing: the order is placed by [OrderRepository] from the QR
/// token the menu was opened with, and the database prices and stores it. This
/// controller is emptied only after that has been confirmed, so the cart never
/// loses a dish the database did not accept.
///
/// Lines are grouped by the QR token of the menu they were added from, so dishes
/// from one table can never surface in another table's cart, and a blank token
/// is refused the same way the public menu refuses it. That keeps the
/// restaurant isolation of the secure `public_menu_by_qr_token` read carrying
/// over to the cart without the cart needing to know anything about restaurants.
class CartController extends ChangeNotifier {
  final Map<String, List<CartLineModel>> _linesByContext = <String, List<CartLineModel>>{};

  /// The lines of the cart for [contextKey], in the order they were added.
  List<CartLineModel> linesFor(String contextKey) => List<CartLineModel>.unmodifiable(_lines(contextKey));

  /// Whether [contextKey] has nothing in the cart.
  bool isEmptyFor(String contextKey) => _lines(contextKey).isEmpty;

  /// How many items the cart for [contextKey] holds across all lines.
  int itemCountFor(String contextKey) => _lines(contextKey).fold<int>(
    0,
    (int total, CartLineModel line) => total + line.quantity,
  );

  /// The cart total for [contextKey] in whole minor units.
  ///
  /// Every line total is already an integer, so the sum cannot drift.
  int subtotalMinorUnitsFor(String contextKey) => _lines(contextKey).fold<int>(
    0,
    (int total, CartLineModel line) => total + line.lineTotalMinorUnits,
  );

  /// Adds an available [item] to the cart for [contextKey] and returns the
  /// quantity the line now holds.
  ///
  /// Adding a dish that is already in the cart raises its quantity instead of
  /// creating a second line for the same dish.
  int add({
    required String contextKey,
    required PublicMenuItemModel item,
    int quantity = 1,
  }) {
    if (!_isValidContext(contextKey)) {
      return 0;
    }
    final lines = _linesByContext.putIfAbsent(contextKey, () => <CartLineModel>[]);
    final index = lines.indexWhere((CartLineModel line) => line.itemId == item.id);
    if (index < 0) {
      final line = CartLineModel.fromMenuItem(item, quantity: quantity);
      lines.add(line);
      notifyListeners();
      return line.quantity;
    }
    final updated = lines[index].withQuantity(lines[index].quantity + quantity);
    lines[index] = updated;
    notifyListeners();
    return updated.quantity;
  }

  /// Raises the quantity of an existing line by one.
  void increaseQuantity({required String contextKey, required String itemId}) {
    _changeQuantity(contextKey, itemId, (int quantity) => quantity + 1);
  }

  /// Lowers the quantity of an existing line by one, never below
  /// [minimumCartQuantity]. Use [removeItem] to take a line away entirely.
  void decreaseQuantity({required String contextKey, required String itemId}) {
    _changeQuantity(contextKey, itemId, (int quantity) => quantity - 1);
  }

  /// Takes a line out of the cart for [contextKey].
  void removeItem({required String contextKey, required String itemId}) {
    final lines = _linesByContext[contextKey];
    if (lines == null) {
      return;
    }
    final lengthBefore = lines.length;
    lines.removeWhere((CartLineModel line) => line.itemId == itemId);
    if (lines.length == lengthBefore) {
      return;
    }
    if (lines.isEmpty) {
      _linesByContext.remove(contextKey);
    }
    notifyListeners();
  }

  /// Empties the cart for [contextKey] in one step.
  ///
  /// Used once an order has actually been stored, so the guest's cart matches
  /// what has been ordered instead of offering to send the same dishes again.
  /// Called before the confirmation is shown and never before the database has
  /// confirmed the order, so a failed order leaves the cart exactly as it was.
  void clearFor(String contextKey) {
    if (!_isValidContext(contextKey)) {
      return;
    }
    if (_linesByContext.remove(contextKey) == null) {
      return;
    }
    notifyListeners();
  }

  void _changeQuantity(
    String contextKey,
    String itemId,
    int Function(int quantity) transform,
  ) {
    final lines = _linesByContext[contextKey];
    if (lines == null) {
      return;
    }
    final index = lines.indexWhere((CartLineModel line) => line.itemId == itemId);
    if (index < 0) {
      return;
    }
    lines[index] = lines[index].withQuantity(transform(lines[index].quantity));
    notifyListeners();
  }

  List<CartLineModel> _lines(String contextKey) {
    if (!_isValidContext(contextKey)) {
      return const <CartLineModel>[];
    }
    return _linesByContext[contextKey] ?? const <CartLineModel>[];
  }

  bool _isValidContext(String contextKey) => contextKey.trim().isNotEmpty;
}
