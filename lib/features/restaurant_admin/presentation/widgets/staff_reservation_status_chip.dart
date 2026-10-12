import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';

/// The colour pair a reservation status is drawn with, so one status always
/// looks the same on every screen.
///
/// Built from [ColorScheme] roles rather than literal colours, so the chip follows
/// the app's light and dark themes and this file holds no palette of its own.
({Color background, Color foreground}) _statusColors(
  BuildContext context,
  ReservationStatus status,
) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    // A booking the restaurant is holding: the app's own emphasis, so a live
    // reservation stands out from a released one.
    ReservationStatus.confirmed => (
      background: scheme.primaryContainer,
      foreground: scheme.onPrimaryContainer,
    ),
    // Released. An error colour rather than a muted one, because a cancellation
    // is the one outcome staff have to notice.
    ReservationStatus.cancelled => (
      background: scheme.errorContainer,
      foreground: scheme.onErrorContainer,
    ),
  };
}

/// The icon that names a reservation status, drawn inside the chip beside its
/// word so status is never carried by colour alone.
IconData _statusIcon(ReservationStatus status) {
  return switch (status) {
    ReservationStatus.confirmed => Icons.event_available_outlined,
    ReservationStatus.cancelled => Icons.event_busy_outlined,
  };
}

/// Shows a reservation's status as an icon and a word.
///
/// The word is [ReservationStatus.displayLabel], shared with the rest of the
/// app, so a staff member and a guest are never shown two different names for
/// one state. The icon sits beside it rather than instead of it.
///
/// A status this client cannot read never reaches here: an unreadable
/// reservation is skipped by the parser rather than rendered with a made-up name.
class StaffReservationStatusChip extends StatelessWidget {
  const StaffReservationStatusChip({super.key, required this.status});

  /// The status to show.
  final ReservationStatus status;

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
          Icon(_statusIcon(status), size: 14, color: colors.foreground),
          const SizedBox(width: 6),
          Text(
            status.displayLabel,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colors.foreground,
              fontWeight: status == ReservationStatus.confirmed
                  ? FontWeight.w600
                  : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
