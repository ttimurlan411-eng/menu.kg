import 'package:flutter/material.dart';

/// Reusable placeholder shown for restaurant admin modules that are not
/// implemented yet.
class ModulePlaceholderPage extends StatelessWidget {
  const ModulePlaceholderPage({
    super.key,
    required this.moduleName,
    this.icon,
  });

  /// Display name of the module, e.g. "Orders".
  final String moduleName;

  /// Optional icon that represents the module.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon ?? Icons.construction_outlined,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(moduleName, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text('Coming soon', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Бул бөлүк кийинки этапта кошулат',
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