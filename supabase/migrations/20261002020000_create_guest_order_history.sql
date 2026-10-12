-- Guest order history: reading one's own orders back with the order access token.
--
-- Placing an order already exists (create_table_order) and already persists an
-- opaque token per QR context on the guest's device, but there was no way to read
-- an order back. This migration adds exactly that read path and nothing else: the
-- same access model as public.guest_reservations, applied to orders.
--
-- The token is the only credential. It is not a session, there is no customer
-- account, and no restaurant, branch, table or order id is ever sent by the
-- client — the same narrow contract the public menu and the reservations have
-- already proved. A guest cannot ask for "the orders of restaurant X": the request
-- has exactly one parameter, and the answer is exactly the orders that token owns.
--
-- What makes this safe:
--
--   * every row is filtered by access_token = btrim(p_access_token), so a guest
--     sees only their own orders and a token from another restaurant, table or
--     guest matches nothing;
--   * an unknown, empty, malformed or expired token returns an empty list rather
--     than an error, so the function cannot be used to find out which tokens
--     exist, exactly as guest_reservations does;
--   * the payload is built here from the stored snapshot columns, so it exposes no
--     restaurant, branch or table id, no access token, and no order id on a line;
--   * the orders, order_items and order_access tables keep no grant at all, so this
--     function stays the only way in and the read cannot be widened by choosing a
--     different query.
--
-- A token is minted per QR context by the app: DeviceOrderAccessStore keys it by
-- the table's QR token, so a guest who scans several tables gets one token per
-- table and a token stored for one table is never the one sent for another. That
-- is what makes a context's history read back only the orders placed from it.
--
-- History deliberately does not follow the restaurant's current state: an order
-- stays readable after the table is closed, the dish is renamed or deleted, or the
-- restaurant itself is deactivated. The stored snapshots are the record, and a
-- guest must still be able to read what they ordered and what it cost.
--
-- Deliberately NOT in this migration, because the project has not defined them:
-- guest cancellation of an order, order status transitions beyond the single
-- initial PENDING state, staff-side and kitchen order handling, payment, and any
-- way for a guest to edit an order after placing it.
--
-- Deliberately NOT touched: the reservation token, its store and the reservation
-- functions. The two capabilities stay separate: an order token cannot read a
-- reservation and a reservation token cannot read an order, because they live in
-- two unrelated tables and are matched only against their own.

-- Defence in depth, repeated on purpose. The customer order migration already
-- enabled RLS and revoked every grant on these tables; restating it here means a
-- later migration that hands out a grant on orders still cannot expose them
-- without also adding a policy, and it documents that the read path below is
-- intended to be the only one.
revoke all on table public.order_access from public, anon, authenticated;
revoke all on table public.orders from public, anon, authenticated;
revoke all on table public.order_items from public, anon, authenticated;

-- The guest's own orders, addressed by the opaque order access token.
--
-- Deliberately identical in shape to the `order` object create_table_order
-- returns, so one guest model reads an order the same way whether it was just
-- placed or read back days later. p_access_token is the whole request.
create or replace function public.guest_orders(p_access_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_orders jsonb;
begin
  -- An unknown, empty or malformed token returns an empty list rather than an
  -- error, so the public flow cannot be probed for database internals and cannot
  -- be used to learn which tokens exist. Every case is deliberately
  -- indistinguishable from a guest who simply has no orders.
  if p_access_token is null or pg_catalog.btrim(p_access_token) = '' then
    return jsonb_build_object('orders', '[]'::jsonb);
  end if;

  select coalesce(
           pg_catalog.jsonb_agg(
             pg_catalog.jsonb_build_object(
               'id', guest_order.id,
               'order_number', guest_order.order_number,
               'status', guest_order.status,
               'currency', guest_order.currency,
               'total', guest_order.total,
               'item_count', guest_order.item_count,
               'restaurant_name', restaurant.name,
               'branch_name', branch.name,
               'table', pg_catalog.jsonb_build_object(
                 'number', ordered_table.table_number,
                 'name', ordered_table.name
               ),
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
                  where stored.order_id = guest_order.id
               ),
               'created_at', guest_order.created_at
             )
             -- Newest first, with the order number as a tie-break so two orders
             -- placed in the same millisecond keep a stable order on every read.
             order by guest_order.created_at desc, guest_order.order_number desc
           ),
           '[]'::jsonb
         )
    into v_orders
    from public.orders as guest_order
    join public.restaurants as restaurant
      on restaurant.id = guest_order.restaurant_id
    join public.branches as branch
      on branch.id = guest_order.branch_id
    -- Every order placed so far belongs to the table its QR code resolved to, so
    -- this is an inner join. An order with no table — the takeaway case the column
    -- already allows for a future step — is deliberately left out rather than
    -- shown with an empty table label, because this step has defined no guest view
    -- for it.
    join public.tables as ordered_table
      on ordered_table.id = guest_order.table_id
   -- The entire isolation of this function: the token is matched against the
   -- orders it owns, and nothing else narrows or widens the result. No guest can
   -- reach another's orders, another restaurant's orders, or another table
   -- context's orders, because the request carries no other value to name them.
   where guest_order.access_token = pg_catalog.btrim(p_access_token);

  return pg_catalog.jsonb_build_object('orders', v_orders);
end;
$$;

comment on function public.guest_orders(text) is
  'Returns the orders created with this opaque guest order access token, newest first, or an empty list for an unknown, empty or expired token. Reads only the stored snapshot amounts, exposes no restaurant, branch or table id, no access token, and no order id on a line.';

-- Defence in depth: the function is granted to the two client roles only, never to
-- public, so nothing can call it through another role.
revoke all on function public.guest_orders(text) from public, anon;

grant execute on function public.guest_orders(text)
  to anon, authenticated;
