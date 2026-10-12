import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/category_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/category_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/category_error_message.dart';

/// Upper bound enforced by the category name validator.
const int maxCategoryNameLength = 100;

String? validateCategoryName(String? value) {
  final name = value?.trim() ?? '';
  if (name.isEmpty) {
    return 'Enter a category name.';
  }
  if (name.length > maxCategoryNameLength) {
    return 'Category name must be $maxCategoryNameLength characters or fewer.';
  }
  return null;
}

String? validateCategorySortOrder(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) {
    return 'Enter a sort order.';
  }
  final order = int.tryParse(raw);
  if (order == null || order < 0) {
    return 'Sort order must be a whole number of 0 or more.';
  }
  return null;
}

/// Manages categories for a single restaurant.
class CategoriesPage extends StatefulWidget {
  const CategoriesPage({
    super.key,
    required this.restaurantId,
    this.repository = const CategoryRepository(),
  });

  /// The restaurant whose categories are managed on this page.
  final String restaurantId;

  final CategoryRepository repository;

  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  List<CategoryModel> _categories = const [];
  bool _isLoading = true;
  String? _loadErrorMessage;
  CategoryModel? _editingCategory;
  String? _deletingCategoryId;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    setState(() {
      _isLoading = true;
      _loadErrorMessage = null;
    });

    try {
      final categories = await widget.repository.getCategories(
        widget.restaurantId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _categories = categories;
        _isLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('Loading categories failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _loadErrorMessage =
            'We could not load your categories. Please try again.';
      });
    }
  }

  void _openCreateDialog() {
    _editingCategory = null;
    _showCategoryForm();
  }

  void _openEditDialog(CategoryModel category) {
    _editingCategory = category;
    _showCategoryForm();
  }

  void _showCategoryForm() {
    showDialog<void>(
      context: context,
      builder: (context) => _CategoryFormDialog(
        category: _editingCategory,
        onSubmit: _saveCategory,
      ),
    );
  }

  Future<void> _saveCategory(
    String name,
    bool isActive,
    int sortOrder,
  ) async {
    final editingCategory = _editingCategory;
    if (editingCategory == null) {
      await widget.repository.createCategory(
        restaurantId: widget.restaurantId,
        name: name,
        isActive: isActive,
        sortOrder: sortOrder,
      );
    } else {
      await widget.repository.updateCategory(
        restaurantId: widget.restaurantId,
        categoryId: editingCategory.id,
        name: name,
        isActive: isActive,
        sortOrder: sortOrder,
      );
    }
    await _loadCategories();
  }

  Future<void> _confirmDeleteCategory(CategoryModel category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete category?'),
        content: Text(
          'Delete "${category.name}"? This cannot be undone.',
        ),
        actions: [
          TextButton(
            key: const Key('deleteCategoryCancelButton'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('deleteCategoryConfirmButton'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _deletingCategoryId = category.id);

    try {
      await widget.repository.deleteCategory(
        restaurantId: widget.restaurantId,
        categoryId: category.id,
      );
      await _loadCategories();
    } catch (error, stackTrace) {
      debugPrint('Deleting category failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(categoryDeleteErrorMessage(error))),
      );
    } finally {
      if (mounted) {
        setState(() => _deletingCategoryId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const _LoadingState();
    }

    if (_loadErrorMessage case final message?) {
      return _ErrorState(message: message, onRetry: _loadCategories);
    }

    return _buildCategoriesList(context);
  }

  Widget _buildCategoriesList(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Categories', style: theme.textTheme.headlineMedium),
            ),
            FilledButton.icon(
              key: const Key('addCategoryButton'),
              onPressed: _openCreateDialog,
              icon: const Icon(Icons.add),
              label: const Text('Add category'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_categories.isEmpty)
          _EmptyState(onAdd: _openCreateDialog)
        else
          for (final category in _categories) ...[
            _CategoryCard(
              category: category,
              isDeleting: _deletingCategoryId == category.id,
              onEdit: () => _openEditDialog(category),
              onDelete: () => _confirmDeleteCategory(category),
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
          Text('Loading categories...'),
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
              key: const Key('categoriesRetryButton'),
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
            Icons.category_outlined,
            size: 56,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text('No categories yet', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Create your first category to organize menu items.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('emptyAddCategoryButton'),
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Add category'),
          ),
        ],
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.category,
    required this.isDeleting,
    required this.onEdit,
    required this.onDelete,
  });

  final CategoryModel category;
  final bool isDeleting;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = category.isActive ? 'Active' : 'Inactive';
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: Key('categoryTile_${category.id}'),
        leading: Icon(
          Icons.category_outlined,
          color: category.isActive
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(category.name, overflow: TextOverflow.ellipsis),
        subtitle: Text('$status · Sort order: ${category.sortOrder}'),
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
                    key: Key('editCategoryButton_${category.id}'),
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: onEdit,
                  ),
                  IconButton(
                    key: Key('deleteCategoryButton_${category.id}'),
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

class _CategoryFormDialog extends StatefulWidget {
  const _CategoryFormDialog({required this.onSubmit, this.category});

  final CategoryModel? category;
  final Future<void> Function(String name, bool isActive, int sortOrder)
  onSubmit;

  @override
  State<_CategoryFormDialog> createState() => _CategoryFormDialogState();
}

class _CategoryFormDialogState extends State<_CategoryFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _sortOrderController;
  late bool _isActive;
  bool _isSaving = false;
  String? _errorMessage;

  bool get _isEditing => widget.category != null;

  @override
  void initState() {
    super.initState();
    final category = widget.category;
    _nameController = TextEditingController(text: category?.name ?? '');
    _sortOrderController = TextEditingController(
      text: category?.sortOrder.toString() ?? '0',
    );
    _isActive = category?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _sortOrderController.dispose();
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
        _isActive,
        int.parse(_sortOrderController.text.trim()),
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (error, stackTrace) {
      debugPrint('Saving category failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() => _errorMessage = categoryMutationErrorMessage(error));
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
      title: Text(_isEditing ? 'Edit category' : 'Add category'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                key: const Key('categoryNameField'),
                controller: _nameController,
                maxLength: maxCategoryNameLength,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: validateCategoryName,
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('categorySortOrderField'),
                controller: _sortOrderController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Sort order',
                  helperText: 'Lower numbers appear first.',
                ),
                validator: validateCategorySortOrder,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                key: const Key('categoryActiveSwitch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Active'),
                subtitle: const Text('Inactive categories are hidden from the menu.'),
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
          key: const Key('categoryFormCancelButton'),
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('categoryFormSubmitButton'),
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