import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/cart/data/models/cart_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_order_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_order_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_order_actions.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_order_error_message.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/widgets/staff_order_status_chip.dart';

/// One order, in full, for the staff member who has to act on it.
///
/// Read-only apart from the status. There is no editing of any kind here: no quantity
/// to change, no line to remove, no note to add and no table to move the order to,
/// because `staff_set_order_status` changes a status and nothing else and the
/// database offers no way to change a line. A screen that offered a line editor would
/// be offering something the backend cannot carry out.
///
/// The status actions are the role's own, filtered by [staffOrderActionsFor], and they
/// are buttons on named moves rather than a free choice of statuses. That is a
/// convenience, not a rule: the database re-checks the role and the lifecycle on
/// every call, so a move refused here is refused there too and is reported as the
/// lifecycle's answer rather than as a permission problem.
///
/// This page reads the order it was given rather than re-reading it, because Step 25
/// defines no single-order read and inventing one would widen the access path for no
/// reason. The list that opened this page reloads when the page is closed, so a
/// refused move or a change made on another device is shown on return.
class StaffOrderDetailsPage extends StatefulWidget {
  const StaffOrderDetailsPage({
    super.key,
    required this.order,
    required this.role,
    this.repository = const StaffOrderRepository(),
  });

  /// The order to show, as the staff list already holds it.
  final StaffOrderModel order;

  /// The signed-in member's role in this restaurant, which decides the actions shown.
  final String role;

  final StaffOrderRepository repository;

  @override
  State<StaffOrderDetailsPage> createState() => _StaffOrderDetailsPageState();
}

class _StaffOrderDetailsPageState extends State<StaffOrderDetailsPage> {
  late StaffOrderModel _order = widget.order;
  bool _isChangingStatus = false;

  Future<void> _changeStatus(OrderStatus target) async {
    setState(() => _isChangingStatus = true);

    try {
      final update = await widget.repository.setOrderStatus(
        orderId: _order.id,
        status: target,
      );

      if (!mounted) {
        return;
      }

      if (update == null) {
        // The database accepted the call but the answer is not a status change this
        // client can read, so nothing is claimed: the order keeps the status it had.
        _showMessage(
          'We could not confirm that change. Pull to refresh on the orders list.',
        );
        return;
      }

      setState(() {
        _order = _order.withStatus(
          update.status,
          updatedAt: update.updatedAt,
        );
      });
      _showMessage(
        'Order ${_order.numberLabel} is now ${update.status.displayLabel.toLowerCase()}.',
      );
    } catch (error, stackTrace) {
      debugPrint('Changing an order status failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      // The wording comes from staffOrderStatusErrorMessage, which tells a refused
      // move, a role that cannot make it and an ended session apart without exposing
      // anything from the database's own message.
      _showMessage(staffOrderStatusErrorMessage(error));
    } finally {
      if (mounted) {
        setState(() => _isChangingStatus = false);
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actions = staffOrderActionsFor(
      role: widget.role,
      status: _order.status,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text('Order ${_order.numberLabel}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: StaffOrderStatusChip(status: _order.status)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DetailRow(
                    icon: Icons.tag,
                    label: 'Order number',
                    value: _order.numberLabel,
                  ),
                  _DetailRow(
                    icon: Icons.table_restaurant_outlined,
                    label: 'Table',
                    value: _order.tableLabel,
                  ),
                  _DetailRow(
                    icon: Icons.schedule_outlined,
                    label: 'Placed',
                    value: formatOrderPlacedAt(_order.createdAt),
                  ),
                  _DetailRow(
                    icon: Icons.local_dining_outlined,
                    label: 'Items',
                    value: '${_order.itemCount}',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Ordered items', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  for (final line in _order.lines)
                    _OrderLineRow(line: line, currency: _order.currency),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('Total', style: theme.textTheme.titleMedium),
                        ),
                        Text(
                          _order.totalLabel,
                          key: const Key('staffOrderTotal'),
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('Next step', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            _actionsHint(actions),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          if (actions.isEmpty)
            Semantics(
              liveRegion: true,
              child: Text(
                _order.status.isTerminal
                    ? 'This order has finished. Nothing more to do.'
                    : 'No status change is available to you for this order.',
                key: const Key('staffOrderNoActions'),
                style: theme.textTheme.bodyMedium,
              ),
            )
          else
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final action in actions)
                  _StatusActionButton(
                    status: action,
                    isBusy: _isChangingStatus,
                    onPressed: () => _changeStatus(action),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// Says what this role may do next, or plainly that there is nothing to do.
  String _actionsHint(List<OrderStatus> actions) {
    if (actions.isEmpty) {
      return _order.status.isTerminal
          ? 'A ${_order.status.displayLabel.toLowerCase()} order is finished.'
          : 'Your role does not move an order out of this status.';
    }
    if (_order.status.isTerminal) {
      return 'This order is finished.';
    }
    return 'Only the moves your role can make are shown.';
  }
}

/// A labelled value, with the icon that names it.
///
/// The status is not repeated here: it is the chip in the app bar, which is where the
/// eye goes first, and a screen that says the same word twice in two weights reads as
/// two different facts.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyLarge,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// One ordered line, with the quantity, the unit price and the line total.
///
/// The names and amounts are the snapshots the guest ordered, not live menu values,
/// so a dish renamed or repriced since cannot make this screen disagree with what was
/// actually ordered. Every amount carries the order's own snapshotted currency rather
/// than the device's locale currency, which is what makes these the same figures the
/// guest was shown.
class _OrderLineRow extends StatelessWidget {
  const _OrderLineRow({required this.line, required this.currency});

  final OrderLineModel line;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unitPrice = formatCartAmount(line.unitPriceMinorUnits, currency);
    final lineTotal = formatCartAmount(line.lineTotalMinorUnits, currency);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text(
              '${line.quantity}×',
              style: theme.textTheme.titleSmall,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.productName, style: theme.textTheme.bodyLarge),
                Text(
                  '$unitPrice each',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(lineTotal, style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }
}

/// The button that offers one move.
///
/// A cancellation is filled rather than toned, because it is the one move that takes
/// something away, and a staff member should have to look at it.
class _StatusActionButton extends StatelessWidget {
  const _StatusActionButton({
    required this.status,
    required this.isBusy,
    required this.onPressed,
  });

  final OrderStatus status;
  final bool isBusy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isCancel = status == OrderStatus.cancelled;
    final label = staffOrderActionLabel(status);

    return isCancel
        ? OutlinedButton.icon(
            key: staffOrderActionKey(status),
            onPressed: isBusy ? null : onPressed,
            icon: isBusy ? _busyIcon() : const Icon(Icons.cancel_outlined),
            label: Text(label),
          )
        : FilledButton.icon(
            key: staffOrderActionKey(status),
            onPressed: isBusy ? null : onPressed,
            icon: isBusy ? _busyIcon() : const Icon(Icons.arrow_forward),
            label: Text(label),
          );
  }

  Widget _busyIcon() {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}