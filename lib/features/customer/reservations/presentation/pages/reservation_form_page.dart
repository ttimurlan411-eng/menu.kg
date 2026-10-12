import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';
import 'package:menukg_flutter/features/customer/reservations/data/repositories/reservation_repository.dart';
import 'package:menukg_flutter/features/customer/reservations/data/reservation_access_store.dart';
import 'package:menukg_flutter/features/customer/reservations/presentation/reservation_error_message.dart';
import 'package:menukg_flutter/features/customer/reservations/presentation/pages/my_reservations_page.dart';

/// The customer form that books a table at the restaurant they are sitting in.
///
/// The page is pushed onto the public menu, so the guest always arrives with a
/// [qrToken] that has already been resolved to a real table, and it books that
/// table and no other: the restaurant, branch and table come from the token, not
/// from anything the guest can choose or edit.
///
/// The page collects only what the database needs and this project already
/// understands — a day, a time, a name and a number of guests that fits the
/// table. It deliberately offers no times list, no "available tables" view and
/// no duration rules, because the project defines no opening hours and no
/// booking length, and inventing them here would be a business decision rather
/// than a feature.
class ReservationFormPage extends StatefulWidget {
  const ReservationFormPage({
    super.key,
    required this.qrToken,
    required this.tableLabel,
    required this.restaurantName,
    required this.branchName,
    this.repository,
    this.accessStore,
  });

  /// The opaque QR token of the table being reserved.
  final String qrToken;

  /// Display labels of the resolved table, for example `Table 12 · Window`.
  final String tableLabel;

  final String restaurantName;
  final String branchName;

  final ReservationRepository? repository;
  final ReservationAccessStore? accessStore;

  @override
  State<ReservationFormPage> createState() => _ReservationFormPageState();
}

class _ReservationFormPageState extends State<ReservationFormPage> {
  /// The furthest day the picker offers.
  ///
  /// A bound is needed to draw a picker at all; the database has no maximum date.
  static final DateTime _lastBookableDay = DateTime.now().add(
    const Duration(days: 365),
  );

  late ReservationRepository _repository =
      widget.repository ?? const ReservationRepository();
  late ReservationAccessStore _accessStore =
      widget.accessStore ?? const DeviceReservationAccessStore();

  final TextEditingController _nameController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late DateTime _date = _today();
  ({int hour, int minute}) _time = _currentTimeOfDay();
  int _guestCount = 1;
  bool _isSubmitting = false;
  String? _errorMessage;
  CreatedReservationModel? _created;

  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  static ({int hour, int minute}) _currentTimeOfDay() {
    final now = DateTime.now();
    return (hour: now.hour, minute: now.minute);
  }

  @override
  void didUpdateWidget(ReservationFormPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository)) {
      _repository = widget.repository ?? const ReservationRepository();
    }
    if (!identical(oldWidget.accessStore, widget.accessStore)) {
      _accessStore = widget.accessStore ?? const DeviceReservationAccessStore();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reserve a table')),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    final created = _created;
    if (created != null) {
      return _ReservationCreated(
        reservation: created.reservation,
        onViewMine: _openMyReservations,
        onMakeAnother: _reset,
      );
    }

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _TableContextCard(
            restaurantName: widget.restaurantName,
            branchName: widget.branchName,
            tableLabel: widget.tableLabel,
          ),
          const SizedBox(height: 24),
          TextFormField(
            key: const Key('reservationGuestNameField'),
            controller: _nameController,
            textInputAction: TextInputAction.next,
            maxLength: 100,
            decoration: const InputDecoration(
              labelText: 'Your name',
              helperText: 'The name the restaurant will expect you under.',
            ),
            validator: (value) =>
                (value ?? '').trim().isEmpty ? 'Please enter your name.' : null,
          ),
          const SizedBox(height: 8),
          _PickerRow(
            fieldKey: const Key('reservationDateField'),
            label: 'Date',
            value: formatReservationDay(_date),
            onTap: _pickDate,
          ),
          const SizedBox(height: 8),
          _PickerRow(
            fieldKey: const Key('reservationTimeField'),
            label: 'Time',
            value: formatReservationClock(
              hour: _time.hour,
              minute: _time.minute,
            ),
            onTap: _pickTime,
          ),
          const SizedBox(height: 8),
          _GuestCountRow(
            count: _guestCount,
            onIncrease: () => setState(() => _guestCount++),
            onDecrease: _guestCount > 1
                ? () => setState(() => _guestCount--)
                : null,
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              key: const Key('reservationErrorMessage'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('reservationSubmitButton'),
            onPressed: _isSubmitting ? null : _submit,
            child: Text(_isSubmitting ? 'Saving...' : 'Request reservation'),
          ),
          const SizedBox(height: 8),
          // Saying what happens next is more honest than implying the restaurant
          // has been told: nothing is sent anywhere in this step.
          Text(
            'Your reservation is saved on this device. Nothing is sent to the '
            'restaurant yet.',
            key: const Key('reservationFootnote'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: _today(),
      lastDate: _lastBookableDay,
    );
    if (picked != null) {
      setState(() => _date = picked);
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _time.hour, minute: _time.minute),
    );
    if (picked != null) {
      setState(() => _time = (hour: picked.hour, minute: picked.minute));
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final accessToken = await _accessStore.readToken();
      final created = await _repository.createReservation(
        qrToken: widget.qrToken,
        date: _date,
        hour: _time.hour,
        minute: _time.minute,
        guestName: _nameController.text,
        guestCount: _guestCount,
        accessToken: accessToken,
      );

      if (!mounted) {
        return;
      }
      if (created == null) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = reservationQrUnavailableMessage;
        });
        return;
      }

      // The token is the guest's only way back to this reservation, so it is
      // stored before the success state is shown.
      await _accessStore.writeToken(created.accessToken);
      if (!mounted) {
        return;
      }
      setState(() {
        _isSubmitting = false;
        _created = created;
      });
    } catch (error) {
      debugPrint('Creating a reservation failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _isSubmitting = false;
        _errorMessage = reservationErrorMessage(error);
      });
    }
  }

  void _reset() {
    setState(() {
      _created = null;
      _errorMessage = null;
    });
    _nameController.clear();
  }

  void _openMyReservations() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => MyReservationsPage(
          repository: _repository,
          accessStore: _accessStore,
        ),
      ),
    );
  }
}

class _TableContextCard extends StatelessWidget {
  const _TableContextCard({
    required this.restaurantName,
    required this.branchName,
    required this.tableLabel,
  });

  final String restaurantName;
  final String branchName;
  final String tableLabel;

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
          Text(restaurantName, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            // Display labels only, as everywhere else in the customer flow.
            '$branchName · $tableLabel',
            key: const Key('reservationTableContext'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final Key fieldKey;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: fieldKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Row(
          children: [
            Expanded(
              child: Text(
                value,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            const Icon(Icons.expand_more),
          ],
        ),
      ),
    );
  }
}

class _GuestCountRow extends StatelessWidget {
  const _GuestCountRow({
    required this.count,
    required this.onIncrease,
    this.onDecrease,
  });

  final int count;
  final VoidCallback onIncrease;
  final VoidCallback? onDecrease;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Expanded(child: Text('Guests', style: theme.textTheme.bodyLarge)),
        IconButton(
          key: const Key('reservationGuestCountDecrease'),
          onPressed: onDecrease,
          tooltip: 'Fewer guests',
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text('$count', key: const Key('reservationGuestCountValue')),
        IconButton(
          key: const Key('reservationGuestCountIncrease'),
          onPressed: onIncrease,
          tooltip: 'More guests',
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}

/// Shown after a reservation is stored, before anything is sent anywhere.
class _ReservationCreated extends StatelessWidget {
  const _ReservationCreated({
    required this.reservation,
    required this.onViewMine,
    required this.onMakeAnother,
  });

  final ReservationModel reservation;
  final VoidCallback onViewMine;
  final VoidCallback onMakeAnother;

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
              Icons.event_available_outlined,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Table requested',
              key: const Key('reservationCreatedTitle'),
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              reservation.whenLabel,
              key: const Key('reservationCreatedWhen'),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              reservation.partyLabel,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Text(
              'Saved on this device. The restaurant has not been notified yet.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('reservationViewMineButton'),
              onPressed: onViewMine,
              child: const Text('View my reservations'),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('reservationMakeAnotherButton'),
              onPressed: onMakeAnother,
              child: const Text('Make another'),
            ),
          ],
        ),
      ),
    );
  }
}
