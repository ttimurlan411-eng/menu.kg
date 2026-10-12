-- Corrective fix for public.create_restaurant_with_owner.
--
-- The function returns TABLE (id uuid, ...), so PL/pgSQL declares an OUT
-- variable named `id`. Inside the profiles upsert the conflict target
-- `on conflict (id)` was read as a column reference and rejected with
-- SQLSTATE 42702 ("column reference "id" is ambiguous"). A conflict target
-- cannot be qualified (`on conflict (profiles.id)` is a syntax error), so the
-- arbiter is now named explicitly as the primary-key constraint it inferred
-- to before: profiles_pkey. Everything else in the function is unchanged.

create or replace function public.create_restaurant_with_owner(
  p_name text,
  p_slug text,
  p_branch_name text,
  p_description text default null,
  p_phone text default null,
  p_address text default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_currency text default 'KGS',
  p_default_language text default 'ky'
)
returns table (
  id uuid,
  name text,
  slug text,
  description text,
  phone text,
  address text,
  currency text,
  default_language text,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz,
  branch_id uuid,
  branch_name text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_name text := pg_catalog.btrim(p_name);
  v_slug text := pg_catalog.btrim(p_slug);
  v_branch_name text := pg_catalog.btrim(p_branch_name);
  v_currency text := pg_catalog.upper(pg_catalog.btrim(p_currency));
  v_default_language text := pg_catalog.btrim(p_default_language);
  v_restaurant public.restaurants%rowtype;
  v_branch public.branches%rowtype;
begin
  if v_user_id is null then
    raise exception using
      errcode = '28000',
      message = 'Authentication is required to create a restaurant.';
  end if;

  if v_name is null or v_name = '' then
    raise exception using
      errcode = '22023',
      message = 'Restaurant name is required.';
  end if;

  if v_slug is null or v_slug = '' then
    raise exception using
      errcode = '22023',
      message = 'Restaurant slug is required.';
  end if;

  if v_branch_name is null or v_branch_name = '' then
    raise exception using
      errcode = '22023',
      message = 'Initial branch name is required.';
  end if;

  if v_currency is null or pg_catalog.char_length(v_currency) <> 3 then
    raise exception using
      errcode = '22023',
      message = 'Currency must be a three-character code.';
  end if;

  if v_default_language is null or v_default_language = '' then
    raise exception using
      errcode = '22023',
      message = 'Default language is required.';
  end if;

  -- restaurant_members.user_id references profiles(id). Ensuring this row
  -- exists here keeps first-restaurant bootstrap usable immediately after sign-up.
  -- The conflict target names the constraint instead of the column because the
  -- unqualified column name collides with the OUT variable `id` (SQLSTATE 42702).
  insert into public.profiles (id)
  values (v_user_id)
  on conflict on constraint profiles_pkey do nothing;

  insert into public.restaurants (
    name,
    slug,
    description,
    phone,
    address,
    latitude,
    longitude,
    currency,
    default_language
  )
  values (
    v_name,
    v_slug,
    nullif(pg_catalog.btrim(p_description), ''),
    nullif(pg_catalog.btrim(p_phone), ''),
    nullif(pg_catalog.btrim(p_address), ''),
    p_latitude,
    p_longitude,
    v_currency,
    v_default_language
  )
  returning * into v_restaurant;

  insert into public.branches (
    restaurant_id,
    name,
    address,
    phone,
    latitude,
    longitude
  )
  values (
    v_restaurant.id,
    v_branch_name,
    nullif(pg_catalog.btrim(p_address), ''),
    nullif(pg_catalog.btrim(p_phone), ''),
    p_latitude,
    p_longitude
  )
  returning * into v_branch;

  insert into public.restaurant_members (
    restaurant_id,
    user_id,
    role,
    is_active
  )
  values (
    v_restaurant.id,
    v_user_id,
    'OWNER',
    true
  );

  return query
  select
    v_restaurant.id,
    v_restaurant.name,
    v_restaurant.slug,
    v_restaurant.description,
    v_restaurant.phone,
    v_restaurant.address,
    v_restaurant.currency,
    v_restaurant.default_language,
    v_restaurant.is_active,
    v_restaurant.created_at,
    v_restaurant.updated_at,
    v_branch.id,
    v_branch.name;
end;
$$;

revoke all on function public.create_restaurant_with_owner(
  text,
  text,
  text,
  text,
  text,
  text,
  numeric,
  numeric,
  text,
  text
) from public, anon;

grant execute on function public.create_restaurant_with_owner(
  text,
  text,
  text,
  text,
  text,
  text,
  numeric,
  numeric,
  text,
  text
) to authenticated;
