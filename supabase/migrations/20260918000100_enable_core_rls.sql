-- Row Level Security for the core multi-tenant schema.
-- No public customer-menu policies are created in this migration.

create schema if not exists private;

revoke all on schema private from public;
grant usage on schema private to authenticated;

create or replace function private.is_active_restaurant_member(
  target_restaurant_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.restaurant_members as membership
    where membership.restaurant_id = target_restaurant_id
      and membership.user_id = (select auth.uid())
      and membership.is_active
  );
$$;

create or replace function private.has_restaurant_role(
  target_restaurant_id uuid,
  allowed_roles text[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.restaurant_members as membership
    where membership.restaurant_id = target_restaurant_id
      and membership.user_id = (select auth.uid())
      and membership.is_active
      and membership.role = any(allowed_roles)
  );
$$;

create or replace function private.can_manage_profile(
  target_profile_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.restaurant_members as current_membership
    join public.restaurant_members as target_membership
      on target_membership.restaurant_id = current_membership.restaurant_id
    where current_membership.user_id = (select auth.uid())
      and current_membership.is_active
      and current_membership.role in ('OWNER', 'MANAGER')
      and target_membership.user_id = target_profile_id
      and target_membership.is_active
  );
$$;

revoke all on function private.is_active_restaurant_member(uuid)
  from public, anon;
revoke all on function private.has_restaurant_role(uuid, text[])
  from public, anon;
revoke all on function private.can_manage_profile(uuid)
  from public, anon;

grant execute on function private.is_active_restaurant_member(uuid)
  to authenticated;
grant execute on function private.has_restaurant_role(uuid, text[])
  to authenticated;
grant execute on function private.can_manage_profile(uuid)
  to authenticated;

create index idx_restaurant_members_active_user_restaurant_role
  on public.restaurant_members (user_id, restaurant_id, role)
  where is_active;

revoke all on table public.restaurants from public, anon, authenticated;
revoke all on table public.branches from public, anon, authenticated;
revoke all on table public.profiles from public, anon, authenticated;
revoke all on table public.restaurant_members from public, anon, authenticated;
revoke all on table public.tables from public, anon, authenticated;
revoke all on table public.categories from public, anon, authenticated;
revoke all on table public.menu_items from public, anon, authenticated;
revoke all on table public.menu_item_images from public, anon, authenticated;

grant select, update on table public.restaurants to authenticated;
grant select, insert, update, delete on table public.branches to authenticated;
grant select, insert, update on table public.profiles to authenticated;
grant select, insert, update, delete on table public.restaurant_members
  to authenticated;
grant select, insert, update, delete on table public.tables to authenticated;
grant select, insert, update, delete on table public.categories to authenticated;
grant select, insert, update, delete on table public.menu_items to authenticated;
grant select, insert, update, delete on table public.menu_item_images
  to authenticated;

alter table public.restaurants enable row level security;
alter table public.branches enable row level security;
alter table public.profiles enable row level security;
alter table public.restaurant_members enable row level security;
alter table public.tables enable row level security;
alter table public.categories enable row level security;
alter table public.menu_items enable row level security;
alter table public.menu_item_images enable row level security;

create policy restaurants_select_active_members
on public.restaurants
for select
to authenticated
using (private.is_active_restaurant_member(id));

create policy restaurants_update_owners_managers
on public.restaurants
for update
to authenticated
using (
  private.has_restaurant_role(id, array['OWNER', 'MANAGER']::text[])
)
with check (
  private.has_restaurant_role(id, array['OWNER', 'MANAGER']::text[])
);

create policy branches_select_active_members
on public.branches
for select
to authenticated
using (private.is_active_restaurant_member(restaurant_id));

create policy branches_insert_owners_managers
on public.branches
for insert
to authenticated
with check (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy branches_update_owners_managers
on public.branches
for update
to authenticated
using (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
)
with check (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy branches_delete_owners_managers
on public.branches
for delete
to authenticated
using (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy profiles_select_own_or_managed_staff
on public.profiles
for select
to authenticated
using (
  id = (select auth.uid())
  or private.can_manage_profile(id)
);

create policy profiles_insert_own
on public.profiles
for insert
to authenticated
with check (id = (select auth.uid()));

create policy profiles_update_own
on public.profiles
for update
to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

create policy restaurant_members_select_own_or_managed_restaurant
on public.restaurant_members
for select
to authenticated
using (
  (user_id = (select auth.uid()) and is_active)
  or private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy restaurant_members_insert_owner_or_limited_manager
on public.restaurant_members
for insert
to authenticated
with check (
  private.has_restaurant_role(restaurant_id, array['OWNER']::text[])
  or (
    private.has_restaurant_role(restaurant_id, array['MANAGER']::text[])
    and role in ('WAITER', 'KITCHEN', 'CASHIER')
  )
);

create policy restaurant_members_update_owner_or_limited_manager
on public.restaurant_members
for update
to authenticated
using (
  private.has_restaurant_role(restaurant_id, array['OWNER']::text[])
  or (
    private.has_restaurant_role(restaurant_id, array['MANAGER']::text[])
    and role in ('WAITER', 'KITCHEN', 'CASHIER')
  )
)
with check (
  private.has_restaurant_role(restaurant_id, array['OWNER']::text[])
  or (
    private.has_restaurant_role(restaurant_id, array['MANAGER']::text[])
    and role in ('WAITER', 'KITCHEN', 'CASHIER')
  )
);

create policy restaurant_members_delete_owner_or_limited_manager
on public.restaurant_members
for delete
to authenticated
using (
  private.has_restaurant_role(restaurant_id, array['OWNER']::text[])
  or (
    private.has_restaurant_role(restaurant_id, array['MANAGER']::text[])
    and role in ('WAITER', 'KITCHEN', 'CASHIER')
  )
);

create policy tables_select_active_members
on public.tables
for select
to authenticated
using (private.is_active_restaurant_member(restaurant_id));

create policy tables_insert_owners_managers
on public.tables
for insert
to authenticated
with check (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy tables_update_owners_managers
on public.tables
for update
to authenticated
using (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
)
with check (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy tables_delete_owners_managers
on public.tables
for delete
to authenticated
using (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy categories_select_active_members
on public.categories
for select
to authenticated
using (private.is_active_restaurant_member(restaurant_id));

create policy categories_insert_owners_managers
on public.categories
for insert
to authenticated
with check (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy categories_update_owners_managers
on public.categories
for update
to authenticated
using (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
)
with check (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy categories_delete_owners_managers
on public.categories
for delete
to authenticated
using (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy menu_items_select_active_members
on public.menu_items
for select
to authenticated
using (private.is_active_restaurant_member(restaurant_id));

create policy menu_items_insert_owners_managers
on public.menu_items
for insert
to authenticated
with check (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy menu_items_update_owners_managers
on public.menu_items
for update
to authenticated
using (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
)
with check (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy menu_items_delete_owners_managers
on public.menu_items
for delete
to authenticated
using (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy menu_item_images_select_active_members
on public.menu_item_images
for select
to authenticated
using (private.is_active_restaurant_member(restaurant_id));

create policy menu_item_images_insert_owners_managers
on public.menu_item_images
for insert
to authenticated
with check (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy menu_item_images_update_owners_managers
on public.menu_item_images
for update
to authenticated
using (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
)
with check (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);

create policy menu_item_images_delete_owners_managers
on public.menu_item_images
for delete
to authenticated
using (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER']::text[]
  )
);
