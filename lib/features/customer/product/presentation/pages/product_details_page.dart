import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/cart/data/cart_controller.dart';
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';
import 'package:menukg_flutter/features/customer/menu/data/repositories/public_menu_repository.dart';
import 'package:menukg_flutter/features/customer/menu/presentation/public_menu_error_message.dart';
import 'package:menukg_flutter/features/customer/menu/presentation/widgets/menu_image.dart';

/// Customer-facing details for one dish, opened from the public menu.
///
/// The page deliberately has no route of its own: it is pushed onto the public
/// menu, so it is always reached with a [qrToken] that has already been
/// resolved to a real table. It reloads that same menu through
/// [PublicMenuRepository] — the exact read-only path the public menu uses — and
/// looks the product up *inside* it with [PublicMenuModel.findItemById].
///
/// That is what keeps products private. There is no `/product/<id>` route and no
/// new database access, so an id from another restaurant, or a dish that has
/// just been switched off, simply does not resolve and renders the same safe
/// "not available" state as an unknown product — with no way to add it to a cart.
class ProductDetailsPage extends StatefulWidget {
  const ProductDetailsPage({
    super.key,
    required this.qrToken,
    required this.itemId,
    this.repository,
    this.cart,
  });

  /// The opaque QR token of the table this guest is sitting at.
  ///
  /// Used to re-resolve the menu and to key the guest's cart. No table,
  /// restaurant or branch id is accepted or exposed here.
  final String qrToken;

  /// Id of the menu item to show, looked up within the resolved menu.
  final String itemId;

  final PublicMenuRepository? repository;

  /// The cart this dish is added to.
  ///
  /// The public menu passes the cart of the table it is showing, so the cart
  /// lives for as long as that menu does. When the page is opened without one it
  /// creates a cart of its own, which keeps it usable on its own and keeps the
  /// cart local either way.
  final CartController? cart;

  @override
  State<ProductDetailsPage> createState() => _ProductDetailsPageState();
}

class _ProductDetailsPageState extends State<ProductDetailsPage> {
  PublicMenuRepository get _repository =>
      widget.repository ?? const PublicMenuRepository();

  late CartController _cart;
  bool _ownsCart = false;

  PublicMenuModel? _menu;
  ({PublicCategoryModel category, PublicMenuItemModel item})? _found;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _adoptCart(widget.cart);
    _loadProduct();
  }

  @override
  void didUpdateWidget(ProductDetailsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cart, widget.cart)) {
      _cart.removeListener(_handleCartChanged);
      if (_ownsCart) {
        _cart.dispose();
      }
      _adoptCart(widget.cart);
    }
  }

  @override
  void dispose() {
    // Removing a listener after the controller is disposed is allowed, so this
    // is safe however the page and the cart are torn down.
    _cart.removeListener(_handleCartChanged);
    if (_ownsCart) {
      _cart.dispose();
    }
    super.dispose();
  }

  void _adoptCart(CartController? cart) {
    _ownsCart = cart == null;
    _cart = cart ?? CartController();
    _cart.addListener(_handleCartChanged);
  }

  void _handleCartChanged() => setState(() {});

  Future<void> _loadProduct() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final menu = await _repository.getMenuByQrToken(widget.qrToken);
      if (!mounted) {
        return;
      }
      setState(() {
        _menu = menu;
        // A null menu, or an id that is not in this menu, is the same safe
        // outcome for the guest: this dish is not available.
        _found = menu?.findItemById(widget.itemId);
        _isLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('Loading product details failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = publicMenuErrorMessage(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;

    return Scaffold(
      appBar: AppBar(title: const Text('Product')),
      body: SafeArea(child: _buildBody(context)),
      // Only offered dishes can be added, so the bar appears with the dish
      // rather than next to a "no longer available" message.
      bottomNavigationBar: found == null
          ? null
          : _AddToCartBar(
              quantityInCart: _quantityInCart(found.item.id),
              onAdd: _addToCart,
            ),
    );
  }

  /// How many of [itemId] the cart for this table already holds.
  int _quantityInCart(String itemId) {
    final lines = _cart.linesFor(widget.qrToken);
    for (final line in lines) {
      if (line.itemId == itemId) {
        return line.quantity;
      }
    }
    return 0;
  }

  void _addToCart() {
    final found = _found;
    if (found == null) {
      return;
    }
    // Adding the same dish again raises the quantity of its line, and the
    // button stays put so the guest can keep browsing from here.
    _cart.add(contextKey: widget.qrToken, item: found.item);
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading product...'),
          ],
        ),
      );
    }

    if (_errorMessage case final message?) {
      return _MessageState(
        message: message,
        icon: Icons.cloud_off_outlined,
        onRetry: _loadProduct,
      );
    }

    final found = _found;
    final menu = _menu;
    if (found == null || menu == null) {
      // Covers a deleted dish, a dish that is no longer available, and an id
      // that does not belong to this table's restaurant.
      return const _MessageState(
        message: 'This dish is no longer available.',
        icon: Icons.no_meals_outlined,
      );
    }

    return _ProductDetailsBody(
      item: found.item,
      categoryName: found.category.name,
      currency: menu.restaurant.currency,
      restaurantName: menu.restaurant.name,
      tableLabel: menu.table.label,
    );
  }
}

/// The cart action for one dish, kept in a bottom bar so it is reachable with a
/// thumb and never sits inside the scrolling details.
class _AddToCartBar extends StatelessWidget {
  const _AddToCartBar({
    required this.quantityInCart,
    required this.onAdd,
  });

  final int quantityInCart;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const Key('addToCartButton'),
            onPressed: onAdd,
            icon: const Icon(Icons.add_shopping_cart),
            // The dish name is already the page title, so the label stays short
            // and reports how many of it the cart holds.
            label: Text(
              quantityInCart > 0
                  ? 'Add to cart · $quantityInCart'
                  : 'Add to cart',
            ),
          ),
        ),
      ),
    );
  }
}

class _ProductDetailsBody extends StatelessWidget {
  const _ProductDetailsBody({
    required this.item,
    required this.categoryName,
    required this.currency,
    required this.restaurantName,
    required this.tableLabel,
  });

  final PublicMenuItemModel item;
  final String categoryName;
  final String currency;
  final String restaurantName;
  final String tableLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        MenuImage(
          url: item.mainImageUrl,
          height: 220,
          width: double.infinity,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                categoryName.toUpperCase(),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(item.name, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              _PriceRow(item: item, currency: currency),
              if (item.description case final description?) ...[
                const SizedBox(height: 16),
                Text(description, style: theme.textTheme.bodyLarge),
              ],
              const SizedBox(height: 20),
              const _AvailabilityBadge(),
              if (item.preparationTimeMinutes > 0) ...[
                const SizedBox(height: 8),
                Text(
                  'About ${item.preparationTimeMinutes} min',
                  key: const Key('productPreparationTime'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  // Table context, so the guest stays oriented. These are
                  // display labels; no ids are shown.
                  '$restaurantName · $tableLabel',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PriceRow extends StatelessWidget {
  const _PriceRow({required this.item, required this.currency});

  final PublicMenuItemModel item;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          formatPublicPrice(item.price, currency),
          key: const Key('productPrice'),
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: item.hasDiscount ? theme.colorScheme.error : null,
          ),
        ),
        if (item.hasDiscount) ...[
          const SizedBox(width: 8),
          Text(
            formatPublicPrice(item.oldPrice!, currency),
            key: const Key('productOldPrice'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              decoration: TextDecoration.lineThrough,
            ),
          ),
        ],
      ],
    );
  }
}

/// A dish only reaches this page when it is in the resolved menu, which the
/// database already filtered to available items.
class _AvailabilityBadge extends StatelessWidget {
  const _AvailabilityBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.check_circle_outline,
          size: 18,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 6),
        Text(
          'Available',
          key: const Key('productAvailabilityBadge'),
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.message,
    required this.icon,
    this.onRetry,
  });

  final String message;
  final IconData icon;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              message,
              key: const Key('productMessage'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('productRetryButton'),
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
