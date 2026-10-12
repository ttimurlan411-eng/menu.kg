-- Staff order-history checks: the read that returns a restaurant's whole order list,
-- every status, newest first, one keyset page at a time.
--
-- Runs against a database where supabase/migrations has been applied, as the table
-- owner (which is also the definer of the staff functions) and as the `anon` and
-- `authenticated` roles with a chosen identity, which is what a real call looks like:
--
--   * the function exists with the arguments the client sends, is SECURITY DEFINER
--     with an empty search path, returns jsonb, and only `authenticated` may execute
--     it
--   * it returns every status, the terminal SERVED and CANCELLED included, newest
--     first by created_at then order_number
--   * keyset pagination walks the whole list page by page with no overlap and no gap,
--     including a page boundary that falls inside a created_at tie
--   * has_more and next_cursor say whether another page exists, and next_cursor is
--     the last returned row's own (created_at, order_number); the last page carries
--     null and has_more false
--   * a cursor at or past the end returns an empty last page, not an error
--   * the branch filter divides one restaurant's history and cannot reach another's
--     branch
--   * the access matrix is the other staff reads': no session is refused with 28000,
--     a non-member, a deactivated member and a cashier with 42501
--     (`staff_order_access_denied`), and a restaurant that does not exist is refused
--     the same way as one that is simply not the caller's
--   * the payload is exactly the shape `staff_list_orders` returns plus has_more and
--     next_cursor, and nothing that belongs to the guest
--   * p_limit is clamped to 1..200, default 50, not obeyed
--   * the existing staff reads and their grants are unchanged
--
-- Usage, against a database where supabase/migrations has been applied:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/staff_order_history.sql
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

create or replace function pg_temp.stored_created_at(p_order uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $fn$
  select stored.created_at
    from public.orders as stored
   where stored.id = p_order;
$fn$;

-- The order numbers of a restaurant's whole stored history, in the read's sort order
-- (created_at desc, order_number desc), optionally narrowed to one branch.
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
           string_agg(
             stored.order_number::text,
             ',' order by stored.created_at desc, stored.order_number desc
           ),
           ''
         )
    from public.orders as stored
   where stored.restaurant_id = p_restaurant_id
     and (p_branch_id is null or stored.branch_id = p_branch_id);
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
-- something to divide. Seven orders are placed in A; three of them share one
-- created_at, so the page boundary can be made to fall inside a tie. Every one of
-- the six lifecycle states is present in A.
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
-- explicitly below to give the read a deterministic order. Restaurant A's order
-- numbers run 1..7 in the order they are placed here.
create temporary table pg_temp.fixture (
  name text primary key,
  order_id uuid not null
);

insert into pg_temp.fixture (name, order_id) values
  ('newest',
   pg_temp.placed_order(
     'a1a1a1a1-1111-4111-8111-111111111111',
     '77777777-7777-7777-7777-777777777771')),
  ('second',
   pg_temp.placed_order(
     'a1a1a1a1-1111-4111-8111-111111111111',
     '77777777-7777-7777-7777-777777777771')),
  ('third',
   pg_temp.placed_order(
     'a1a1a1a1-1111-4111-8111-111111111111',
     '77777777-7777-7777-7777-777777777771')),
  ('tie_a',
   pg_temp.placed_order(
     'a1a1a1a1-1111-4111-8111-111111111111',
     '77777777-7777-7777-7777-777777777771')),
  ('tie_b',
   pg_temp.placed_order(
     'a1a1a1a1-1111-4111-8111-111111111111',
     '77777777-7777-7777-7777-777777777771')),
  ('tie_c',
   pg_temp.placed_order(
     'a1a1a1a1-1111-4111-8111-111111111111',
     '77777777-7777-7777-7777-777777777771')),
  ('oldest_branch', -- in the Airport branch, so the branch filter has to work
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

-- Every status is represented among restaurant A's orders.
select pg_temp.walk_to((select order_id from pg_temp.fixture where name = 'newest'), 'SERVED');
select pg_temp.walk_to((select order_id from pg_temp.fixture where name = 'second'), 'CANCELLED');
select pg_temp.walk_to((select order_id from pg_temp.fixture where name = 'tie_a'), 'ACCEPTED');
select pg_temp.walk_to((select order_id from pg_temp.fixture where name = 'tie_b'), 'PREPARING');
select pg_temp.walk_to((select order_id from pg_temp.fixture where name = 'tie_c'), 'READY');
-- 'third' stays PENDING.

-- The newest rows are the newest, and the three tie_* orders share one created_at.
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'newest'),
  now() - interval '1 hour');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'second'),
  now() - interval '2 hours');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'third'),
  now() - interval '3 hours');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'tie_a'),
  now() - interval '4 hours');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'tie_b'),
  now() - interval '4 hours');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'tie_c'),
  now() - interval '4 hours');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'oldest_branch'),
  now() - interval '5 hours');
select pg_temp.set_created_at(
  (select order_id from pg_temp.fixture where name = 'other_restaurant'),
  now() - interval '6 hours');

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
     and proname = 'staff_list_order_history';

  perform pg_temp.assert_equals(
    v_arguments,
    'p_restaurant_id,p_branch_id,p_limit,p_before_created_at,p_before_order_number',
    'staff_list_order_history takes a restaurant, an optional branch, a limit and a two-part cursor'
  );

  perform pg_temp.assert_true(
    (select prosecdef from pg_catalog.pg_proc
      where pronamespace = 'public'::regnamespace
        and proname = 'staff_list_order_history'),
    'staff_list_order_history runs as its definer'
  );

  perform pg_temp.assert_equals(
    (select pg_catalog.array_to_string(proconfig, ',')
       from pg_catalog.pg_proc
      where pronamespace = 'public'::regnamespace
        and proname = 'staff_list_order_history'),
    'search_path=""',
    'staff_list_order_history runs with an empty search path'
  );

  perform pg_temp.assert_true(
    has_function_privilege(
      'authenticated',
      'public.staff_list_order_history(uuid, uuid, integer, timestamptz, bigint)',
      'execute'
    ),
    'a signed-in client may execute the history read'
  );

  perform pg_temp.assert_true(
    not has_function_privilege(
      'anon',
      'public.staff_list_order_history(uuid, uuid, integer, timestamptz, bigint)',
      'execute'
    ),
    'a guest may not execute the history read'
  );

  -- The cursor's order number is bigint, matching public.orders.order_number, so a
  -- cursor for a large order number is not silently narrowed away.
  perform pg_temp.assert_equals(
    (select pg_catalog.format_type(proargtypes[4], null)
       from pg_catalog.pg_proc
      where pronamespace = 'public'::regnamespace
        and proname = 'staff_list_order_history'),
    'bigint',
    'the history cursor''s order number is bigint, as the column is'
  );

  perform pg_temp.assert_true(
    exists (
      select 1 from pg_catalog.pg_indexes
       where schemaname = 'public'
         and indexname = 'idx_orders_history_restaurant_created_at'
         and indexdef ilike '%restaurant_id%created_at%order_number%'
    ),
    'the history read has its composite (restaurant, created_at, order_number) index'
  );
end;
$$;

set local role authenticated;

-- ---------------------------------------------------------------------------
-- Access: the same matrix as the other staff reads
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.sign_in(null);

  perform pg_temp.assert_fails_with(
    'select public.staff_list_order_history(
       ''11111111-1111-1111-1111-111111111111'')',
    '28000',
    'Authentication is required to read restaurant orders.',
    'reading history without a session is refused'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000008');

  perform pg_temp.assert_fails_with(
    'select public.staff_list_order_history(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_order_access_denied',
    'a signed-in non-member cannot read a restaurant''s history'
  );
  perform pg_temp.assert_fails_with(
    'select public.staff_list_order_history(
       ''99999999-9999-9999-9999-999999999999'')',
    '42501',
    'staff_order_access_denied',
    'a restaurant that does not exist is refused like one that is not ours'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000006');
  perform pg_temp.assert_fails_with(
    'select public.staff_list_order_history(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_order_access_denied',
    'a deactivated member cannot read the restaurant''s history'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000005');
  perform pg_temp.assert_fails_with(
    'select public.staff_list_order_history(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_order_access_denied',
    'a cashier cannot read the restaurant''s history'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000007');
  perform pg_temp.assert_fails_with(
    'select public.staff_list_order_history(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_order_access_denied',
    'the other restaurant''s owner cannot read this restaurant''s history'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Every status, newest first, one page at a time
-- ---------------------------------------------------------------------------
do $$
declare
  v_payload jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_payload := public.staff_list_order_history(
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

  -- The default page is 50, which is more than the fixture, so the whole history is
  -- returned in the read's order, every status.
  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(v_payload),
    pg_temp.stored_order_numbers('11111111-1111-1111-1111-111111111111'),
    'the default page returns the whole history, newest first'
  );
  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(v_payload),
    '1,2,3,6,5,4,7',
    'the order is created_at desc, with order_number desc breaking the create-time tie'
  );

  -- All six lifecycle states are present, terminal ones included.
  perform pg_temp.assert_true(
    (select count(distinct entry ->> 'status')
       from jsonb_array_elements(v_payload -> 'orders') as listed(entry)) = 6,
    'every one of the six statuses is in the history'
  );
  perform pg_temp.assert_true(
    exists (
      select 1
        from jsonb_array_elements(v_payload -> 'orders') as listed(entry)
       where listed.entry ->> 'status' in ('SERVED', 'CANCELLED')
    ),
    'terminal SERVED and CANCELLED orders are in the history'
  );

  -- The last page: the whole fixture fits on one page, so nothing follows it.
  perform pg_temp.assert_equals(
    (v_payload ->> 'has_more')::text,
    'false',
    'a page that is the whole history reports has_more false'
  );
  perform pg_temp.assert_true(
    v_payload -> 'next_cursor' = 'null'::jsonb,
    'the last page carries a null next_cursor'
  );

  -- Nothing from the other restaurant.
  perform pg_temp.assert_true(
    v_payload::text not like '%Kebab%',
    'the payload holds nothing from the other restaurant'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Keyset pagination: page by page, no overlap, no gap, tie boundary included
-- ---------------------------------------------------------------------------
do $$
declare
  v_page1 jsonb;
  v_page2 jsonb;
  v_page3 jsonb;
  v_cursor1_created_at text;
  v_cursor1_order_number text;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  -- Page one is four rows. Row four and row five share a created_at, so the page
  -- boundary falls inside the tie.
  v_page1 := public.staff_list_order_history(
    '11111111-1111-1111-1111-111111111111', null, 4);

  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(v_page1),
    '1,2,3,6',
    'the first page is the four newest orders'
  );
  perform pg_temp.assert_equals(
    (v_page1 ->> 'has_more')::text,
    'true',
    'a full page with rows behind it reports has_more true'
  );
  perform pg_temp.assert_true(
    (v_page1 -> 'next_cursor') ? 'created_at'
      and (v_page1 -> 'next_cursor') ? 'order_number',
    'next_cursor carries both halves of the key'
  );

  v_cursor1_created_at := v_page1 -> 'next_cursor' ->> 'created_at';
  v_cursor1_order_number := v_page1 -> 'next_cursor' ->> 'order_number';

  perform pg_temp.assert_equals(
    v_cursor1_order_number,
    '6',
    'next_cursor names the last returned row, not the first row that was cut off'
  );
  perform pg_temp.assert_equals(
    v_cursor1_created_at::timestamptz::text,
    pg_temp.stored_created_at(
      (select order_id from pg_temp.fixture where name = 'tie_c'))::text,
    'next_cursor''s created_at is the last returned row''s own'
  );

  -- Page two continues across the tie.
  v_page2 := public.staff_list_order_history(
    '11111111-1111-1111-1111-111111111111',
    null,
    4,
    v_cursor1_created_at::timestamptz,
    v_cursor1_order_number::bigint
  );

  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(v_page2),
    '5,4,7',
    'the second page continues exactly after the first, across the create-time tie'
  );
  perform pg_temp.assert_equals(
    (v_page2 ->> 'has_more')::text,
    'false',
    'the second page is the last, so has_more is false'
  );
  perform pg_temp.assert_true(
    v_page2 -> 'next_cursor' = 'null'::jsonb,
    'the last page carries a null next_cursor'
  );

  -- The two pages together are the whole history, with no repeat and no hole.
  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(v_page1) || ',' ||
      pg_temp.payload_order_numbers(v_page2),
    pg_temp.stored_order_numbers('11111111-1111-1111-1111-111111111111'),
    'the pages together are the whole history, with no overlap and no gap'
  );

  -- A cursor on the last tie row in sort order (the lowest order number of the
  -- group): strictly older rows only.
  v_page3 := public.staff_list_order_history(
    '11111111-1111-1111-1111-111111111111',
    null,
    4,
    pg_temp.stored_created_at(
      (select order_id from pg_temp.fixture where name = 'tie_a')),
    (select pg_temp.stored_order_number(
       (select order_id from pg_temp.fixture where name = 'tie_a'))::bigint)
  );

  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(v_page3),
    '7',
    'a cursor on the last tie row returns only the rows strictly older'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- The end of the history, and a partial cursor
-- ---------------------------------------------------------------------------
do $$
declare
  v_empty jsonb;
  v_partial jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  -- A cursor older than every row: an empty last page, not an error.
  v_empty := public.staff_list_order_history(
    '11111111-1111-1111-1111-111111111111',
    null,
    4,
    now() - interval '10 hours',
    0::bigint
  );

  perform pg_temp.assert_equals(
    jsonb_array_length(v_empty -> 'orders')::text,
    '0',
    'a cursor past the end returns an empty page'
  );
  perform pg_temp.assert_equals(
    (v_empty ->> 'has_more')::text,
    'false',
    'the empty page reports no more'
  );
  perform pg_temp.assert_true(
    v_empty -> 'next_cursor' = 'null'::jsonb,
    'the empty page carries no cursor'
  );

  -- A partial cursor (one half only) is a first-page request, not a half-open read:
  -- it returns the same newest rows a first page does.
  v_partial := public.staff_list_order_history(
    '11111111-1111-1111-1111-111111111111',
    null,
    4,
    now() - interval '4 hours',
    null
  );
  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(v_partial),
    '1,2,3,6',
    'a partial cursor is treated as a first-page request'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Branch filter: divides one restaurant's history, never another's branch
-- ---------------------------------------------------------------------------
do $$
declare
  v_branch_center jsonb;
  v_branch_airport jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_branch_center := public.staff_list_order_history(
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333331'
  );
  perform pg_temp.assert_equals(
    v_branch_center ->> 'branch_id',
    '33333333-3333-3333-3333-333333333331',
    'the payload reports the branch that was asked for'
  );
  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(v_branch_center),
    pg_temp.stored_order_numbers(
      '11111111-1111-1111-1111-111111111111',
      '33333333-3333-3333-3333-333333333331'
    ),
    'a branch filter returns that branch''s history only'
  );

  v_branch_airport := public.staff_list_order_history(
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333332'
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_branch_airport -> 'orders')::text,
    '1',
    'the other branch of the same restaurant returns its own one order'
  );

  -- A branch id belonging to the other restaurant cannot be used to read it: it
  -- matches no order of this restaurant's and returns an empty list.
  perform pg_temp.assert_equals(
    pg_temp.payload_order_numbers(
      public.staff_list_order_history(
        '11111111-1111-1111-1111-111111111111',
        '44444444-4444-4444-4444-444444444444'
      )
    ),
    '',
    'a branch of another restaurant matches no order'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- What one history order looks like, and what must not be there
-- ---------------------------------------------------------------------------
do $$
declare
  v_payload jsonb;
  v_order jsonb;
  v_stored jsonb;
  v_keys text;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_payload := public.staff_list_order_history(
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333331'
  );

  v_order := v_payload -> 'orders' -> 0;
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
    jsonb_array_length(v_order -> 'items')::text,
    pg_temp.stored_line_count((v_order ->> 'id')::uuid)::text,
    'every stored line is in the payload'
  );
  perform pg_temp.assert_equals(
    v_order -> 'items' -> 0 ->> 'product_name',
    pg_temp.stored_first_line((v_order ->> 'id')::uuid) ->> 'product_name',
    'a line carries the product name as it was ordered'
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

  -- The order object is exactly the fields the unpaginated read sends.
  select string_agg(key, ',' order by key)
    into v_keys
    from jsonb_object_keys(v_order) as key;

  perform pg_temp.assert_equals(
    v_keys,
    'branch_id,created_at,currency,id,item_count,items,order_number,status,table,total,updated_at',
    'a history order carries exactly the fields a screen needs'
  );

  -- The envelope is the unpaginated read's envelope plus the two paging fields.
  select string_agg(key, ',' order by key)
    into v_keys
    from jsonb_object_keys(v_payload) as key;

  perform pg_temp.assert_equals(
    v_keys,
    'branch_id,has_more,next_cursor,orders,restaurant_id',
    'the payload is the staff envelope plus has_more and next_cursor'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- p_limit is clamped to 1..200, default 50, not obeyed
-- ---------------------------------------------------------------------------
do $$
declare
  v_payload jsonb;
  v_total integer;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_total := pg_temp.stored_order_count('11111111-1111-1111-1111-111111111111');

  perform pg_temp.assert_equals(
    v_total::text,
    '7',
    'the fixture has seven orders to bound the default against'
  );

  v_payload := public.staff_list_order_history(
    '11111111-1111-1111-1111-111111111111', null, 1);
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    '1',
    'a limit of one returns one order'
  );

  v_payload := public.staff_list_order_history(
    '11111111-1111-1111-1111-111111111111', null, 0);
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    '1',
    'a limit of zero is clamped up to one rather than returning nothing'
  );

  v_payload := public.staff_list_order_history(
    '11111111-1111-1111-1111-111111111111', null, -5);
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    '1',
    'a negative limit is clamped up to one'
  );

  v_payload := public.staff_list_order_history(
    '11111111-1111-1111-1111-111111111111', null, 1000000);
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    v_total::text,
    'a limit above the ceiling returns the whole history'
  );

  v_payload := public.staff_list_order_history(
    '11111111-1111-1111-1111-111111111111', null, null);
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'orders')::text,
    v_total::text,
    'an absent limit falls back to the default, which returns the whole fixture'
  );
end;
$$;

reset role;

-- ---------------------------------------------------------------------------
-- The existing staff reads are untouched
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.assert_true(
    has_function_privilege(
      'authenticated',
      'public.staff_list_orders(uuid, uuid, integer)',
      'execute'
    )
    and has_function_privilege(
      'authenticated',
      'public.staff_list_active_orders(uuid, uuid, integer)',
      'execute'
    )
    and has_function_privilege(
      'authenticated',
      'public.staff_set_order_status(uuid, text)',
      'execute'
    ),
    'the existing staff functions keep their execute grant'
  );

  perform pg_temp.assert_true(
    not has_function_privilege(
      'anon',
      'public.staff_list_order_history(uuid, uuid, integer, timestamptz, bigint)',
      'execute'
    ),
    'the history read stays out of a guest''s hands'
  );
end;
$$;

rollback;
