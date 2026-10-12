-- Guest order history: isolation and access-control checks for the read path.
--
-- Runs public.guest_orders against a real database and proves the properties that
-- matter for "My Orders", as the `anon` and `authenticated` roles rather than as
-- the owner:
--
--   * neither role can read or write the order tables directly
--   * the token is the only thing the function accepts
--   * an unknown, empty, malformed or foreign token returns no orders
--   * a token from one QR context cannot reach another QR context's orders
--   * a token from one restaurant cannot reach another restaurant's orders
--   * order items are reachable only through their own guest's token, and never
--     through a reservation token, another guest's token or a signed-in session
--   * the payload is the stored snapshot and nothing else: no access token, no
--     restaurant, branch, table or line order id
--   * history does not follow the live menu, the table or the restaurant
--
-- Usage, against a database where supabase/migrations has been applied:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/guest_order_history_isolation.sql
--
-- On Supabase the auth schema and the anon/authenticated roles already exist and
-- the guard below does nothing. Against a plain Postgres it creates a minimal
-- stand-in for `auth.users` and the two roles, so the whole project can be
-- verified locally. Everything runs in one transaction that is rolled back at the
-- end, so the script leaves no rows behind.

\set ON_ERROR_STOP on

begin;

-- Guard: Supabase already provides auth.users and the anon/authenticated roles.
do $$
begin
  if to_regclass('auth.users') is null then
    create schema if not exists auth;
    create table auth.users (id uuid primary key, email text);
    create or replace function auth.uid()
    returns uuid
    language sql
    stable
    as $fn$
      select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
    $fn$;
  end if;

  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end
$$;

grant usage on schema public to anon, authenticated;

-- Helpers, created as the session owner and used from any role.
create or replace function pg_temp.assert_true(
  condition boolean,
  message text
)
returns void
language plpgsql
as $$
begin
  if condition is not true then
    raise exception 'FAILED: %', message using errcode = 'P0001';
  end if;
  raise notice 'ok: %', message;
end;
$$;

create or replace function pg_temp.assert_equals(
  actual text,
  expected text,
  message text
)
returns void
language plpgsql
as $$
begin
  if actual is distinct from expected then
    raise exception 'FAILED: % (got %, expected %)',
      message, actual, expected using errcode = 'P0001';
  end if;
  raise notice 'ok: %', message;
end;
$$;

-- Asserts that [statement] is refused for the current role. Any error passes,
-- which is intentional: both "permission denied for table" and "row-level
-- security policy" mean the guest is locked out.
create or replace function pg_temp.assert_denied(
  statement text,
  message text
)
returns void
language plpgsql
as $$
begin
  begin
    execute statement;
  exception
    when others then
      raise notice 'ok: % (refused with %)', message, sqlstate;
      return;
  end;

  raise exception 'FAILED: % (the statement was allowed)', message
    using errcode = 'P0001';
end;
$$;

-- Asserts that [statement] fails with [expected_code].
create or replace function pg_temp.assert_fails_with(
  statement text,
  expected_code text,
  message text
)
returns void
language plpgsql
as $$
begin
  begin
    execute statement;
  exception
    when others then
      if sqlstate = expected_code then
        raise notice 'ok: % (% raised)', message, sqlstate;
        return;
      end if;
      raise exception 'FAILED: % (got %, expected %)',
        message, sqlstate, expected_code using errcode = 'P0001';
  end;

  raise exception 'FAILED: % (the statement was allowed)', message
    using errcode = 'P0001';
end;
$$;

-- The orders inside a guest_orders payload.
create or replace function pg_temp.orders(payload jsonb)
returns setof jsonb
language sql
stable
as $fn$
  select jsonb_array_elements(coalesce(payload -> 'orders', '[]'::jsonb));
$fn$;

-- The number of orders inside a guest_orders payload.
create or replace function pg_temp.order_count(payload jsonb)
returns integer
language sql
stable
as $fn$
  select coalesce(
    jsonb_array_length(coalesce(payload -> 'orders', '[]'::jsonb)),
    0
  );
$fn$;

-- The order ids inside a guest_orders payload, as a sorted text array, so two
-- payloads can be compared as sets.
create or replace function pg_temp.order_ids(payload jsonb)
returns text[]
language sql
stable
as $fn$
  select coalesce(
    array_agg(entry ->> 'id' order by entry ->> 'id'),
    '{}'::text[]
  )
    from pg_temp.orders(payload) as entry;
$fn$;

-- Fixtures: two restaurants, and two tables in the first of them, so isolation can
-- be tested across restaurants and across QR contexts within one restaurant.
insert into public.restaurants (id, name, slug)
values
  ('11111111-1111-1111-1111-111111111111', 'Ala-Too', 'ala-too'),
  ('22222222-2222-2222-2222-222222222222', 'Beshkempir', 'beshkempir');

insert into public.branches (id, restaurant_id, name)
values
  (
    '33333333-3333-3333-3333-333333333333',
    '11111111-1111-1111-1111-111111111111',
    'Center'
  ),
  (
    '44444444-4444-4444-4444-444444444444',
    '22222222-2222-2222-2222-222222222222',
    'Airport'
  );

insert into public.tables (
  id, restaurant_id, branch_id, table_number, name, capacity, qr_token
)
values
  -- Context A of restaurant one.
  (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333333',
    '12', 'Window', 4, 'a1a1a1a1-1111-4111-8111-111111111111'
  ),
  -- Context B of restaurant one: a different table, same restaurant and branch.
  (
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333333',
    '13', 'Terrace', 4, 'b1b1b1b1-1111-4111-8111-111111111111'
  ),
  -- A different restaurant entirely.
  (
    'cccccccc-cccc-cccc-cccc-cccccccccccc',
    '22222222-2222-2222-2222-222222222222',
    '44444444-4444-4444-4444-444444444444',
    '1', 'Hall', 4, 'c1c1c1c1-1111-4111-8111-111111111111'
  );

insert into public.categories (id, restaurant_id, name)
values
  (
    '55555555-5555-5555-5555-555555555555',
    '11111111-1111-1111-1111-111111111111',
    'Mains'
  ),
  (
    '66666666-6666-6666-6666-666666666666',
    '22222222-2222-2222-2222-222222222222',
    'Mains'
  );

insert into public.menu_items (
  id, restaurant_id, branch_id, category_id, name, price, is_available
)
values
  (
    '77777777-7777-7777-7777-777777777777',
    '11111111-1111-1111-1111-111111111111',
    null,
    '55555555-5555-5555-5555-555555555555',
    'Beshbarmak', 450.00, true
  ),
  (
    '88888888-8888-8888-8888-888888888888',
    '11111111-1111-1111-1111-111111111111',
    null,
    '55555555-5555-5555-5555-555555555555',
    'Kebab', 600.50, true
  ),
  (
    '99999999-9999-9999-9999-999999999999',
    '22222222-2222-2222-2222-222222222222',
    null,
    '66666666-6666-6666-6666-666666666666',
    'Foreign Dish', 100.00, true
  );

-- The order tables stay private: the read path is the only way in.
set local role anon;

do $$
begin
  perform pg_temp.assert_denied(
    'select * from public.orders',
    'anon cannot directly select orders'
  );
  perform pg_temp.assert_denied(
    'select id, status, total from public.orders where total > 0',
    'anon cannot select order columns directly either'
  );
  perform pg_temp.assert_denied(
    'insert into public.orders default values',
    'anon cannot insert orders'
  );
  perform pg_temp.assert_denied(
    'update public.orders set status = ''CANCELLED''',
    'anon cannot update orders'
  );
  perform pg_temp.assert_denied(
    'delete from public.orders',
    'anon cannot delete orders'
  );
end;
$$;

do $$
begin
  perform pg_temp.assert_denied(
    'select * from public.order_items',
    'anon cannot directly select order items'
  );
  perform pg_temp.assert_denied(
    'select product_name, unit_price from public.order_items',
    'anon cannot select the item snapshots directly either'
  );
  perform pg_temp.assert_denied(
    'insert into public.order_items default values',
    'anon cannot insert order items'
  );
  perform pg_temp.assert_denied(
    'update public.order_items set product_name = ''Free''',
    'anon cannot update order items'
  );
  perform pg_temp.assert_denied(
    'delete from public.order_items',
    'anon cannot delete order items'
  );
  perform pg_temp.assert_denied(
    'select * from public.order_access',
    'anon cannot read the order access tokens'
  );
  perform pg_temp.assert_denied(
    'select * from public.restaurant_order_counters',
    'anon cannot read the order counters'
  );
end;
$$;

-- The read path is exactly one function, and it is reachable: a client can read
-- its own orders without a session, and only through this function.
do $$
declare
  v_anon_orders boolean;
  v_anon_items boolean;
  v_anon_rpc boolean;
begin
  select has_table_privilege('anon', 'public.orders', 'select')
    into v_anon_orders;
  select has_table_privilege('anon', 'public.order_items', 'select')
    into v_anon_items;
  select has_function_privilege(
    'anon', 'public.guest_orders(text)', 'execute'
  )
    into v_anon_rpc;

  perform pg_temp.assert_true(v_anon_orders is false,
    'anon holds no select privilege on orders');
  perform pg_temp.assert_true(v_anon_items is false,
    'anon holds no select privilege on order items');
  perform pg_temp.assert_true(v_anon_rpc is true,
    'anon may execute guest_orders, the controlled read path');
end;
$$;

-- The function is written the way the isolation depends on: security definer, so
-- it can read rows no client may read, with an empty search_path so nothing
-- outside pg_catalog can be reached through it.
do $$
declare
  v_definer boolean;
  v_config text[];
begin
  select prosecdef, proconfig
    into v_definer, v_config
    from pg_proc
   where oid = 'public.guest_orders(text)'::regprocedure;

  perform pg_temp.assert_true(v_definer is true,
    'guest_orders runs as the definer so the token is the only check');
  perform pg_temp.assert_true(
    v_config is not null
      and array_to_string(v_config, ',') = 'search_path=""',
    'guest_orders runs with an empty search_path'
  );
end;
$$;

reset role;

-- Two guests at two tables of the same restaurant, and one at the other
-- restaurant. Every token is minted by the create function, so this is the exact
-- shape a real guest holds, and the tokens are handed to each check through
-- session settings so no block has to recompute them.
create or replace function pg_temp.seed_orders()
returns table (context_a text, context_b text, other_restaurant text)
language plpgsql
as $$
declare
  v_a text;
  v_b text;
  v_c text;
begin
  -- Context A: two orders from the same guest, so a history has more than one row.
  v_a := public.create_table_order(
    'a1a1a1a1-1111-4111-8111-111111111111',
    '[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 2}]'::jsonb
  ) ->> 'access_token';

  perform public.create_table_order(
    'a1a1a1a1-1111-4111-8111-111111111111',
    '[
      {"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 1},
      {"item_id": "88888888-8888-8888-8888-888888888888", "quantity": 2}
    ]'::jsonb,
    v_a
  );

  -- Context B: a second guest at the other table of the same restaurant.
  v_b := public.create_table_order(
    'b1b1b1b1-1111-4111-8111-111111111111',
    '[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 1}]'::jsonb
  ) ->> 'access_token';

  -- The other restaurant.
  v_c := public.create_table_order(
    'c1c1c1c1-1111-4111-8111-111111111111',
    '[{"item_id": "99999999-9999-9999-9999-999999999999", "quantity": 1}]'::jsonb
  ) ->> 'access_token';

  return query select v_a, v_b, v_c;
end;
$$;

-- The tokens are handed to each check through transaction-local settings, so no
-- block has to recompute them and no block can accidentally seed its own data.
do $$
declare
  v_a text;
  v_b text;
  v_c text;
begin
  select context_a, context_b, other_restaurant
    into v_a, v_b, v_c
    from pg_temp.seed_orders();

  perform set_config('menukg.token_a', v_a, true);
  perform set_config('menukg.token_b', v_b, true);
  perform set_config('menukg.token_c', v_c, true);
end;
$$;

-- The token of the guest of context A, for the checks below.
create or replace function pg_temp.token_a()
returns text
language sql
stable
as $fn$
  select current_setting('menukg.token_a');
$fn$;

-- The token of the guest at context B.
create or replace function pg_temp.token_b()
returns text
language sql
stable
as $fn$
  select current_setting('menukg.token_b');
$fn$;

-- The token of the guest of the other restaurant.
create or replace function pg_temp.token_c()
returns text
language sql
stable
as $fn$
  select current_setting('menukg.token_c');
$fn$;

do $$
declare
  v_a text := pg_temp.token_a();
  v_b text := pg_temp.token_b();
  v_c text := pg_temp.token_c();
  v_payload jsonb;
  v_line jsonb;
begin
  -- The guest reads back their own orders, and gets both.
  v_payload := public.guest_orders(v_a);
  perform pg_temp.assert_equals(
    pg_temp.order_count(v_payload)::text,
    '2',
    'the guest reads back both of their own orders'
  );

  -- Newest first. Every order in this script is placed in one transaction and so
  -- shares a created_at, which is exactly why the order number is the tie-break.
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 ->> 'order_number',
    '2',
    'a guest who ordered twice sees their newest order first'
  );
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 1 ->> 'order_number',
    '1',
    'the earlier order follows it'
  );

  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 ->> 'restaurant_name',
    'Ala-Too',
    'the read payload names the restaurant'
  );
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 ->> 'branch_name',
    'Center',
    'the read payload names the branch'
  );
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 -> 'table' ->> 'number',
    '12',
    'the read payload names the table'
  );
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 ->> 'status',
    'PENDING',
    'the read payload reports the stored status'
  );

  -- The header, the total and the item count are the stored snapshots, so what a
  -- guest reads back is exactly what they were charged.
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 ->> 'total',
    '1651.00',
    'the order total is the stored total, to the cent'
  );
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 ->> 'item_count',
    '3',
    'the item count is the stored count across the lines'
  );
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 ->> 'currency',
    'KGS',
    'the currency is the snapshotted one'
  );

  -- The items, with the name and price as they were when the guest ordered, in the
  -- order the guest placed them.
  v_line := v_payload -> 'orders' -> 0 -> 'items' -> 0;
  perform pg_temp.assert_equals(
    v_line ->> 'product_name',
    'Beshbarmak',
    'an item keeps the product name'
  );
  perform pg_temp.assert_equals(
    v_line ->> 'unit_price',
    '450.00',
    'an item keeps the snapshot unit price'
  );
  perform pg_temp.assert_equals(
    v_line ->> 'quantity',
    '1',
    'an item keeps its quantity'
  );
  perform pg_temp.assert_equals(
    v_line ->> 'line_total',
    '450.00',
    'an item keeps the stored line total'
  );
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 -> 'items' -> 1 ->> 'product_name',
    'Kebab',
    'the items come back in the order the guest placed them'
  );
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 -> 'items' -> 1 ->> 'unit_price',
    '600.50',
    'a fractional snapshot price keeps its cents'
  );
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 -> 'items' -> 1 ->> 'line_total',
    '1201.00',
    'the second line total is its own price times its own quantity'
  );

  -- The payload must stay as narrow as the create payload: no credential, and no
  -- internal identifier anywhere in it.
  perform pg_temp.assert_true(
    not (v_payload ? 'access_token')
      and not (v_payload -> 'orders' -> 0 ? 'access_token')
      and not (v_payload -> 'orders' -> 0 ? 'restaurant_id')
      and not (v_payload -> 'orders' -> 0 ? 'branch_id')
      and not (v_payload -> 'orders' -> 0 ? 'table_id')
      and not (v_line ? 'order_id')
      and not (v_line ? 'restaurant_id')
      and not (v_line ? 'access_token'),
    'the read payload exposes no access token and no restaurant, branch, table or line order id'
  );
end;
$$;

-- A token from one QR context cannot reach another QR context's orders, even in
-- the same restaurant on the same branch.
do $$
declare
  v_a text := pg_temp.token_a();
  v_b text := pg_temp.token_b();
  v_a_payload jsonb;
  v_b_ids text[];
  v_a_ids text[];
begin
  v_a_payload := public.guest_orders(v_a);

  select coalesce(array_agg(id order by id), '{}'::uuid[]) into v_b_ids
    from public.orders where access_token = v_b;
  select coalesce(array_agg(guest_order.id order by guest_order.id), '{}'::uuid[])
    into v_a_ids
    from public.orders as guest_order
    join public.tables as ordered_table
      on ordered_table.id = guest_order.table_id
   where guest_order.access_token = v_a
     and ordered_table.qr_token = 'b1b1b1b1-1111-4111-8111-111111111111'::uuid;

  perform pg_temp.assert_equals(
    v_a_ids::text,
    '{}',
    'context A owns no order of context B to begin with'
  );
  perform pg_temp.assert_true(
    not (v_b_ids::text[] && pg_temp.order_ids(v_a_payload)),
    'a context A token returns none of context B''s orders'
  );
  perform pg_temp.assert_equals(
    pg_temp.order_count(public.guest_orders(v_b))::text,
    '1',
    'context B sees only its own single order'
  );
  perform pg_temp.assert_true(
    not exists (
      select 1
        from pg_temp.orders(public.guest_orders(v_b)) as listed
        join public.orders as guest_order
          on guest_order.id = (listed ->> 'id')::uuid
       where guest_order.table_id <> 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid
    ),
    'the other context''s token returns only orders of its own table'
  );
  perform pg_temp.assert_equals(
    public.guest_orders(v_b) -> 'orders' -> 0 -> 'table' ->> 'number',
    '13',
    'each context reads back its own table'
  );
end;
$$;

-- A token from another restaurant cannot reach the first restaurant's orders.
do $$
declare
  v_a text := pg_temp.token_a();
  v_c text := pg_temp.token_c();
begin
  perform pg_temp.assert_equals(
    pg_temp.order_count(public.guest_orders(v_c))::text,
    '1',
    'the other restaurant''s guest sees only their own order'
  );
  perform pg_temp.assert_equals(
    public.guest_orders(v_c) -> 'orders' -> 0 ->> 'restaurant_name',
    'Beshkempir',
    'the other restaurant names itself'
  );
  perform pg_temp.assert_true(
    not exists (
      select 1
        from pg_temp.orders(public.guest_orders(v_c)) as listed
        join public.orders as guest_order
          on guest_order.id = (listed ->> 'id')::uuid
       where guest_order.restaurant_id = '11111111-1111-1111-1111-111111111111'::uuid
    ),
    'the other restaurant''s guest never sees an order of the first'
  );
  perform pg_temp.assert_true(
    not exists (
      select 1
        from pg_temp.orders(public.guest_orders(v_a)) as listed
        join public.orders as guest_order
          on guest_order.id = (listed ->> 'id')::uuid
       where guest_order.restaurant_id = '22222222-2222-2222-2222-222222222222'::uuid
    ),
    'the first restaurant''s guest never sees an order of the other'
  );
end;
$$;

-- Nothing that is not this guest's token opens anything: no error, no rows.
do $$
begin
  perform pg_temp.assert_equals(
    pg_temp.order_count(public.guest_orders('not-a-real-token'))::text,
    '0',
    'an unknown token returns no orders'
  );
  perform pg_temp.assert_equals(
    pg_temp.order_count(public.guest_orders(''))::text,
    '0',
    'an empty token returns no orders'
  );
  perform pg_temp.assert_equals(
    pg_temp.order_count(public.guest_orders('   '))::text,
    '0',
    'a blank token returns no orders'
  );
  perform pg_temp.assert_equals(
    pg_temp.order_count(public.guest_orders(null))::text,
    '0',
    'a missing token returns no orders'
  );
  perform pg_temp.assert_equals(
    pg_temp.order_count(
      public.guest_orders(
        'a1b2c3d4-1111-4111-8111-111111111111e5f60718-2222-4333-8444-555555555555'
      )
    )::text,
    '0',
    'a well formed but never issued token returns no orders'
  );
  perform pg_temp.assert_equals(
    pg_temp.order_count(
      public.guest_orders(gen_random_uuid()::text || gen_random_uuid()::text)
    )::text,
    '0',
    'a token for a guest with no orders returns no orders'
  );
end;
$$;

-- Order items are reachable only through their own guest's token. A reservation
-- token is a different capability in a different table, and neither credential
-- opens the other.
do $$
declare
  v_a text := pg_temp.token_a();
  v_reservation_token text;
begin
  v_reservation_token := public.create_table_reservation(
    'a1a1a1a1-1111-4111-8111-111111111111',
    current_date + 1,
    '19:00',
    'Askar',
    2
  ) ->> 'access_token';

  perform pg_temp.assert_equals(
    pg_temp.order_count(public.guest_orders(v_reservation_token))::text,
    '0',
    'a reservation token reads no orders'
  );
  perform pg_temp.assert_equals(
    pg_temp.order_count(public.guest_reservations(v_a))::text,
    '0',
    'an order token reads no reservations'
  );

  -- A signed-in user is not a guest and holds no order capability of their own.
  perform pg_temp.assert_equals(
    pg_temp.order_count(public.guest_orders(null))::text,
    '0',
    'a signed-out call with no token still reads nothing'
  );
end;
$$;

-- A guest's history is exactly the orders that token owns, and every item in it
-- belongs to an order of the same restaurant.
do $$
declare
  v_a text := pg_temp.token_a();
  v_payload jsonb;
begin
  v_payload := public.guest_orders(v_a);

  perform pg_temp.assert_true(
    (select count(*) from pg_temp.orders(v_payload) as listed)
    = (
      select count(*) from public.orders where access_token = v_a
    ),
    'the rpc returns every order the token owns and no more'
  );

  perform pg_temp.assert_true(
    not exists (
      select 1
        from pg_temp.orders(v_payload) as listed
        join public.order_items as stored
          on stored.order_id = (listed ->> 'id')::uuid
       where stored.restaurant_id <> (
         select restaurant_id from public.orders
          where id = (listed ->> 'id')::uuid
       )
         or jsonb_array_length(listed -> 'items')
            <> (
              select count(*) from public.order_items as line
               where line.order_id = (listed ->> 'id')::uuid
            )
    ),
    'every item returned belongs to the order it is returned with'
  );
end;
$$;

-- The function is a read: it changes nothing.
do $$
declare
  v_a text := pg_temp.token_a();
  v_before integer;
  v_after integer;
begin
  select count(*) into v_before from public.orders;

  perform public.guest_orders(v_a);

  select count(*) into v_after from public.orders;
  perform pg_temp.assert_equals(
    v_before::text,
    v_after::text,
    'reading an order history stores nothing'
  );
end;
$$;

-- History does not follow the live menu, the table or the restaurant.
do $$
declare
  v_a text := pg_temp.token_a();
  v_payload jsonb;
begin
  update public.menu_items
     set name = 'Beshbarmak XXL', price = 999.00
   where id = '77777777-7777-7777-7777-777777777777';

  update public.tables set is_active = false
   where qr_token = 'a1a1a1a1-1111-4111-8111-111111111111'::uuid;

  update public.restaurants set is_active = false
   where id = '11111111-1111-1111-1111-111111111111'::uuid;

  v_payload := public.guest_orders(v_a);

  perform pg_temp.assert_equals(
    pg_temp.order_count(v_payload)::text,
    '2',
    'a closed table and a closed restaurant still leave the history readable'
  );
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 -> 'items' -> 0 ->> 'product_name',
    'Beshbarmak',
    'a renamed product does not rewrite a read order'
  );
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 -> 'items' -> 0 ->> 'unit_price',
    '450.00',
    'a repriced product does not rewrite a read order'
  );

  delete from public.menu_items where id = '77777777-7777-7777-7777-777777777777';

  v_payload := public.guest_orders(v_a);
  perform pg_temp.assert_equals(
    pg_temp.order_count(v_payload)::text,
    '2',
    'a deleted product does not remove the orders it was sold in'
  );
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 -> 'items' -> 0 ->> 'line_total',
    '450.00',
    'a deleted product leaves its snapshot and line total readable'
  );
  -- jsonb_build_object turns a null column into a JSON null, not the string
  -- 'null', and ->> on a JSON null is itself a SQL null. Reading the raw jsonb is
  -- what distinguishes "the product is gone" from "the payload left it out".
  perform pg_temp.assert_equals(
    pg_catalog.jsonb_typeof(
      v_payload -> 'orders' -> 0 -> 'items' -> 0 -> 'menu_item_id'
    ),
    'null',
    'the reference to a deleted product is reported as null, not guessed'
  );
end;
$$;

-- A signed-in staff member is not a guest: the token model is the only path into
-- order history, and staff-side order handling is a later step this deliberately
-- does not guess at.
set local role authenticated;

do $$
begin
  perform pg_temp.assert_denied(
    'select * from public.orders',
    'a signed-in user cannot directly select orders'
  );
  perform pg_temp.assert_denied(
    'select * from public.order_items',
    'a signed-in user cannot directly select order items'
  );
  perform pg_temp.assert_denied(
    'update public.orders set status = ''CANCELLED''',
    'a signed-in user cannot update orders'
  );
  perform pg_temp.assert_denied(
    'delete from public.orders',
    'a signed-in user cannot delete orders'
  );
  perform pg_temp.assert_denied(
    'select * from public.order_access',
    'a signed-in user cannot read the order access tokens'
  );
  perform pg_temp.assert_denied(
    'select * from public.restaurant_order_counters',
    'a signed-in user cannot read the order counters'
  );
end;
$$;

do $$
declare
  v_a text := pg_temp.token_a();
begin
  perform pg_temp.assert_equals(
    pg_temp.order_count(public.guest_orders('not-a-real-token'))::text,
    '0',
    'a signed-in user gets the same empty list for an unknown guest token'
  );
  -- The token is the only credential, so a signed-in user reading with a guest
  -- token they hold gets that guest's orders and nothing more. This is the token
  -- model working, not a staff capability: there is no session-bound order access.
  perform pg_temp.assert_equals(
    pg_temp.order_count(public.guest_orders(v_a))::text,
    '2',
    'a signed-in user reading with a guest token reads only that guest''s orders'
  );
  perform pg_temp.assert_equals(
    pg_temp.order_count(public.guest_orders(null))::text,
    '0',
    'a signed-in user with no guest token reads nothing'
  );
end;
$$;

reset role;

rollback;
