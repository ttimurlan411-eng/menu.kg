abstract final class SupabaseConfig {
  const SupabaseConfig._();

  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://lsmohzfjhqbfkjskilbh.supabase.co',
  );

  static const String supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_mopbNbBHs2JQ2RD4gGO9_g_tTqbjHP4',
  );
}
