import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:menukg_flutter/app/router/app_router.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/table_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/table_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/table_error_message.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Upper bound enforced by the table number validator.
const int maxTableNumberLength = 50;

/// Edge length of the QR code shown in the QR dialog.
const double tableQrCodeSize = 200;

String? validateTableNumber(String? value) {
  final number = value?.trim() ?? '';
  if (number.isEmpty) {
    return 'Enter a table number.';
  }
  if (number.length > maxTableNumberLength) {
    return 'Table number must be $maxTableNumberLength characters or fewer.';
  }
  return null;
}

String? validateTableCapacity(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) {
    return 'Enter a capacity.';
  }
  final capacity = int.tryParse(raw);
  if (capacity == null || capacity < 1) {
    return 'Capacity must be a whole number of 1 or more.';
  }
  return null;
}

/// Formats a table capacity for display.
String formatTableCapacity(int capacity) => '$capacity seat${capacity == 1 ? '' : 's'}';

/// Manages tables and their QR codes for a single restaurant branch.
class TablesPage extends StatefulWidget {
  const TablesPage({
    super.key,
    required this.restaurantId,
    required this.branchId,
    this.repository = const TableRepository(),
  });

  /// The restaurant whose tables are managed on this page.
  final String restaurantId;

  /// The branch the tables belong to. The database requires it.
  final String branchId;

  final TableRepository repository;

  @override
  State<TablesPage> createState() => _TablesPageState();
}

class _TablesPageState extends State<TablesPage> {
  List<TableModel> _tables = const [];
  bool _isLoading = true;
  String? _loadErrorMessage;
  TableModel? _editingTable;
  String? _deletingTableId;

  @override
  void initState() {
    super.initState();
    _loadTables();
  }

  Future<void> _loadTables() async {
    setState(() {
      _isLoading = true;
      _loadErrorMessage = null;
    });

    try {
      final tables = await widget.repository.getTables(
        widget.restaurantId,
        branchId: widget.branchId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _tables = tables;
        _isLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('Loading tables failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _loadErrorMessage = 'We could not load your tables. Please try again.';
      });
    }
  }

  void _openCreateDialog() {
    _editingTable = null;
    _showTableForm();
  }

  void _openEditDialog(TableModel table) {
    _editingTable = table;
    _showTableForm();
  }

  void _showTableForm() {
    showDialog<void>(
      context: context,
      builder: (context) => _TableFormDialog(
        table: _editingTable,
        onSubmit: _saveTable,
      ),
    );
  }

  Future<void> _saveTable(
    String tableNumber,
    int capacity,
    String? name,
    String? zone,
    bool isActive,
  ) async {
    final editingTable = _editingTable;
    if (editingTable == null) {
      await widget.repository.createTable(
        restaurantId: widget.restaurantId,
        branchId: widget.branchId,
        tableNumber: tableNumber,
        capacity: capacity,
        name: name,
        zone: zone,
      );
    } else {
      await widget.repository.updateTable(
        restaurantId: widget.restaurantId,
        tableId: editingTable.id,
        tableNumber: tableNumber,
        capacity: capacity,
        name: name,
        zone: zone,
        isActive: isActive,
      );
    }
    await _loadTables();
  }

  Future<void> _confirmDeleteTable(TableModel table) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete table?'),
        content: Text(
          'Delete "${table.displayName}"? Its QR code will stop working.',
        ),
        actions: [
          TextButton(
            key: const Key('deleteTableCancelButton'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('deleteTableConfirmButton'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _deletingTableId = table.id);

    try {
      await widget.repository.deleteTable(
        restaurantId: widget.restaurantId,
        tableId: table.id,
      );
      await _loadTables();
    } catch (error, stackTrace) {
      debugPrint('Deleting table failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tableDeleteErrorMessage(error))),
      );
    } finally {
      if (mounted) {
        setState(() => _deletingTableId = null);
      }
    }
  }

  void _showQrDialog(TableModel table) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${table.displayName} QR code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // AlertDialog measures its content with IntrinsicWidth. QrImageView
            // is a LayoutBuilder, which cannot answer intrinsic queries, so it
            // is given a tight size here to keep that measurement off the QR.
            SizedBox.square(
              dimension: tableQrCodeSize,
              child: QrImageView(
                key: const Key('tableQrCode'),
                data: AppRouter.publicMenuUrl(table.qrToken),
                size: tableQrCodeSize,
                semanticsLabel: 'QR code for ${table.displayName}',
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              AppRouter.publicMenuUrl(table.qrToken),
              key: const Key('tableQrUrl'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Customers scan this to open the public menu for this table.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('tableQrCloseButton'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const _LoadingState();
    }

    if (_loadErrorMessage case final message?) {
      return _ErrorState(message: message, onRetry: _loadTables);
    }

    return _buildTablesList(context);
  }

  Widget _buildTablesList(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Tables', style: theme.textTheme.headlineMedium),
            ),
            FilledButton.icon(
              key: const Key('addTableButton'),
              onPressed: _openCreateDialog,
              icon: const Icon(Icons.add),
              label: const Text('Add table'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_tables.isEmpty)
          _EmptyState(onAdd: _openCreateDialog)
        else
          for (final table in _tables) ...[
            _TableCard(
              table: table,
              isDeleting: _deletingTableId == table.id,
              onEdit: () => _openEditDialog(table),
              onDelete: () => _confirmDeleteTable(table),
              onShowQr: () => _showQrDialog(table),
            ),
            const SizedBox(height: 12),
          ],
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
          Text('Loading tables...'),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('tablesRetryButton'),
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(
            Icons.table_restaurant_outlined,
            size: 56,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text('No tables yet', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Add your tables to generate QR codes for the public menu.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('emptyAddTableButton'),
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Add table'),
          ),
        ],
      ),
    );
  }
}

class _TableCard extends StatelessWidget {
  const _TableCard({
    required this.table,
    required this.isDeleting,
    required this.onEdit,
    required this.onDelete,
    required this.onShowQr,
  });

  final TableModel table;
  final bool isDeleting;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onShowQr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final details = <String>[
      formatTableCapacity(table.capacity),
      ?table.zone,
      if (!table.isActive) 'Inactive',
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: Key('tableTile_${table.id}'),
        leading: Icon(
          Icons.table_restaurant_outlined,
          color: table.isActive
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(table.displayName, overflow: TextOverflow.ellipsis),
        subtitle: Text(details.join(' · ')),
        trailing: isDeleting
            ? const SizedBox(
                width: 24,
                height: 24,
                child: Padding(
                  padding: EdgeInsets.all(2),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: Key('showQrButton_${table.id}'),
                    tooltip: 'Show QR code',
                    icon: const Icon(Icons.qr_code_2_outlined),
                    onPressed: onShowQr,
                  ),
                  IconButton(
                    key: Key('editTableButton_${table.id}'),
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: onEdit,
                  ),
                  IconButton(
                    key: Key('deleteTableButton_${table.id}'),
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: onDelete,
                  ),
                ],
              ),
      ),
    );
  }
}

class _TableFormDialog extends StatefulWidget {
  const _TableFormDialog({required this.onSubmit, this.table});

  final TableModel? table;

  final Future<void> Function(
    String tableNumber,
    int capacity,
    String? name,
    String? zone,
    bool isActive,
  )
  onSubmit;

  @override
  State<_TableFormDialog> createState() => _TableFormDialogState();
}

class _TableFormDialogState extends State<_TableFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _tableNumberController;
  late final TextEditingController _capacityController;
  late final TextEditingController _nameController;
  late final TextEditingController _zoneController;
  late bool _isActive;
  bool _isSaving = false;
  String? _errorMessage;

  bool get _isEditing => widget.table != null;

  @override
  void initState() {
    super.initState();
    final table = widget.table;
    _tableNumberController = TextEditingController(
      text: table?.tableNumber ?? '',
    );
    _capacityController = TextEditingController(
      text: table == null ? '' : table.capacity.toString(),
    );
    _nameController = TextEditingController(text: table?.name ?? '');
    _zoneController = TextEditingController(text: table?.zone ?? '');
    _isActive = table?.isActive ?? true;
  }

  @override
  void dispose() {
    _tableNumberController.dispose();
    _capacityController.dispose();
    _nameController.dispose();
    _zoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      await widget.onSubmit(
        _tableNumberController.text.trim(),
        int.parse(_capacityController.text.trim()),
        _nameController.text.trim().isEmpty ? null : _nameController.text.trim(),
        _zoneController.text.trim().isEmpty ? null : _zoneController.text.trim(),
        _isActive,
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (error, stackTrace) {
      debugPrint('Saving table failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() => _errorMessage = tableMutationErrorMessage(error));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(_isEditing ? 'Edit table' : 'Add table'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                key: const Key('tableNumberField'),
                controller: _tableNumberController,
                maxLength: maxTableNumberLength,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Table number'),
                validator: validateTableNumber,
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('tableCapacityField'),
                controller: _capacityController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Capacity'),
                validator: validateTableCapacity,
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('tableNameField'),
                controller: _nameController,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Name (optional)'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('tableZoneField'),
                controller: _zoneController,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Zone (optional)'),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                key: const Key('tableActiveSwitch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Active'),
                subtitle: const Text('Inactive tables are hidden from guests.'),
                value: _isActive,
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _isActive = value),
              ),
              if (_errorMessage case final message?) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    message,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('tableFormCancelButton'),
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('tableFormSubmitButton'),
          onPressed: _isSaving ? null : _submit,
          child: _isSaving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
