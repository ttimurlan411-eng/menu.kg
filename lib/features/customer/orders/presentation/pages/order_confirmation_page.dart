import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/cart/data/models/cart_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';

/// Shown after the database has confirmed an order was stored.
///
/// Everything on screen comes from the created order the database returned:
/// the number, the total, the currency, the item count and the lines as they were
/// snapshotted when the order was placed. Nothing here is estimated and nothing
/// is guessed — there is deliberately no preparation time and no progress or
/// status wording, because this step has defined no way for a guest to follow an
/// order and inventing one would promise something the app cannot deliver.
class OrderConfirmationPage extends StatelessWidget {
  const OrderConfirmationPage({
    super.key,
    required this.order,
    required this.onBackToMenu,
  });

  /// The order the database confirmed, already parsed.
  final OrderModel order;

  /// Returns the guest to the menu of the table they ordered from.
  final VoidCallback onBackToMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Order placed'),
        // There is nothing to go back to that would still make sense: the cart
        // has been emptied by the order, so leaving with the system back button
        // would land on an empty cart.
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Center(
              child: Column(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Your order has been accepted',
                    key: const Key('orderConfirmationTitle'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Show this number to the staff when you pay.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _OrderSummaryCard(order: order),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('orderConfirmationBackToMenuButton'),
              onPressed: onBackToMenu,
              child: const Text('Back to menu'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The stored facts about the order: number, total, currency and item count.
///
/// Read straight from the created order rather than recomputed from the cart the
/// guest just emptied, so what is shown is what the database recorded.
class _OrderSummaryCard extends StatelessWidget {
  const _OrderSummaryCard({required this.order});

  final OrderModel order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Display labels only, as everywhere else in the customer flow: no
          // restaurant, branch, table or order id is shown.
          Text(order.restaurantName, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '${order.branchName} · ${order.table.label}',
            key: const Key('orderConfirmationTableContext'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('Order number', style: theme.textTheme.bodyLarge),
              const Spacer(),
              Text(
                order.numberLabel,
                key: const Key('orderConfirmationNumber'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('Total', style: theme.textTheme.bodyLarge),
              const Spacer(),
              Text(
                order.totalLabel,
                key: const Key('orderConfirmationTotal'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('Items', style: theme.textTheme.bodyLarge),
              const Spacer(),
              Text(
                '${order.itemCount}',
                key: const Key('orderConfirmationItemCount'),
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 8),
          for (final line in order.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(line.label, style: theme.textTheme.bodyMedium),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    // The cart's own money formatting, so a line cannot look
                    // different here than it did in the cart.
                    formatCartAmount(line.lineTotalMinorUnits, order.currency),
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            // What the order actually is, with nothing added: it was stored, and
            // this step has no way to follow it beyond that.
            'Prices are the ones shown on the menu when you ordered.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
