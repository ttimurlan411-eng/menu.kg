import 'package:flutter/material.dart';

abstract final class AppTheme {
  const AppTheme._();

  static ThemeData get light => ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF006C4C)),
    useMaterial3: true,
  );
}
