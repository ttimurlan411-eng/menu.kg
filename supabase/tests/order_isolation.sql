-- Order isolation and access-control checks.
--
-- Runs the customer order function against a real database and proves the
-- properties that matter for this feature, as the `anon` and `authenticated`
-- roles rather than as the owner:
--
--   * neither role can read or write the order tables directly
--   * a QR token resolves the restaurant, branch and table, and nothing else
--   * an item of another restaurant, another branch, or a switched-off dish is
--     refused, indistinguishably
--   * prices and names come from the live menu, never from the request
--   * an order total is the sum of the line totals of its own stored snapshots
--   * a menu item that is renamed or repriced afterwards does not rewrite history
--   * deleting a product does not delete the orders it was sold in
--   * order numbers are per restaurant
--
-- Usage, against a database where supabase/migrations has been applied:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/order_isolation.sql
--
-- On Supabase the auth schema and the anon/authenticated roles already exist and
-- the guard below does nothing. Against a plain Postgres it creates a minimal
-- stand-in for `auth.users` and the two roles, so the whole project can be
-- verified locally. Everything runs in one transaction that is rolled back at
-- the end, so the script leaves no rows behind.

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

-- Asserts that [statement] returns exactly [expected].
--
-- The comparison is made in jsonb, because the create function returns jsonb and
-- a SQL null and a json null are different answers that must not be confused.
create or replace function pg_temp.assert_result(
  statement text,
  expected jsonb,
  message text
)
returns void
language plpgsql
as $$
declare
  v_actual jsonb;
begin
  begin
    execute statement into v_actual;
  exception
    when others then
      raise exception 'FAILED: % (got error %, expected %)',
        message, sqlstate, expected using errcode = 'P0001';
  end;

  if v_actual is distinct from expected then
    raise exception 'FAILED: % (got %, expected %)',
      message, v_actual, expected using errcode = 'P0001';
  end if;

  raise notice 'ok: %', message;
end;
$$;

-- The items inside a create_table_order payload.
create or replace function pg_temp.order_items(payload jsonb)
returns setof jsonb
language sql
stable
as $fn$
  select jsonb_array_elements(coalesce(payload -> 'order' -> 'items', '[]'::jsonb));
$fn$;

-- Fixtures: two restaurants, so isolation can be tested across them.
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
    'abababab-abab-abab-abab-abababababab',
    '11111111-1111-1111-1111-111111111111',
    'Riverside'
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
  (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333333',
    '12', 'Window', 4, 'a1a1a1a1-1111-4111-8111-111111111111'
  ),
  (
    'dddddddd-dddd-dddd-dddd-dddddddddddd',
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333333',
    '99', null, 4, 'd1d1d1d1-1111-4111-8111-111111111111'
  ),
  (
    'cccccccc-cccc-cccc-cccc-cccccccccccc',
    '22222222-2222-2222-2222-222222222222',
    '44444444-4444-4444-4444-444444444444',
    '1', null, 4, 'c1c1c1c1-1111-4111-8111-111111111111'
  );

-- The third table is switched off, like a table taken out of service.
update public.tables
   set is_active = false
 where id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';

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
  -- Two dishes offered to the Center branch of restaurant A.
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
  -- A dish that is switched off.
  (
    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
    '11111111-1111-1111-1111-111111111111',
    null,
    '55555555-5555-5555-5555-555555555555',
    'Hidden Dish', 300.00, false
  ),
  -- A dish that belongs to another branch of the same restaurant.
  (
    'f1f1f1f1-f1f1-f1f1-f1f1-f1f1f1f1f1f1',
    '11111111-1111-1111-1111-111111111111',
    'abababab-abab-abab-abab-abababababab',
    '55555555-5555-5555-5555-555555555555',
    'Riverside Only', 400.00, true
  ),
  -- A dish of the other restaurant.
  (
    '99999999-9999-9999-9999-999999999999',
    '22222222-2222-2222-2222-222222222222',
    null,
    '66666666-6666-6666-6666-666666666666',
    'Foreign Dish', 100.00, true
  );

-- The composite keys are what make a cross-restaurant order impossible to store,
-- not merely unlikely. Checked directly, as the table owner, because no client
-- ever gets this far: the create function resolves the restaurant from the token.
do $$
begin
  perform pg_temp.assert_fails_with(
    $stmt$
      insert into public.orders (
        order_number, access_token, restaurant_id, branch_id, table_id,
        status, currency, total, item_count
      )
      select 1, 'probe', '11111111-1111-1111-1111-111111111111',
        '44444444-4444-4444-4444-444444444444',
        'cccccccc-cccc-cccc-cccc-cccccccccccc',
        'PENDING', 'KGS', 100.00, 1
    $stmt$,
    '23503',
    'a branch from another restaurant cannot be attached to an order'
  );

  perform pg_temp.assert_fails_with(
    $stmt$
      insert into public.orders (
        order_number, access_token, restaurant_id, branch_id, table_id,
        status, currency, total, item_count
      )
      select 1, 'probe', '11111111-1111-1111-1111-111111111111',
        '33333333-3333-3333-3333-333333333333',
        'cccccccc-cccc-cccc-cccc-cccccccccccc',
        'PENDING', 'KGS', 100.00, 1
    $stmt$,
    '23503',
    'a table from another restaurant cannot be attached to an order'
  );
end;
$$;

-- An order line cannot belong to an order of another restaurant either, and it
-- cannot carry a menu item of another restaurant.
do $$
declare
  v_token text;
  v_other_order uuid;
begin
  v_token :=
    pg_catalog.gen_random_uuid()::text
    || pg_catalog.gen_random_uuid()::text;
  insert into public.order_access (access_token) values (v_token);

  v_other_order := public.create_table_order(
    'c1c1c1c1-1111-4111-8111-111111111111',
    '[{"item_id": "99999999-9999-9999-9999-999999999999", "quantity": 1}]'::jsonb,
    v_token
  ) -> 'order' ->> 'id';

  perform pg_temp.assert_fails_with(
    'insert into public.order_items (
       order_id, restaurant_id, menu_item_id, product_name,
       unit_price, quantity, sort_order, line_total
     ) values (
       ''' || v_other_order || '''::uuid,
       ''11111111-1111-1111-1111-111111111111'',
       ''77777777-7777-7777-7777-777777777777'',
       ''Beshbarmak'', 450.00, 1, 9, 450.00
     )',
    '23503',
    'an order line cannot cross into another restaurant''s order'
  );
end;
$$;

-- An anonymous guest with no session at all.
set local role anon;

do $$
begin
  perform pg_temp.assert_denied(
    'select * from public.orders',
    'anon cannot select orders'
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
  perform pg_temp.assert_denied(
    'select * from public.order_items',
    'anon cannot select order lines'
  );
  perform pg_temp.assert_denied(
    'insert into public.order_items default values',
    'anon cannot insert order lines'
  );
  perform pg_temp.assert_denied(
    'select * from public.order_access',
    'anon cannot read order access tokens'
  );
  perform pg_temp.assert_denied(
    'select * from public.restaurant_order_counters',
    'anon cannot read order counters'
  );
  perform pg_temp.assert_denied(
    'select * from public.tables',
    'anon cannot read tables'
  );
  perform pg_temp.assert_denied(
    'select * from public.menu_items',
    'anon cannot read menu items'
  );
end;
$$;

reset role;

-- Placing an order as an anonymous guest.
do $$
declare
  v_result jsonb;
  v_token text;
  v_order jsonb;
  v_first jsonb;
  v_second jsonb;
begin
  v_result := public.create_table_order(
    'a1a1a1a1-1111-4111-8111-111111111111',
    '[
      {"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 2},
      {"item_id": "88888888-8888-8888-8888-888888888888", "quantity": 1}
    ]'::jsonb
  );

  perform pg_temp.assert_true(v_result is not null, 'a valid qr token places an order');

  v_token := v_result ->> 'access_token';
  v_order := v_result -> 'order';

  perform pg_temp.assert_true(
    v_token is not null and length(v_token) = 72,
    'the response carries a 72 character access token (244 bits)'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'status',
    'PENDING',
    'a new order starts pending'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'currency',
    'KGS',
    'the order snapshots the restaurant currency'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'order_number',
    '1',
    'the first order of a restaurant is number 1'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'restaurant_name',
    'Ala-Too',
    'the order names the restaurant'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'branch_name',
    'Center',
    'the order names the branch'
  );
  perform pg_temp.assert_equals(
    v_order -> 'table' ->> 'number',
    '12',
    'the order names the table'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'item_count',
    '3',
    'the order counts every item across its lines'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'total',
    '1500.50',
    'the total is the sum of the line totals of the stored snapshots'
  );

  v_first := (
    select value from pg_temp.order_items(v_result) as line(value) limit 1
  );
  v_second := (
    select value from pg_temp.order_items(v_result) as line(value) offset 1
  );

  perform pg_temp.assert_equals(
    v_first ->> 'product_name',
    'Beshbarmak',
    'the line keeps the product name'
  );
  perform pg_temp.assert_equals(
    v_first ->> 'unit_price',
    '450.00',
    'the line keeps the unit price'
  );
  perform pg_temp.assert_equals(
    v_first ->> 'line_total',
    '900.00',
    'the line total is the snapshot price times the quantity'
  );
  perform pg_temp.assert_equals(
    v_second ->> 'line_total',
    '600.50',
    'a fractional price keeps its cents in the line total'
  );

  -- The payload must stay as narrow as the public menu payload.
  perform pg_temp.assert_true(
    not (v_order ? 'restaurant_id')
      and not (v_order ? 'branch_id')
      and not (v_order ? 'table_id')
      and not (v_order ? 'access_token')
      and not (v_first ? 'restaurant_id')
      and not (v_first ? 'order_id'),
    'the response exposes no restaurant, branch, table or order id on a line'
  );
end;
$$;

-- The stored rows agree with each other, checked in the tables themselves.
do $$
declare
  v_bad integer;
begin
  select count(*)
    into v_bad
    from public.order_items
   where line_total <> unit_price * quantity;

  perform pg_temp.assert_equals(
    v_bad::text,
    '0',
    'every stored line total equals its own price times its own quantity'
  );

  select count(*)
    into v_bad
    from public.orders as o
   where o.total <> (
     select coalesce(sum(i.line_total), 0)
       from public.order_items as i
      where i.order_id = o.id
   );

  perform pg_temp.assert_equals(
    v_bad::text,
    '0',
    'every stored order total equals the sum of its own lines'
  );

  select count(*)
    into v_bad
    from public.order_items as i
    join public.orders as o on o.id = i.order_id
   where i.restaurant_id <> o.restaurant_id
      or i.menu_item_id is not null
        and not exists (
          select 1
            from public.menu_items as m
           where m.id = i.menu_item_id
             and m.restaurant_id = i.restaurant_id
        );

  perform pg_temp.assert_equals(
    v_bad::text,
    '0',
    'every stored line belongs to the same restaurant as its order and its product'
  );
end;
$$;

-- Amounts and names are read from the live menu, never taken from the request.
set local role anon;

do $$
declare
  v_result jsonb;
begin
  v_result := public.create_table_order(
    'a1a1a1a1-1111-4111-8111-111111111111',
    '[
      {
        "item_id": "77777777-7777-7777-7777-777777777777",
        "quantity": 1,
        "unit_price": 0.01,
        "line_total": 0.01,
        "product_name": "Free Beshbarmak"
      }
    ]'::jsonb
  );

  perform pg_temp.assert_equals(
    v_result -> 'order' -> 'items' -> 0 ->> 'unit_price',
    '450.00',
    'a price sent by the client is ignored in favour of the menu price'
  );
  perform pg_temp.assert_equals(
    v_result -> 'order' -> 'items' -> 0 ->> 'product_name',
    'Beshbarmak',
    'a name sent by the client is ignored in favour of the menu name'
  );
  perform pg_temp.assert_equals(
    v_result -> 'order' ->> 'total',
    '450.00',
    'the total follows the menu price, not the price the client asked for'
  );
end;
$$;

reset role;

-- A second order gets the next number, and the same guest token is reused.
do $$
declare
  v_first jsonb;
  v_second jsonb;
begin
  v_first := public.create_table_order(
    'a1a1a1a1-1111-4111-8111-111111111111',
    '[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 1}]'::jsonb
  );

  perform pg_temp.assert_equals(
    v_first -> 'order' ->> 'order_number',
    '3',
    'order numbers advance within a restaurant'
  );

  v_second := public.create_table_order(
    'a1a1a1a1-1111-4111-8111-111111111111',
    '[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 1}]'::jsonb,
    v_first ->> 'access_token'
  );

  perform pg_temp.assert_equals(
    v_second ->> 'access_token',
    v_first ->> 'access_token',
    'a returning guest keeps the same access token'
  );
  perform pg_temp.assert_equals(
    v_second -> 'order' ->> 'order_number',
    '4',
    'the reused token still gets the next number'
  );
end;
$$;

-- Order numbers are per restaurant, so no guest can read the platform's volume.
do $$
declare
  v_other jsonb;
begin
  v_other := public.create_table_order(
    'c1c1c1c1-1111-4111-8111-111111111111',
    '[{"item_id": "99999999-9999-9999-9999-999999999999", "quantity": 1}]'::jsonb
  );

  perform pg_temp.assert_equals(
    v_other -> 'order' ->> 'order_number',
    '2',
    'the other restaurant counts its own orders, not the first restaurant''s'
  );
  perform pg_temp.assert_equals(
    v_other -> 'order' ->> 'restaurant_name',
    'Beshkempir',
    'the other restaurant names itself'
  );
end;
$$;

-- Everything the create function will not order.
set local role anon;

do $$
declare
  v_qr constant text := 'a1a1a1a1-1111-4111-8111-111111111111';
  v_one_dish constant text := '[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 1}]';
  -- A dish of the other restaurant, which this table's restaurant does not serve.
  v_foreign_dish constant text := '[{"item_id": "99999999-9999-9999-9999-999999999999", "quantity": 1}]';
begin
  perform pg_temp.assert_fails_with(
    format(
      'select public.create_table_order(%L, ''[]''::jsonb)', v_qr
    ),
    'P0001',
    'an empty cart cannot create an order'
  );

  perform pg_temp.assert_fails_with(
    format('select public.create_table_order(%L, null)', v_qr),
    'P0001',
    'a missing item list cannot create an order'
  );

  perform pg_temp.assert_fails_with(
    format('select public.create_table_order(%L, %L::jsonb)', v_qr, v_foreign_dish),
    'P0001',
    'a dish of another restaurant cannot be ordered'
  );

  perform pg_temp.assert_fails_with(
    format(
      'select public.create_table_order(%L, ''[{"item_id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", "quantity": 1}]''::jsonb)',
      v_qr
    ),
    'P0001',
    'a dish that is switched off cannot be ordered'
  );

  perform pg_temp.assert_fails_with(
    format(
      'select public.create_table_order(%L, ''[{"item_id": "f1f1f1f1-f1f1-f1f1-f1f1-f1f1f1f1f1f1", "quantity": 1}]''::jsonb)',
      v_qr
    ),
    'P0001',
    'a dish of another branch cannot be ordered from this table'
  );

  perform pg_temp.assert_fails_with(
    format(
      'select public.create_table_order(%L, ''[{"item_id": "00000000-0000-4000-8000-000000000000", "quantity": 1}]''::jsonb)',
      v_qr
    ),
    'P0001',
    'an item that does not exist cannot be ordered'
  );

  perform pg_temp.assert_fails_with(
    format(
      'select public.create_table_order(%L, ''[{"item_id": "not-a-uuid", "quantity": 1}]''::jsonb)',
      v_qr
    ),
    'P0001',
    'a malformed item id is refused without a cast error'
  );

  perform pg_temp.assert_fails_with(
    format(
      'select public.create_table_order(%L, ''[{"quantity": 1}]''::jsonb)', v_qr
    ),
    'P0001',
    'a line without an item id is refused'
  );

  perform pg_temp.assert_fails_with(
    format(
      'select public.create_table_order(%L, ''[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 0}]''::jsonb)',
      v_qr
    ),
    'P0001',
    'a quantity of zero is refused'
  );

  perform pg_temp.assert_fails_with(
    format(
      'select public.create_table_order(%L, ''[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": -3}]''::jsonb)',
      v_qr
    ),
    'P0001',
    'a negative quantity is refused'
  );

  perform pg_temp.assert_fails_with(
    format(
      'select public.create_table_order(%L, ''[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 1000}]''::jsonb)',
      v_qr
    ),
    'P0001',
    'an absurd quantity is refused'
  );

  perform pg_temp.assert_fails_with(
    format(
      'select public.create_table_order(%L, ''[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": "many"}]''::jsonb)',
      v_qr
    ),
    'P0001',
    'a non numeric quantity is refused without a cast error'
  );

  perform pg_temp.assert_fails_with(
    format(
      'select public.create_table_order(%L, ''[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 1}, {"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 1}]''::jsonb)',
      v_qr
    ),
    'P0001',
    'the same dish on two lines is refused'
  );

  perform pg_temp.assert_fails_with(
    format('select public.create_table_order(%L, ''{"item_id": "x"}''::jsonb)', v_qr),
    'P0001',
    'an item list that is not an array is refused'
  );

  perform pg_temp.assert_fails_with(
    format('select public.create_table_order(%L, ''[1, 2, 3]''::jsonb)', v_qr),
    'P0001',
    'an item list of non objects is refused'
  );
end;
$$;

-- A QR code that does not resolve is "no order", never an error.
do $$
begin
  perform pg_temp.assert_result(
    'select public.create_table_order(''not-a-uuid'', ''[]''::jsonb)',
    null::jsonb,
    'a malformed qr token resolves to nothing'
  );
  perform pg_temp.assert_result(
    'select public.create_table_order(''00000000-0000-4000-8000-000000000000'', ''[]''::jsonb)',
    null::jsonb,
    'an unknown qr token resolves to nothing'
  );
  perform pg_temp.assert_result(
    'select public.create_table_order(''d1d1d1d1-1111-4111-8111-111111111111'', ''[]''::jsonb)',
    null::jsonb,
    'an inactive table''s qr token resolves to nothing'
  );
end;
$$;

reset role;

-- A rejected request stores nothing.
do $$
declare
  v_orders integer;
  v_items integer;
begin
  select count(*) into v_orders from public.orders;
  select count(*) into v_items from public.order_items;

  perform pg_temp.assert_true(
    v_orders = 6,
    'only the accepted orders were stored'
  );
  perform pg_temp.assert_true(
    v_items = 7,
    'only the accepted lines were stored'
  );
end;
$$;

-- Historical orders do not follow the live menu.
do $$
declare
  v_order_id uuid;
  v_name text;
  v_price numeric;
begin
  -- An order that actually has a line for the dish about to be renamed, found by
  -- that fact and not by ordering: every order in this script is placed inside one
  -- transaction, so now() gives them all the same created_at and ordering by it
  -- would pick an arbitrary order by id, which may not have this line at all.
  select i.order_id
    into v_order_id
    from public.order_items as i
   where i.menu_item_id = '77777777-7777-7777-7777-777777777777'
   order by i.order_id
   limit 1;

  update public.menu_items
     set name = 'Beshbarmak XXL', price = 999.00
   where id = '77777777-7777-7777-7777-777777777777';

  select product_name, unit_price
    into v_name, v_price
    from public.order_items
   where order_id = v_order_id
     and menu_item_id = '77777777-7777-7777-7777-777777777777';

  perform pg_temp.assert_equals(
    v_name,
    'Beshbarmak',
    'a renamed product does not rewrite the order line'
  );
  perform pg_temp.assert_equals(
    v_price::text,
    '450.00',
    'a repriced product does not rewrite the order line'
  );
end;
$$;

-- Deleting a product keeps the order, and clears only the reference.
do $$
declare
  v_lines integer;
  v_total numeric;
begin
  delete from public.menu_items
   where id = '77777777-7777-7777-7777-777777777777';

  select count(*), max(line_total)
    into v_lines, v_total
    from public.order_items
   where product_name = 'Beshbarmak';

  perform pg_temp.assert_true(
    v_lines > 0,
    'deleting a product does not delete the lines it was sold in'
  );
  perform pg_temp.assert_equals(
    coalesce(v_total, 0)::text,
    '900.00',
    'a deleted product leaves its snapshot and line total intact'
  );

  perform pg_temp.assert_true(
    not exists (
      select 1
        from public.order_items as i
        join public.menu_items as m on m.id = i.menu_item_id
       where i.product_name = 'Beshbarmak'
    ),
    'the reference is cleared on every line that pointed at the deleted product'
  );

  perform pg_temp.assert_true(
    exists (
      select 1
        from public.order_items as i
        join public.menu_items as m
          on m.id = i.menu_item_id
         and m.restaurant_id = i.restaurant_id
       where i.product_name = 'Kebab'
    ),
    'a line pointing at a product that still exists keeps its reference'
  );
end;
$$;

-- A signed-in restaurant user has no order access either: staff-side order
-- handling is a later step, and this migration deliberately writes no policy for
-- it rather than guessing at one.
set local role authenticated;

do $$
begin
  perform pg_temp.assert_denied(
    'select * from public.orders',
    'a signed-in user cannot select orders'
  );
  perform pg_temp.assert_denied(
    'insert into public.orders default values',
    'a signed-in user cannot insert orders'
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
    'select * from public.order_items',
    'a signed-in user cannot select order lines'
  );
  perform pg_temp.assert_denied(
    'select * from public.order_access',
    'a signed-in user cannot read order access tokens'
  );
  perform pg_temp.assert_denied(
    'select * from public.restaurant_order_counters',
    'a signed-in user cannot read order counters'
  );
end;
$$;

reset role;

-- Nothing a guest sent was stored, and the number of stored rows is exactly the
-- number of accepted lines.
do $$
declare
  v_bad integer;
begin
  select count(*)
    into v_bad
    from public.order_items
   where char_length(btrim(product_name)) = 0
      or quantity < 1
      or unit_price < 0
      or line_total < 0;

  perform pg_temp.assert_equals(
    v_bad::text,
    '0',
    'no stored line breaks the column rules'
  );

  perform pg_temp.assert_true(
    not exists (select 1 from public.orders where status <> 'PENDING'),
    'every stored order is pending'
  );
end;
$$;

rollback;
