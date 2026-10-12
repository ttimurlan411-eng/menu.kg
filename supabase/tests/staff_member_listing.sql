-- Staff member listing checks: the read-only member list that a restaurant's
-- active owner or manager may ask for.
--
-- Runs against a database where supabase/migrations has been applied, as the table
-- owner (which is also the definer of the staff functions) and as the `anon` and
-- `authenticated` roles with a chosen identity, which is what a real call looks like:
--
--   * the function exists with the argument the client sends, is SECURITY DEFINER
--     with an empty search path, returns jsonb, and only `authenticated` may execute
--     it
--   * no session is refused with 28000
--   * an active OWNER and an active MANAGER may list their restaurant's members
--   * a WAITER, KITCHEN worker, CASHIER, a deactivated member, a signed-in non-member,
--     an owner of another restaurant and a restaurant that does not exist are all
--     refused with 42501 (staff_member_access_denied)
--   * a deactivated OWNER is refused like any other deactivated member: the role does
--     not survive the active flag
--   * the payload carries exactly the approved fields per member, management roles
--     first, active and deactivated members both listed, and nothing belonging to a
--     profile that this step has not approved
--   * the existing staff functions keep their grants and the authorization helper is
--     still in place
--
-- Usage, against a database where supabase/migrations has been applied:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/staff_member_listing.sql
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

-- One member from the payload, by user id, so a test can assert on a known person
-- without depending on the list order.
create or replace function pg_temp.member(
  p_payload jsonb,
  p_user_id uuid
)
returns jsonb
language sql
stable
as $fn$
  select entry
    from jsonb_array_elements(p_payload -> 'members') as listed(entry)
   where entry ->> 'user_id' = p_user_id::text
   limit 1;
$fn$;

-- The roles of one payload, in the order the payload lists them.
create or replace function pg_temp.payload_roles(p_payload jsonb)
returns text
language sql
stable
as $fn$
  select coalesce(
           string_agg(entry ->> 'role', ',' order by ordinal),
           ''
         )
    from jsonb_array_elements(p_payload -> 'members') with ordinality
      as listed(entry, ordinal);
$fn$;

-- The profile id of the first member listed, so ordering can be checked.
create or replace function pg_temp.payload_user_ids(p_payload jsonb)
returns text
language sql
stable
as $fn$
  select coalesce(
           string_agg(entry ->> 'user_id', ',' order by ordinal),
           ''
         )
    from jsonb_array_elements(p_payload -> 'members') with ordinality
      as listed(entry, ordinal);
$fn$;

-- The stored rows, which no client role has any grant on, so these are
-- SECURITY DEFINER. They exist only in this script, which is rolled back.
create or replace function pg_temp.stored_member_id(
  p_restaurant_id uuid,
  p_user_id uuid
)
returns text
language sql
stable
security definer
set search_path = ''
as $fn$
  select stored.id::text
    from public.restaurant_members as stored
   where stored.restaurant_id = p_restaurant_id
     and stored.user_id = p_user_id;
$fn$;

create or replace function pg_temp.stored_display_name(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $fn$
  select stored.full_name
    from public.profiles as stored
   where stored.id = p_user_id;
$fn$;

create or replace function pg_temp.stored_member_count(p_restaurant_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $fn$
  select count(*)::integer
    from public.restaurant_members as stored
   where stored.restaurant_id = p_restaurant_id;
$fn$;

-- ---------------------------------------------------------------------------
-- Fixtures
--
-- Two restaurants. Restaurant A has one member of every role, a deactivated waiter
-- and a deactivated owner; one waiter's profile has no display name, so the null is
-- exercised. Restaurant B is a second restaurant with its own owner. One signed-in
-- user belongs to neither.
-- ---------------------------------------------------------------------------
insert into public.restaurants (id, name, slug)
values
  ('11111111-1111-1111-1111-111111111111', 'Ala-Too', 'ala-too'),
  ('22222222-2222-2222-2222-222222222222', 'Beshkempir', 'beshkempir');

insert into auth.users (id, email)
values
  ('e0000000-0000-4000-8000-000000000001', 'owner-a@example.com'),
  ('e0000000-0000-4000-8000-000000000002', 'manager-a@example.com'),
  ('e0000000-0000-4000-8000-000000000003', 'waiter-a@example.com'),
  ('e0000000-0000-4000-8000-000000000004', 'kitchen-a@example.com'),
  ('e0000000-0000-4000-8000-000000000005', 'cashier-a@example.com'),
  ('e0000000-0000-4000-8000-000000000006', 'inactive-waiter-a@example.com'),
  ('e0000000-0000-4000-8000-000000000007', 'owner-b@example.com'),
  ('e0000000-0000-4000-8000-000000000008', 'outsider@example.com'),
  ('e0000000-0000-4000-8000-000000000009', 'former-owner-a@example.com');

-- The waiter's profile deliberately has no full_name.
insert into public.profiles (id, full_name)
values
  ('e0000000-0000-4000-8000-000000000001', 'Aigerim Owner'),
  ('e0000000-0000-4000-8000-000000000002', 'Bakyt Manager'),
  ('e0000000-0000-4000-8000-000000000003', null),
  ('e0000000-0000-4000-8000-000000000004', 'Daniyar Kitchen'),
  ('e0000000-0000-4000-8000-000000000005', 'Elena Cashier'),
  ('e0000000-0000-4000-8000-000000000006', 'Nurlan Inactive'),
  ('e0000000-0000-4000-8000-000000000007', 'Other Owner'),
  ('e0000000-0000-4000-8000-000000000008', 'Outsider'),
  ('e0000000-0000-4000-8000-000000000009', 'Former Owner');

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
  -- Deactivated: still a member, with no access of any kind.
  ('11111111-1111-1111-1111-111111111111',
   'e0000000-0000-4000-8000-000000000006', 'WAITER', false),
  -- A former owner who is deactivated: the role does not survive the active flag.
  ('11111111-1111-1111-1111-111111111111',
   'e0000000-0000-4000-8000-000000000009', 'OWNER', false),
  -- Belongs to the other restaurant only.
  ('22222222-2222-2222-2222-222222222222',
   'e0000000-0000-4000-8000-000000000007', 'OWNER', true);

-- ---------------------------------------------------------------------------
-- The function exists, takes the argument the client sends, and only
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
     and proname = 'staff_list_restaurant_members';

  perform pg_temp.assert_equals(
    v_arguments,
    'p_restaurant_id',
    'staff_list_restaurant_members takes a restaurant'
  );

  perform pg_temp.assert_true(
    (select prosecdef from pg_catalog.pg_proc
      where pronamespace = 'public'::regnamespace
        and proname = 'staff_list_restaurant_members'),
    'staff_list_restaurant_members runs as its definer'
  );

  perform pg_temp.assert_equals(
    (select pg_catalog.array_to_string(proconfig, ',')
       from pg_catalog.pg_proc
      where pronamespace = 'public'::regnamespace
        and proname = 'staff_list_restaurant_members'),
    'search_path=""',
    'staff_list_restaurant_members runs with an empty search path'
  );

  perform pg_temp.assert_equals(
    (select pg_catalog.format_type(prorettype, null)
       from pg_catalog.pg_proc
      where pronamespace = 'public'::regnamespace
        and proname = 'staff_list_restaurant_members'),
    'jsonb',
    'staff_list_restaurant_members returns jsonb'
  );

  perform pg_temp.assert_true(
    has_function_privilege(
      'authenticated',
      'public.staff_list_restaurant_members(uuid)',
      'execute'
    ),
    'a signed-in client may execute the member list'
  );

  perform pg_temp.assert_true(
    not has_function_privilege(
      'anon',
      'public.staff_list_restaurant_members(uuid)',
      'execute'
    ),
    'a guest may not execute the member list'
  );
end;
$$;

-- The grant is the door: the `anon` role cannot execute the function at all, before
-- any of the checks inside it run. A guest is refused by the privilege system itself,
-- not by the function.
set local role anon;

do $$
begin
  perform pg_temp.assert_fails_with(
    'select public.staff_list_restaurant_members(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'permission denied for function staff_list_restaurant_members',
    'the guest role may not execute the member list at all'
  );
end;
$$;

reset role;
set local role authenticated;

-- ---------------------------------------------------------------------------
-- Access: owners and managers only
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.sign_in(null);

  perform pg_temp.assert_fails_with(
    'select public.staff_list_restaurant_members(
       ''11111111-1111-1111-1111-111111111111'')',
    '28000',
    'Authentication is required to read restaurant members.',
    'listing members without a session is refused'
  );

  -- A signed-in user who belongs to no restaurant.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000008');
  perform pg_temp.assert_fails_with(
    'select public.staff_list_restaurant_members(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_member_access_denied',
    'a signed-in non-member cannot list a restaurant''s members'
  );
  perform pg_temp.assert_fails_with(
    'select public.staff_list_restaurant_members(
       ''99999999-9999-9999-9999-999999999999'')',
    '42501',
    'staff_member_access_denied',
    'a restaurant that does not exist is refused like one that is not ours'
  );

  -- The owner of the other restaurant cannot reach this one.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000007');
  perform pg_temp.assert_fails_with(
    'select public.staff_list_restaurant_members(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_member_access_denied',
    'the other restaurant''s owner cannot list this restaurant''s members'
  );

  -- Working roles have no member-management access.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000003');
  perform pg_temp.assert_fails_with(
    'select public.staff_list_restaurant_members(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_member_access_denied',
    'a waiter cannot list members'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000004');
  perform pg_temp.assert_fails_with(
    'select public.staff_list_restaurant_members(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_member_access_denied',
    'a kitchen worker cannot list members'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000005');
  perform pg_temp.assert_fails_with(
    'select public.staff_list_restaurant_members(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_member_access_denied',
    'a cashier cannot list members'
  );

  -- Deactivated members are refused, including a deactivated owner.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000006');
  perform pg_temp.assert_fails_with(
    'select public.staff_list_restaurant_members(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_member_access_denied',
    'a deactivated waiter cannot list members'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000009');
  perform pg_temp.assert_fails_with(
    'select public.staff_list_restaurant_members(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_member_access_denied',
    'a deactivated owner cannot list members'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- An owner and a manager may list, and a manager is not an owner: both see the same
-- restaurant's members, and neither is given a write
-- ---------------------------------------------------------------------------
do $$
declare
  v_owner_payload jsonb;
  v_manager_payload jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');
  v_owner_payload := public.staff_list_restaurant_members(
    '11111111-1111-1111-1111-111111111111');

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000002');
  v_manager_payload := public.staff_list_restaurant_members(
    '11111111-1111-1111-1111-111111111111');

  perform pg_temp.assert_equals(
    v_owner_payload::text,
    v_manager_payload::text,
    'an owner and a manager are shown the same member list'
  );

  perform pg_temp.assert_equals(
    pg_catalog.jsonb_array_length(v_owner_payload -> 'members')::text,
    pg_temp.stored_member_count('11111111-1111-1111-1111-111111111111')::text,
    'every membership of the restaurant is listed'
  );
  perform pg_temp.assert_equals(
    pg_catalog.jsonb_array_length(v_owner_payload -> 'members')::text,
    '7',
    'the restaurant has seven memberships, active and deactivated'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- The payload: the scope it answered for, the approved fields, and the order
-- ---------------------------------------------------------------------------
do $$
declare
  v_payload jsonb;
  v_member jsonb;
  v_keys text;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');
  v_payload := public.staff_list_restaurant_members(
    '11111111-1111-1111-1111-111111111111');

  perform pg_temp.assert_equals(
    v_payload ->> 'restaurant_id',
    '11111111-1111-1111-1111-111111111111',
    'the payload reports the restaurant that was asked for'
  );

  -- Management roles first, then the working roles; two owners because one owner is
  -- deactivated and still listed.
  perform pg_temp.assert_equals(
    pg_temp.payload_roles(v_payload),
    'OWNER,OWNER,MANAGER,WAITER,WAITER,KITCHEN,CASHIER',
    'the list is ordered management roles first, then by role'
  );

  -- Within a role, a named member comes before a nameless one.
  perform pg_temp.assert_equals(
    pg_temp.member(v_payload, 'e0000000-0000-4000-8000-000000000003') ->> 'role',
    'WAITER',
    'the nameless waiter is still listed'
  );
  perform pg_temp.assert_true(
    pg_temp.member(v_payload, 'e0000000-0000-4000-8000-000000000003')
      -> 'display_name' = 'null'::jsonb,
    'a waiter with no display name reads as null, not as a guessed name'
  );

  -- The member object is exactly the approved fields.
  v_member := pg_temp.member(v_payload, 'e0000000-0000-4000-8000-000000000001');
  select string_agg(key, ',' order by key)
    into v_keys
    from pg_catalog.jsonb_object_keys(v_member) as key;

  perform pg_temp.assert_equals(
    v_keys,
    'display_name,id,is_active,role,user_id',
    'a member carries exactly the approved fields'
  );

  -- The envelope is exactly the scope and the list.
  select string_agg(key, ',' order by key)
    into v_keys
    from pg_catalog.jsonb_object_keys(v_payload) as key;

  perform pg_temp.assert_equals(
    v_keys,
    'members,restaurant_id',
    'the payload carries exactly the member list and the scope'
  );

  -- The member id is the stored membership id, and the display name is the stored
  -- profile name.
  perform pg_temp.assert_equals(
    v_member ->> 'id',
    pg_temp.stored_member_id(
      '11111111-1111-1111-1111-111111111111',
      'e0000000-0000-4000-8000-000000000001'
    ),
    'the member id is the stored restaurant_members id'
  );
  perform pg_temp.assert_equals(
    v_member ->> 'display_name',
    pg_temp.stored_display_name('e0000000-0000-4000-8000-000000000001'),
    'the display name is the stored profile name'
  );
  perform pg_temp.assert_equals(
    v_member ->> 'display_name',
    'Aigerim Owner',
    'the owner''s display name is the one the profile holds'
  );

  -- Active and deactivated members are both listed, marked by is_active.
  perform pg_temp.assert_equals(
    pg_temp.member(v_payload, 'e0000000-0000-4000-8000-000000000001')
      ->> 'is_active',
    'true',
    'an active owner is marked active'
  );
  perform pg_temp.assert_equals(
    pg_temp.member(v_payload, 'e0000000-0000-4000-8000-000000000006')
      ->> 'is_active',
    'false',
    'a deactivated waiter is listed and marked inactive'
  );
  perform pg_temp.assert_equals(
    pg_temp.member(v_payload, 'e0000000-0000-4000-8000-000000000009')
      ->> 'is_active',
    'false',
    'a deactivated owner is listed and marked inactive'
  );

  -- Nothing that is not an approved field, by name or by value.
  perform pg_temp.assert_true(
    v_payload::text not like '%email%'
      and v_payload::text not like '%password%'
      and v_payload::text not like '%access_token%'
      and v_payload::text not like '%phone%'
      and v_payload::text not like '%avatar%',
    'no email, password, token, phone or avatar is in the payload'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- A restaurant's members are its own, and its owner cannot reach another's
-- ---------------------------------------------------------------------------
do $$
declare
  v_payload jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000007');
  v_payload := public.staff_list_restaurant_members(
    '22222222-2222-2222-2222-222222222222');

  perform pg_temp.assert_equals(
    pg_catalog.jsonb_array_length(v_payload -> 'members')::text,
    '1',
    'the other restaurant''s owner sees only that restaurant''s one member'
  );
  perform pg_temp.assert_equals(
    pg_temp.member(v_payload, 'e0000000-0000-4000-8000-000000000007') ->> 'role',
    'OWNER',
    'the other restaurant''s list holds its own owner'
  );

  -- None of the first restaurant's members leaked across.
  perform pg_temp.assert_true(
    pg_temp.member(v_payload, 'e0000000-0000-4000-8000-000000000001')
      is null,
    'one restaurant''s member list names no member of the other'
  );
end;
$$;

reset role;

-- ---------------------------------------------------------------------------
-- The existing staff controls are untouched
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.assert_true(
    to_regprocedure('private.has_restaurant_role(uuid, text[])') is not null,
    'the role helper the listing reuses still exists'
  );

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
      'public.staff_list_order_history(uuid, uuid, integer, timestamptz, bigint)',
      'execute'
    )
    and has_function_privilege(
      'authenticated',
      'public.staff_list_reservations(uuid, uuid, date, integer)',
      'execute'
    ),
    'the existing staff functions keep their execute grant'
  );

  perform pg_temp.assert_true(
    not has_function_privilege(
      'anon',
      'public.staff_list_restaurant_members(uuid)',
      'execute'
    ),
    'the member list stays out of a guest''s hands'
  );
end;
$$;

rollback;
