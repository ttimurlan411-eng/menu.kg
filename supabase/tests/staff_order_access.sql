-- Staff order access checks: who may read a restaurant's orders, who may move one,
-- and what is refused to everyone else.
--
-- Runs against a database where supabase/migrations has been applied, as the table
-- owner (which is also the definer of the staff functions) and as the `anon` and
-- `authenticated` roles with a chosen identity, which is what a real call looks
-- like:
--
--   * a guest cannot call either staff function, and no grant on the order tables
--     exists for either client role: the two functions are the only way in
--   * `private.can_read_restaurant_orders` and
--     `private.can_manage_restaurant_orders` are not callable by a client at all
--   * a call with no session is refused; so is a call from a signed-in user who is
--     not an active member of the restaurant; so is one that names a restaurant or
--     an order that does not exist, with the same answer as belonging to somebody
--     else
--   * a member reads only their own restaurant, optionally one branch, and a branch
--     of another restaurant matches nothing rather than leaking it
--   * the payload carries the order header, the ordered table and the item
--     snapshots, and no guest access token, no order_access row and no history
--   * p_limit is clamped rather than obeyed
--   * the whole role matrix: which role may make which move, and which role is
--     refused. Every attempt starts from a real order that reached its state only
--     through moves the database allowed
--   * an illegal move and a status the lifecycle does not have are refused by
--     guard_order_status_transition with its own P0001 error, proving the staff
--     function delegates the lifecycle rather than re-deciding it
--   * an accepted move records exactly one history row; a refused one changes
--     nothing and records nothing
--   * the guest read still works, and still reports the state staff moved the order
--     to
--
-- Usage, against a database where supabase/migrations has been applied:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/staff_order_access.sql
--
-- On Supabase the auth schema and the anon/authenticated roles already exist and the
-- guard below does nothing. Against a plain Postgres it creates a minimal stand-in,
-- as the other scripts do. Everything runs in one transaction that is rolled back at
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

-- Asserts that [statement] is refused for the current role. Any error passes, which
-- is intentional: a permission error and a rule refusing the statement are both
-- answers, and both mean the statement did not happen.
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

-- Asserts that [statement] fails with [expected_code] and [expected_message].
--
-- The message is asserted as well as the sqlstate because the two refusals that
-- share 42501 are different answers: an order that is not the caller's, and a move
-- the caller's role does not make. A client maps them to different wording, so they
-- have to be told apart here as well.
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

-- Signs the session in as [p_user], the way a Supabase request does: the identity
-- comes from the JWT, so it is the only thing that decides who a caller is.
--
-- Null signs nobody out, which is the anonymous call the client makes with no
-- session at all.
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

-- A freshly placed order, through the guest's own function, so every move below
-- starts from a real order rather than a hand-built row.
--
-- p_qr_token selects which table the order belongs to, which is how an order gets
-- into a chosen branch.
create or replace function pg_temp.placed_order(
  p_qr_token text default 'a1a1a1a1-1111-4111-8111-111111111111',
  p_item text default '77777777-7777-7777-7777-777777777777',
  p_quantity integer default 1
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
      pg_catalog.jsonb_build_object('item_id', p_item, 'quantity', p_quantity)
    ),
    null
  ) -> 'order' ->> 'id';

  return v_id::uuid;
end;
$$;

-- A freshly placed order, walked to [p_from] along the lifecycle.
--
-- SECURITY DEFINER because it writes the orders table, which no client role may
-- write: a test has to be able to put an order into a state through moves the
-- database allowed, without going through the function under test. A refused step
-- raises, so a state that cannot be reached fails the test rather than passing it.
create or replace function pg_temp.order_in_state(p_from text)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_order uuid := pg_temp.placed_order();
  v_step text;
begin
  foreach v_step in array case p_from
    when 'PENDING' then '{}'::text[]
    when 'ACCEPTED' then array['PENDING', 'ACCEPTED']
    when 'PREPARING' then array['PENDING', 'ACCEPTED', 'PREPARING']
    when 'READY' then array['PENDING', 'ACCEPTED', 'PREPARING', 'READY']
    when 'SERVED' then array['PENDING', 'ACCEPTED', 'PREPARING', 'READY', 'SERVED']
    when 'CANCELLED' then array['PENDING', 'CANCELLED']
  end
  loop
    update public.orders set status = v_step where id = v_order;

    if not found then
      raise exception 'FAILED: walking to % was refused', p_from
        using errcode = 'P0001';
    end if;
  end loop;

  return v_order;
end;
$$;

-- Attempts one staff status change as [p_user], and reports what happened as
-- '<sqlstate>:<message>', or 'ok'.
--
-- Deliberately not SECURITY DEFINER: it must run as the client role, so that calling
-- the staff function here proves the function is executable by that role and not
-- merely by its definer. The answer is a single line a test can compare exactly, and
-- catching the error leaves the attempt rolled back to its own savepoint, so the
-- order stays usable for the assertions that follow.
create or replace function pg_temp.staff_move(
  p_user uuid,
  p_order uuid,
  p_to text
)
returns text
language plpgsql
volatile
as $$
declare
  v_result text;
begin
  perform pg_temp.sign_in(p_user);

  begin
    perform public.staff_set_order_status(p_order, p_to);
    v_result := 'ok';
  exception
    when others then
      v_result := sqlstate || ':' || sqlerrm;
  end;

  perform pg_temp.sign_in(null);

  return v_result;
end;
$$;

-- The transitions recorded for one order, as 'OLD>NEW' pairs in commit order.
--
-- SECURITY DEFINER like the other expectation helpers: the audit trail has no grant
-- for any client role either, and what a staff move recorded is exactly what a test
-- has to check.
create or replace function pg_temp.recorded_transitions(p_order uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(
           string_agg(old_status || '>' || new_status, ',' order by id),
           ''
         )
    from public.order_status_history
   where order_id = p_order;
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

-- What the payload is compared against.
--
-- These read the order tables, which no client role has any grant on, so they are
-- SECURITY DEFINER: a test that compares a payload against the stored row has to ask
-- something that may read the row, otherwise the comparison would have to be built
-- by the same function under test. They exist only in this script, which is rolled
-- back, and read nothing a caller of the staff functions could not already have
-- read through them.
create or replace function pg_temp.stored_snapshot(p_order uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select to_jsonb(stored) from public.orders as stored where stored.id = p_order;
$fn$;

create or replace function pg_temp.stored_status(p_order uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $fn$
  select stored.status from public.orders as stored where stored.id = p_order;
$fn$;

-- The stored amounts of the first line, in the order the guest placed them.
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

create or replace function pg_temp.stored_order_numbers(
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
           string_agg(stored.order_number::text, ',' order by stored.order_number desc),
           ''
         )
    from public.orders as stored
   where stored.restaurant_id = p_restaurant_id
     and (p_branch_id is null or stored.branch_id = p_branch_id);
$fn$;

-- The order a guest token owns, so a guest-role block can name an order id without
-- being able to read the orders table.
create or replace function pg_temp.order_id_for_token(p_token text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $fn$
  select stored.id
    from public.orders as stored
   where stored.access_token = pg_catalog.btrim(p_token);
$fn$;

create or replace function pg_temp.stored_order_count(
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
     and (p_branch_id is null or stored.branch_id = p_branch_id);
$fn$;

-- ---------------------------------------------------------------------------
-- Fixtures
--
-- Two restaurants, each with branches, tables and something to order, so a leak
-- between them is a wrong answer rather than an empty one. Restaurant A has two
-- branches, so the branch filter has something to divide.
-- ---------------------------------------------------------------------------
insert into public.restaurants (id, name, slug)
values
  ('11111111-1111-1111-1111-111111111111', 'Ala-Too', 'ala-too'),
  ('22222222-2222-2222-2222-222222222222', 'Beshkempir', 'beshkempir');

insert into public.branches (id, restaurant_id, name)
values
  ('33333333-3333-3333-3333-333333333333',
   '11111111-1111-1111-1111-111111111111', 'Center'),
  ('33333333-3333-3333-3333-333333333334',
   '11111111-1111-1111-1111-111111111111', 'Airport'),
  ('44444444-4444-4444-4444-444444444444',
   '22222222-2222-2222-2222-222222222222', 'Airport');

insert into public.tables (
  id, restaurant_id, branch_id, table_number, name, capacity, qr_token
)
values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '12', 'Window', 4,
   'a1a1a1a1-1111-4111-8111-111111111111'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaab',
   '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333334', '3', null, 2,
   'a2a2a2a2-2222-4222-8222-222222222222'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   '22222222-2222-2222-2222-222222222222',
   '44444444-4444-4444-4444-444444444444', '1', 'Bar', 2,
   'b1b1b1b1-1111-4111-8111-111111111111');

insert into public.categories (id, restaurant_id, name)
values
  ('55555555-5555-5555-5555-555555555555',
   '11111111-1111-1111-1111-111111111111', 'Mains'),
  ('55555555-5555-5555-5555-555555555556',
   '22222222-2222-2222-2222-222222222222', 'Mains');

insert into public.menu_items (
  id, restaurant_id, branch_id, category_id, name, price, is_available
)
values
  ('77777777-7777-7777-7777-777777777777',
   '11111111-1111-1111-1111-111111111111', null,
   '55555555-5555-5555-5555-555555555555', 'Beshbarmak', 450.00, true),
  ('77777777-7777-7777-7777-777777777778',
   '22222222-2222-2222-2222-222222222222', null,
   '55555555-5555-5555-5555-555555555556', 'Kebab', 600.00, true);

-- Staff, one membership each, plus the awkward cases: a member whose membership has
-- been deactivated, a member of the other restaurant only, a signed-in user with no
-- membership at all, and someone who belongs to both restaurants.
insert into auth.users (id, email)
select
  staff.id,
  staff.id::text || '@example.com'
from (values
  ('e0000000-0000-4000-8000-000000000001'::uuid),
  ('e0000000-0000-4000-8000-000000000002'::uuid),
  ('e0000000-0000-4000-8000-000000000003'::uuid),
  ('e0000000-0000-4000-8000-000000000004'::uuid),
  ('e0000000-0000-4000-8000-000000000005'::uuid),
  ('e0000000-0000-4000-8000-000000000006'::uuid),
  ('e0000000-0000-4000-8000-000000000007'::uuid),
  ('e0000000-0000-4000-8000-000000000008'::uuid),
  ('e0000000-0000-4000-8000-000000000009'::uuid)
) as staff(id);

insert into public.profiles (id)
select id from auth.users;

insert into public.restaurant_members (restaurant_id, user_id, role, is_active)
values
  ('11111111-1111-1111-1111-111111111111',
   'e0000000-0000-4000-8000-000000000001', 'OWNER', true),
  ('11111111-1111-1111-1111-111111111111',
   'e0000000-0000-4000-8000-000000000002', 'MANAGER', true),
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
   'e0000000-0000-4000-8000-000000000007', 'OWNER', true),
  -- Owner of the other restaurant and a waiter of this one: membership, not
  -- ownership, is what grants access.
  ('22222222-2222-2222-2222-222222222222',
   'e0000000-0000-4000-8000-000000000009', 'OWNER', true),
  ('11111111-1111-1111-1111-111111111111',
   'e0000000-0000-4000-8000-000000000009', 'WAITER', true);

-- The orders everything else is about: two in restaurant A's first branch, one in its
-- second, one in the other restaurant.
select pg_temp.placed_order('a1a1a1a1-1111-4111-8111-111111111111', p_quantity => 2);
select pg_temp.placed_order('a1a1a1a1-1111-4111-8111-111111111111');
select pg_temp.placed_order('a2a2a2a2-2222-4222-8222-222222222222');
select pg_temp.placed_order('b1b1b1b1-1111-4111-8111-111111111111',
                           '77777777-7777-7777-7777-777777777778');

-- ---------------------------------------------------------------------------
-- The staff functions exist, take the arguments the client sends, and nothing else
-- ---------------------------------------------------------------------------
do $$
declare
  v_arguments text;
  v_source text;
begin
  select pg_catalog.array_to_string(proargnames, ',')
    into v_arguments
    from pg_catalog.pg_proc
   where pronamespace = 'public'::regnamespace
     and proname = 'staff_list_orders';

  perform pg_temp.assert_true(
    v_arguments = 'p_restaurant_id,p_branch_id,p_limit',
    'staff_list_orders takes a restaurant, an optional branch and a limit'
  );

  -- The status function deliberately takes no restaurant: the order id resolves it.
  -- An argument here would be one more thing for a client to name wrongly, and the
  -- membership is checked against the order's own restaurant either way.
  select pg_catalog.array_to_string(proargnames, ',')
    into v_arguments
    from pg_catalog.pg_proc
   where pronamespace = 'public'::regnamespace
     and proname = 'staff_set_order_status';

  perform pg_temp.assert_equals(
    v_arguments,
    'p_order_id,p_new_status',
    'staff_set_order_status takes only an order id and a status'
  );

  -- The function authorizes and writes; it does not judge the lifecycle. If it ever
  -- named the lifecycle error it would be deciding legality itself, and the guard
  -- would be a second rule to keep in step.
  select pg_catalog.pg_get_functiondef(p.oid)
    into v_source
    from pg_catalog.pg_proc as p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'staff_set_order_status';

  perform pg_temp.assert_true(
    v_source not like '%invalid_order_status%',
    'staff_set_order_status does not name the lifecycle error'
  );
  perform pg_temp.assert_true(
    v_source not like '%allowedNextStatuses%'
      and v_source like '%update public.orders%',
    'staff_set_order_status writes by updating the orders table, not by another route'
  );
end;
$$;

-- Both functions run as their definer with an empty search path, so neither can be
-- walked into another schema's objects.
do $$
declare
  v_function record;
begin
  for v_function in
    select p.proname, p.prosecdef, p.proconfig
      from pg_catalog.pg_proc as p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('staff_list_orders', 'staff_set_order_status')
  loop
    perform pg_temp.assert_true(
      v_function.prosecdef,
      v_function.proname || ' runs as its definer'
    );
    perform pg_temp.assert_true(
      v_function.proconfig::text like '%search_path=%',
      v_function.proname || ' pins its search path'
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- A guest cannot reach the staff path at all
-- ---------------------------------------------------------------------------
set local role anon;

do $$
begin
  perform pg_temp.assert_denied(
    'select public.staff_list_orders(''11111111-1111-1111-1111-111111111111'')',
    'anon cannot list a restaurant''s orders'
  );
  perform pg_temp.assert_denied(
    'select public.staff_set_order_status(
       ''00000000-0000-4000-8000-000000000000'', ''ACCEPTED'')',
    'anon cannot move an order'
  );
  perform pg_temp.assert_denied(
    'select * from public.orders',
    'anon cannot read orders'
  );
  perform pg_temp.assert_denied(
    'select * from public.order_items',
    'anon cannot read order lines'
  );
  perform pg_temp.assert_denied(
    'select * from public.order_access',
    'anon cannot read guest order tokens'
  );
  perform pg_temp.assert_denied(
    'select * from public.order_status_history',
    'anon cannot read the status history'
  );
end;
$$;

-- A signed-in staff member is no different at the table level: membership grants the
-- two functions, not the orders table.
set local role authenticated;
select pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

do $$
begin
  perform pg_temp.assert_denied(
    'select * from public.orders',
    'a signed-in owner cannot read the orders table directly'
  );
  perform pg_temp.assert_denied(
    'select * from public.order_items',
    'a signed-in owner cannot read the order lines table directly'
  );
  perform pg_temp.assert_denied(
    'select * from public.order_access',
    'a signed-in owner cannot read the guest tokens table directly'
  );
  perform pg_temp.assert_denied(
    'update public.orders set status = ''ACCEPTED'' where order_number = 1',
    'a signed-in owner cannot move an order through the table'
  );
  perform pg_temp.assert_denied(
    'select private.can_read_restaurant_orders(
       ''11111111-1111-1111-1111-111111111111'')',
    'the read authorization helper is not callable by a client'
  );
  perform pg_temp.assert_denied(
    'select private.can_manage_restaurant_orders(
       ''11111111-1111-1111-1111-111111111111'', ''PENDING'', ''ACCEPTED'')',
    'the move authorization helper is not callable by a client'
  );
end;
$$;

reset role;

-- The grants are exactly these four functions for the signed-in role, and none is
-- granted to a guest. `staff_list_active_orders` (added by
-- 20261009000000_create_staff_active_orders.sql) is the live working-list read and
-- `staff_list_order_history` (added by 20261010000000_create_staff_order_history.sql)
-- is the paginated whole-history read; both are listed here so a new order-named
-- function cannot quietly join the signed-in surface.
do $$
declare
  v_staff_functions text;
begin
  select string_agg(proname, ',' order by proname)
    into v_staff_functions
    from pg_catalog.pg_proc
   where pronamespace = 'public'::regnamespace
     and has_function_privilege('authenticated', oid, 'execute')
     and (proname ilike '%order%' or proname ilike '%status%')
     -- Reservation functions are a separate feature, checked by
     -- staff_reservation_access.sql; they must not be counted as order functions here.
     and proname not ilike '%reservation%'
     -- A trigger function cannot be called on its own, so it is not a path into
     -- anything; the lifecycle guard is deliberately left executable for the writer
     -- of the table, as its own migration explains.
     and prorettype <> 'trigger'::regtype
     and proname not in ('create_table_order', 'guest_orders');

  perform pg_temp.assert_equals(
    v_staff_functions,
    'staff_list_active_orders,staff_list_order_history,staff_list_orders,staff_set_order_status',
    'a signed-in client may execute exactly the four staff order functions'
  );

  select count(*)
    into v_staff_functions
    from pg_catalog.pg_proc
   where pronamespace = 'public'::regnamespace
     and has_function_privilege('anon', oid, 'execute')
     and (proname ilike '%order%' or proname ilike '%status%')
     -- Reservation functions are a separate feature, checked by
     -- staff_reservation_access.sql; they must not be counted as order functions here.
     and proname not ilike '%reservation%'
     and prorettype <> 'trigger'::regtype
     and proname not in ('create_table_order', 'guest_orders');

  perform pg_temp.assert_equals(
    v_staff_functions::text,
    '0',
    'a guest may execute no function that names an order or a status'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading: whose orders, which branch, and what is in the answer
-- ---------------------------------------------------------------------------
set local role authenticated;

-- No session at all: a signed-out client, or a stale session the app has not noticed
-- yet, is refused rather than answered with somebody's orders.
do $$
declare
  v_order uuid := pg_temp.placed_order();
begin
  perform pg_temp.sign_in(null);

  perform pg_temp.assert_fails_with(
    'select public.staff_list_orders(''11111111-1111-1111-1111-111111111111'')',
    '28000',
    'Authentication is required to read restaurant orders.',
    'listing orders without a session is refused'
  );
  perform pg_temp.assert_fails_with(
    format('select public.staff_set_order_status(%L, ''ACCEPTED'')', v_order),
    '28000',
    'Authentication is required to change an order status.',
    'moving an order without a session is refused'
  );

  -- A signed-in user with no membership anywhere is refused with the same answer as
  -- a restaurant that does not exist: this is not a way to find out what exists.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000008');

  perform pg_temp.assert_fails_with(
    'select public.staff_list_orders(''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_order_access_denied',
    'a signed-in non-member cannot list a restaurant''s orders'
  );
  perform pg_temp.assert_fails_with(
    'select public.staff_list_orders(
       ''99999999-9999-9999-9999-999999999999'')',
    '42501',
    'staff_order_access_denied',
    'a restaurant that does not exist is refused like one that is not ours'
  );
  perform pg_temp.assert_fails_with(
    format('select public.staff_set_order_status(%L, ''ACCEPTED'')', v_order),
    '42501',
    'staff_order_access_denied',
    'a signed-in non-member cannot move an order'
  );
end;
$$;

-- A member reads their own restaurant, and only their own.
do $$
declare
  v_payload jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_payload := public.staff_list_orders(
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

  -- Newest first. Every order here shares a created_at, because they were all placed
  -- in this one transaction, so the order number is what the list is sorted by.
  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(v_payload),
    pg_temp.stored_order_numbers('11111111-1111-1111-1111-111111111111'),
    'an owner sees their own restaurant''s orders, newest first'
  );

  perform pg_temp.assert_true(
    v_payload::text not like '%b1b1b1b1%'
      and v_payload::text not like '%Beshkempir%'
      and v_payload::text not like '%Kebab%',
    'the payload holds nothing from the other restaurant'
  );

  -- The other restaurant's owner reads only theirs.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000007');

  v_payload := public.staff_list_orders(
    '22222222-2222-2222-2222-222222222222'
  );

  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    '1',
    'the other restaurant''s owner sees exactly their own one order'
  );
  perform pg_temp.assert_true(
    v_payload::text not like '%Beshbarmak%',
    'the other restaurant''s orders are not in it'
  );

  -- And cannot reach the first one at all.
  perform pg_temp.assert_fails_with(
    'select public.staff_list_orders(''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_order_access_denied',
    'the other restaurant''s owner cannot list the first restaurant''s orders'
  );

  -- Belonging to both is enough: access follows the membership of the restaurant
  -- being read, not who owns it.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000009');

  perform pg_temp.assert_equals(
    jsonb_array_length(
      public.staff_list_orders('11111111-1111-1111-1111-111111111111') -> 'orders'
    )::text,
    pg_temp.stored_order_count(
      '11111111-1111-1111-1111-111111111111'
    )::text,
    'a member of both restaurants reads the one whose membership covers it'
  );

  -- A deactivated membership grants nothing, in either direction.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000006');

  perform pg_temp.assert_fails_with(
    'select public.staff_list_orders(''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_order_access_denied',
    'a deactivated member cannot read the restaurant''s orders'
  );

  -- A cashier may not: this step defines no order duties for that role.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000005');

  perform pg_temp.assert_fails_with(
    'select public.staff_list_orders(''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_order_access_denied',
    'a cashier cannot read the restaurant''s orders'
  );
end;
$$;

-- The branch filter divides one restaurant's orders without reaching another's.
do $$
declare
  v_payload jsonb;
  v_center uuid;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_payload := public.staff_list_orders(
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333333'
  );

  perform pg_temp.assert_equals(
    v_payload ->> 'branch_id',
    '33333333-3333-3333-3333-333333333333',
    'the payload reports the branch that was asked for'
  );
  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(v_payload),
    pg_temp.stored_order_numbers(
      '11111111-1111-1111-1111-111111111111',
      '33333333-3333-3333-3333-333333333333'
    ),
    'a branch filter returns that branch''s orders only'
  );

  perform pg_temp.assert_equals(
    jsonb_array_length(
      public.staff_list_orders(
        '11111111-1111-1111-1111-111111111111',
        '33333333-3333-3333-3333-333333333334'
      ) -> 'orders'
    )::text,
    '1',
    'the other branch of the same restaurant returns its own one order'
  );

  -- A branch id belonging to the other restaurant cannot be used to read it, and
  -- says nothing about whether it exists: an empty list is the same answer as a
  -- branch with no orders.
  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(
      public.staff_list_orders(
        '11111111-1111-1111-1111-111111111111',
        '44444444-4444-4444-4444-444444444444'
      )
    ),
    '',
    'a branch of another restaurant matches nothing'
  );

  -- And the order of the arguments cannot be used to swap them: naming the other
  -- restaurant is refused, not answered with its orders.
  perform pg_temp.assert_fails_with(
    'select public.staff_list_orders(
       ''22222222-2222-2222-2222-222222222222'',
       ''33333333-3333-3333-3333-333333333333'')',
    '42501',
    'staff_order_access_denied',
    'naming another restaurant is refused whatever branch is asked for'
  );
end;
$$;

-- What one order looks like inside the payload, and what must not be there.
do $$
declare
  v_payload jsonb;
  v_order jsonb;
  v_stored jsonb;
  v_keys text;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_payload := public.staff_list_orders(
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333333'
  );

  v_order := v_payload -> 'orders' -> 0;

  v_stored := pg_temp.stored_snapshot((v_order ->> 'id')::uuid);

  perform pg_temp.assert_equals(
    v_order ->> 'order_number',
    v_stored ->> 'order_number',
    'the order number is the stored one'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'status',
    'PENDING',
    'the order is reported in the state it is really in'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'currency',
    'KGS',
    'the currency is the one snapshotted with the order'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'total',
    v_stored ->> 'total',
    'the total is the stored total, not a sum made here'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'item_count',
    v_stored ->> 'item_count',
    'the item count is the stored one'
  );
  perform pg_temp.assert_equals(
    v_order ->> 'branch_id',
    '33333333-3333-3333-3333-333333333333',
    'the branch is named, because staff work one branch'
  );
  perform pg_temp.assert_true(
    v_order ? 'created_at' and v_order ? 'updated_at',
    'the order carries when it was placed and last changed'
  );

  -- The table is what staff bring the order to, so it is named here even though the
  -- guest payload deliberately withholds it.
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
    v_order -> 'table' ->> 'name',
    'Window',
    'the ordered table carries its name'
  );

  -- The lines are the stored snapshots, in the order the guest placed them.
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
    v_order -> 'items' -> 0 ->> 'unit_price',
    pg_temp.stored_first_line((v_order ->> 'id')::uuid) ->> 'unit_price',
    'a line carries the snapshotted price, not the live menu price'
  );
  perform pg_temp.assert_equals(
    v_order -> 'items' -> 0 ->> 'line_total',
    pg_temp.stored_first_line((v_order ->> 'id')::uuid) ->> 'line_total',
    'a line carries the stored line total'
  );
  perform pg_temp.assert_equals(
    v_order -> 'items' -> 0 ->> 'quantity',
    pg_temp.stored_first_line((v_order ->> 'id')::uuid) ->> 'quantity',
    'a line carries the quantity that was ordered'
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

  -- And the key set is exactly what a client can rely on.
  select string_agg(key, ',' order by key)
    into v_keys
    from jsonb_object_keys(v_order) as key;

  perform pg_temp.assert_equals(
    v_keys,
    'branch_id,created_at,currency,id,item_count,items,order_number,status,table,total,updated_at',
    'a staff order carries exactly the fields a screen needs'
  );
end;
$$;

-- p_limit is clamped, not obeyed.
do $$
declare
  v_count integer;
  v_payload jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_count := pg_temp.stored_order_count(
    '11111111-1111-1111-1111-111111111111'
  );

  v_payload := public.staff_list_orders(
    '11111111-1111-1111-1111-111111111111', null, 1
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    '1',
    'a limit of one returns one order'
  );

  v_payload := public.staff_list_orders(
    '11111111-1111-1111-1111-111111111111', null, 0
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    '1',
    'a limit of zero is clamped up to one rather than returning nothing'
  );

  v_payload := public.staff_list_orders(
    '11111111-1111-1111-1111-111111111111', null, -5
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    '1',
    'a negative limit is clamped up to one'
  );

  v_payload := public.staff_list_orders(
    '11111111-1111-1111-1111-111111111111', null, 1000000
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    v_count::text,
    'a limit above the ceiling returns the whole restaurant''s orders'
  );

  v_payload := public.staff_list_orders(
    '11111111-1111-1111-1111-111111111111', null, null
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    v_count::text,
    'an absent limit falls back to the default'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Moving: the role matrix, exactly as it is written down
-- ---------------------------------------------------------------------------

-- OWNER and MANAGER: anything the lifecycle allows, and nothing it does not.
do $$
begin
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000001',
      pg_temp.order_in_state('PENDING'),
      'ACCEPTED'),
    'ok', 'an owner may accept an order');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000001',
      pg_temp.order_in_state('PENDING'),
      'CANCELLED'),
    'ok', 'an owner may cancel an order');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000001',
      pg_temp.order_in_state('READY'),
      'SERVED'),
    'ok', 'an owner may serve an order');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000001',
      pg_temp.order_in_state('PENDING'),
      'SERVED'),
    'P0001:invalid_order_status_transition',
    'an owner may not skip ahead: the lifecycle refuses, not the role');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000001',
      pg_temp.order_in_state('PENDING'),
      'READY'),
    'P0001:invalid_order_status_transition',
    'an owner may not jump a state');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000001',
      pg_temp.order_in_state('SERVED'),
      'PENDING'),
    'P0001:invalid_order_status_transition',
    'an owner may not move a served order backwards');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000001',
      pg_temp.order_in_state('CANCELLED'),
      'PENDING'),
    'P0001:invalid_order_status_transition',
    'an owner may not reopen a cancelled order'
  );

  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000002',
      pg_temp.order_in_state('PENDING'),
      'ACCEPTED'),
    'ok', 'a manager may accept an order');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000002',
      pg_temp.order_in_state('READY'),
      'CANCELLED'),
    'P0001:invalid_order_status_transition',
    'a manager may not cancel an order whose food is ready'
  );
end;
$$;

-- WAITER: the customer-service steps, and cancellation.
do $$
begin
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000003',
      pg_temp.order_in_state('PENDING'),
      'ACCEPTED'),
    'ok', 'a waiter may accept an order');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000003',
      pg_temp.order_in_state('ACCEPTED'),
      'PREPARING'),
    'ok', 'a waiter may start an order');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000003',
      pg_temp.order_in_state('READY'),
      'SERVED'),
    'ok', 'a waiter may serve an order');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000003',
      pg_temp.order_in_state('PENDING'),
      'CANCELLED'),
    'ok', 'a waiter may cancel a pending order');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000003',
      pg_temp.order_in_state('PREPARING'),
      'CANCELLED'),
    'ok', 'a waiter may cancel an order being prepared');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000003',
      pg_temp.order_in_state('PREPARING'),
      'READY'),
    '42501:staff_order_status_not_permitted',
    'a waiter may not mark an order ready');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000003',
      pg_temp.order_in_state('PENDING'),
      'PREPARING'),
    '42501:staff_order_status_not_permitted',
    'a waiter may not start an order that was not accepted');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000003',
      pg_temp.order_in_state('READY'),
      'CANCELLED'),
    'P0001:invalid_order_status_transition',
    'a waiter is allowed to try cancelling, and the lifecycle refuses a ready order'
  );
end;
$$;

-- KITCHEN: the kitchen steps, and cancellation.
do $$
begin
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000004',
      pg_temp.order_in_state('ACCEPTED'),
      'PREPARING'),
    'ok', 'a kitchen member may start an accepted order');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000004',
      pg_temp.order_in_state('PREPARING'),
      'READY'),
    'ok', 'a kitchen member may mark an order ready');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000004',
      pg_temp.order_in_state('PENDING'),
      'CANCELLED'),
    'ok', 'a kitchen member may cancel a pending order');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000004',
      pg_temp.order_in_state('PENDING'),
      'ACCEPTED'),
    '42501:staff_order_status_not_permitted',
    'a kitchen member may not accept an order');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000004',
      pg_temp.order_in_state('READY'),
      'SERVED'),
    '42501:staff_order_status_not_permitted',
    'a kitchen member may not serve an order');
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000004',
      pg_temp.order_in_state('PENDING'),
      'SERVED'),
    '42501:staff_order_status_not_permitted',
    'a kitchen member may not skip the whole chain');
end;
$$;

-- CASHIER: nothing, and refused before any lifecycle question is asked.
do $$
begin
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000005',
      pg_temp.order_in_state('PENDING'),
      'ACCEPTED'),
    '42501:staff_order_access_denied',
    'a cashier has no order access at all'
  );
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000005',
      pg_temp.order_in_state('PENDING'),
      'CANCELLED'),
    '42501:staff_order_access_denied',
    'a cashier may not cancel either'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Moving: what the refusals are refused on, and what they leave behind
-- ---------------------------------------------------------------------------

-- A refused move changes nothing and records nothing; an accepted one records exactly
-- one transition, written by the same trigger as any other writer.
do $$
declare
  v_order uuid;
  v_payload jsonb;
  v_keys text;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000003');

  v_order := pg_temp.placed_order();

  v_payload := public.staff_set_order_status(v_order, 'ACCEPTED');

  perform pg_temp.assert_equals(
    v_payload ->> 'id',
    v_order::text,
    'the answer names the order that was moved'
  );
  perform pg_temp.assert_equals(
    v_payload ->> 'status',
    'ACCEPTED',
    'the answer reports the status that was stored'
  );
  perform pg_temp.assert_true(
    v_payload ? 'updated_at',
    'the answer reports when the row changed'
  );

  select string_agg(key, ',' order by key)
    into v_keys
    from jsonb_object_keys(v_payload) as key;

  perform pg_temp.assert_equals(
    v_keys,
    'id,status,updated_at',
    'the answer carries only what a status change changed'
  );

  perform pg_temp.assert_equals(
    pg_temp.recorded_transitions(v_order),
    'PENDING>ACCEPTED',
    'a staff move records exactly one transition'
  );

  -- A refused move by the same waiter: nothing stored, nothing recorded.
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_order_status(%L, ''READY'')',
      v_order
    ),
    '42501',
    'staff_order_status_not_permitted',
    'a waiter is refused the kitchen step'
  );

  perform pg_temp.assert_equals(
    pg_temp.stored_status(v_order),
    'ACCEPTED',
    'a refused move leaves the status where it was'
  );
  perform pg_temp.assert_equals(
    pg_temp.recorded_transitions(v_order),
    'PENDING>ACCEPTED',
    'a refused move records nothing'
  );
end;
$$;

-- Orders that are not the caller's, and arguments that name nothing.
do $$
declare
  v_foreign uuid;
  v_own uuid;
begin
  v_own := pg_temp.placed_order();

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');
  v_foreign := pg_temp.placed_order(
    'b1b1b1b1-1111-4111-8111-111111111111',
    '77777777-7777-7777-7777-777777777778'
  );

  -- The owner of the other restaurant cannot move an order of the first one, and is
  -- told only that it is not theirs.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000007');

  perform pg_temp.assert_fails_with(
    format('select public.staff_set_order_status(%L, ''ACCEPTED'')', v_own),
    '42501',
    'staff_order_access_denied',
    'another restaurant''s owner cannot move this order'
  );
  perform pg_temp.assert_equals(
    pg_temp.stored_status(v_own),
    'PENDING',
    'the order they were refused is untouched'
  );

  -- An order id that does not exist is the same answer as one that is not theirs, so
  -- this function cannot be used to find out which order ids are real.
  perform pg_temp.assert_fails_with(
    'select public.staff_set_order_status(
       ''00000000-0000-4000-8000-000000000000'', ''ACCEPTED'')',
    '42501',
    'staff_order_access_denied',
    'an order id that does not exist is refused the same way'
  );

  -- A deactivated member is refused before any move is considered.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000006');

  perform pg_temp.assert_fails_with(
    format('select public.staff_set_order_status(%L, ''ACCEPTED'')', v_own),
    '42501',
    'staff_order_access_denied',
    'a deactivated member cannot move an order'
  );

  -- Missing arguments are a malformed request rather than a permission problem.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  perform pg_temp.assert_fails_with(
    'select public.staff_set_order_status(null, ''ACCEPTED'')',
    '22023',
    'An order id and a status are required.',
    'a missing order id is refused as a malformed request'
  );
  perform pg_temp.assert_fails_with(
    'select public.staff_set_order_status(
       ''00000000-0000-4000-8000-000000000000'', ''   '')',
    '22023',
    'An order id and a status are required.',
    'a blank status is refused as a malformed request'
  );

  -- A status that is not a state at all is the lifecycle's answer, not the role's,
  -- and the case is exactly as strict as the stored constraint.
  perform pg_temp.assert_fails_with(
    format('select public.staff_set_order_status(%L, ''REFUNDED'')', v_own),
    'P0001',
    'invalid_order_status',
    'a status the lifecycle does not have is refused'
  );
  perform pg_temp.assert_fails_with(
    format('select public.staff_set_order_status(%L, ''accepted'')', v_own),
    'P0001',
    'invalid_order_status',
    'a status in the wrong case is refused'
  );
  perform pg_temp.assert_equals(
    pg_temp.stored_status(v_own),
    'PENDING',
    'a refused status leaves the order where it was'
  );

  -- Whitespace around a real status is trimmed rather than refused, so a client that
  -- sends a padded value is not told its status is unknown.
  perform pg_temp.assert_equals(
    public.staff_set_order_status(v_own, '  ACCEPTED  ') ->> 'status',
    'ACCEPTED',
    'a padded status is trimmed and stored'
  );
  perform pg_temp.assert_equals(
    pg_temp.recorded_transitions(v_own),
    'PENDING>ACCEPTED',
    'the trimmed move is recorded once, as the real transition'
  );

  -- And the owner who was refused another restaurant's order may still move an order of
  -- their own restaurant, so that refusal was about which order was named and not about
  -- who was asking.
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000007', v_foreign, 'ACCEPTED'),
    'ok',
    'the same owner may move an order of their own restaurant'
  );
  perform pg_temp.assert_equals(
    pg_temp.stored_status(v_foreign),
    'ACCEPTED',
    'the order they were allowed to move really moved'
  );
end;
$$;

-- The guard is still on the table, still enabled, and still the thing that refuses an
-- illegal move: the staff function has not replaced it or turned it off.
do $$
declare
  v_trigger record;
begin
  select t.tgname, t.tgenabled
    into v_trigger
    from pg_catalog.pg_trigger as t
   where t.tgrelid = 'public.orders'::regclass
     and t.tgname = 'guard_orders_status_transition'
     and not t.tgisinternal;

  perform pg_temp.assert_true(
    v_trigger.tgname is not null,
    'the lifecycle guard is still on the orders table'
  );
  perform pg_temp.assert_equals(
    v_trigger.tgenabled::text,
    'O',
    'the lifecycle guard is still enabled for every writer'
  );

  select t.tgname, t.tgenabled
    into v_trigger
    from pg_catalog.pg_trigger as t
   where t.tgrelid = 'public.orders'::regclass
     and t.tgname = 'record_orders_status_change'
     and not t.tgisinternal;

  perform pg_temp.assert_equals(
    v_trigger.tgenabled::text,
    'O',
    'the history trigger is still enabled for every writer'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- The guest side is untouched
-- ---------------------------------------------------------------------------

-- The guest who placed an order still reads it, still with the token, and now sees
-- the state staff moved it to: the staff path was added beside the guest one.
set local role anon;

do $$
declare
  v_token text;
  v_payload jsonb;
  v_order uuid;
begin
  -- The guest places an order, so the token and the order are the same one rather
  -- than two unrelated fixtures.
  v_token := public.create_table_order(
    'a1a1a1a1-1111-4111-8111-111111111111',
    '[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 1}]'::jsonb
  ) ->> 'access_token';

  v_order := pg_temp.order_id_for_token(v_token);

  -- Staff move an order. The guest read is called by a guest and the move by a
  -- member, so both are done from this block with the role switched.
  set local role authenticated;
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000003');

  v_payload := public.staff_set_order_status(v_order, 'ACCEPTED');

  perform pg_temp.assert_equals(
    v_payload ->> 'status',
    'ACCEPTED',
    'a waiter accepted the order'
  );

  set local role anon;

  v_payload := public.guest_orders(v_token);

  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 ->> 'status',
    'ACCEPTED',
    'the guest reads back the status staff moved their order to'
  );
  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 ->> 'order_number',
    pg_temp.stored_snapshot(v_order) ->> 'order_number',
    'the guest reads back the same order'
  );
  perform pg_temp.assert_true(
    v_payload::text not like '%access_token%',
    'the guest payload still carries no token of its own'
  );
end;
$$;

reset role;

-- A guest token is not a staff credential. The guest who owns an order cannot move it,
-- even naming its own order id, because the staff functions are not executable by the
-- guest role at all: there is no argument either function takes that a token could go
-- into. The session is the only credential on this side.
do $$
declare
  v_token text;
begin
  v_token := public.create_table_order(
    'a1a1a1a1-1111-4111-8111-111111111111',
    '[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 1}]'::jsonb
  ) ->> 'access_token';

  set local role anon;

  perform pg_temp.assert_denied(
    format(
      'select public.staff_set_order_status(%L, ''ACCEPTED'')',
      pg_temp.order_id_for_token(v_token)::text
    ),
    'a guest cannot move their own order'
  );
  perform pg_temp.assert_denied(
    'select public.staff_list_orders(''11111111-1111-1111-1111-111111111111'')',
    'a guest cannot list a restaurant''s orders'
  );
end;
$$;

reset role;

rollback;