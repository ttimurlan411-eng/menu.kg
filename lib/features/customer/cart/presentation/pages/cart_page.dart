import 'package:flutter/material.dart';
import 'package:menukg_flutter/app/router/app_router.dart';
import 'package:menukg_flutter/features/customer/cart/data/cart_controller.dart';
import 'package:menukg_flutter/features/customer/cart/data/models/cart_model.dart';
import 'package:menukg_flutter/features/customer/menu/data/repositories/public_menu_repository.dart';
import 'package:menukg_flutter/features/customer/menu/presentation/widgets/menu_image.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/order_access_store.dart';
import 'package:menukg_flutter/features/customer/orders/data/repositories/order_repository.dart';
import 'package:menukg_flutter/features/customer/orders/presentation/order_error_message.dart';
import 'package:menukg_flutter/features/customer/orders/presentation/pages/order_confirmation_page.dart';
import 'package:menukg_flutter/features/customer/product/presentation/pages/product_details_page.dart';

/// The guest's cart for one table, opened from the public menu, and the place
/// where an order is placed from.
///
/// The token that lets a guest come back to their orders is held in an
/// [OrderAccessStore] keyed by [qrToken], never in this page's state, so it is
/// never rebuilt on a rebuild and never reaches a widget that would display it.
///
/// The page is grouped by [qrToken], so it always shows the cart of the table
/// whose menu is on screen, and it never learns a restaurant or table id. The
/// order it sends carries no restaurant, branch or table id either: the same
/// [qrToken] the menu was opened with is the only context that leaves this page,
/// and the database resolves it.
///
/// The cart itself stays the one the public menu created — this page reads and
/// edits that same controller rather than keeping a second copy — and it is
/// emptied only after the database has confirmed the order, so a failed order
/// leaves the guest's choices untouched.
class CartPage extends StatefulWidget {
  const CartPage({
    super.key,
    required this.qrToken,
    required this.cart,
    required this.currency,
    this.repository,
    this.offeredItemIds,
    this.orderRepository,
    this.orderAccessStore,
  });

  /// The opaque QR token whose cart is shown.
  final String qrToken;

  final CartController cart;

  /// Currency of the restaurant the menu came from, used for display only.
  final String currency;

  /// The same read-only menu source the menu itself uses, handed on when a line
  /// is opened. It never adds a second access path.
  final PublicMenuRepository? repository;

  /// Ids the menu behind this cart still offers.
  ///
  /// Passed down from the already loaded menu, so checking that a line is still
  /// available costs no extra database read. When it is null nothing is known
  /// about availability and every line is treated as offered.
  final Set<String>? offeredItemIds;

  /// Where the order is sent, created from the default client when not supplied.
  final OrderRepository? orderRepository;

  /// Where this menu's order access token lives between app runs, created from
  /// the device store when not supplied.
  final OrderAccessStore? orderAccessStore;

  @override
  State<CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> {
  OrderRepository get _orderRepository =>
      widget.orderRepository ?? const OrderRepository();

  /// Where this menu's order token is kept, created from the device store when
  /// not supplied.
  OrderAccessStore get _accessStore =>
      widget.orderAccessStore ?? const DeviceOrderAccessStore();

  /// True from the moment an order is sent until the database answers.
  ///
  /// This is what stops a second tap: the button is disabled while it is set, and
  /// the submit method also returns early if a request is already in flight, so a
  /// double tap cannot produce two orders.
  bool _isPlacingOrder = false;

  String? _orderErrorMessage;

  @override
  void initState() {
    super.initState();
    widget.cart.addListener(_handleCartChanged);
  }

  @override
  void didUpdateWidget(CartPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cart, widget.cart)) {
      oldWidget.cart.removeListener(_handleCartChanged);
      widget.cart.addListener(_handleCartChanged);
    }
    if (widget.qrToken != oldWidget.qrToken) {
      // A different table's cart is on screen, so a message about this table's
      // order no longer applies.
      _orderErrorMessage = null;
    }
  }

  @override
  void dispose() {
    // Removing a listener after the controller is disposed is allowed, so this
    // is safe however the cart page and the cart are torn down.
    widget.cart.removeListener(_handleCartChanged);
    super.dispose();
  }

  void _handleCartChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your cart')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildBody(context)),
            _buildCheckout(context),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final lines = widget.cart.linesFor(widget.qrToken);
    if (lines.isEmpty) {
      return const _EmptyCart();
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: lines.length,
      separatorBuilder: (BuildContext context, int index) =>
          const Divider(height: 1, indent: 16, endIndent: 16),
      itemBuilder: (BuildContext context, int index) {
        final line = lines[index];
        return _CartLineTile(
          line: line,
          currency: widget.currency,
          isOffered: _isOffered(line),
          onIncrease: () => widget.cart.increaseQuantity(
            contextKey: widget.qrToken,
            itemId: line.itemId,
          ),
          onDecrease: () => widget.cart.decreaseQuantity(
            contextKey: widget.qrToken,
            itemId: line.itemId,
          ),
          onRemove: () => widget.cart.removeItem(
            contextKey: widget.qrToken,
            itemId: line.itemId,
          ),
          onOpen: _isOffered(line) ? () => _openDetails(line) : null,
        );
      },
    );
  }

  /// The subtotal and the place order action, always at the foot of the page.
  ///
  /// The lines and the total a guest is about to order are therefore both on
  /// screen at the moment they press the button, and the button is disabled
  /// whenever there is nothing orderable to send.
  Widget _buildCheckout(BuildContext context) {
    final lines = widget.cart.linesFor(widget.qrToken);
    final orderableLines = lines.where(_isOffered).toList();
    final subtotalMinorUnits = _subtotalOfOfferedLines(lines);
    final hasOrderableLines = orderableLines.isNotEmpty;
    final canPlaceOrder = hasOrderableLines && !_isPlacingOrder;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        _CartSummary(
          subtotalMinorUnits: subtotalMinorUnits,
          currency: widget.currency,
          footnote: hasOrderableLines
              ? 'Prices are checked against the menu when your order is placed.'
              : lines.isEmpty
              ? 'Add a dish to place an order.'
              : 'Remove the unavailable dishes to place an order.',
        ),
        if (_orderErrorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _orderErrorMessage!,
              key: const Key('cartOrderErrorMessage'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('placeOrderButton'),
              onPressed: canPlaceOrder ? _placeOrder : null,
              child: _isPlacingOrder
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 12),
                        Text('Placing order...'),
                      ],
                    )
                  : const Text('Place order'),
            ),
          ),
        ),
      ],
    );
  }

/// Sends the orderable lines of this cart to the database.
  ///
  /// The request carries the [qrToken] and the item ids with their quantities and
  /// nothing else: no price, no name, no total, and no restaurant, branch, table
  /// or order id. The database prices the order from the live menu of the
  /// restaurant the token resolved to, which is also what makes an order for
  /// another restaurant impossible from here.
  ///
  /// Lines the menu no longer offers are left out of the request rather than
  /// failed on, so a dish that was switched off after it was added does not block
  /// the rest of the order. An order of nothing is not sent at all.
  ///
  /// The cart is emptied only once the database has confirmed the order, below.
  Future<void> _placeOrder() async {
    if (_isPlacingOrder) {
      return;
    }

    // Nothing orderable is not an error, so it is caught here rather than left to
    // the repository: a request that is never sent must not be reported as an
    // unresolved QR token below.
    final hasOrderableLine = widget.cart
        .linesFor(widget.qrToken)
        .any(_isOffered);
    if (!hasOrderableLine) {
      return;
    }

    setState(() {
      _isPlacingOrder = true;
      _orderErrorMessage = null;
    });

    try {
      // The token is read and kept in a local variable, never in widget state: it
      // is a credential and nothing on screen has any use for it.
      final storedToken = await _accessStore.readToken(
        contextKey: widget.qrToken,
      );

      final created = await _orderRepository.createOrderFromCart(
        qrToken: widget.qrToken,
        cart: widget.cart,
        contextKey: widget.qrToken,
        offeredItemIds: widget.offeredItemIds,
        accessToken: storedToken,
      );

      if (!mounted) {
        return;
      }
      if (created == null) {
        setState(() {
          _isPlacingOrder = false;
          _orderErrorMessage = orderQrUnavailableMessage;
        });
        return;
      }

      // The token the database answered with is stored before the cart is
      // emptied, so a guest who orders again from this menu reuses this identity
      // rather than becoming a new guest. Only this menu's token is touched.
      await _accessStore.writeToken(
        contextKey: widget.qrToken,
        token: created.accessToken,
      );

      // The cart is emptied only now, after the database has confirmed the
      // order. Above this line nothing has been removed, so a failure anywhere
      // earlier leaves the guest's cart exactly as it was.
      widget.cart.clearFor(widget.qrToken);
      await _openConfirmation(created.order);
    } catch (error) {
      debugPrint('Placing an order failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _isPlacingOrder = false;
        _orderErrorMessage = orderErrorMessage(error);
      });
    }
  }

  /// Shows what was stored, replacing this page so the emptied cart is not left
  /// behind the confirmation.
  ///
  /// The route goes through [AppRouter] like every other route in the app, so
  /// there is one place that decides which page a name resolves to.
  Future<void> _openConfirmation(OrderModel order) async {
    await Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute<void>(
        settings: RouteSettings(
          name: AppRouter.orderConfirmationRouteName,
          arguments: order,
        ),
        builder: (BuildContext context) => OrderConfirmationPage(
          order: order,
          onBackToMenu: () => Navigator.of(context).maybePop(),
        ),
      ),
    );

    if (!mounted) {
      return;
    }
    setState(() {
      _isPlacingOrder = false;
      _orderErrorMessage = null;
    });
  }

  /// Whether the menu behind this cart still offers [line].
  bool _isOffered(CartLineModel line) =>
      widget.offeredItemIds?.contains(line.itemId) ?? true;

  /// The total of the lines that can still be ordered.
  ///
  /// A line the menu no longer offers is left out rather than quietly added to a
  /// total the guest cannot get, which is why the sum is taken here and not from
  /// [CartController.subtotalMinorUnitsFor].
  int _subtotalOfOfferedLines(List<CartLineModel> lines) {
    return lines
        .where(_isOffered)
        .fold<int>(0, (int total, CartLineModel line) => total + line.lineTotalMinorUnits);
  }

  /// Opens the details of a line, keeping the table context and the cart.
  Future<void> _openDetails(CartLineModel line) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => ProductDetailsPage(
          qrToken: widget.qrToken,
          itemId: line.itemId,
          repository: widget.repository,
          cart: widget.cart,
        ),
      ),
    );
  }
}

class _CartLineTile extends StatelessWidget {
  const _CartLineTile({
    required this.line,
    required this.currency,
    required this.isOffered,
    required this.onIncrease,
    required this.onDecrease,
    required this.onRemove,
    this.onOpen,
  });

  final CartLineModel line;
  final String currency;
  final bool isOffered;
  final VoidCallback onIncrease;
  final VoidCallback onDecrease;
  final VoidCallback onRemove;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      key: Key('cartLine_${line.itemId}'),
      onTap: onOpen,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: MenuImage(
        url: line.imageUrl,
        height: 56,
        width: 56,
        borderRadius: BorderRadius.circular(12),
      ),
      title: Text(
        line.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: isOffered ? null : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isOffered) ...[
            Text(
              'No longer available',
              key: const Key('cartLineUnavailable'),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Row(
            children: [
              _QuantityStepper(
                quantity: line.quantity,
                onIncrease: onIncrease,
                onDecrease: onDecrease,
              ),
              const SizedBox(width: 4),
              IconButton(
                key: Key('cartLineRemove_${line.itemId}'),
                onPressed: onRemove,
                tooltip: 'Remove ${line.name}',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ],
      ),
      trailing: Text(
        formatCartAmount(line.lineTotalMinorUnits, currency),
        key: Key('cartLineTotal_${line.itemId}'),
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _QuantityStepper extends StatelessWidget {
  const _QuantityStepper({
    required this.quantity,
    required this.onIncrease,
    required this.onDecrease,
  });

  final int quantity;
  final VoidCallback onIncrease;
  final VoidCallback onDecrease;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canDecrease = quantity > minimumCartQuantity;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('cartLineDecrease'),
          onPressed: canDecrease ? onDecrease : null,
          tooltip: 'Decrease quantity',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text(
          '$quantity',
          key: const Key('cartLineQuantity'),
          style: theme.textTheme.titleMedium,
        ),
        IconButton(
          key: const Key('cartLineIncrease'),
          onPressed: onIncrease,
          tooltip: 'Increase quantity',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}

class _CartSummary extends StatelessWidget {
  const _CartSummary({
    required this.subtotalMinorUnits,
    required this.currency,
    required this.footnote,
  });

  final int subtotalMinorUnits;
  final String currency;
  final String footnote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Subtotal', style: theme.textTheme.titleMedium),
              const Spacer(),
              Text(
                formatCartAmount(subtotalMinorUnits, currency),
                key: const Key('cartSubtotal'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            footnote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyCart extends StatelessWidget {
  const _EmptyCart();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.shopping_cart_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'Your cart is empty.',
              key: const Key('cartEmptyMessage'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Add a dish from the menu to see it here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
