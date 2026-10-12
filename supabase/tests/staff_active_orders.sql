-- Staff active-order checks: the read that returns only the orders a restaurant
-- still has to act on.
--
-- Runs against a database where supabase/migrations has been applied, as the table
-- owner (which is also the definer of the staff functions) and as the `anon` and
-- `authenticated` roles with a chosen identity, which is what a real call looks
-- like:
--
--   * the function exists with the arguments the client sends, is SECURITY DEFINER
--     with an empty search path, returns jsonb, and only `authenticated` may execute
--     it
--   * it returns exactly the four non-terminal states and never SERVED or CANCELLED
--   * the whole point of the read: an older active order is still returned when
--     newer terminal orders exist, while `staff_list_orders` with the same small
--     limit has already lost it
--   * it lists newest first with the order number as the tie-break
--   * the branch filter divides one restaurant's active orders without reaching
--     another's branch
--   * the access matrix is the history read's: no session is refused with 28000, a
--     non-member, a deactivated member and a cashier with 42501
--     (`staff_order_access_denied`), and a restaurant that does not exist is refused
--     the same way as one that is simply not the caller's
--   * the payload is exactly the shape `staff_list_orders` returns, with the ordered
--     table and item snapshots, and nothing that belongs to the guest
--   * p_limit is clamped to 1..1000, not obeyed
--
-- Usage, against a database where supabase/migrations has been applied:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/staff_active_orders.sql
--
-- As the other scripts do, the guard below stands in for the parts of Supabase a
-- plain Postgres does not have, and everything runs in one transaction that is
-- rolled back at the end, so the script leaves no rows behind.

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

-- Asserts that [statement] fails with [expected_code] and [expected_message].
create or replace function pg_temp.assert_fails_with(
  statement text,
  expected_code text,
  expected_message text,
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
      if sqlstate = expected_code and sqlerrm = expected_message then
        raise notice 'ok: % (% %)', message, sqlstate, expected_message;
        return;
      end if;
      raise exception 'FAILED: % (got % %, expected % %)',
        message, sqlstate, sqlerrm, expected_code, expected_message
        using errcode = 'P0001';
  end;

  raise exception 'FAILED: % (the statement was allowed)', message
    using errcode = 'P0001';
end;
$$;

-- Signs the session in as [p_user], the way a Supabase request does.
create or replace function pg_temp.sign_in(p_user uuid)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claim.sub',
    coalesce(p_user::text, ''),
    true
  );
end;
$$;

-- A freshly placed order through the guest's own function, so every fixture order is
-- a real order rather than a hand-built row.
create or replace function pg_temp.placed_order(
  p_qr_token text,
  p_item text
)
returns uuid
language plpgsql
volatile
as $$
declare
  v_id text;
begin
  v_id := public.create_table_order(
    p_qr_token,
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('item_id', p_item, 'quantity', 1)
    ),
    null
  ) -> 'order' ->> 'id';

  return v_id::uuid;
end;
$$;

-- Walks an already placed order to [p_to] along the lifecycle, one legal step at a
-- time, so the guard trigger that refuses a skipped state is satisfied.
create or replace function pg_temp.walk_to(p_order uuid, p_to text)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_step text;
begin
  foreach v_step in array case p_to
    when 'ACCEPTED' then array['ACCEPTED']
    when 'PREPARING' then array['ACCEPTED', 'PREPARING']
    when 'READY' then array['ACCEPTED', 'PREPARING', 'READY']
    when 'SERVED' then array['ACCEPTED', 'PREPARING', 'READY', 'SERVED']
    when 'CANCELLED' then array['CANCELLED']
  end
  loop
    update public.orders set status = v_step where id = p_order;

    if not found then
      raise exception 'FAILED: walking to % was refused', p_to
        using errcode = 'P0001';
    end if;
  end loop;

  return p_order;
end;
$$;

-- Sets an order's created_at, so the read's ordering can be made deterministic even
-- though every order here is placed inside one transaction at one now().
create or replace function pg_temp.set_created_at(
  p_order uuid,
  p_created_at timestamptz
)
returns void
language sql
volatile
security definer
set search_path = ''
as $fn$
  update public.orders set created_at = p_created_at where id = p_order;
$fn$;

-- The order numbers of one payload, in the order the payload lists them.
create or replace function pg_temp.payload_order_numbers(p_payload jsonb)
returns text
language sql
stable
as $fn$
  select coalesce(
           string_agg(entry ->> 'order_number', ',' order by ordinal),
           ''
         )
    from jsonb_array_elements(p_payload -> 'orders') with ordinality
      as listed(entry, ordinal);
$fn$;

-- The stored rows, which no client role has any grant on, so these are SECURITY
-- DEFINER. They exist only in this script, which is rolled back.
create or replace function pg_temp.stored_snapshot(p_order uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select to_jsonb(stored) from public.orders as stored where stored.id = p_order;
$fn$;

create or replace function pg_temp.stored_order_number(p_order uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $fn$
  select stored.order_number::text
    from public.orders as stored
   where stored.id = p_order;
$fn$;

-- The order numbers of a restaurant's stored active orders, in the function's sort
-- order (created_at desc, order_number desc), optionally narrowed to one branch.
create or replace function pg_temp.stored_active_order_numbers(
  p_restaurant_id uuid,
  p_branch_id uuid default null
)
returns text
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(
           string_agg(
             stored.order_number::text,
             ',' order by stored.created_at desc, stored.order_number desc
           ),
           ''
         )
    from public.orders as stored
   where stored.restaurant_id = p_restaurant_id
     and stored.status in ('PENDING', 'ACCEPTED', 'PREPARING', 'READY')
     and (p_branch_id is null or stored.branch_id = p_branch_id);
$fn$;

create or replace function pg_temp.stored_active_order_count(
  p_restaurant_id uuid,
  p_branch_id uuid default null
)
returns integer
language sql
stable
security definer
set search_path = ''
as $fn$
  select count(*)::integer
    from public.orders as stored
   where stored.restaurant_id = p_restaurant_id
     and stored.status in ('PENDING', 'ACCEPTED', 'PREPARING', 'READY')
     and (p_branch_id is null or stored.branch_id = p_branch_id);
$fn$;

create or replace function pg_temp.stored_first_line(p_order uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select to_jsonb(stored)
    from public.order_items as stored
   where stored.order_id = p_order
   order by stored.sort_order
   limit 1;
$fn$;

create or replace function pg_temp.stored_line_count(p_order uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $fn$
  select count(*)::integer
    from public.order_items as stored
   where stored.order_id = p_order;
$fn$;

-- ---------------------------------------------------------------------------
-- Fixtures
--
-- Two restaurants. Restaurant A has two branches, so the branch filter has
-- something to divide. One order in A is left PENDING and made the oldest row in
-- the whole restaurant; the rest pile up newer and terminal, which is exactly the
-- shape that hides it from the history read.
-- ---------------------------------------------------------------------------
insert into public.restaurants (id, name, slug)
values
  ('11111111-1111-1111-1111-111111111111', 'Ala-Too', 'ala-too'),
  ('22222222-2222-2222-2222-222222222222', 'Beshkempir', 'beshkempir');

insert into public.branches (id, restaurant_id, name)
values
  ('33333333-3333-3333-3333-333333333331',
   '11111111-1111-1111-1111-111111111111', 'Center'),
  ('33333333-3333-3333-3333-333333333332',
   '11111111-1111-1111-1111-111111111111', 'Airport'),
  ('44444444-4444-4444-4444-444444444444',
   '22222222-2222-2222-2222-222222222222', 'Airport');

insert into public.tables (
  id, restaurant_id, branch_id, table_number, name, capacity, qr_token
)
values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333331', '12', 'Window', 4,
   'a1a1a1a1-1111-4111-8111-111111111111'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaab',
   '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333332', '3', null, 2,
   'a2a2a2a2-2222-4222-8222-222222222222'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   '22222222-2222-2222-2222-222222222222',
   '44444444-4444-4444-4444-444444444444', '1', 'Bar', 2,
   'b1b1b1b1-1111-4111-8111-111111111111');

insert into public.categories (id, restaurant_id, name)
values
  ('55555555-5555-5555-5555-555555555551',
   '11111111-1111-1111-1111-111111111111', 'Mains'),
  ('55555555-5555-5555-5555-555555555552',
   '22222222-2222-2222-2222-222222222222', 'Mains');

insert into public.menu_items (
  id, restaurant_id, branch_id, category_id, name, price, is_available
)
values
  ('77777777-7777-7777-7777-777777777771',
   '11111111-1111-1111-1111-111111111111', null,
   '55555555-5555-5555-5555-555555555551', 'Beshbarmak', 450.00, true),
  ('77777777-7777-7777-7777-777777777772',
   '22222222-2222-2222-2222-222222222222', null,
   '55555555-5555-5555-5555-555555555552', 'Kebab', 600.00, true);

insert into auth.users (id, email)
select
  staff.id,
  staff.id::text || '@example.com'
from (values
  ('e0000000-0000-4000-8000-000000000001'::uuid),
  ('e0000000-0000-4000-8000-000000000003'::uuid),
  ('e0000000-0000-4000-8000-000000000004'::uuid),
  ('e0000000-0000-4000-8000-000000000005'::uuid),
  ('e0000000-0000-4000-8000-000000000006'::uuid),
  ('e0000000-0000-4000-8000-000000000007'::uuid),
  ('e0000000-0000-4000-8000-000000000008'::uuid)
) as staff(id);

insert into public.profiles (id)
select id from auth.users;

insert into public.restaurant_members (restaurant_id, user_id, role, is_active)
values
  ('11111111-1111-1111-1111-111111111111',
   'e0000000-0000-4000-8000-000000000001', 'OWNER', true),
  ('11111111-1111-1111-1111-111111111111',
   'e0000000-0000-4000-8000-000000000003', 'WAITER', true),
  ('11111111-1111-1111-1111-111111111111',
   'e0000000-0000-4000-8000-000000000004', 'KITCHEN', true),
  ('11111111-1111-1111-1111-111111111111',
   'e0000000-0000-4000-8000-000000000005', 'CASHIER', true),
  -- Deactivated: still a member on paper, with no access of any kind.
  ('11111111-1111-1111-1111-111111111111',
   'e0000000-0000-4000-8000-000000000006', 'WAITER', false),
  -- Belongs to the other restaurant only.
  ('22222222-2222-2222-2222-222222222222',
   'e0000000-0000-4000-8000-000000000007', 'OWNER', true);

-- The orders. All are placed inside one transaction, so their created_at is set
-- explicitly below to give the read a deterministic order.
create temporary table pg_temp.fixture (
  name text primary key,
  order_id uuid not null
);

insert into pg_temp.fixture (name, order_id) values
  ('pending',
   pg_temp.placed_order(
     'a1a1a1a1-1111-4111-8111-111111111111',
     '77777777-7777-7777-7777-777777777771')),
  ('accepted',
   pg_temp.placed_order(
     'a1a1a1a1-1111-4111-8111-111111111111',
     '77777777-7777-7777-7777-777777777771')),
  ('preparing',
   pg_temp.placed_order(
     'a1a1a1a1-1111-4111-8111-111111111111',
     '77777777-7777-7777-7777-777777777771')),
  ('ready',
   pg_temp.placed_order(
     'a1a1a1a1-1111-4111-8111-111111111111',
     '77777777-7777-7777-7777-777777777771')),
  ('served',
   pg_temp.placed_order(
     'a1a1a1a1-1111-4111-8111-111111111111',
     '77777777-7777-7777-7777-777777777771')),
  ('cancelled',
   pg_temp.placed_order(
     'a1a1a1a1-1111-4111-8111-111111111111',
     '77777777-7777-7777-7777-777777777771')),
  ('branch_two',
   pg_temp.placed_order(
     'a2a2a2a2-2222-4222-8222-222222222222',
     '77777777-7777-7777-7777-777777777771')),
  ('other_restaurant',
   pg_temp.placed_order(
     'b1b1b1b1-1111-4111-8111-111111111111',
     '77777777-7777-7777-7777-777777777772'));

-- The fixture table is read from inside the authenticated block, so it is granted to
-- the role the tests switch to. It lives in pg_temp and is rolled back with it.
grant select on pg_temp.fixture to authenticated, anon;

select pg_temp.walk_to((select order_id from pg_temp.fixture where name = 'accepted'), 'ACCEPTED');
select pg_temp.walk_to((select order_id from pg_temp.fixture where name = 'preparing'), 'PREPARING');
select pg_temp.walk_to((select order_id from pg_temp.fixture where name = 'ready'), 'READY');
select pg_temp.walk_to((select order_id from pg_temp.fixture where name = 'served'), 'SERVED');
select pg_temp.walk_to((select order_id from pg_temp.fixture where name = 'cancelled'), 'CANCELLED');

-- The pending order is the oldest row in restaurant A; the terminal orders are the
-- newest. That is the state the history read cannot survive.
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'pending'),
  now() - interval '3 hours');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'accepted'),
  now() - interval '2 hours');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'preparing'),
  now() - interval '1 hour');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'ready'),
  now() - interval '30 minutes');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'cancelled'),
  now() - interval '20 minutes');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'served'),
  now() - interval '10 minutes');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'branch_two'),
  now() - interval '4 hours');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'other_restaurant'),
  now() - interval '5 hours');

-- ---------------------------------------------------------------------------
-- The function exists, takes the arguments the client sends, and only
-- `authenticated` may execute it
-- ---------------------------------------------------------------------------
do $$
declare
  v_arguments text;
begin
  select pg_catalog.array_to_string(proargnames, ',')
    into v_arguments
    from pg_catalog.pg_proc
   where pronamespace = 'public'::regnamespace
     and proname = 'staff_list_active_orders';

  perform pg_temp.assert_equals(
    v_arguments,
    'p_restaurant_id,p_branch_id,p_limit',
    'staff_list_active_orders takes a restaurant, an optional branch and a limit'
  );

  perform pg_temp.assert_true(
    (select prosecdef from pg_catalog.pg_proc
      where pronamespace = 'public'::regnamespace
        and proname = 'staff_list_active_orders'),
    'staff_list_active_orders runs as its definer'
  );

  perform pg_temp.assert_equals(
    (select pg_catalog.array_to_string(proconfig, ',')
       from pg_catalog.pg_proc
      where pronamespace = 'public'::regnamespace
        and proname = 'staff_list_active_orders'),
    'search_path=""',
    'staff_list_active_orders runs with an empty search path'
  );

  perform pg_temp.assert_true(
    has_function_privilege(
      'authenticated',
      'public.staff_list_active_orders(uuid, uuid, integer)',
      'execute'
    ),
    'a signed-in client may execute the active read'
  );

  perform pg_temp.assert_true(
    not has_function_privilege(
      'anon',
      'public.staff_list_active_orders(uuid, uuid, integer)',
      'execute'
    ),
    'a guest may not execute the active read'
  );

  perform pg_temp.assert_true(
    exists (
      select 1 from pg_catalog.pg_indexes
       where schemaname = 'public'
         and indexname = 'idx_orders_active_restaurant_created_at'
         and indexdef ilike '%where%PENDING%'
    ),
    'the active read has a partial index on the four active states'
  );
end;
$$;

set local role authenticated;

-- ---------------------------------------------------------------------------
-- Access: the same matrix as the history read
-- ---------------------------------------------------------------------------
do $$
declare
  v_order uuid := (select order_id from pg_temp.fixture where name = 'pending');
begin
  perform pg_temp.sign_in(null);

  perform pg_temp.assert_fails_with(
    'select public.staff_list_active_orders(
       ''11111111-1111-1111-1111-111111111111'')',
    '28000',
    'Authentication is required to read restaurant orders.',
    'reading active orders without a session is refused'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000008');

  perform pg_temp.assert_fails_with(
    'select public.staff_list_active_orders(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_order_access_denied',
    'a signed-in non-member cannot read a restaurant''s active orders'
  );
  perform pg_temp.assert_fails_with(
    'select public.staff_list_active_orders(
       ''99999999-9999-9999-9999-999999999999'')',
    '42501',
    'staff_order_access_denied',
    'a restaurant that does not exist is refused like one that is not ours'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000006');
  perform pg_temp.assert_fails_with(
    'select public.staff_list_active_orders(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_order_access_denied',
    'a deactivated member cannot read the restaurant''s active orders'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000005');
  perform pg_temp.assert_fails_with(
    'select public.staff_list_active_orders(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_order_access_denied',
    'a cashier cannot read the restaurant''s active orders'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000007');
  perform pg_temp.assert_fails_with(
    'select public.staff_list_active_orders(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_order_access_denied',
    'the other restaurant''s owner cannot read this restaurant''s active orders'
  );

  -- The active read is not a way around the lifecycle either: it names no order, so
  -- the order id above is only here to make the intent explicit.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');
  perform pg_temp.assert_true(
    pg_temp.stored_order_number(v_order) is not null,
    'the pending fixture order exists, so the reads below have something to return'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Only the active states, and the newest active order survives a large history
-- ---------------------------------------------------------------------------
do $$
declare
  v_payload jsonb;
  v_history jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_payload := public.staff_list_active_orders(
    '11111111-1111-1111-1111-111111111111'
  );

  perform pg_temp.assert_equals(
    v_payload ->> 'restaurant_id',
    '11111111-1111-1111-1111-111111111111',
    'the payload reports the restaurant that was asked for'
  );
  perform pg_temp.assert_equals(
    v_payload ->> 'branch_id',
    null,
    'the payload reports no branch when no branch was asked for'
  );

  -- Exactly the four active orders, newest first.
  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(v_payload),
    pg_temp.stored_active_order_numbers(
      '11111111-1111-1111-1111-111111111111'
    ),
    'the active read returns exactly the active orders, newest first'
  );

  -- The terminal fixtures are nowhere in it, by their state.
  perform pg_temp.assert_true(
    not exists (
      select 1
        from jsonb_array_elements(v_payload -> 'orders') as listed(entry)
       where listed.entry ->> 'status' in ('SERVED', 'CANCELLED')
    ),
    'the active read never returns a served or a cancelled order'
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    '5',
    'restaurant A has five active orders and all of them are returned'
  );

  -- The bug this read exists to fix. The history read returns the two newest rows,
  -- which are both terminal, and the older pending order is gone from that window.
  -- The active read returns the pending order regardless of how much newer history
  -- exists.
  v_history := public.staff_list_orders(
    '11111111-1111-1111-1111-111111111111',
    null,
    2
  );

  perform pg_temp.assert_true(
    ',' || pg_temp.payload_order_numbers(v_history) || ',' not like
      '%,' || pg_temp.stored_order_number(
        (select order_id from pg_temp.fixture where name = 'pending')) || ',%',
    'the history window has already lost the old pending order'
  );
  perform pg_temp.assert_true(
    ',' || pg_temp.payload_order_numbers(v_payload) || ',' like
      '%,' || pg_temp.stored_order_number(
        (select order_id from pg_temp.fixture where name = 'pending')) || ',%',
    'the active read still returns the old pending order'
  );

  -- The other restaurant's order is not in the answer, by id and by product. The
  -- order number is deliberately not compared: it is a per-restaurant number, so the
  -- other restaurant's first order also carries the number 1.
  perform pg_temp.assert_true(
    v_payload::text not like '%Kebab%'
      and not exists (
        select 1
          from jsonb_array_elements(v_payload -> 'orders') as listed(entry)
         where (listed.entry ->> 'id')::uuid =
               (select order_id from pg_temp.fixture
                 where name = 'other_restaurant')
      ),
    'the payload holds nothing from the other restaurant'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Branch filter: divides one restaurant's active orders, never another's branch
-- ---------------------------------------------------------------------------
do $$
declare
  v_branch_one jsonb;
  v_branch_two jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_branch_one := public.staff_list_active_orders(
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333331'
  );

  perform pg_temp.assert_equals(
    v_branch_one ->> 'branch_id',
    '33333333-3333-3333-3333-333333333331',
    'the payload reports the branch that was asked for'
  );
  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(v_branch_one),
    pg_temp.stored_active_order_numbers(
      '11111111-1111-1111-1111-111111111111',
      '33333333-3333-3333-3333-333333333331'
    ),
    'a branch filter returns that branch''s active orders only'
  );

  v_branch_two := public.staff_list_active_orders(
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333332'
  );

  perform pg_temp.assert_equals(
    jsonb_array_length(v_branch_two -> 'orders')::text,
    '1',
    'the other branch of the same restaurant returns its own one active order'
  );

  -- A branch id belonging to the other restaurant cannot be used to read it: it
  -- matches no order of this restaurant's and returns an empty list.
  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(
      public.staff_list_active_orders(
        '11111111-1111-1111-1111-111111111111',
        '44444444-4444-4444-4444-444444444444'
      )
    ),
    '',
    'a branch of another restaurant matches no active order'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- What one active order looks like, and what must not be there
-- ---------------------------------------------------------------------------
do $$
declare
  v_payload jsonb;
  v_order jsonb;
  v_stored jsonb;
  v_keys text;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_payload := public.staff_list_active_orders(
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333331'
  );

  -- Newest first: the ready order, then preparing, accepted, pending.
  v_order := v_payload -> 'orders' -> 0;

  perform pg_temp.assert_equals(
    v_order ->> 'status',
    'READY',
    'the newest active order is the ready one'
  );

  v_stored := pg_temp.stored_snapshot((v_order ->> 'id')::uuid);

  perform pg_temp.assert_equals(
    v_order ->> 'order_number',
    v_stored ->> 'order_number',
    'the order number is the stored one'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'currency',
    'KGS',
    'the currency is the one snapshotted with the order'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'total',
    v_stored ->> 'total',
    'the total is the stored total'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'item_count',
    v_stored ->> 'item_count',
    'the item count is the stored one'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'branch_id',
    '33333333-3333-3333-3333-333333333331',
    'the branch is named, because staff work one branch'
  );
  perform pg_temp.assert_true(
    v_order ? 'created_at' and v_order ? 'updated_at',
    'the order carries when it was placed and last changed'
  );

  perform pg_temp.assert_equals(
    v_order -> 'table' ->> 'id',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'the ordered table is named by id'
  );
  perform pg_temp.assert_equals(
    v_order -> 'table' ->> 'number',
    '12',
    'the ordered table carries its number'
  );

  perform pg_temp.assert_equals(
    jsonb_array_length(v_order -> 'items')::text,
    pg_temp.stored_line_count((v_order ->> 'id')::uuid)::text,
    'every stored line is in the payload'
  );
  perform pg_temp.assert_equals(
    v_order -> 'items' -> 0 ->> 'product_name',
    pg_temp.stored_first_line((v_order ->> 'id')::uuid) ->> 'product_name',
    'a line carries the product name as it was ordered'
  );
  perform pg_temp.assert_equals(
    v_order -> 'items' -> 0 ->> 'line_total',
    pg_temp.stored_first_line((v_order ->> 'id')::uuid) ->> 'line_total',
    'a line carries the stored line total'
  );

  -- Nothing that belongs to the guest, and nothing that is not an order.
  perform pg_temp.assert_true(
    v_payload::text not like '%access_token%'
      and v_payload::text not like '%' || (v_stored ->> 'access_token') || '%',
    'no guest access token is in the payload, by name or by value'
  );
  perform pg_temp.assert_true(
    v_payload::text not like '%old_status%'
      and v_payload::text not like '%new_status%',
    'the status history is not in the payload'
  );
  perform pg_temp.assert_true(
    v_payload::text not like '%user_id%'
      and v_payload::text not like '%restaurant_members%',
    'no membership or staff identity is in the payload'
  );

  -- The key set is exactly the history read's.
  select string_agg(key, ',' order by key)
    into v_keys
    from jsonb_object_keys(v_order) as key;

  perform pg_temp.assert_equals(
    v_keys,
    'branch_id,created_at,currency,id,item_count,items,order_number,status,table,total,updated_at',
    'an active order carries exactly the fields a screen needs'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- p_limit is clamped to 1..1000, not obeyed
-- ---------------------------------------------------------------------------
do $$
declare
  v_active_count integer;
  v_payload jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_active_count := pg_temp.stored_active_order_count(
    '11111111-1111-1111-1111-111111111111'
  );

  perform pg_temp.assert_equals(
    v_active_count::text,
    '5',
    'the fixture has five active orders to bound the default against'
  );

  v_payload := public.staff_list_active_orders(
    '11111111-1111-1111-1111-111111111111', null, 1
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    '1',
    'a limit of one returns one active order'
  );

  v_payload := public.staff_list_active_orders(
    '11111111-1111-1111-1111-111111111111', null, 0
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    '1',
    'a limit of zero is clamped up to one rather than returning nothing'
  );

  v_payload := public.staff_list_active_orders(
    '11111111-1111-1111-1111-111111111111', null, -5
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    '1',
    'a negative limit is clamped up to one'
  );

  v_payload := public.staff_list_active_orders(
    '11111111-1111-1111-1111-111111111111', null, 1000000
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    v_active_count::text,
    'a limit above the ceiling returns every active order'
  );

  v_payload := public.staff_list_active_orders(
    '11111111-1111-1111-1111-111111111111', null, null
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    v_active_count::text,
    'an absent limit falls back to the default and returns every active order'
  );
end;
$$;

reset role;

rollback;
