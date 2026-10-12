-- Public, read-only customer menu resolved from a table's opaque qr_token.
--
-- Anonymous visitors arriving from a table QR code must read the menu without
-- an account. Instead of granting anon access to any table, this migration
-- exposes a single SECURITY DEFINER function that returns only the columns the
-- customer menu renders, for exactly one restaurant/branch resolved from the
-- token.
--
-- Deliberately NOT exposed publicly:
--   * restaurants.phone / address / latitude / longitude / slug
--   * profiles, restaurant_members, and every other admin/staff column
--   * restaurant_id, branch_id and table ids of the resolved rows
--
-- No anon INSERT/UPDATE/DELETE policy is created, and no anon table grant is
-- added, so this function is the only path an anonymous client has into the
-- database. Existing RLS for authenticated users is untouched.

create or replace function public.public_menu_by_qr_token(p_qr_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_token uuid;
  v_table public.tables%rowtype;
  v_restaurant public.restaurants%rowtype;
  v_branch public.branches%rowtype;
  v_categories jsonb;
begin
  -- A malformed token is reported as "no menu" instead of a cast error, so the
  -- public URL cannot be probed for database internals through error text.
  if p_qr_token is null
    or pg_catalog.btrim(p_qr_token) !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  then
    return null;
  end if;

  v_token := pg_catalog.btrim(p_qr_token)::uuid;

  select *
    into v_table
    from public.tables as t
   where t.qr_token = v_token
     and t.is_active
   limit 1;

  if not found then
    return null;
  end if;

  select *
    into v_restaurant
    from public.restaurants as r
   where r.id = v_table.restaurant_id
     and r.is_active;

  if not found then
    return null;
  end if;

  -- Re-checks that the branch belongs to the same restaurant as the table.
  select *
    into v_branch
    from public.branches as b
   where b.id = v_table.branch_id
     and b.restaurant_id = v_table.restaurant_id
     and b.is_active;

  if not found then
    return null;
  end if;

  -- Categories visible to this branch, each with only its available items.
  -- A category without any available item is dropped so guests never see an
  -- empty section. branch_id null means "applies to every branch".
  with visible_categories as (
    select c.id, c.name, c.description, c.image_url, c.sort_order
      from public.categories as c
     where c.restaurant_id = v_table.restaurant_id
       and c.is_active
       and (c.branch_id is null or c.branch_id = v_table.branch_id)
  ),
  category_items as (
    select
      vc.id as category_id,
      vc.name as category_name,
      vc.description as category_description,
      vc.image_url as category_image_url,
      vc.sort_order as category_sort_order,
      coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id', i.id,
                     'name', i.name,
                     'description', i.description,
                     'price', i.price,
                     'old_price', i.old_price,
                     'main_image_url', i.main_image_url,
                     'preparation_time_minutes', i.preparation_time_minutes
                   )
                   order by i.sort_order, i.name
                 )
            from public.menu_items as i
           where i.restaurant_id = v_table.restaurant_id
             and i.category_id = vc.id
             and i.is_available
             and (i.branch_id is null or i.branch_id = v_table.branch_id)
        ),
        '[]'::jsonb
      ) as items
      from visible_categories as vc
  )
  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'id', ci.category_id,
               'name', ci.category_name,
               'description', ci.category_description,
               'image_url', ci.category_image_url,
               'items', ci.items
             )
             order by ci.category_sort_order, ci.category_name
           ),
           '[]'::jsonb
         )
    into v_categories
    from category_items as ci
   where pg_catalog.jsonb_array_length(ci.items) > 0;

  return jsonb_build_object(
    'restaurant', jsonb_build_object(
      'name', v_restaurant.name,
      'logo_url', v_restaurant.logo_url,
      'cover_url', v_restaurant.cover_url,
      'description', v_restaurant.description,
      'currency', v_restaurant.currency,
      'default_language', v_restaurant.default_language
    ),
    'branch', jsonb_build_object(
      'name', v_branch.name
    ),
    'table', jsonb_build_object(
      'number', v_table.table_number,
      'name', v_table.name
    ),
    'categories', v_categories
  );
end;
$$;

comment on function public.public_menu_by_qr_token(text) is
  'Resolves a table qr_token to the public customer menu for its restaurant and branch. Returns null when the token is unknown or its table, branch or restaurant is inactive. Exposes no restaurant, branch or table ids.';

-- Defence in depth: the core tables stay unreadable and unwritable for anon.
-- These are no-ops today because the RLS migration already revoked every
-- grant, and they keep that true if a later migration re-grants something.
revoke all on table public.restaurants from anon;
revoke all on table public.branches from anon;
revoke all on table public.tables from anon;
revoke all on table public.categories from anon;
revoke all on table public.menu_items from anon;
revoke all on table public.menu_item_images from anon;
revoke all on table public.profiles from anon;
revoke all on table public.restaurant_members from anon;

revoke all on function public.public_menu_by_qr_token(text) from public, anon;

grant execute on function public.public_menu_by_qr_token(text)
  to anon, authenticated;