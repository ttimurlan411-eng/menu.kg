import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';

/// The colour pair a status is drawn with, so one status always looks the same.
///
/// Built from [ColorScheme] roles rather than literal colours, so the chip follows
/// the app's light and dark themes and this file holds no palette of its own.
({Color background, Color foreground}) _statusColors(
  BuildContext context,
  OrderStatus status,
) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    // Waiting to be looked at: quiet, so an accepted order stands out on the list.
    OrderStatus.pending => (
      background: scheme.surfaceContainerHighest,
      foreground: scheme.onSurfaceVariant,
    ),
    // Taken and being worked: the primary colour, which is the app's own emphasis.
    OrderStatus.accepted => (
      background: scheme.primaryContainer,
      foreground: scheme.onPrimaryContainer,
    ),
    OrderStatus.preparing => (
      background: scheme.tertiaryContainer,
      foreground: scheme.onTertiaryContainer,
    ),
    // Finished and on the pass: strong, because this is the order a waiter is after.
    OrderStatus.ready => (
      background: scheme.primary,
      foreground: scheme.onPrimary,
    ),
    // Done. Muted rather than an error colour: a served order is a good outcome, not
    // a failure, and colouring it as one would make a full service look like trouble.
    OrderStatus.served => (
      background: scheme.secondaryContainer,
      foreground: scheme.onSecondaryContainer,
    ),
    OrderStatus.cancelled => (
      background: scheme.errorContainer,
      foreground: scheme.onErrorContainer,
    ),
  };
}

/// How loudly a status is written, as a FontWeight rather than as a second chip.
///
/// Kept next to the colours for the same reason they are kept together: the status of
/// an order is the first thing a staff member reads, and how it looks must not depend
/// on which page it is on.
FontWeight _statusWeight(OrderStatus status) {
  return switch (status) {
    OrderStatus.pending || OrderStatus.cancelled => FontWeight.w500,
    _ => FontWeight.w600,
  };
}

/// Shows an order's status as an icon and a word.
///
/// The word is [OrderStatus.displayLabel], the same wording the guest sees, so a waiter
/// and the guest looking at the same order are never shown two different names for one
/// state. The icon is beside it rather than instead of it: status is never carried by
/// colour alone, and a screen reader announces the word with it.
///
/// A status this client cannot read never reaches here: an unreadable order is skipped
/// by the parser rather than rendered with a made-up name.
class StaffOrderStatusChip extends StatelessWidget {
  const StaffOrderStatusChip({super.key, required this.status});

  /// The status to show.
  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = _statusColors(context, status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(staffOrderStatusIcon(status), size: 14, color: colors.foreground),
          const SizedBox(width: 6),
          Text(
            status.displayLabel,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colors.foreground,
              fontWeight: _statusWeight(status),
            ),
          ),
        ],
      ),
    );
  }
}

/// The icon that names a status, drawn inside the chip beside its word.
IconData staffOrderStatusIcon(OrderStatus status) {
  return switch (status) {
    OrderStatus.pending => Icons.schedule_outlined,
    OrderStatus.accepted => Icons.check_circle_outline,
    OrderStatus.preparing => Icons.soup_kitchen_outlined,
    OrderStatus.ready => Icons.room_service_outlined,
    OrderStatus.served => Icons.done_all,
    OrderStatus.cancelled => Icons.cancel_outlined,
  };
}