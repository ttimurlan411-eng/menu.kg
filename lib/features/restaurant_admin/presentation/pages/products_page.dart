import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/category_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/menu_item_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/category_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/menu_item_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/menu_item_error_message.dart';

/// Upper bound enforced by the product name validator.
const int maxProductNameLength = 100;

String? validateProductName(String? value) {
  final name = value?.trim() ?? '';
  if (name.isEmpty) {
    return 'Enter a product name.';
  }
  if (name.length > maxProductNameLength) {
    return 'Product name must be $maxProductNameLength characters or fewer.';
  }
  return null;
}

String? validateProductPrice(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) {
    return 'Enter a price.';
  }
  final price = double.tryParse(raw);
  if (price == null || price < 0) {
    return 'Price must be a number of 0 or more.';
  }
  return null;
}

/// Formats a price the same way it is stored: with two decimals.
String formatProductPrice(double price) => price.toStringAsFixed(2);

/// Manages menu items for a single restaurant.
class ProductsPage extends StatefulWidget {
  const ProductsPage({
    super.key,
    required this.restaurantId,
    this.menuItemRepository = const MenuItemRepository(),
    this.categoryRepository = const CategoryRepository(),
  });

  /// The restaurant whose products are managed on this page.
  final String restaurantId;

  final MenuItemRepository menuItemRepository;

  /// Used to display category names and to offer categories in the form.
  final CategoryRepository categoryRepository;

  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  List<MenuItemModel> _menuItems = const [];
  List<CategoryModel> _categories = const [];
  bool _isLoading = true;
  String? _loadErrorMessage;
  MenuItemModel? _editingMenuItem;
  String? _deletingMenuItemId;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _loadErrorMessage = null;
    });

    try {
      final menuItems = await widget.menuItemRepository.getMenuItems(
        widget.restaurantId,
      );
      final categories = await widget.categoryRepository.getCategories(
        widget.restaurantId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _menuItems = menuItems;
        _categories = categories;
        _isLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('Loading menu items failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _loadErrorMessage =
            'We could not load your products. Please try again.';
      });
    }
  }

  String _categoryName(String categoryId) {
    for (final category in _categories) {
      if (category.id == categoryId) {
        return category.name;
      }
    }
    return 'Unknown category';
  }

  void _openCreateDialog() {
    _editingMenuItem = null;
    _showProductForm();
  }

  void _openEditDialog(MenuItemModel menuItem) {
    _editingMenuItem = menuItem;
    _showProductForm();
  }

  void _showProductForm() {
    showDialog<void>(
      context: context,
      builder: (context) => _ProductFormDialog(
        categories: _categories,
        product: _editingMenuItem,
        onSubmit: _saveMenuItem,
      ),
    );
  }

  Future<void> _saveMenuItem(
    String name,
    String categoryId,
    double price,
    bool isAvailable,
  ) async {
    final editingMenuItem = _editingMenuItem;
    if (editingMenuItem == null) {
      await widget.menuItemRepository.createMenuItem(
        restaurantId: widget.restaurantId,
        categoryId: categoryId,
        name: name,
        price: price,
        isAvailable: isAvailable,
      );
    } else {
      await widget.menuItemRepository.updateMenuItem(
        restaurantId: widget.restaurantId,
        menuItemId: editingMenuItem.id,
        categoryId: categoryId,
        name: name,
        price: price,
        isAvailable: isAvailable,
      );
    }
    await _loadData();
  }

  Future<void> _confirmDeleteMenuItem(MenuItemModel menuItem) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete product?'),
        content: Text(
          'Delete "${menuItem.name}"? This cannot be undone.',
        ),
        actions: [
          TextButton(
            key: const Key('deleteProductCancelButton'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('deleteProductConfirmButton'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _deletingMenuItemId = menuItem.id);

    try {
      await widget.menuItemRepository.deleteMenuItem(
        restaurantId: widget.restaurantId,
        menuItemId: menuItem.id,
      );
      await _loadData();
    } catch (error, stackTrace) {
      debugPrint('Deleting menu item failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(menuItemDeleteErrorMessage(error))),
      );
    } finally {
      if (mounted) {
        setState(() => _deletingMenuItemId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const _LoadingState();
    }

    if (_loadErrorMessage case final message?) {
      return _ErrorState(message: message, onRetry: _loadData);
    }

    return _buildProductsList(context);
  }

  Widget _buildProductsList(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Products', style: theme.textTheme.headlineMedium),
            ),
            FilledButton.icon(
              key: const Key('addProductButton'),
              onPressed: _openCreateDialog,
              icon: const Icon(Icons.add),
              label: const Text('Add product'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_menuItems.isEmpty)
          _EmptyState(onAdd: _openCreateDialog)
        else
          for (final menuItem in _menuItems) ...[
            _MenuItemCard(
              menuItem: menuItem,
              categoryName: _categoryName(menuItem.categoryId),
              isDeleting: _deletingMenuItemId == menuItem.id,
              onEdit: () => _openEditDialog(menuItem),
              onDelete: () => _confirmDeleteMenuItem(menuItem),
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
          Text('Loading products...'),
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
              key: const Key('productsRetryButton'),
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
            Icons.restaurant_menu_outlined,
            size: 56,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text('No products yet', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Create your first product to build your menu.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('emptyAddProductButton'),
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Add product'),
          ),
        ],
      ),
    );
  }
}

class _MenuItemCard extends StatelessWidget {
  const _MenuItemCard({
    required this.menuItem,
    required this.categoryName,
    required this.isDeleting,
    required this.onEdit,
    required this.onDelete,
  });

  final MenuItemModel menuItem;
  final String categoryName;
  final bool isDeleting;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = menuItem.isAvailable ? 'Available' : 'Unavailable';
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: Key('productTile_${menuItem.id}'),
        isThreeLine: true,
        leading: Icon(
          Icons.restaurant_menu_outlined,
          color: menuItem.isAvailable
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(menuItem.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '$categoryName · Price: ${formatProductPrice(menuItem.price)}\n'
          '$status',
        ),
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
                    key: Key('editProductButton_${menuItem.id}'),
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: onEdit,
                  ),
                  IconButton(
                    key: Key('deleteProductButton_${menuItem.id}'),
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

class _ProductFormDialog extends StatefulWidget {
  const _ProductFormDialog({
    required this.categories,
    required this.onSubmit,
    this.product,
  });

  final List<CategoryModel> categories;
  final MenuItemModel? product;
  final Future<void> Function(
    String name,
    String categoryId,
    double price,
    bool isAvailable,
  )
  onSubmit;

  @override
  State<_ProductFormDialog> createState() => _ProductFormDialogState();
}

class _ProductFormDialogState extends State<_ProductFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _priceController;
  late String? _categoryId;
  late bool _isAvailable;
  bool _isSaving = false;
  String? _errorMessage;

  bool get _isEditing => widget.product != null;

  @override
  void initState() {
    super.initState();
    final product = widget.product;
    _nameController = TextEditingController(text: product?.name ?? '');
    _priceController = TextEditingController(
      text: product == null ? '' : formatProductPrice(product.price),
    );
    _categoryId = product?.categoryId;
    _isAvailable = product?.isAvailable ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _priceController.dispose();
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
        _nameController.text.trim(),
        _categoryId!,
        double.parse(_priceController.text.trim()),
        _isAvailable,
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (error, stackTrace) {
      debugPrint('Saving menu item failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() => _errorMessage = menuItemMutationErrorMessage(error));
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
      title: Text(_isEditing ? 'Edit product' : 'Add product'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                key: const Key('productNameField'),
                controller: _nameController,
                maxLength: maxProductNameLength,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: validateProductName,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: const Key('productCategoryField'),
                initialValue: _categoryId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Category'),
                hint: widget.categories.isEmpty
                    ? const Text('No categories yet')
                    : null,
                items: [
                  for (final category in widget.categories)
                    DropdownMenuItem(
                      value: category.id,
                      child: Text(
                        category.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _categoryId = value),
                validator: (value) {
                  if (value != null) {
                    return null;
                  }
                  return widget.categories.isEmpty
                      ? 'Create a category first.'
                      : 'Choose a category.';
                },
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('productPriceField'),
                controller: _priceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Price',
                  prefixText: 'KGS ',
                  helperText: 'Use a number of 0 or more.',
                ),
                validator: validateProductPrice,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                key: const Key('productAvailableSwitch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Available'),
                subtitle: const Text('Unavailable products are hidden from the menu.'),
                value: _isAvailable,
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _isAvailable = value),
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
          key: const Key('productFormCancelButton'),
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('productFormSubmitButton'),
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