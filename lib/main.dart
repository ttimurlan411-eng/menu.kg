import 'package:flutter/widgets.dart';
import 'package:menukg_flutter/app/app.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseService.initialize();

  runApp(const MenukgApp());
}
