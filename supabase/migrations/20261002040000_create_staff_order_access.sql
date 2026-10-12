-- Staff order access: the read path and the status change, for signed-in staff only.
--
-- Order storage, the guest read and the lifecycle already exist. What was missing
-- was the way the restaurant itself sees its own orders: until now the only ways in
-- were `create_table_order` and `guest_orders`, both addressed by a guest's opaque
-- token, so no member of a restaurant could list what had been ordered there or
-- move an order along.
--
-- This migration adds exactly two staff entry points and the authorization they
-- share:
--
--   * `public.staff_list_orders(p_restaurant_id, p_branch_id, p_limit)` reads the
--     orders of one restaurant, optionally narrowed to one branch;
--   * `public.staff_set_order_status(p_order_id, p_new_status)` moves one order,
--     and nothing else.
--
-- Both authenticate with the existing Supabase Auth session. There is no second
-- sign-in, no staff password and no staff token: the caller is `auth.uid()`, and
-- the membership row in `public.restaurant_members` is the whole of what they are.
-- That table already exists with roles OWNER, MANAGER, WAITER, KITCHEN and CASHIER,
-- so nothing here creates a role or an enum.
--
-- Who may do what. Reading is for the four roles that work an order, and moving an
-- order is narrowed further per move:
--
--   role      may move                                                        may read
--   OWNER     any move the lifecycle allows                                   yes
--   MANAGER   any move the lifecycle allows                                   yes
--   WAITER    PENDING->ACCEPTED, ACCEPTED->PREPARING, READY->SERVED, and any    yes
--             cancellation the lifecycle permits
--   KITCHEN   ACCEPTED->PREPARING, PREPARING->READY, and any cancellation      yes
--             the lifecycle permits
--   CASHIER   nothing                                                         no
--
-- CASHIER is excluded on purpose: this step defines what a cashier may do with an
-- order, and the honest answer is nothing, because payment and cash handling do
-- not exist in this project yet. Adding the role later is a one-line change here.
--
-- Two separate questions are kept apart, because they have different owners:
--
--   * `private.can_manage_restaurant_orders` answers "may this member's role make
--     this move", and only that. It is the whole of the role matrix above, and it
--     is expressed by delegating to `private.has_restaurant_role`, the primitive the
--     existing policies already use.
--   * `public.guard_order_status_transition` answers "may this move be made at
--     all", and stays the only place the lifecycle is written down.
--
-- The status RPC therefore decides *authorization* and then writes the new status
-- like any other writer. It does not re-check the lifecycle, does not raise the
-- lifecycle errors itself, and cannot skip the trigger: the guard fires for the
-- definer of the function exactly as it does for the table owner. An order in
-- READY that staff ask to cancel, or a status the lifecycle has never heard of, is
-- refused by the trigger with `invalid_order_status_transition` or
-- `invalid_order_status`, not with an authorization error — so an owner asking for
-- something impossible is told it is impossible, and the audit trail and the rules
-- stay in exactly one place.
--
-- What the staff payload may contain. Unlike the guest payload, this one does carry
-- ids: restaurant, branch and table are what a staff screen works with, and a member
-- of a restaurant can already select all three through the policies from
-- 20260918000100_enable_core_rls.sql. What it does not carry is anything that
-- belongs to the guest: no `access_token`, no `order_access` row, and no status
-- history. A staff screen needs to know where an order is now, not how to read it
-- as the guest who placed it. The guest's read path is not widened by this migration
-- and the token is not readable from here.
--
-- Refusals are deliberately undifferentiated where being precise would leak. A
-- caller who is not an active member of the order's restaurant, and a caller who
-- names an order id that does not exist, both get `staff_order_access_denied`
-- (42501): whether some other restaurant's order id is real is not something this
-- function answers for anyone. The same holds for the read: a restaurant that does
-- not exist and one the caller is not a member of are the same answer.
--
-- Defence in depth, repeated on purpose. The orders, order_items, order_access and
-- order_status_history tables keep no grant at all and keep RLS enabled, so the two
-- functions below are the only way an authenticated member reaches order data, and
-- adding a grant later cannot expose the tables without also adding a policy. The
-- two guest functions are reasserted unchanged with their grants, so this migration
-- provably widens nothing on the guest side.
--
-- Deliberately NOT in this migration, because the project has not defined them:
--
--   * any waiter, kitchen or owner screen. Nothing here is reachable from the UI,
--     and no page is expected to exist for it yet;
--   * `changed_by` on `public.order_status_history`. The audit trail still records
--     what moved an order and when but not who, because this step consumes nothing
--     that would read an identity off it, and the first place a user id is written
--     to an order belongs with the step that also shows a staff identity;
--   * order editing: no line changes, no quantity changes, no notes, no cancellation
--     reason. A staff screen must never be able to change what a guest ordered, only
--     where it has got to;
--   * payment, discounts, tax, tip, tables of the day, dashboard counts, or any
--     reservation or customer-facing change;
--   * a staff RLS policy on `orders`. The two functions are the access path on
--     purpose: a policy would hand every authenticated member a direct query on the
--     table, which is a wider door than the one this step has defined.

-- Defence in depth on the order tables, as in every order migration before this one.
revoke all on table public.order_access from public, anon, authenticated;
revoke all on table public.orders from public, anon, authenticated;
revoke all on table public.order_items from public, anon, authenticated;
revoke all on table public.order_status_history from public, anon, authenticated;

-- Whether the caller may read this restaurant's orders at all.
--
-- Built on `private.has_restaurant_role` rather than written out again, so the answer
-- to "is this user an active member of this restaurant with this role" stays in the
-- one function the existing policies already trust. Inactive memberships are
-- excluded there, which is what makes deactivating a member revoke order access as
-- well as menu access.
--
-- CASHIER is absent by design, as the header says: no order access for a role whose
-- order duties this project has not defined.
create or replace function private.can_read_restaurant_orders(
  target_restaurant_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_restaurant_role(
    target_restaurant_id,
    array['OWNER', 'MANAGER', 'WAITER', 'KITCHEN']::text[]
  );
$$;

comment on function private.can_read_restaurant_orders(uuid) is
  'True when the caller has an active membership of this restaurant with a role that works orders: OWNER, MANAGER, WAITER or KITCHEN. Used by staff_list_orders and staff_set_order_status only.';

-- Whether the caller may make this particular move on an order of this restaurant.
--
-- The three arguments are the restaurant, the status the order is actually in and
-- the status asked for. The middle two are deliberately parameters rather than a
-- lookup: the caller of this function has already read the order and passes what it
-- really holds, so a client cannot claim an order is somewhere else in the lifecycle
-- to unlock a move it is not entitled to.
--
-- The case below is the role matrix and nothing else. Where a move is not listed, or
-- is not a move a role is given, the answer is no:
--
--   * cancellation is every order role's business, and `from_status` is not narrowed
--     further here on purpose — where an order may be cancelled is the lifecycle's
--     question, and duplicating it in an authorization function is how the two drift
--     apart. The trigger still refuses cancelling a READY order;
--   * the default is OWNER and MANAGER only. Management is not restricted to a list
--     of moves: it may attempt any move, and the trigger decides whether the move
--     itself is legal. That is what keeps this function from becoming a second,
--     drifting copy of the lifecycle;
--   * a no-op (a status equal to itself) is a default branch move, so OWNER and
--     MANAGER may write one and a WAITER or KITCHEN may not. Writing a status that
--     does not change it is not a transition, so it records no history either way.
create or replace function private.can_manage_restaurant_orders(
  target_restaurant_id uuid,
  from_status text,
  to_status text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_restaurant_role(
    target_restaurant_id,
    case
      when to_status = 'CANCELLED'
        then array['OWNER', 'MANAGER', 'WAITER', 'KITCHEN']::text[]
      when from_status = 'PENDING' and to_status = 'ACCEPTED'
        then array['OWNER', 'MANAGER', 'WAITER']::text[]
      when from_status = 'ACCEPTED' and to_status = 'PREPARING'
        then array['OWNER', 'MANAGER', 'WAITER', 'KITCHEN']::text[]
      when from_status = 'PREPARING' and to_status = 'READY'
        then array['OWNER', 'MANAGER', 'KITCHEN']::text[]
      when from_status = 'READY' and to_status = 'SERVED'
        then array['OWNER', 'MANAGER', 'WAITER']::text[]
      else array['OWNER', 'MANAGER']::text[]
    end
  );
$$;

comment on function private.can_manage_restaurant_orders(uuid, text, text) is
  'True when the caller has an active membership of this restaurant whose role may make this move: WAITER and KITCHEN are limited to their own steps and to cancellation, OWNER and MANAGER may attempt any move. Says nothing about whether the move is legal — guard_order_status_transition does.';

-- Neither helper is a client-callable function. Both are used inside the security
-- definer functions below, which run as the owner, so `revoke from public` is
-- enough: `public` includes `authenticated`, so no grant is issued to any client
-- role and there is no path to either helper from postgrest. A later migration that
-- wants one in an RLS policy must grant it to `authenticated` deliberately, the way
-- the policies in 20260918000100_enable_core_rls.sql already do for their helpers.
revoke all on function private.can_read_restaurant_orders(uuid)
  from public, anon;
revoke all on function private.can_manage_restaurant_orders(uuid, text, text)
  from public, anon;

-- A restaurant's own orders, newest first.
--
-- p_restaurant_id is the restaurant being worked and p_branch_id narrows that to one
-- branch, both supplied by the caller and both authorized against `auth.uid()`
-- before anything is read. p_limit is clamped to 1..200 rather than trusted, because
-- a limit a client chose is also a limit the database has to answer.
--
-- There is no filter on branch, restaurant or table activity. An order belongs to
-- the restaurant that took it whatever has happened to the branch since, exactly as
-- the guest read treats it: staff still need to see the orders of a branch that has
-- been closed for the day, and an order whose table has since been deleted is still
-- an order.
--
-- The branch filter cannot reach another restaurant's branch. An order carries the
-- composite foreign key (branch_id, restaurant_id) into branches, so an order already
-- filtered to p_restaurant_id can only be in one of that restaurant's branches;
-- naming a foreign branch id therefore matches no order and returns an empty list,
-- which is the same answer as a branch with no orders and says nothing about whether
-- that branch exists.
--
-- The items subquery reads the stored snapshots, in the order the guest placed them.
create or replace function public.staff_list_orders(
  p_restaurant_id uuid,
  p_branch_id uuid default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 200);
  v_orders jsonb;
begin
  if (select auth.uid()) is null then
    raise exception using
      errcode = '28000',
      message = 'Authentication is required to read restaurant orders.';
  end if;

  -- An unknown restaurant, a restaurant with no such id and a restaurant the caller
  -- is not an active member of are one answer on purpose. This function is for staff
  -- of a restaurant they belong to, and it is not a way to find out which
  -- restaurants exist.
  if p_restaurant_id is null
     or not private.can_read_restaurant_orders(p_restaurant_id) then
    raise exception using
      errcode = '42501',
      message = 'staff_order_access_denied';
  end if;

  with recent as (
    select
      staff_order.id,
      staff_order.order_number,
      staff_order.status,
      staff_order.currency,
      staff_order.total,
      staff_order.item_count,
      staff_order.branch_id,
      staff_order.table_id,
      staff_order.created_at,
      staff_order.updated_at
    from public.orders as staff_order
    where staff_order.restaurant_id = p_restaurant_id
      and (p_branch_id is null or staff_order.branch_id = p_branch_id)
    -- Newest first, with the order number as the tie-break so two orders placed in
    -- the same millisecond keep a stable order on every read. The limit is applied
    -- here, before the aggregation, so it bounds the rows read and not the array.
    order by staff_order.created_at desc, staff_order.order_number desc
    limit v_limit
  )
  select coalesce(
           pg_catalog.jsonb_agg(
             pg_catalog.jsonb_build_object(
               'id', recent.id,
               'order_number', recent.order_number,
               'status', recent.status,
               'currency', recent.currency,
               'total', recent.total,
               'item_count', recent.item_count,
               'branch_id', recent.branch_id,
               -- The table is null for an order placed without one, which the
               -- column already allows for a takeaway order that no step has
               -- defined. It is left null rather than shown as an empty table, and
               -- unlike the guest read it does not remove such an order from the
               -- list: staff still need to see it.
               'table', case
                 when ordered_table.id is null then null
                 else pg_catalog.jsonb_build_object(
                   'id', ordered_table.id,
                   'number', ordered_table.table_number,
                   'name', ordered_table.name
                 )
               end,
               'items', (
                 select coalesce(
                          pg_catalog.jsonb_agg(
                            pg_catalog.jsonb_build_object(
                              'menu_item_id', stored.menu_item_id,
                              'product_name', stored.product_name,
                              'unit_price', stored.unit_price,
                              'quantity', stored.quantity,
                              'line_total', stored.line_total
                            )
                            order by stored.sort_order
                          ),
                          '[]'::jsonb
                        )
                   from public.order_items as stored
                  where stored.order_id = recent.id
               ),
               'created_at', recent.created_at,
               'updated_at', recent.updated_at
             )
             order by recent.created_at desc, recent.order_number desc
           ),
           '[]'::jsonb
         )
    into v_orders
    from recent
    left join public.tables as ordered_table
      on ordered_table.id = recent.table_id;

  -- The restaurant and branch are echoed back from the request, not looked up: they
  -- are the caller's own scope, already authorized above. No access token, no
  -- order_access row and no history row is in this payload, and none can be added
  -- to it by a caller.
  return pg_catalog.jsonb_build_object(
    'restaurant_id', p_restaurant_id,
    'branch_id', p_branch_id,
    'orders', v_orders
  );
end;
$$;

comment on function public.staff_list_orders(uuid, uuid, integer) is
  'Returns up to p_limit (clamped to 1..200) of the orders of one restaurant, newest first, optionally narrowed to p_branch_id, for an active OWNER, MANAGER, WAITER or KITCHEN member of that restaurant. Carries the order header, the ordered table and the stored item snapshots, and no guest access token, no order_access row and no status history. Raises staff_order_access_denied (42501) for a restaurant the caller is not an active member of and for one that does not exist, and 28000 without a session.';

-- Moves one order, and only a status.
--
-- Deliberately no p_restaurant_id. Every other function in this schema that reaches
-- another restaurant's rows carries the restaurant or a token that resolves to one,
-- because a guest has nothing else to be addressed by. A staff member does: the
-- order id. The restaurant is read from the order itself and the membership is
-- checked against that, so there is no parameter here for a client to get wrong, and
-- no order of another restaurant can be named as this restaurant's by anyone.
--
-- The check order matters, and is the same order in both functions: a session, then
-- the order, then the membership, then the role's move, then the write. A caller who
-- is not a member learns only that the order is not theirs; a member whose role may
-- not make this move learns only that; and the write itself is a plain update that
-- the lifecycle guard vets exactly as it vets every other writer.
create or replace function public.staff_set_order_status(
  p_order_id uuid,
  p_new_status text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_restaurant_id uuid;
  -- What the order really holds now, read rather than trusted from the caller.
  v_current_status text;
  v_new_status text;
  -- What the write below stored, which is not what was asked for when the trigger
  -- refused the move.
  v_stored_id uuid;
  v_stored_status text;
  v_updated_at timestamptz;
begin
  if (select auth.uid()) is null then
    raise exception using
      errcode = '28000',
      message = 'Authentication is required to change an order status.';
  end if;

  if p_order_id is null or p_new_status is null or pg_catalog.btrim(p_new_status) = '' then
    raise exception using
      errcode = '22023',
      message = 'An order id and a status are required.';
  end if;

  v_new_status := pg_catalog.btrim(p_new_status);

  select staff_order.restaurant_id, staff_order.status
    into v_restaurant_id, v_current_status
    from public.orders as staff_order
   where staff_order.id = p_order_id;

  -- No order, an order id that does not exist and an order belonging to a restaurant
  -- this caller is not an active member of are one answer. Whether an order id from
  -- another restaurant is real is not something this function answers.
  if v_restaurant_id is null
     or not private.can_read_restaurant_orders(v_restaurant_id) then
    raise exception using
      errcode = '42501',
      message = 'staff_order_access_denied';
  end if;

  -- Authorization only: whether this move is legal is the trigger's answer, and this
  -- function does not know. See the header.
  if not private.can_manage_restaurant_orders(
       v_restaurant_id,
       v_current_status,
       v_new_status
     ) then
    raise exception using
      errcode = '42501',
      message = 'staff_order_status_not_permitted';
  end if;

  -- A plain update. It is not what makes this caller's write safe: the guard and the
  -- history trigger below fire for the definer of this function exactly as they fire
  -- for the table owner, which is the point of putting them on the table rather than
  -- in a function. An invalid move, or a status the lifecycle does not have, is
  -- refused here by public.guard_order_status_transition with its own P0001 error.
  update public.orders as staff_order
     set status = v_new_status
   where staff_order.id = p_order_id
     and staff_order.restaurant_id = v_restaurant_id
  returning staff_order.id, staff_order.status, staff_order.updated_at
    into v_stored_id, v_stored_status, v_updated_at;

  -- Nothing can delete an order, so this write found the row it read above. It is
  -- still checked, because a write that changed no row must not be answered with a
  -- status nobody stored.
  if v_stored_id is null then
    raise exception using
      errcode = '42501',
      message = 'staff_order_access_denied';
  end if;

  -- The id, the state it is now in and when the row changed. The lines are not in
  -- this answer because nothing about them changed: a staff screen updates the
  -- status of the order it already has rather than re-reading the whole order.
  return pg_catalog.jsonb_build_object(
    'id', v_stored_id,
    'status', v_stored_status,
    'updated_at', v_updated_at
  );
end;
$$;

comment on function public.staff_set_order_status(uuid, text) is
  'Moves one order to p_new_status for an active member of the order''s own restaurant, and changes nothing else. Authorization only: whether the move is legal is decided by guard_order_status_transition, which fires for this function as it does for any writer. Raises staff_order_access_denied (42501) for an order of another restaurant or one that does not exist, staff_order_status_not_permitted (42501) for a move this role does not make, 22023 for a missing argument, and the lifecycle''s own P0001 error for an illegal move. Returns the order id, its new status and updated_at.';

-- Both functions are callable by a signed-in member and by nobody else. Never
-- granted to `anon`: a guest is not staff, holds no membership and has no session
-- that would pass the checks above, so the function refuses them as it refuses an
-- empty restaurant id.
revoke all on function public.staff_list_orders(uuid, uuid, integer)
  from public, anon;

grant execute on function public.staff_list_orders(uuid, uuid, integer)
  to authenticated;

revoke all on function public.staff_set_order_status(uuid, text)
  from public, anon;

grant execute on function public.staff_set_order_status(uuid, text)
  to authenticated;

-- The guest side is reasserted unchanged, with the same grants as before this
-- migration: no guest-executable function has gained a status parameter, and the two
-- functions above are not executable by `anon`.
revoke all on function public.create_table_order(text, jsonb, text) from public, anon;
grant execute on function public.create_table_order(text, jsonb, text)
  to anon, authenticated;

revoke all on function public.guest_orders(text) from public, anon;
grant execute on function public.guest_orders(text)
  to anon, authenticated;