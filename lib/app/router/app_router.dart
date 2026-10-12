import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/auth/data/services/auth_service.dart';
import 'package:menukg_flutter/features/auth/presentation/pages/auth_gate.dart';
import 'package:menukg_flutter/features/customer/menu/presentation/pages/public_menu_page.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/customer/orders/presentation/pages/order_confirmation_page.dart';

abstract final class AppRouter {
  const AppRouter._();

  static const String initialRoute = '/';

  /// Path of the public table QR menu, where `[qrToken]` is the opaque token.
  static const String publicMenuRoutePath = '/t/:qrToken';

  /// Public menu base used by the printed QR codes, for example
  /// `https://menu.kg/t/<qrToken>`.
  static const String publicMenuBaseUrl = 'https://menu.kg/t';

  /// Name of the confirmation shown after an order was stored.
  ///
  /// Unlike [publicMenuRoutePath] this is a name rather than a path, because a
  /// confirmation has nothing to resolve from a link: it can only be shown for an
  /// order this device has just placed, and the order itself travels as the route
  /// argument. A URL is therefore never enough to reach it, which is why it is
  /// deliberately not a public route.
  static const String orderConfirmationRouteName = '/order-confirmation';

  /// The root route switches between the public and authenticated areas.
  static Widget initialPage({AuthService authService = const AuthService()}) {
    return AuthGate(authService: authService);
  }

  /// Builds the in-app route for [qrToken], for example `/t/<qrToken>`.
  static String publicMenuRoute(String qrToken) {
    return '/t/${Uri.encodeComponent(qrToken.trim())}';
  }

  /// Builds the shareable public URL printed into a table's QR code.
  ///
  /// Only the opaque token is included; table, restaurant and branch ids are
  /// never part of a public link.
  static String publicMenuUrl(String qrToken) {
    return '$publicMenuBaseUrl/${Uri.encodeComponent(qrToken.trim())}';
  }

  /// Extracts the QR token from a public menu path such as `/t/<qrToken>`.
  ///
  /// Returns `null` for anything else, so only the opaque token is ever used as
  /// a public identifier.
  static String? parsePublicMenuQrToken(String? routeName) {
    if (routeName == null) {
      return null;
    }

    final segments = routeName.split('/');

    // '/t/<qrToken>' has an empty first segment from the leading slash.
    final isPublicMenu =
        segments.length == 3 &&
        segments[0].isEmpty &&
        segments[1] == 't' &&
        segments[2].isNotEmpty;

    if (!isPublicMenu) {
      return null;
    }

    final qrToken = Uri.decodeComponent(segments[2]);
    return qrToken.isEmpty ? null : qrToken;
  }

  /// Resolves the public routes, which must work without authentication.
  ///
  /// Returns `null` for unknown routes so the caller can fall back to its own
  /// handling.
  static Route<Object?>? onGenerateRoute(RouteSettings settings) {
    final qrToken = parsePublicMenuQrToken(settings.name);
    if (qrToken != null) {
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (context) => PublicMenuPage(qrToken: qrToken),
      );
    }

    // The confirmation is reachable only with an order argument, which means only
    // from the cart that just placed it. A bare name with no argument resolves to
    // nothing, so this route cannot be opened by typing or sharing a path.
    if (settings.name == orderConfirmationRouteName &&
        settings.arguments is OrderModel) {
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (context) => OrderConfirmationPage(
          order: settings.arguments! as OrderModel,
          onBackToMenu: () => Navigator.of(context).maybePop(),
        ),
      );
    }

    return null;
  }
}