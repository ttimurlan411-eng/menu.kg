import 'package:menukg_flutter/core/constants/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract final class SupabaseService {
  const SupabaseService._();

  static Future<void> initialize() async {
    await Supabase.initialize(
      url: SupabaseConfig.supabaseUrl,
      publishableKey: SupabaseConfig.supabasePublishableKey,
    );
  }

  static SupabaseClient get client => Supabase.instance.client;
}
