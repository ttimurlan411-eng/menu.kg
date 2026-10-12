-- Active orders: the orders a restaurant has to act on, independent of how much
-- history has piled up behind them.
--
-- `staff_list_orders` (20261002040000) reads a restaurant's orders newest first and
-- clamps a caller's limit to at most 200. That window is a history window: an order
-- that is still waiting is returned only because it happens to be among the newest
-- rows. Once more than the limit of newer orders exist — which the terminal states
-- SERVED and CANCELLED fill up fastest — an older order that still needs a person
-- falls out of the answer and disappears from both the staff orders list and the
-- kitchen screen. The window is not wrong for history; it is the wrong shape for
-- work.
--
-- This migration adds exactly one function:
--
--   * `public.staff_list_active_orders(p_restaurant_id, p_branch_id, p_limit)`
--     returns only the orders whose lifecycle status is one a person still has to
--     act on — PENDING, ACCEPTED, PREPARING or READY — and never the two terminal
--     states SERVED and CANCELLED.
--
-- Nothing else changes. `staff_list_orders` and `staff_set_order_status` are not
-- touched: the history read keeps its 1..200 window and its callers, the status
-- move keeps its authorization, and this function is added beside them. It is a
-- second read path into the same tables, not a replacement, so a client that has
-- not been updated still reads history exactly as before.
--
-- Why the lifecycle states are the filter. The transitions are fixed by
-- 20261002030000_create_order_status_lifecycle.sql: PENDING -> ACCEPTED -> PREPARING
-- -> READY -> SERVED, with CANCELLED reachable from the three states before the food
-- is ready. SERVED and CANCELLED are terminal, so nothing follows them and no one is
-- waiting on them. The four non-terminal states are the whole of the set that needs
-- attention, and they are named here as literals rather than derived, exactly as the
-- orders check constraint names them. A future state would have to be added to both
-- places deliberately.
--
-- What the payload may contain. It is the same wrapper and the same order object
-- `staff_list_orders` returns — restaurant_id, branch_id and an orders array whose
-- entries carry the order header, the ordered table and the stored item snapshots —
-- so `tryParseStaffOrders` on the client reads it without a second parser. Nothing
-- that belongs to the guest is in it: no access_token, no order_access row and no
-- status history, and none can be added to it by a caller.
--
-- One honest limitation, stated rather than hidden: p_limit is clamped to a maximum
-- of 1000. That is a safety cap on how much work one request may do, and it is not a
-- promise that an arbitrarily large number of active orders will always be returned.
-- A restaurant whose active orders ever exceeded 1000 would need paginated active
-- reads; this migration does not add them, because no part of the product has an
-- active backlog anywhere near that size and inventing a paging protocol for it
-- would be a guess. The cap is set high enough that the pathological case this
-- migration exists to fix — an old active order hidden behind a large history — is
-- fixed for every realistic restaurant.
--
-- Authorization is not written again. The same helper `staff_list_orders` uses,
-- `private.can_read_restaurant_orders`, answers whether the caller is an active
-- OWNER, MANAGER, WAITER or KITCHEN member of the restaurant. CASHIER stays excluded
-- for the same reason it is excluded from the other read, and a deactivated member
-- stays excluded because the helper reads the membership's is_active flag. The
-- function raises the same `staff_order_access_denied` (42501) for a restaurant that
-- does not exist and for one the caller is not a member of, and `28000` without a
-- session. It runs as its definer with an empty search path, like every other
-- function in this schema that reaches order data.
--
-- Defence in depth, repeated as in every order migration before this one: the order
-- tables keep no grant and keep row level security enabled, so this function is the
-- only new way in and no policy on `public.orders` is added. The grants at the end
-- reassert the two existing client paths unchanged.

-- The order tables stay exactly as closed as every order migration before this one
-- left them.
revoke all on table public.order_access from public, anon, authenticated;
revoke all on table public.orders from public, anon, authenticated;
revoke all on table public.order_items from public, anon, authenticated;
revoke all on table public.order_status_history from public, anon, authenticated;

-- A restaurant's own active orders, newest first.
--
-- p_restaurant_id is the restaurant being worked and p_branch_id narrows that to one
-- branch, both supplied by the caller and both authorized against `auth.uid()` before
-- anything is read. p_limit is clamped to 1..1000 rather than trusted, because a
-- limit a client chose is also a limit the database has to answer; see the header for
-- what that cap does and does not guarantee.
--
-- The branch filter cannot reach another restaurant's branch. An order carries the
-- composite foreign key (branch_id, restaurant_id) into branches, so an order already
-- filtered to p_restaurant_id can only be in one of that restaurant's branches;
-- naming a foreign branch id therefore matches no order and returns an empty list,
-- which is the same answer as a branch with no active orders and says nothing about
-- whether that branch exists.
--
-- The items subquery reads the stored snapshots, in the order the guest placed them,
-- exactly as `staff_list_orders` does.
create or replace function public.staff_list_active_orders(
  p_restaurant_id uuid,
  p_branch_id uuid default null,
  p_limit integer default 500
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 500), 1), 1000);
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

  with active as (
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
      and staff_order.status in (
        'PENDING', 'ACCEPTED', 'PREPARING', 'READY'
      )
      and (p_branch_id is null or staff_order.branch_id = p_branch_id)
    -- Newest first, with the order number as the tie-break so two orders placed in
    -- the same millisecond keep a stable order on every read. The limit is applied
    -- here, before the aggregation, so it bounds the rows read and not the array.
    -- The active set is what the limit bounds, not a mix of active and terminal
    -- rows, which is the whole point of this function.
    order by staff_order.created_at desc, staff_order.order_number desc
    limit v_limit
  )
  select coalesce(
           pg_catalog.jsonb_agg(
             pg_catalog.jsonb_build_object(
               'id', active.id,
               'order_number', active.order_number,
               'status', active.status,
               'currency', active.currency,
               'total', active.total,
               'item_count', active.item_count,
               'branch_id', active.branch_id,
               -- The table is null for an order placed without one, exactly as in
               -- `staff_list_orders`, and such an order is still listed.
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
                  where stored.order_id = active.id
               ),
               'created_at', active.created_at,
               'updated_at', active.updated_at
             )
             order by active.created_at desc, active.order_number desc
           ),
           '[]'::jsonb
         )
    into v_orders
    from active
    left join public.tables as ordered_table
      on ordered_table.id = active.table_id;

  -- The restaurant and branch are echoed back from the request, not looked up: they
  -- are the caller's own scope, already authorized above. No access token, no
  -- order_access row and no history row is in this payload.
  return pg_catalog.jsonb_build_object(
    'restaurant_id', p_restaurant_id,
    'branch_id', p_branch_id,
    'orders', v_orders
  );
end;
$$;

comment on function public.staff_list_active_orders(uuid, uuid, integer) is
  'Returns up to p_limit (clamped to 1..1000, default 500) of the orders of one restaurant whose status is PENDING, ACCEPTED, PREPARING or READY, newest first, optionally narrowed to p_branch_id, for an active OWNER, MANAGER, WAITER or KITCHEN member of that restaurant. Excludes the terminal SERVED and CANCELLED states. The payload is the same wrapper and order shape staff_list_orders returns, and carries no guest access token, no order_access row and no status history. Raises staff_order_access_denied (42501) for a restaurant the caller is not an active member of and for one that does not exist, and 28000 without a session. The 1..1000 cap is a safety bound, not a guarantee that an arbitrarily large active backlog is returned in one read.';

-- Justified partial index.
--
-- The existing idx_orders_restaurant_id (restaurant_id, created_at desc) serves the
-- history read but cannot skip terminal rows: an active-order read against a large
-- history still walks index entries for orders that need nobody. This index covers
-- only the four active states, so the planner reads active rows alone and the same
-- key order satisfies the created_at DESC, order_number DESC sort. The branch filter
-- is applied on top of the restaurant prefix; the active set is small, so that is
-- cheap either way. This matches the project's existing plain `create index`
-- convention and adds nothing but the predicate.
create index idx_orders_active_restaurant_created_at
  on public.orders (restaurant_id, created_at desc, order_number desc)
  where status in ('PENDING', 'ACCEPTED', 'PREPARING', 'READY');

comment on index public.idx_orders_active_restaurant_created_at is
  'Partial index on the four non-terminal order states, for staff_list_active_orders: it lets the read skip SERVED and CANCELLED history entirely and returns the active orders in the order the function sorts them.';

-- Callable by a signed-in member and by nobody else. Never granted to `anon`: a
-- guest is not staff, holds no membership and has no session that would pass the
-- checks above, so the function refuses them as it refuses an empty restaurant id.
revoke all on function public.staff_list_active_orders(uuid, uuid, integer)
  from public, anon;

grant execute on function public.staff_list_active_orders(uuid, uuid, integer)
  to authenticated;

-- The existing client paths are reasserted with their grants exactly as before this
-- migration: no existing function changed, and the two staff functions keep the
-- argument lists and grants they already had.
revoke all on function public.create_table_order(text, jsonb, text) from public, anon;
grant execute on function public.create_table_order(text, jsonb, text)
  to anon, authenticated;

revoke all on function public.guest_orders(text) from public, anon;
grant execute on function public.guest_orders(text)
  to anon, authenticated;

revoke all on function public.staff_list_orders(uuid, uuid, integer)
  from public, anon;
grant execute on function public.staff_list_orders(uuid, uuid, integer)
  to authenticated;

revoke all on function public.staff_set_order_status(uuid, text)
  from public, anon;
grant execute on function public.staff_set_order_status(uuid, text)
  to authenticated;
