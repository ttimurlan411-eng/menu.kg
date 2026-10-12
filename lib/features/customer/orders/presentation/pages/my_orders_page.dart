import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/cart/data/models/cart_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/order_access_store.dart';
import 'package:menukg_flutter/features/customer/orders/data/repositories/order_repository.dart';
import 'package:menukg_flutter/features/customer/orders/presentation/order_error_message.dart';

/// The guest's own orders, read back with the order access token on this device.
///
/// There is no account to sign in with, so this page is honest about what it is:
/// the orders placed from the QR context it was opened for, on this device, and
/// nothing else. A guest who changes phone, or clears app data, sees an empty
/// list, because the token is the only credential and it is gone. Saying that
/// plainly is better than a list that quietly hides orders the guest remembers
/// making — and it is the same limit "My Reservations" already states, for the
/// same reason.
///
/// The token is read once, passed straight to the repository and then dropped: it
/// is a credential, nothing on screen has a use for it, and it is never held in
/// this page's state or rendered anywhere.
class MyOrdersPage extends StatefulWidget {
  const MyOrdersPage({
    super.key,
    required this.contextKey,
    this.repository,
    this.accessStore,
  });

  /// The QR token of the menu this list belongs to.
  ///
  /// It is not a credential and is not sent to the database: it selects which
  /// stored token to read, so a menu and its orders stay one context. Required
  /// rather than optional because a list of orders with no context has no
  /// defensible answer — it would be every order this device ever placed.
  final String contextKey;

  final OrderRepository? repository;
  final OrderAccessStore? accessStore;

  @override
  State<MyOrdersPage> createState() => _MyOrdersPageState();
}

class _MyOrdersPageState extends State<MyOrdersPage> {
  late OrderRepository _repository =
      widget.repository ?? const OrderRepository();
  late OrderAccessStore _accessStore =
      widget.accessStore ?? const DeviceOrderAccessStore();

  /// `null` while loading, a list once loaded.
  List<OrderModel>? _orders;
  String? _errorMessage;
  bool _isLoading = true;

  @override
  void didUpdateWidget(MyOrdersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository)) {
      _repository = widget.repository ?? const OrderRepository();
    }
    if (!identical(oldWidget.accessStore, widget.accessStore)) {
      _accessStore = widget.accessStore ?? const DeviceOrderAccessStore();
    }
    // The context itself changing means this list is no longer about the orders
    // on screen, so it is loaded again rather than left showing the old table's.
    if (oldWidget.contextKey != widget.contextKey) {
      _load();
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Read for this context only: a token stored for another table is a
      // different guest, and reading it here would list another context's orders.
      final token = await _accessStore.readToken(contextKey: widget.contextKey);
      final orders = await _repository.getMyOrders(token);
      if (!mounted) {
        return;
      }
      setState(() {
        _orders = orders;
        _isLoading = false;
      });
    } catch (error) {
      debugPrint('Loading orders failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = orderListErrorMessage(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My orders'),
        actions: [
          IconButton(
            key: const Key('reloadOrdersButton'),
            onPressed: _isLoading ? null : _load,
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading && _orders == null) {
      return const Center(
        child: CircularProgressIndicator(key: Key('ordersLoading')),
      );
    }

    if (_errorMessage != null && _orders == null) {
      return _MessagePane(
        icon: Icons.cloud_off_outlined,
        message: _errorMessage!,
        actionLabel: 'Try again',
        onAction: _load,
        actionKey: const Key('retryOrdersButton'),
      );
    }

    final orders = _orders ?? const [];
    if (orders.isEmpty) {
      return const _MessagePane(
        key: Key('ordersEmptyState'),
        icon: Icons.receipt_long_outlined,
        // Covers both a device that never ordered and a token the database no
        // longer recognises: the two are the same answer, so the wording does not
        // guess which one it is.
        message: 'No orders on this device yet.\n'
            'Open a table QR code to place one.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: orders.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) => _OrderHistoryCard(order: orders[index]),
    );
  }
}

/// One past order: when it was placed, what it holds and what it came to.
///
/// Everything comes from the stored snapshots, so a dish renamed or repriced since,
/// or deleted altogether, still reads exactly as the guest ordered it.
class _OrderHistoryCard extends StatelessWidget {
  const _OrderHistoryCard({required this.order});

  final OrderModel order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      key: Key('orderCard_${order.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        order.numberLabel,
                        key: Key('orderHistoryNumber_${order.id}'),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      // Display labels only, as everywhere in the customer flow: no
                      // restaurant, branch, table or order id is shown.
                      Text(
                        '${order.restaurantName} · ${order.branchName}',
                        style: theme.textTheme.bodyMedium,
                      ),
                      Text(
                        order.table.label,
                        key: Key('orderHistoryTable_${order.id}'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Chip(
                  label: Text(
                    order.status.displayLabel,
                    key: Key('orderHistoryStatus_${order.id}'),
                  ),
                  labelStyle: theme.textTheme.labelMedium,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              formatOrderPlacedAt(order.createdAt),
              key: Key('orderHistoryPlacedAt_${order.id}'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            for (var index = 0; index < order.lines.length; index++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        order.lines[index].label,
                        key: Key(
                          'orderHistoryLine_${order.id}_$index',
                        ),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      // The line total the database stored, formatted with the
                      // cart's own money formatting so a line cannot look
                      // different here than it did when it was ordered.
                      formatCartAmount(
                        order.lines[index].lineTotalMinorUnits,
                        order.currency,
                      ),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('${order.itemCount} items', style: theme.textTheme.bodyMedium),
                const Spacer(),
                Text('Total', style: theme.textTheme.bodyMedium),
                const SizedBox(width: 8),
                Text(
                  // The stored order total, not a sum recomputed here, so what is
                  // shown is what the database recorded for the whole order.
                  order.totalLabel,
                  key: Key('orderHistoryTotal_${order.id}'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MessagePane extends StatelessWidget {
  const _MessagePane({
    super.key,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.actionKey,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                key: actionKey,
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
