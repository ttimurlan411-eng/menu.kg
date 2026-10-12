-- Order history: a restaurant's whole order list, newest first, read one page at a
-- time.
--
-- `staff_list_orders` (20261002040000) reads the same list but clamps to a small
-- window and offers no way to continue: a caller gets the newest 1..200 rows and
-- that is all. `staff_list_active_orders` (20261009000000) reads only the four
-- states a person still has to act on. Neither answers "what did this restaurant
-- do last week" — the first truncates, the second hides every finished order.
--
-- This migration adds exactly one function:
--
--   * `public.staff_list_order_history(p_restaurant_id, p_branch_id, p_limit,
--     p_before_created_at, p_before_order_number)`
--
--     returns every status — PENDING, ACCEPTED, PREPARING, READY, SERVED and
--     CANCELLED — newest first, in pages, using keyset (cursor) pagination rather
--     than OFFSET so a page is found by where the previous one ended rather than by
--     counting rows that may move underneath it.
--
-- Nothing else changes. `staff_list_orders`, `staff_set_order_status` and
-- `staff_list_active_orders` are not touched, keep their arguments and their grants,
-- and are reasserted unchanged at the end. No table grant, row level security
-- policy, role helper, lifecycle rule or realtime publication is altered. The order
-- tables stay as closed as every order migration left them: this function is the
-- only new way in and it opens nothing directly.
--
-- How a page is found. The list order is `created_at desc, order_number desc`, the
-- same stable order the other staff reads use. `(restaurant_id, order_number)` is
-- unique (orders_restaurant_id_order_number_key), so `(created_at, order_number)` is
-- a total, never-repeating key and a cursor that names the last row of a page cannot
-- land on it again. The next page is every row strictly older in that tuple order:
--
--   (created_at, order_number) < (p_before_created_at, p_before_order_number)
--
-- The condition is applied only when both cursor arguments are present. A partial
-- cursor (one of the two null) is treated as no cursor at all, i.e. a first-page
-- request, and answers with the newest rows; it is never a half-consumed page. This
-- is deliberate: two cursor columns are one key, and reading from only half of it
-- would return the whole list again from a position the caller did not intend.
--
-- The payload. It is the same wrapper `staff_list_orders` sends — restaurant_id,
-- branch_id and an orders array whose entries carry the order header, the ordered
-- table and the stored item snapshots — plus two fields a pager needs:
--
--   * has_more    whether another page exists after this one
--   * next_cursor the `{created_at, order_number}` of the last returned database row,
--                 or null when has_more is false. It is built from the row the
--                 database returned, never from what a client parsed, so a client
--                 that skips an order it cannot read still hands back a cursor that
--                 points exactly where the database stopped.
--
-- The extra fields are additive. `tryParseStaffOrders` reads restaurant_id and
-- orders and ignores everything else, so a client that has not been taught to page
-- still reads the first page exactly as it reads `staff_list_orders`.
--
-- How has_more is known: the query reads at most one row more than the page
-- (`v_limit + 1`). If that extra row exists, the page is full and more follow; it is
-- not returned and only the first v_limit rows are aggregated. Otherwise the fetched
-- rows are the whole page and nothing follows. Because the sort is a total order and
-- created_at and order_number never change, two orders placed in the same
-- millisecond cannot be duplicated or skipped across the page boundary.
--
-- Authorization is not written again. The same helper the other reads use,
-- `private.can_read_restaurant_orders`, answers whether the caller is an active
-- OWNER, MANAGER, WAITER or KITCHEN member of the restaurant. CASHIER stays excluded
-- for the same reason it is excluded from the other reads, and a deactivated member
-- stays excluded because the helper reads the membership's is_active flag. The
-- function raises the same `staff_order_access_denied` (42501) for a restaurant that
-- does not exist and for one the caller is not a member of, and `28000` without a
-- session. It runs as its definer with an empty search path, like every other
-- function in this schema that reaches order data.
--
-- p_limit is clamped to 1..200, default 50, a safety bound on how much work one
-- request may do rather than a promise about the whole restaurant. Nothing that
-- belongs to the guest is in the payload: no access_token, no order_access row and
-- no order_status_history row, and none can be added to it by a caller.

-- The order tables stay exactly as closed as every order migration before this one
-- left them.
revoke all on table public.order_access from public, anon, authenticated;
revoke all on table public.orders from public, anon, authenticated;
revoke all on table public.order_items from public, anon, authenticated;
revoke all on table public.order_status_history from public, anon, authenticated;

-- A restaurant's own orders, newest first, one page at a time.
--
-- p_restaurant_id is the restaurant being read, p_branch_id narrows it to one branch,
-- p_limit is the page size and the two p_before_* arguments are the cursor. All are
-- supplied by the caller and authorized against auth.uid() before anything is read;
-- the cursor is only ever a filter, so it cannot widen the scope the membership check
-- already fixed.
--
-- order_number is bigint in public.orders (orders_restaurant_id_order_number_key is
-- unique on (restaurant_id, order_number)), so p_before_order_number is bigint here
-- too. Resolving it as integer would narrow the key and could refuse a cursor for an
-- order number that is perfectly valid.
--
-- The items subquery reads the stored snapshots, in the order the guest placed them,
-- exactly as `staff_list_orders` does.
create or replace function public.staff_list_order_history(
  p_restaurant_id uuid,
  p_branch_id uuid default null,
  p_limit integer default 50,
  p_before_created_at timestamptz default null,
  p_before_order_number bigint default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  -- How many rows the query fetched, which is at most v_limit + 1.
  v_fetched integer;
  -- The page itself, already trimmed to v_limit.
  v_orders jsonb;
  -- The last row of the page, used to build next_cursor when the page is not the
  -- last one.
  v_next_created_at timestamptz;
  v_next_order_number bigint;
  v_has_more boolean;
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

  with candidates as (
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
      -- The cursor, applied only when both halves are present. A partial cursor is
      -- not a cursor: the OR makes the whole condition true and the page starts from
      -- the newest rows, which is a first-page request.
      and (
        p_before_created_at is null
        or p_before_order_number is null
        or (staff_order.created_at, staff_order.order_number)
             < (p_before_created_at, p_before_order_number)
      )
    -- Newest first, with the order number as the tie-break so two orders placed in
    -- the same millisecond keep one stable order across every page. One extra row is
    -- read so has_more can be answered without a second query.
    order by staff_order.created_at desc, staff_order.order_number desc
    limit v_limit + 1
  ),
  numbered as (
    select
      candidates.*,
      row_number() over (
        order by candidates.created_at desc, candidates.order_number desc
      ) as rn
    from candidates
  ),
  kept as (
    select * from numbered where numbered.rn <= v_limit
  )
  select
    -- Every fetched row, which is what tells the two cases apart.
    (select count(*) from numbered)::integer,
    -- The page. Ordering by rn keeps the exact order the query produced.
    (
      select coalesce(
               pg_catalog.jsonb_agg(
                 pg_catalog.jsonb_build_object(
                   'id', kept.id,
                   'order_number', kept.order_number,
                   'status', kept.status,
                   'currency', kept.currency,
                   'total', kept.total,
                   'item_count', kept.item_count,
                   'branch_id', kept.branch_id,
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
                      where stored.order_id = kept.id
                   ),
                   'created_at', kept.created_at,
                   'updated_at', kept.updated_at
                 )
                 order by kept.rn
               ),
               '[]'::jsonb
             )
        from kept
        left join public.tables as ordered_table
          on ordered_table.id = kept.table_id
    ),
    -- The last returned database row; present exactly when more follow. When the
    -- page is not the last, rn = v_limit is the last page row, and it is that row's
    -- pair, not anything a client sent, that becomes next_cursor.
    (select kept.created_at from kept where kept.rn = v_limit),
    (select kept.order_number from kept where kept.rn = v_limit)
  into v_fetched, v_orders, v_next_created_at, v_next_order_number;

  v_has_more := v_fetched > v_limit;

  -- The restaurant and branch are echoed back from the request, not looked up: they
  -- are the caller's own scope, already authorized above. next_cursor is null on the
  -- last page, so a client stops on its own field rather than guessing from a short
  -- page. No access token, no order_access row and no history row is in this payload.
  return pg_catalog.jsonb_build_object(
    'restaurant_id', p_restaurant_id,
    'branch_id', p_branch_id,
    'orders', v_orders,
    'has_more', v_has_more,
    'next_cursor', case
      when v_has_more then pg_catalog.jsonb_build_object(
        'created_at', v_next_created_at,
        'order_number', v_next_order_number
      )
      else null
    end
  );
end;
$$;

comment on function public.staff_list_order_history(uuid, uuid, integer, timestamptz, bigint) is
  'Returns one page (up to p_limit, clamped to 1..200, default 50) of all of one restaurant''s orders, every status, newest first by created_at then order_number, optionally narrowed to p_branch_id, for an active OWNER, MANAGER, WAITER or KITCHEN member of that restaurant. Pagination is keyset: p_before_created_at and p_before_order_number are the (created_at, order_number) of the last row of the previous page, and the next page is every row strictly older; a partial cursor is treated as a first-page request. The payload is the staff_list_orders envelope plus has_more and next_cursor (the last returned row''s pair, or null on the last page), and carries no guest access token, no order_access row and no status history. Raises staff_order_access_denied (42501) for a restaurant the caller is not an active member of and for one that does not exist, and 28000 without a session.';

-- Justified index.
--
-- The history read orders by (restaurant_id, created_at desc, order_number desc) and
-- walks it with a tuple cursor. idx_orders_restaurant_id is (restaurant_id,
-- created_at desc): it has no order_number column, so for two orders created in the
-- same instant the planner must still sort the tie, and it cannot seek directly to a
-- cursor pair. idx_orders_active_restaurant_created_at has the right columns but is
-- partial on the four active states, so it cannot serve a read that includes SERVED
-- and CANCELLED. This index is the full, non-partial key the read needs: it is not a
-- duplicate of either (one is a prefix without the tie-break, the other excludes the
-- terminal rows), and it lets the planner seek to the cursor and stop after
-- v_limit + 1 rows. It matches the project's existing plain `create index`
-- convention.
create index idx_orders_history_restaurant_created_at
  on public.orders (restaurant_id, created_at desc, order_number desc);

comment on index public.idx_orders_history_restaurant_created_at is
  'Full-key index for staff_list_order_history: (restaurant_id, created_at desc, order_number desc) lets the keyset cursor seek straight to where the previous page ended and read exactly one page, for every order status including the terminal ones.';

-- Callable by a signed-in member and by nobody else. Never granted to `anon`: a
-- guest is not staff, holds no membership and has no session that would pass the
-- checks above, so the function refuses them as it refuses an empty restaurant id.
revoke all on function public.staff_list_order_history(uuid, uuid, integer, timestamptz, bigint)
  from public, anon;

grant execute on function public.staff_list_order_history(uuid, uuid, integer, timestamptz, bigint)
  to authenticated;

-- The existing client paths are reasserted with their grants exactly as before this
-- migration: no existing function changed, and each keeps the argument list and the
-- grant it already had.
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

revoke all on function public.staff_list_active_orders(uuid, uuid, integer)
  from public, anon;
grant execute on function public.staff_list_active_orders(uuid, uuid, integer)
  to authenticated;

revoke all on function public.staff_set_order_status(uuid, text)
  from public, anon;
grant execute on function public.staff_set_order_status(uuid, text)
  to authenticated;
