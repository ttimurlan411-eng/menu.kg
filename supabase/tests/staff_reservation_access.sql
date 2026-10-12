-- Staff reservation access checks: who may read a restaurant's reservations, who may
-- cancel one, and what is refused to everyone else.
--
-- Runs against a database where supabase/migrations has been applied, as the table
-- owner (which is also the definer of the staff functions) and as the `anon` and
-- `authenticated` roles with a chosen identity, which is what a real call looks
-- like:
--
--   * a guest cannot call either staff function, and no grant on the reservation
--     tables exists for either client role: the two functions are the only way in
--   * `private.can_read_restaurant_reservations` is not callable by a client at all
--   * the helper's role matrix holds: OWNER, MANAGER and WAITER may work a
--     restaurant's reservations, KITCHEN, CASHIER, an inactive membership, a
--     non-member and a member of another restaurant may not
--   * a call with no session is refused; so is a call from a signed-in user who is
--     not an active member of the restaurant; so is one that names a restaurant or
--     a reservation that does not exist, with the same answer as belonging to
--     somebody else
--   * a member reads only their own restaurant, optionally one branch and one date,
--     and a branch of another restaurant matches nothing rather than leaking it
--   * the payload carries the reservation header the Bookings screen renders, and no
--     guest access token and no reservation_access row, by name or by value
--   * p_limit is clamped rather than obeyed, including the 100 ceiling
--   * the one status move this phase defines, CONFIRMED -> CANCELLED, works for the
--     roles that work reservations, and every other move is refused: a move the
--     schema cannot hold, a move the phase does not define, and a cross-restaurant
--     move all leave the row untouched
--   * the guest read path is untouched and still reports the state staff moved the
--     reservation to
--
-- Usage, against a database where supabase/migrations has been applied:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/staff_reservation_access.sql
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
-- share 42501 are different answers: a reservation that is not the caller's, and a
-- move this phase does not define. A client maps them to different wording, so they
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

-- A freshly booked reservation, through the guest's own function, so every
-- reservation below is a real one rather than a hand-built row.
--
-- p_qr_token selects the table the reservation belongs to, which is how a
-- reservation gets into a chosen branch and restaurant.
create or replace function pg_temp.placed_reservation(
  p_qr_token text default 'a1a1a1a1-1111-4111-8111-111111111111',
  p_reserved_date date default current_date + 1,
  p_reserved_time time default '19:00',
  p_guest_name text default 'Askar',
  p_guest_count integer default 2
)
returns uuid
language plpgsql
volatile
as $$
declare
  v_id text;
begin
  v_id := public.create_table_reservation(
    p_qr_token,
    p_reserved_date,
    p_reserved_time,
    p_guest_name,
    p_guest_count,
    null
  ) -> 'reservation' ->> 'id';

  return v_id::uuid;
end;
$$;

-- A reservation already in a state other than CONFIRMED, walked there through a
-- write the owner may make, so a refused transition starts from a row the schema
-- really holds. Only CANCELLED exists beside CONFIRMED.
create or replace function pg_temp.reservation_in_state(
  p_state text,
  p_qr_token text default 'a1a1a1a1-1111-4111-8111-111111111111',
  p_reserved_date date default current_date + 1,
  p_reserved_time time default '19:00'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid := pg_temp.placed_reservation(
    p_qr_token, p_reserved_date, p_reserved_time
  );
begin
  if p_state = 'CANCELLED' then
    update public.reservations set status = 'CANCELLED' where id = v_id;
  elsif p_state = 'CONFIRMED' then
    null;
  else
    raise exception 'FAILED: unknown reservation state %', p_state
      using errcode = 'P0001';
  end if;

  return v_id;
end;
$$;

-- Attempts one staff status change as [p_user], and reports what happened as
-- '<sqlstate>:<message>', or 'ok'.
--
-- Deliberately not SECURITY DEFINER: it must run as the client role, so that calling
-- the staff function here proves the function is executable by that role and not
-- merely by its definer. The answer is a single line a test can compare exactly, and
-- catching the error leaves the attempt rolled back to its own savepoint, so the
-- reservation stays usable for the assertions that follow.
create or replace function pg_temp.staff_move(
  p_user uuid,
  p_reservation uuid,
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
    perform public.staff_set_reservation_status(p_reservation, p_to);
    v_result := 'ok';
  exception
    when others then
      v_result := sqlstate || ':' || sqlerrm;
  end;

  perform pg_temp.sign_in(null);

  return v_result;
end;
$$;

-- The reservation ids of one payload, in the order the payload lists them.
create or replace function pg_temp.payload_reservation_ids(p_payload jsonb)
returns text
language sql
stable
as $fn$
  select coalesce(
           string_agg(entry ->> 'id', ',' order by ordinal),
           ''
         )
    from jsonb_array_elements(p_payload -> 'reservations') with ordinality
      as listed(entry, ordinal);
$fn$;

-- What the payload is compared against.
--
-- These read the reservation tables, which no client role has any grant on, so they
-- are SECURITY DEFINER: a test that compares a payload against the stored rows has
-- to ask something that may read them. They exist only in this script, which is
-- rolled back.
create or replace function pg_temp.stored_reservation_ids(
  p_restaurant_id uuid,
  p_branch_id uuid default null,
  p_date date default null
)
returns text
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(
           string_agg(stored.id::text, ',' order by
             stored.reserved_date,
             stored.reserved_time,
             stored.created_at,
             stored.id
           ),
           ''
         )
    from public.reservations as stored
   where stored.restaurant_id = p_restaurant_id
     and (p_branch_id is null or stored.branch_id = p_branch_id)
     and (p_date is null or stored.reserved_date = p_date);
$fn$;

create or replace function pg_temp.stored_reservation_count(
  p_restaurant_id uuid,
  p_branch_id uuid default null,
  p_date date default null
)
returns integer
language sql
stable
security definer
set search_path = ''
as $fn$
  select count(*)::integer
    from public.reservations as stored
   where stored.restaurant_id = p_restaurant_id
     and (p_branch_id is null or stored.branch_id = p_branch_id)
     and (p_date is null or stored.reserved_date = p_date);
$fn$;

create or replace function pg_temp.stored_snapshot(p_reservation uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select to_jsonb(stored)
    from public.reservations as stored
   where stored.id = p_reservation;
$fn$;

create or replace function pg_temp.stored_status(p_reservation uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $fn$
  select stored.status
    from public.reservations as stored
   where stored.id = p_reservation;
$fn$;

-- The reservation a guest token owns, so a guest-role block can name an id without
-- being able to read the reservations table.
create or replace function pg_temp.reservation_id_for_token(p_token text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $fn$
  select stored.id
    from public.reservations as stored
   where stored.access_token = pg_catalog.btrim(p_token);
$fn$;

-- ---------------------------------------------------------------------------
-- Fixtures
--
-- Three restaurants, so a leak between them is a wrong answer rather than an empty
-- one. Restaurant A has two branches, so the branch filter has something to divide.
-- Restaurant C is only for the limit ceiling, so the 101 rows it holds never disturb
-- the read counts A is checked against.
-- ---------------------------------------------------------------------------
insert into public.restaurants (id, name, slug)
values
  ('11111111-1111-1111-1111-111111111111', 'Ala-Too', 'ala-too'),
  ('22222222-2222-2222-2222-222222222222', 'Beshkempir', 'beshkempir'),
  ('55555555-5555-5555-5555-555555555555', 'Ceiling', 'ceiling');

insert into public.branches (id, restaurant_id, name)
values
  ('33333333-3333-3333-3333-333333333333',
   '11111111-1111-1111-1111-111111111111', 'Center'),
  ('33333333-3333-3333-3333-333333333334',
   '11111111-1111-1111-1111-111111111111', 'Airport'),
  ('44444444-4444-4444-4444-444444444444',
   '22222222-2222-2222-2222-222222222222', 'Airport'),
  ('66666666-6666-6666-6666-666666666666',
   '55555555-5555-5555-5555-555555555555', 'Only');

insert into public.tables (
  id, restaurant_id, branch_id, table_number, name, capacity, qr_token
)
values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333333', '12', 'Window', 6,
   'a1a1a1a1-1111-4111-8111-111111111111'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaab',
   '11111111-1111-1111-1111-111111111111',
   '33333333-3333-3333-3333-333333333334', '3', null, 4,
   'a2a2a2a2-2222-4222-8222-222222222222'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   '22222222-2222-2222-2222-222222222222',
   '44444444-4444-4444-4444-444444444444', '1', 'Bar', 4,
   'b1b1b1b1-1111-4111-8111-111111111111'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc',
   '55555555-5555-5555-5555-555555555555',
   '66666666-6666-6666-6666-666666666666', '1', 'Ceiling', 500,
   'c1c1c1c1-1111-4111-8111-111111111111');

-- Staff, one membership each, plus the awkward cases: a member whose membership has
-- been deactivated, a member of another restaurant only, a signed-in user with no
-- membership at all, someone who belongs to both restaurants, and the owner of the
-- ceiling restaurant.
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
  ('e0000000-0000-4000-8000-000000000009'::uuid),
  ('e0000000-0000-4000-8000-000000000010'::uuid)
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
   'e0000000-0000-4000-8000-000000000009', 'WAITER', true),
  -- Owner of the ceiling restaurant.
  ('55555555-5555-5555-5555-555555555555',
   'e0000000-0000-4000-8000-000000000010', 'OWNER', true);

-- The reservations every read test is about, so the branches and the dates have
-- something to divide: two in A's first branch on the first day, one in A's first
-- branch on the second day, one in A's second branch, one in the other restaurant.
select pg_temp.placed_reservation(
  'a1a1a1a1-1111-4111-8111-111111111111', current_date + 1, '19:00', 'Askar', 3);
select pg_temp.placed_reservation(
  'a1a1a1a1-1111-4111-8111-111111111111', current_date + 1, '20:00', 'Nurlan', 2);
select pg_temp.placed_reservation(
  'a1a1a1a1-1111-4111-8111-111111111111', current_date + 2, '19:00', 'Timur', 4);
select pg_temp.placed_reservation(
  'a2a2a2a2-2222-4222-8222-222222222222', current_date + 1, '19:00', 'Aizada', 2);
select pg_temp.placed_reservation(
  'b1b1b1b1-1111-4111-8111-111111111111', current_date + 1, '19:00', 'Other', 2);

-- Reservations the status tests move: fresh CONFIRMED rows for each role, one
-- already cancelled, and one belonging to the other restaurant.
select pg_temp.placed_reservation(
  'a1a1a1a1-1111-4111-8111-111111111111', current_date + 3, '19:00', 'Owner', 2);
select pg_temp.placed_reservation(
  'a1a1a1a1-1111-4111-8111-111111111111', current_date + 3, '20:00', 'Waiter', 2);
select pg_temp.placed_reservation(
  'a1a1a1a1-1111-4111-8111-111111111111', current_date + 3, '21:00', 'Manager', 2);
select pg_temp.reservation_in_state(
  'CANCELLED', 'a1a1a1a1-1111-4111-8111-111111111111',
  current_date + 3, '22:00');
select pg_temp.placed_reservation(
  'b1b1b1b1-1111-4111-8111-111111111111', current_date + 3, '19:00', 'Foreign', 2);

-- 101 bookings in the ceiling restaurant, on one table and one day, so a request
-- for more than 100 has more than 100 to return and the ceiling is observable.
do $$
declare
  v_minute integer;
begin
  for v_minute in 0..100 loop
    perform pg_temp.placed_reservation(
      'c1c1c1c1-1111-4111-8111-111111111111',
      current_date + 1,
      ('00:00'::time + make_interval(mins => v_minute))::time,
      'Ceiling ' || v_minute::text,
      2
    );
  end loop;
end;
$$;

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
     and proname = 'staff_list_reservations';

  perform pg_temp.assert_equals(
    v_arguments,
    'p_restaurant_id,p_branch_id,p_date,p_limit',
    'staff_list_reservations takes a restaurant, an optional branch, an optional date and a limit'
  );

  -- The status function deliberately takes no restaurant: the reservation id
  -- resolves it. An argument here would be one more thing for a client to name
  -- wrongly, and the membership is checked against the reservation's own restaurant
  -- either way.
  select pg_catalog.array_to_string(proargnames, ',')
    into v_arguments
    from pg_catalog.pg_proc
   where pronamespace = 'public'::regnamespace
     and proname = 'staff_set_reservation_status';

  perform pg_temp.assert_equals(
    v_arguments,
    'p_reservation_id,p_new_status',
    'staff_set_reservation_status takes only a reservation id and a status'
  );

  -- The functions must not name the guest token anywhere in their bodies: a payload
  -- that never selects it cannot leak it.
  select pg_catalog.pg_get_functiondef(p.oid)
    into v_source
    from pg_catalog.pg_proc as p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'staff_list_reservations';

  perform pg_temp.assert_true(
    v_source not like '%access_token%',
    'staff_list_reservations never selects the guest access token'
  );

  select pg_catalog.pg_get_functiondef(p.oid)
    into v_source
    from pg_catalog.pg_proc as p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'staff_set_reservation_status';

  perform pg_temp.assert_true(
    v_source not like '%access_token%',
    'staff_set_reservation_status never touches the guest access token'
  );
  perform pg_temp.assert_true(
    v_source like '%update public.reservations%',
    'staff_set_reservation_status writes by updating the reservations table, not by another route'
  );
  perform pg_temp.assert_true(
    v_source not like '%PENDING%' and v_source not like '%REJECTED%',
    'staff_set_reservation_status knows no PENDING or REJECTED status'
  );
end;
$$;

-- The three functions run as their definer with an empty search path, so none can
-- be walked into another schema's objects.
do $$
declare
  v_function record;
begin
  for v_function in
    select p.proname, p.prosecdef, p.proconfig
      from pg_catalog.pg_proc as p
     where (p.pronamespace = 'public'::regnamespace
            and p.proname in
              ('staff_list_reservations', 'staff_set_reservation_status'))
        or (p.pronamespace = 'private'::regnamespace
            and p.proname = 'can_read_restaurant_reservations')
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

-- The authorization helper's matrix, asked as the definer so the answer can be
-- observed directly. It delegates to private.has_restaurant_role, which excludes an
-- inactive membership, so this is the whole role model in one place.
do $$
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');
  perform pg_temp.assert_true(
    private.can_read_restaurant_reservations(
      '11111111-1111-1111-1111-111111111111'
    ),
    'an owner may read reservations'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000002');
  perform pg_temp.assert_true(
    private.can_read_restaurant_reservations(
      '11111111-1111-1111-1111-111111111111'
    ),
    'a manager may read reservations'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000003');
  perform pg_temp.assert_true(
    private.can_read_restaurant_reservations(
      '11111111-1111-1111-1111-111111111111'
    ),
    'a waiter may read reservations'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000004');
  perform pg_temp.assert_true(
    not private.can_read_restaurant_reservations(
      '11111111-1111-1111-1111-111111111111'
    ),
    'a kitchen member may not read reservations'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000005');
  perform pg_temp.assert_true(
    not private.can_read_restaurant_reservations(
      '11111111-1111-1111-1111-111111111111'
    ),
    'a cashier may not read reservations'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000006');
  perform pg_temp.assert_true(
    not private.can_read_restaurant_reservations(
      '11111111-1111-1111-1111-111111111111'
    ),
    'a deactivated member may not read reservations'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000007');
  perform pg_temp.assert_true(
    not private.can_read_restaurant_reservations(
      '11111111-1111-1111-1111-111111111111'
    ),
    'a member of another restaurant may not read reservations'
  );

  perform pg_temp.sign_in(null);
  perform pg_temp.assert_true(
    not private.can_read_restaurant_reservations(
      '11111111-1111-1111-1111-111111111111'
    ),
    'nobody signed in may not read reservations'
  );

  perform pg_temp.sign_in(null);
end;
$$;

-- ---------------------------------------------------------------------------
-- A guest cannot reach the staff path at all
-- ---------------------------------------------------------------------------
set local role anon;

do $$
begin
  perform pg_temp.assert_denied(
    'select public.staff_list_reservations(
       ''11111111-1111-1111-1111-111111111111'')',
    'anon cannot list a restaurant''s reservations'
  );
  perform pg_temp.assert_denied(
    'select public.staff_set_reservation_status(
       ''00000000-0000-4000-8000-000000000000'', ''CANCELLED'')',
    'anon cannot move a reservation'
  );
  perform pg_temp.assert_denied(
    'select * from public.reservations',
    'anon cannot read reservations'
  );
  perform pg_temp.assert_denied(
    'select * from public.reservation_access',
    'anon cannot read guest reservation tokens'
  );
  perform pg_temp.assert_denied(
    'select private.can_read_restaurant_reservations(
       ''11111111-1111-1111-1111-111111111111'')',
    'the reservation authorization helper is not callable by a guest'
  );
end;
$$;

-- A signed-in staff member is no different at the table level: membership grants the
-- two functions, not the reservation tables.
set local role authenticated;
select pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

do $$
begin
  perform pg_temp.assert_denied(
    'select * from public.reservations',
    'a signed-in owner cannot read the reservations table directly'
  );
  perform pg_temp.assert_denied(
    'select * from public.reservation_access',
    'a signed-in owner cannot read the guest tokens table directly'
  );
  perform pg_temp.assert_denied(
    'update public.reservations set status = ''CANCELLED''',
    'a signed-in owner cannot move a reservation through the table'
  );
  perform pg_temp.assert_denied(
    'select private.can_read_restaurant_reservations(
       ''11111111-1111-1111-1111-111111111111'')',
    'the reservation authorization helper is not callable by a client'
  );
end;
$$;

reset role;

-- The grants are exactly these two functions for the signed-in role, and neither is
-- granted to a guest.
do $$
declare
  v_staff_functions text;
begin
  select string_agg(proname, ',' order by proname)
    into v_staff_functions
    from pg_catalog.pg_proc
   where pronamespace = 'public'::regnamespace
     and has_function_privilege('authenticated', oid, 'execute')
     and proname ilike '%reservation%'
     and prorettype <> 'trigger'::regtype
     and proname not in
       ('create_table_reservation', 'guest_reservations', 'cancel_guest_reservation');

  perform pg_temp.assert_equals(
    v_staff_functions,
    'staff_list_reservations,staff_set_reservation_status',
    'a signed-in client may execute exactly the two staff reservation functions'
  );

  select count(*)
    into v_staff_functions
    from pg_catalog.pg_proc
   where pronamespace = 'public'::regnamespace
     and has_function_privilege('anon', oid, 'execute')
     and proname ilike '%reservation%'
     and prorettype <> 'trigger'::regtype
     and proname not in
       ('create_table_reservation', 'guest_reservations', 'cancel_guest_reservation');

  perform pg_temp.assert_equals(
    v_staff_functions::text,
    '0',
    'a guest may execute no function that names a reservation'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading: whose reservations, which branch, which date, and what is in the answer
-- ---------------------------------------------------------------------------
set local role authenticated;

-- No session at all: a signed-out client, or a stale session the app has not noticed
-- yet, is refused rather than answered with somebody's reservations.
do $$
declare
  v_reservation uuid := pg_temp.placed_reservation(
    'a1a1a1a1-1111-4111-8111-111111111111', current_date + 9, '19:00',
    'No session', 2
  );
begin
  perform pg_temp.sign_in(null);

  perform pg_temp.assert_fails_with(
    'select public.staff_list_reservations(
       ''11111111-1111-1111-1111-111111111111'')',
    '28000',
    'Authentication is required to read restaurant reservations.',
    'listing reservations without a session is refused'
  );
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''CANCELLED'')',
      v_reservation
    ),
    '28000',
    'Authentication is required to change a reservation status.',
    'moving a reservation without a session is refused'
  );

  -- A signed-in user with no membership anywhere is refused with the same answer as
  -- a restaurant that does not exist: this is not a way to find out what exists.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000008');

  perform pg_temp.assert_fails_with(
    'select public.staff_list_reservations(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_reservation_access_denied',
    'a signed-in non-member cannot list a restaurant''s reservations'
  );
  perform pg_temp.assert_fails_with(
    'select public.staff_list_reservations(
       ''99999999-9999-9999-9999-999999999999'')',
    '42501',
    'staff_reservation_access_denied',
    'a restaurant that does not exist is refused like one that is not ours'
  );
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''CANCELLED'')',
      v_reservation
    ),
    '42501',
    'staff_reservation_access_denied',
    'a signed-in non-member cannot move a reservation'
  );
end;
$$;

-- A member reads their own restaurant, and only their own.
do $$
declare
  v_payload jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_payload := public.staff_list_reservations(
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
  perform pg_temp.assert_equals(
    v_payload ->> 'date',
    null,
    'the payload reports no date when no date was asked for'
  );

  -- Chronological, oldest booking first, and every reservation of the restaurant.
  perform pg_temp.assert_equals(
    pg_temp.payload_reservation_ids(v_payload),
    pg_temp.stored_reservation_ids('11111111-1111-1111-1111-111111111111'),
    'an owner sees their own restaurant''s reservations, oldest booking first'
  );

  perform pg_temp.assert_true(
    v_payload::text not like '%Other%'
      and v_payload::text not like '%Beshkempir%',
    'the payload holds nothing from the other restaurant'
  );

  -- The other restaurant's owner reads only theirs.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000007');

  v_payload := public.staff_list_reservations(
    '22222222-2222-2222-2222-222222222222'
  );

  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'reservations')::text,
    pg_temp.stored_reservation_count('22222222-2222-2222-2222-222222222222')::text,
    'the other restaurant''s owner sees exactly their own reservations'
  );
  perform pg_temp.assert_equals(
    pg_temp.payload_reservation_ids(v_payload),
    pg_temp.stored_reservation_ids('22222222-2222-2222-2222-222222222222'),
    'and they are the stored ones'
  );

  -- And cannot reach the first one at all.
  perform pg_temp.assert_fails_with(
    'select public.staff_list_reservations(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_reservation_access_denied',
    'the other restaurant''s owner cannot list the first restaurant''s reservations'
  );

  -- Belonging to both is enough: access follows the membership of the restaurant
  -- being read, not who owns it.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000009');

  perform pg_temp.assert_equals(
    jsonb_array_length(
      public.staff_list_reservations(
        '11111111-1111-1111-1111-111111111111'
      ) -> 'reservations'
    )::text,
    pg_temp.stored_reservation_count(
      '11111111-1111-1111-1111-111111111111'
    )::text,
    'a member of both restaurants reads the one whose membership covers it'
  );

  -- A deactivated membership grants nothing, in either direction.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000006');

  perform pg_temp.assert_fails_with(
    'select public.staff_list_reservations(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_reservation_access_denied',
    'a deactivated member cannot read the restaurant''s reservations'
  );

  -- A kitchen member may not: a reservation is not what the kitchen works on.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000004');

  perform pg_temp.assert_fails_with(
    'select public.staff_list_reservations(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_reservation_access_denied',
    'a kitchen member cannot read the restaurant''s reservations'
  );

  -- A cashier may not either: this step defines no reservation duties for the role.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000005');

  perform pg_temp.assert_fails_with(
    'select public.staff_list_reservations(
       ''11111111-1111-1111-1111-111111111111'')',
    '42501',
    'staff_reservation_access_denied',
    'a cashier cannot read the restaurant''s reservations'
  );
end;
$$;

-- The branch filter divides one restaurant's reservations without reaching another's.
do $$
declare
  v_payload jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_payload := public.staff_list_reservations(
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333333'
  );

  perform pg_temp.assert_equals(
    v_payload ->> 'branch_id',
    '33333333-3333-3333-3333-333333333333',
    'the payload reports the branch that was asked for'
  );
  perform pg_temp.assert_equals(
    pg_temp.payload_reservation_ids(v_payload),
    pg_temp.stored_reservation_ids(
      '11111111-1111-1111-1111-111111111111',
      '33333333-3333-3333-3333-333333333333'
    ),
    'a branch filter returns that branch''s reservations only'
  );

  perform pg_temp.assert_equals(
    jsonb_array_length(
      public.staff_list_reservations(
        '11111111-1111-1111-1111-111111111111',
        '33333333-3333-3333-3333-333333333334'
      ) -> 'reservations'
    )::text,
    '1',
    'the other branch of the same restaurant returns its own one reservation'
  );

  -- A branch id belonging to the other restaurant cannot be used to read it, and
  -- says nothing about whether it exists: an empty list is the same answer as a
  -- branch with no reservations.
  perform pg_temp.assert_equals(
    pg_temp.payload_reservation_ids(
      public.staff_list_reservations(
        '11111111-1111-1111-1111-111111111111',
        '44444444-4444-4444-4444-444444444444'
      )
    ),
    '',
    'a branch of another restaurant matches nothing'
  );

  -- And the order of the arguments cannot be used to swap them: naming the other
  -- restaurant is refused, not answered with its reservations.
  perform pg_temp.assert_fails_with(
    'select public.staff_list_reservations(
       ''22222222-2222-2222-2222-222222222222'',
       ''33333333-3333-3333-3333-333333333333'')',
    '42501',
    'staff_reservation_access_denied',
    'naming another restaurant is refused whatever branch is asked for'
  );
end;
$$;

-- The date filter keeps one day apart from the next.
do $$
declare
  v_payload jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_payload := public.staff_list_reservations(
    '11111111-1111-1111-1111-111111111111',
    null,
    current_date + 1
  );

  perform pg_temp.assert_equals(
    v_payload ->> 'date',
    (current_date + 1)::text,
    'the payload reports the date that was asked for'
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'reservations')::text,
    pg_temp.stored_reservation_count(
      '11111111-1111-1111-1111-111111111111', null, current_date + 1
    )::text,
    'the first day returns that day''s reservations only'
  );
  perform pg_temp.assert_equals(
    pg_temp.payload_reservation_ids(v_payload),
    pg_temp.stored_reservation_ids(
      '11111111-1111-1111-1111-111111111111', null, current_date + 1
    ),
    'and they are the stored ones'
  );

  perform pg_temp.assert_equals(
    jsonb_array_length(
      public.staff_list_reservations(
        '11111111-1111-1111-1111-111111111111',
        null,
        current_date + 2
      ) -> 'reservations'
    )::text,
    '1',
    'the second day returns its own one reservation'
  );

  -- A day with no bookings is an empty list, not an error.
  perform pg_temp.assert_equals(
    jsonb_array_length(
      public.staff_list_reservations(
        '11111111-1111-1111-1111-111111111111',
        null,
        current_date + 8
      ) -> 'reservations'
    )::text,
    '0',
    'a day with no bookings is an empty list'
  );

  -- A branch and a date narrow together.
  perform pg_temp.assert_equals(
    pg_temp.payload_reservation_ids(
      public.staff_list_reservations(
        '11111111-1111-1111-1111-111111111111',
        '33333333-3333-3333-3333-333333333333',
        current_date + 1
      )
    ),
    pg_temp.stored_reservation_ids(
      '11111111-1111-1111-1111-111111111111',
      '33333333-3333-3333-3333-333333333333',
      current_date + 1
    ),
    'a branch and a date narrow together'
  );
end;
$$;

-- What one reservation looks like inside the payload, and what must not be there.
do $$
declare
  v_payload jsonb;
  v_reservation jsonb;
  v_stored jsonb;
  v_keys text;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_payload := public.staff_list_reservations(
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333333',
    current_date + 1,
    1
  );

  v_reservation := v_payload -> 'reservations' -> 0;
  v_stored := pg_temp.stored_snapshot((v_reservation ->> 'id')::uuid);

  perform pg_temp.assert_equals(
    v_reservation ->> 'id',
    v_stored ->> 'id',
    'the reservation id is the stored one'
  );
  perform pg_temp.assert_equals(
    v_reservation ->> 'restaurant_id',
    v_stored ->> 'restaurant_id',
    'the restaurant is named, because staff work one restaurant'
  );
  perform pg_temp.assert_equals(
    v_reservation ->> 'branch_id',
    v_stored ->> 'branch_id',
    'the branch is named, because staff work one branch'
  );
  perform pg_temp.assert_equals(
    v_reservation ->> 'table_id',
    v_stored ->> 'table_id',
    'the table is named, because staff seat a guest at it'
  );
  perform pg_temp.assert_equals(
    v_reservation ->> 'reserved_date',
    v_stored ->> 'reserved_date',
    'the reservation date is the stored one'
  );
  perform pg_temp.assert_equals(
    v_reservation ->> 'reserved_time',
    v_stored ->> 'reserved_time',
    'the reservation time is the stored one'
  );
  perform pg_temp.assert_equals(
    v_reservation ->> 'guest_name',
    v_stored ->> 'guest_name',
    'the guest name is the stored one'
  );
  perform pg_temp.assert_equals(
    v_reservation ->> 'guest_count',
    v_stored ->> 'guest_count',
    'the guest count is the stored one'
  );
  perform pg_temp.assert_equals(
    v_reservation ->> 'status',
    v_stored ->> 'status',
    'the reservation is reported in the state it is really in'
  );
  perform pg_temp.assert_true(
    v_reservation ? 'created_at' and v_reservation ? 'updated_at',
    'the reservation carries when it was made and last changed'
  );

  -- Nothing that belongs to the guest, by name or by value.
  perform pg_temp.assert_true(
    not (v_reservation ? 'access_token'),
    'a reservation carries no access_token key'
  );
  perform pg_temp.assert_true(
    v_payload::text not like '%access_token%'
      and v_payload::text not like '%' || (v_stored ->> 'access_token') || '%',
    'no guest access token is in the payload, by name or by value'
  );
  perform pg_temp.assert_true(
    v_payload::text not like '%qr_token%',
    'no table qr token is in the payload'
  );
  perform pg_temp.assert_true(
    v_payload::text not like '%user_id%'
      and v_payload::text not like '%restaurant_members%',
    'no membership or staff identity is in the payload'
  );

  -- And the key set is exactly what a client can rely on.
  select string_agg(key, ',' order by key)
    into v_keys
    from jsonb_object_keys(v_reservation) as key;

  perform pg_temp.assert_equals(
    v_keys,
    'branch_id,created_at,guest_count,guest_name,id,reserved_date,reserved_time,restaurant_id,status,table_id,updated_at',
    'a staff reservation carries exactly the fields a screen needs'
  );

  -- The top-level envelope is the caller's own scope, echoed back.
  select string_agg(key, ',' order by key)
    into v_keys
    from jsonb_object_keys(v_payload) as key;

  perform pg_temp.assert_equals(
    v_keys,
    'branch_id,date,reservations,restaurant_id',
    'the payload is the scope that was asked for plus the list'
  );
end;
$$;

-- p_limit is clamped, not obeyed, and the ceiling is 100.
do $$
declare
  v_count integer;
  v_payload jsonb;
begin
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  v_count := pg_temp.stored_reservation_count(
    '11111111-1111-1111-1111-111111111111'
  );

  v_payload := public.staff_list_reservations(
    '11111111-1111-1111-1111-111111111111', null, null, 1
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'reservations')::text,
    '1',
    'a limit of one returns one reservation'
  );

  v_payload := public.staff_list_reservations(
    '11111111-1111-1111-1111-111111111111', null, null, 0
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'reservations')::text,
    '1',
    'a limit of zero is clamped up to one rather than returning nothing'
  );

  v_payload := public.staff_list_reservations(
    '11111111-1111-1111-1111-111111111111', null, null, -5
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'reservations')::text,
    '1',
    'a negative limit is clamped up to one'
  );

  v_payload := public.staff_list_reservations(
    '11111111-1111-1111-1111-111111111111', null, null, 1000000
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'reservations')::text,
    v_count::text,
    'a limit above the ceiling returns the whole restaurant''s reservations'
  );

  v_payload := public.staff_list_reservations(
    '11111111-1111-1111-1111-111111111111', null, null, null
  );
  perform pg_temp.assert_equals(
    jsonb_array_length(v_payload -> 'reservations')::text,
    v_count::text,
    'an absent limit falls back to the default'
  );

  -- The ceiling restaurant holds 101 reservations, so the safe maximum is
  -- observable rather than merely asserted.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000010');

  perform pg_temp.assert_equals(
    pg_temp.stored_reservation_count(
      '55555555-5555-5555-5555-555555555555'
    )::text,
    '101',
    'the ceiling restaurant really holds more than the maximum'
  );

  perform pg_temp.assert_equals(
    jsonb_array_length(
      public.staff_list_reservations(
        '55555555-5555-5555-5555-555555555555', null, null, 1000000
      ) -> 'reservations'
    )::text,
    '100',
    'a limit above the ceiling is clamped down to 100'
  );

  perform pg_temp.assert_equals(
    jsonb_array_length(
      public.staff_list_reservations(
        '55555555-5555-5555-5555-555555555555', null, null, 101
      ) -> 'reservations'
    )::text,
    '100',
    'a limit exactly above the ceiling is clamped down to 100'
  );

  perform pg_temp.assert_equals(
    jsonb_array_length(
      public.staff_list_reservations(
        '55555555-5555-5555-5555-555555555555', null, null, 100
      ) -> 'reservations'
    )::text,
    '100',
    'a limit of 100 returns 100'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Moving: the one transition this phase defines, and every refusal around it
-- ---------------------------------------------------------------------------

-- No session, a non-member, a reservation of another restaurant, a reservation id
-- that names nothing, and a role with no reservation duties are all refused before
-- any move is considered.
do $$
declare
  v_own uuid;
  v_foreign uuid := pg_temp.reservation_in_state(
    'CONFIRMED', 'b1b1b1b1-1111-4111-8111-111111111111',
    current_date + 3, '23:00'
  );
begin
  v_own := pg_temp.placed_reservation(
    'a1a1a1a1-1111-4111-8111-111111111111', current_date + 3, '23:00',
    'Refusal', 2
  );

  -- No session.
  perform pg_temp.sign_in(null);
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''CANCELLED'')', v_own
    ),
    '28000',
    'Authentication is required to change a reservation status.',
    'a signed-out caller cannot move a reservation'
  );

  -- A signed-in user with no membership anywhere.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000008');
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''CANCELLED'')', v_own
    ),
    '42501',
    'staff_reservation_access_denied',
    'a signed-in non-member cannot move a reservation'
  );
  perform pg_temp.assert_equals(
    pg_temp.stored_status(v_own),
    'CONFIRMED',
    'the reservation they were refused is untouched'
  );

  -- The owner of the other restaurant cannot move this reservation, and is told only
  -- that it is not theirs.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000007');
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''CANCELLED'')', v_own
    ),
    '42501',
    'staff_reservation_access_denied',
    'another restaurant''s owner cannot move this reservation'
  );
  perform pg_temp.assert_equals(
    pg_temp.stored_status(v_own),
    'CONFIRMED',
    'the reservation they were refused is still untouched'
  );

  -- A reservation id that does not exist is the same answer as one that is not
  -- theirs, so this function cannot be used to find out which ids are real.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');
  perform pg_temp.assert_fails_with(
    'select public.staff_set_reservation_status(
       ''00000000-0000-4000-8000-000000000000'', ''CANCELLED'')',
    '42501',
    'staff_reservation_access_denied',
    'a reservation id that does not exist is refused the same way'
  );

  -- A kitchen member and a cashier have no reservation duties.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000004');
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''CANCELLED'')', v_own
    ),
    '42501',
    'staff_reservation_access_denied',
    'a kitchen member cannot move a reservation'
  );

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000005');
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''CANCELLED'')', v_own
    ),
    '42501',
    'staff_reservation_access_denied',
    'a cashier cannot move a reservation'
  );

  -- A deactivated member is refused before any move is considered.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000006');
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''CANCELLED'')', v_own
    ),
    '42501',
    'staff_reservation_access_denied',
    'a deactivated member cannot move a reservation'
  );

  perform pg_temp.assert_equals(
    pg_temp.stored_status(v_own),
    'CONFIRMED',
    'every refused caller left the reservation where it was'
  );

  -- The other restaurant's own owner may move their own reservation, so the earlier
  -- refusal was about which reservation was named and not about who was asking.
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000007', v_foreign, 'CANCELLED'
    ),
    'ok',
    'the same owner may cancel a reservation of their own restaurant'
  );
  perform pg_temp.assert_equals(
    pg_temp.stored_status(v_foreign),
    'CANCELLED',
    'the reservation they were allowed to move really moved'
  );

  perform pg_temp.sign_in(null);
end;
$$;

-- The one legal move, for every role that works reservations.
do $$
declare
  v_id uuid;
  v_payload jsonb;
  v_keys text;
begin
  -- A waiter cancels.
  v_id := pg_temp.placed_reservation(
    'a1a1a1a1-1111-4111-8111-111111111111', current_date + 4, '19:00',
    'Waiter cancel', 2
  );

  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000003', v_id, 'CANCELLED'
    ),
    'ok',
    'a waiter may cancel a confirmed reservation'
  );
  perform pg_temp.assert_equals(
    pg_temp.stored_status(v_id),
    'CANCELLED',
    'the waiter''s cancellation really stored'
  );

  -- The answer is only what a status change changed, and never a token.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');
  v_payload := public.staff_set_reservation_status(
    pg_temp.placed_reservation(
      'a1a1a1a1-1111-4111-8111-111111111111', current_date + 4, '20:00',
      'Answer shape', 2
    ),
    'CANCELLED'
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
    v_payload ->> 'status',
    'CANCELLED',
    'the answer reports the status that was stored'
  );
  perform pg_temp.assert_true(
    v_payload ? 'updated_at',
    'the answer reports when the row changed'
  );
  perform pg_temp.assert_true(
    v_payload::text not like '%access_token%',
    'the answer carries no access token'
  );

  -- An owner cancels.
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000001',
      pg_temp.placed_reservation(
        'a1a1a1a1-1111-4111-8111-111111111111', current_date + 4, '21:00',
        'Owner cancel', 2
      ),
      'CANCELLED'
    ),
    'ok',
    'an owner may cancel a confirmed reservation'
  );

  -- A manager cancels.
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000002',
      pg_temp.placed_reservation(
        'a1a1a1a1-1111-4111-8111-111111111111', current_date + 4, '22:00',
        'Manager cancel', 2
      ),
      'CANCELLED'
    ),
    'ok',
    'a manager may cancel a confirmed reservation'
  );

  -- A member of both restaurants may cancel in the restaurant their membership
  -- covers.
  perform pg_temp.assert_equals(
    pg_temp.staff_move(
      'e0000000-0000-4000-8000-000000000009',
      pg_temp.placed_reservation(
        'a1a1a1a1-1111-4111-8111-111111111111', current_date + 4, '23:00',
        'Both cancel', 2
      ),
      'CANCELLED'
    ),
    'ok',
    'a member of both restaurants may cancel in the one they belong to'
  );

  -- Cancelling frees the slot, because the unique index only covers CONFIRMED rows.
  perform pg_temp.assert_true(
    pg_temp.placed_reservation(
      'a1a1a1a1-1111-4111-8111-111111111111', current_date + 4, '19:00',
      'Rebooked', 2
    ) is not null,
    'a cancelled slot is bookable again'
  );
end;
$$;

-- A move this phase does not define, and a status the schema cannot hold, are both
-- refused, and neither changes anything.
do $$
declare
  v_confirmed uuid;
  v_cancelled uuid;
  v_keys text;
begin
  v_confirmed := pg_temp.placed_reservation(
    'a1a1a1a1-1111-4111-8111-111111111111', current_date + 5, '19:00',
    'Invalid', 2
  );
  v_cancelled := pg_temp.reservation_in_state(
    'CANCELLED', 'a1a1a1a1-1111-4111-8111-111111111111',
    current_date + 5, '20:00'
  );

  -- A status the schema cannot hold is the word's answer, not a transition question.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''PENDING'')', v_confirmed
    ),
    'P0001',
    'invalid_reservation_status',
    'PENDING is not a status this schema holds'
  );
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''REJECTED'')', v_confirmed
    ),
    'P0001',
    'invalid_reservation_status',
    'REJECTED is not a status this schema holds'
  );
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''cancelled'')', v_confirmed
    ),
    'P0001',
    'invalid_reservation_status',
    'a status in the wrong case is refused'
  );

  -- Re-confirming is not a move this phase defines.
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''CONFIRMED'')', v_confirmed
    ),
    'P0001',
    'invalid_reservation_status_transition',
    'confirming an already confirmed reservation is refused'
  );
  perform pg_temp.assert_equals(
    pg_temp.stored_status(v_confirmed),
    'CONFIRMED',
    'a refused no-op leaves the reservation where it was'
  );

  -- Reopening a cancelled reservation is not a move this phase defines.
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''CONFIRMED'')', v_cancelled
    ),
    'P0001',
    'invalid_reservation_status_transition',
    'reopening a cancelled reservation is refused'
  );
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''CANCELLED'')', v_cancelled
    ),
    'P0001',
    'invalid_reservation_status_transition',
    'cancelling twice is refused rather than a no-op'
  );
  perform pg_temp.assert_equals(
    pg_temp.stored_status(v_cancelled),
    'CANCELLED',
    'a refused transition leaves the cancelled reservation cancelled'
  );

  -- Missing arguments are a malformed request rather than a permission problem.
  perform pg_temp.assert_fails_with(
    'select public.staff_set_reservation_status(null, ''CANCELLED'')',
    '22023',
    'A reservation id and a status are required.',
    'a missing reservation id is refused as a malformed request'
  );
  perform pg_temp.assert_fails_with(
    'select public.staff_set_reservation_status(
       ''00000000-0000-4000-8000-000000000000'', ''   '')',
    '22023',
    'A reservation id and a status are required.',
    'a blank status is refused as a malformed request'
  );

  -- Whitespace around a real status is trimmed rather than refused.
  perform pg_temp.assert_equals(
    public.staff_set_reservation_status(
      pg_temp.placed_reservation(
        'a1a1a1a1-1111-4111-8111-111111111111', current_date + 5, '21:00',
        'Padded', 2
      ),
      '  CANCELLED  '
    ) ->> 'status',
    'CANCELLED',
    'a padded status is trimmed and stored'
  );

  perform pg_temp.sign_in(null);
end;
$$;

-- A staff status change is scoped to one restaurant: the cross-restaurant attempt is
-- refused and the row it named does not move.
do $$
declare
  v_a uuid;
  v_b uuid;
begin
  v_a := pg_temp.placed_reservation(
    'a1a1a1a1-1111-4111-8111-111111111111', current_date + 6, '19:00',
    'A only', 2
  );
  v_b := pg_temp.placed_reservation(
    'b1b1b1b1-1111-4111-8111-111111111111', current_date + 6, '19:00',
    'B only', 2
  );

  -- The owner of B cannot cancel A's reservation.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000007');
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''CANCELLED'')', v_a
    ),
    '42501',
    'staff_reservation_access_denied',
    'the owner of another restaurant cannot affect A''s reservation'
  );
  perform pg_temp.assert_equals(
    pg_temp.stored_status(v_a),
    'CONFIRMED',
    'A''s reservation is untouched by the cross-restaurant attempt'
  );

  -- And the owner of A cannot cancel B's.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');
  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_reservation_status(%L, ''CANCELLED'')', v_b
    ),
    '42501',
    'staff_reservation_access_denied',
    'the owner of A cannot affect B''s reservation'
  );
  perform pg_temp.assert_equals(
    pg_temp.stored_status(v_b),
    'CONFIRMED',
    'B''s reservation is untouched by the cross-restaurant attempt'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- The guest side is untouched
-- ---------------------------------------------------------------------------

-- The guest who booked a reservation still reads it, still with the token, and now
-- sees the state staff moved it to: the staff path was added beside the guest one.
set local role anon;

do $$
declare
  v_token text;
  v_payload jsonb;
  v_reservation uuid;
begin
  -- The guest books, so the token and the reservation are the same one rather than
  -- two unrelated fixtures.
  v_token := public.create_table_reservation(
    'a1a1a1a1-1111-4111-8111-111111111111',
    current_date + 7, '19:00', 'Guest', 2
  ) ->> 'access_token';

  v_reservation := pg_temp.reservation_id_for_token(v_token);

  -- Staff cancel it. The guest read is called by a guest and the move by a member,
  -- so both are done from this block with the role switched.
  set local role authenticated;
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000003');

  v_payload := public.staff_set_reservation_status(v_reservation, 'CANCELLED');

  perform pg_temp.assert_equals(
    v_payload ->> 'status',
    'CANCELLED',
    'a waiter cancelled the guest''s reservation'
  );

  set local role anon;

  v_payload := public.guest_reservations(v_token);

  perform pg_temp.assert_equals(
    v_payload -> 'reservations' -> 0 ->> 'status',
    'CANCELLED',
    'the guest reads back the status staff moved their reservation to'
  );
  perform pg_temp.assert_true(
    v_payload::text not like '%access_token%',
    'the guest payload still carries no token of its own'
  );
end;
$$;

reset role;

-- A guest token is not a staff credential. The guest who owns a reservation cannot
-- move it, even naming its own reservation id, because the staff functions are not
-- executable by the guest role at all.
do $$
declare
  v_token text;
  v_reservation uuid;
begin
  v_token := public.create_table_reservation(
    'a1a1a1a1-1111-4111-8111-111111111111',
    current_date + 8, '19:00', 'Guest again', 2
  ) ->> 'access_token';

  -- The id is resolved as the owner, before the role switches: a guest cannot read
  -- the reservations table, so the assertion below is about the function and not
  -- about the lookup.
  select stored.id
    into v_reservation
    from public.reservations as stored
   where stored.access_token = v_token;

  set local role anon;

  perform pg_temp.assert_denied(
    format(
      'select public.staff_set_reservation_status(%L, ''CANCELLED'')',
      v_reservation
    ),
    'a guest cannot move their own reservation'
  );
  perform pg_temp.assert_denied(
    'select public.staff_list_reservations(
       ''11111111-1111-1111-1111-111111111111'')',
    'a guest cannot list a restaurant''s reservations'
  );
end;
$$;

reset role;

rollback;
