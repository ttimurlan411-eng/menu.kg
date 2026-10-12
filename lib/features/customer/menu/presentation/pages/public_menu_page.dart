import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/cart/data/cart_controller.dart';
import 'package:menukg_flutter/features/customer/cart/presentation/pages/cart_page.dart';
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';
import 'package:menukg_flutter/features/customer/menu/data/repositories/public_menu_repository.dart';
import 'package:menukg_flutter/features/customer/menu/presentation/public_menu_error_message.dart';
import 'package:menukg_flutter/features/customer/menu/presentation/widgets/menu_image.dart';
import 'package:menukg_flutter/features/customer/orders/data/order_access_store.dart';
import 'package:menukg_flutter/features/customer/orders/data/repositories/order_repository.dart';
import 'package:menukg_flutter/features/customer/orders/presentation/pages/my_orders_page.dart';
import 'package:menukg_flutter/features/customer/product/presentation/pages/product_details_page.dart';
import 'package:menukg_flutter/features/customer/reservations/data/repositories/reservation_repository.dart';
import 'package:menukg_flutter/features/customer/reservations/data/reservation_access_store.dart';
import 'package:menukg_flutter/features/customer/reservations/presentation/pages/my_reservations_page.dart';
import 'package:menukg_flutter/features/customer/reservations/presentation/pages/reservation_form_page.dart';

/// The public, mobile-first customer menu opened from a table QR code.
///
/// Guests need no account, so this page never redirects to sign-in and offers
/// no admin action. The cart it opens is local and belongs to the table whose
/// QR token opened this menu, and that same token is what an order placed from
/// the cart is scoped to. Payment is deliberately out of scope.
class PublicMenuPage extends StatefulWidget {
  const PublicMenuPage({
    super.key,
    required this.qrToken,
    this.repository,
    this.cart,
    this.reservationRepository,
    this.reservationAccessStore,
    this.orderRepository,
    this.orderAccessStore,
  });

  /// The opaque QR token from the scanned link. Never a table id.
  final String qrToken;

  final PublicMenuRepository? repository;

  /// The cart for this table's menu.
  ///
  /// Created by the page when it is not supplied, so a cart lives exactly as
  /// long as the menu that filled it and is empty again on the next visit.
  final CartController? cart;

  /// Reservations for this table, created by the page when not supplied.
  final ReservationRepository? reservationRepository;

  /// Where the guest's reservation token lives between app runs.
  final ReservationAccessStore? reservationAccessStore;

  /// Where an order from this table's cart is sent, created when not supplied.
  final OrderRepository? orderRepository;

  /// Where this menu's order access token lives between app runs.
  ///
  /// Separate from [reservationAccessStore] on purpose: the two tokens are
  /// different capabilities and neither store can read or overwrite the other.
  final OrderAccessStore? orderAccessStore;

  @override
  State<PublicMenuPage> createState() => _PublicMenuPageState();
}

class _PublicMenuPageState extends State<PublicMenuPage> {
  PublicMenuRepository get _repository =>
      widget.repository ?? const PublicMenuRepository();

  late CartController _cart;
  bool _ownsCart = false;

  PublicMenuModel? _menu;
  bool _isLoading = true;
  String? _errorMessage;
  String? _selectedCategoryId;

  @override
  void initState() {
    super.initState();
    _adoptCart(widget.cart);
    _loadMenu();
  }

  @override
  void didUpdateWidget(PublicMenuPage oldWidget) {
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
    // is safe however the menu and the cart are torn down.
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

  Future<void> _loadMenu() async {
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
        _isLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('Loading public menu failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        // The menu could not be loaded at all, so the error state offers a retry.
        _errorMessage = publicMenuErrorMessage(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(child: _buildBody(context)),
      floatingActionButton: _buildActions(),
    );
  }

  /// The cart and reservation buttons, shown only once there is a menu worth
  /// ordering from.
  ///
  /// Stacked in one column so neither covers the other: the cart is the reason
  /// most guests stay on this page, and reserving is the less frequent action,
  /// so the cart stays closest to the thumb.
  Widget? _buildActions() {
    final menu = _menu;
    if (menu == null || menu.isEmpty) {
      return null;
    }

    final itemCount = _cart.itemCountFor(widget.qrToken);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        FloatingActionButton(
          key: const Key('cartButton'),
          // Both buttons would otherwise carry the same default hero tag, which
          // two floating buttons in one subtree may not do.
          heroTag: 'publicMenuCartButton',
          tooltip: 'Your cart',
          onPressed: _openCart,
          child: Badge(
            isLabelVisible: itemCount > 0,
            label: Text('$itemCount'),
            child: const Icon(Icons.shopping_cart_outlined),
          ),
        ),
        const SizedBox(height: 12),
        FloatingActionButton(
          key: const Key('reserveTableButton'),
          heroTag: 'publicMenuReserveTableButton',
          tooltip: 'Reserve this table',
          onPressed: _openReservationForm,
          child: const Icon(Icons.event_available_outlined),
        ),
      ],
    );
  }

  /// Pushes the form that books this table.
  ///
  /// The menu already resolved the QR token, so the form inherits the exact
  /// table, branch and restaurant the guest is sitting at as display labels and
  /// cannot be pointed at another table.
  void _openReservationForm() {
    final menu = _menu;
    if (menu == null) {
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => ReservationFormPage(
          qrToken: widget.qrToken,
          tableLabel: menu.table.label,
          restaurantName: menu.restaurant.name,
          branchName: menu.branch.name,
          repository: widget.reservationRepository,
          accessStore: widget.reservationAccessStore,
        ),
      ),
    );
  }

  /// Pushes the product details page for [item].
  ///
  /// The page is pushed rather than routed so it always sits on top of this
  /// menu: the guest keeps their table context and the back action returns to
  /// the exact menu, filter and scroll position. The same cart travels with it,
  /// so a dish added from the details is in the cart this menu shows.
  void _openProduct(PublicMenuItemModel item) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => ProductDetailsPage(
          qrToken: widget.qrToken,
          itemId: item.id,
          repository: widget.repository,
          cart: _cart,
        ),
      ),
    );
  }

  /// Pushes the cart of this table, offering the ids the loaded menu still has.
  void _openCart() {
    final menu = _menu;
    if (menu == null) {
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => CartPage(
          qrToken: widget.qrToken,
          cart: _cart,
          currency: menu.restaurant.currency,
          repository: widget.repository,
          // Read from the menu already in memory, so opening the cart costs no
          // further database read.
          offeredItemIds: {for (final category in menu.categories) ...category.items.map((item) => item.id)},
          // The same order source the cart page would build for itself, handed on
          // so a test can observe the real request this flow sends.
          orderRepository: widget.orderRepository,
          orderAccessStore: widget.orderAccessStore,
        ),
      ),
    );
  }

  /// Pushes the guest's own reservations for this device.
  void _openMyReservations() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => MyReservationsPage(
          repository: widget.reservationRepository,
          accessStore: widget.reservationAccessStore,
        ),
      ),
    );
  }

  /// Pushes the orders this device placed from this table's menu.
  ///
  /// Pushed like [MyReservationsPage] rather than routed: a past order is only
  /// reachable from the menu it was placed from, because that menu's QR token is
  /// what selects the stored order token. A URL could name no context at all, so
  /// the public QR route stays untouched and both guest lists keep one way in.
  void _openMyOrders() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => MyOrdersPage(
          contextKey: widget.qrToken,
          repository: widget.orderRepository,
          accessStore: widget.orderAccessStore,
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const _LoadingState();
    }

    final menu = _menu;
    if (menu == null) {
      return _ErrorState(
        message: _errorMessage ?? 'This menu is not available right now.',
        onRetry: _loadMenu,
      );
    }

    if (menu.isEmpty) {
      return _EmptyMenu(restaurant: menu.restaurant);
    }

    return _buildMenu(context, menu);
  }

  Widget _buildMenu(BuildContext context, PublicMenuModel menu) {
    final theme = Theme.of(context);
    // A selected category can stop being offered while the menu is open, for
    // example when its last dish is switched off. It would then match nothing,
    // so the filter falls back to the full menu instead of emptying the screen.
    // Both branches read the menu that is already in memory: a category tap
    // never asks the database for anything.
    final selectedCategoryId = menu.offersCategory(_selectedCategoryId)
        ? _selectedCategoryId
        : null;
    final showsAllCategories = selectedCategoryId == null;
    final visibleCategories = showsAllCategories
        ? menu.categories
        : menu.categories
              .where((category) => category.id == selectedCategoryId)
              .toList();

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _RestaurantHeader(menu: menu)),
        SliverToBoxAdapter(
          child: _CategoryFilterBar(
            categories: menu.categories,
            selectedCategoryId: selectedCategoryId,
            onSelected: (categoryId) =>
                setState(() => _selectedCategoryId = categoryId),
          ),
        ),
        for (final category in visibleCategories)
          SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: _CategoryHeader(
                  category: category,
                  currency: menu.restaurant.currency,
                ),
              ),
              SliverList.separated(
                itemCount: category.items.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final item = category.items[index];
                  return _MenuItemTile(
                    key: Key('menuItem_${item.id}'),
                    item: item,
                    currency: menu.restaurant.currency,
                    // Keeps the QR context: the product page re-resolves the
                    // same token instead of trusting the id on its own.
                    onTap: () => _openProduct(item),
                  );
                },
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        SliverToBoxAdapter(
          child: Padding(
            // Extra room at the bottom keeps this note clear of the stacked
            // cart and reservation buttons.
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 168),
            child: Column(
              children: [
                Text(
                  'Prices are the ones shown here. Your order is placed against '
                  'this menu when you confirm it in the cart.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                // The one way back into past reservations for a guest who
                // reopens the app: there is no account and no tab bar to hang
                // this on, and the access token only lives on this device.
                TextButton(
                  key: const Key('myReservationsButton'),
                  onPressed: _openMyReservations,
                  child: const Text('My reservations'),
                ),
                // The same for past orders, scoped to this menu by the order token
                // stored under this QR context.
                TextButton(
                  key: const Key('myOrdersButton'),
                  onPressed: _openMyOrders,
                  child: const Text('My orders'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Shows the restaurant, branch and table the guest is sitting at.
class _RestaurantHeader extends StatelessWidget {
  const _RestaurantHeader({required this.menu});

  final PublicMenuModel menu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final restaurant = menu.restaurant;
    final coverUrl = restaurant.coverUrl;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (coverUrl != null)
          MenuImage(
            url: coverUrl,
            height: 160,
            borderRadius: BorderRadius.zero,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (restaurant.logoUrl case final logoUrl?)
                MenuImage(
                  url: logoUrl,
                  height: 56,
                  width: 56,
                  borderRadius: BorderRadius.circular(12),
                ),
              if (restaurant.logoUrl != null) const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      restaurant.name,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 4),
                    // Branch and table are display labels only. No ids are shown.
                    Text(
                      '${menu.branch.name} · ${menu.table.label}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (restaurant.description case final description?) ...[
                      const SizedBox(height: 8),
                      Text(description, style: theme.textTheme.bodyMedium),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Horizontal category chips used to filter the menu.
///
/// The bar is tall enough for the chips to keep the full 48dp tap target, so
/// switching category stays comfortable with a thumb.
class _CategoryFilterBar extends StatelessWidget {
  const _CategoryFilterBar({
    required this.categories,
    required this.selectedCategoryId,
    required this.onSelected,
  });

  final List<PublicCategoryModel> categories;
  final String? selectedCategoryId;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FilterChip(
              key: const Key('categoryChip_all'),
              label: const Text('All'),
              selected: selectedCategoryId == null,
              onSelected: (_) => onSelected(null),
            ),
          ),
          for (final category in categories)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FilterChip(
                key: Key('categoryChip_${category.id}'),
                label: Text(category.name),
                selected: selectedCategoryId == category.id,
                onSelected: (isSelected) =>
                    onSelected(isSelected ? category.id : null),
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.category, required this.currency});

  final PublicCategoryModel category;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final details = <String>[
      category.name,
      '${category.items.length} item${category.items.length == 1 ? '' : 's'}',
      formatPublicPrice(
        category.items
            .map((item) => item.price)
            .reduce((lowest, price) => price < lowest ? price : lowest),
        currency,
      ),
    ];

    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Text(details.join(' · '), style: theme.textTheme.titleMedium),
    );
  }
}

class _MenuItemTile extends StatelessWidget {
  const _MenuItemTile({
    super.key,
    required this.item,
    required this.currency,
    required this.onTap,
  });

  final PublicMenuItemModel item;
  final String currency;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageUrl = item.mainImageUrl;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      title: Text(item.name, style: theme.textTheme.titleMedium),
      subtitle: item.description == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(item.description!, style: theme.textTheme.bodyMedium),
            ),
      trailing: _PriceLabel(item: item, currency: currency),
      leading: imageUrl == null
          ? null
          : MenuImage(
              url: imageUrl,
              height: 56,
              width: 56,
              borderRadius: BorderRadius.circular(10),
            ),
      onTap: onTap,
    );
  }
}

class _PriceLabel extends StatelessWidget {
  const _PriceLabel({required this.item, required this.currency});

  final PublicMenuItemModel item;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (item.hasDiscount)
          Text(
            formatPublicPrice(item.oldPrice!, currency),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              decoration: TextDecoration.lineThrough,
            ),
          ),
        Text(
          formatPublicPrice(item.price, currency),
          key: Key('menuItemPrice_${item.id}'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: item.hasDiscount ? theme.colorScheme.error : null,
          ),
        ),
      ],
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading menu...'),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

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
              Icons.qr_code_2_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              key: const Key('publicMenuErrorMessage'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('publicMenuRetryButton'),
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the restaurant is active but has no available dishes yet.
class _EmptyMenu extends StatelessWidget {
  const _EmptyMenu({required this.restaurant});

  final PublicRestaurantInfo restaurant;

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
              Icons.restaurant_menu_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              restaurant.name,
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'The menu is being updated. Please check back shortly.',
              key: const Key('publicMenuEmptyMessage'),
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