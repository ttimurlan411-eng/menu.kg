import 'package:flutter/material.dart';

/// A remote menu image that degrades to a neutral placeholder.
///
/// Menu images are optional, so a dish without a photo and a photo that fails
/// to load both render the same placeholder instead of an error box. Shared by
/// the public menu and the product details page so the two never diverge.
class MenuImage extends StatelessWidget {
  const MenuImage({
    super.key,
    required this.url,
    required this.height,
    this.width,
    this.borderRadius = BorderRadius.zero,
  });

  /// The image URL, or `null` when the dish has no photo.
  final String? url;

  final double height;
  final double? width;
  final BorderRadius borderRadius;

  /// Whether there is a photo to show.
  bool get hasImage => url != null && url!.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (!hasImage) {
      return _placeholder(context);
    }

    return ClipRRect(
      borderRadius: borderRadius,
      child: Image.network(
        url!,
        height: height,
        width: width,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _placeholder(context),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: height,
      width: width,
      color: theme.colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.restaurant_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
