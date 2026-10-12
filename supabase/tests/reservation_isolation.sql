-- Reservation isolation and access-control checks.
--
-- Runs the guest reservation functions against a real database and proves the
-- properties that matter for this feature, as the `anon` and `authenticated`
-- roles rather than as the owner:
--
--   * neither role can read or write the reservation tables directly
--   * a guest reads only the reservations created with their own token
--   * a reservation id from another guest cannot be cancelled
--   * a QR token from another restaurant cannot reach another restaurant
--   * an already booked slot is rejected, and a cancelled slot is bookable again
--   * the returned payload carries no restaurant, branch or table id
--
-- Usage, against a database where supabase/migrations has been applied:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/reservation_isolation.sql
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
declare
  v_code text;
begin
  begin
    execute statement;
  exception
    when others then
      v_code := sqlstate;
  end;

  if v_code is distinct from expected_code then
    raise exception 'FAILED: % (got %, expected %)',
      message, v_code, expected_code using errcode = 'P0001';
  end if;
  raise notice 'ok: % (% raised)', message, v_code;
end;
$$;

create or replace function pg_temp.reservation_rows(payload jsonb)
returns setof jsonb
language sql
stable
as $fn$
  select jsonb_array_elements(coalesce(payload -> 'reservations', '[]'::jsonb));
$fn$;

-- The number of reservations inside a guest_reservations payload.
create or replace function pg_temp.list_size(payload jsonb)
returns integer
language sql
stable
as $fn$
  select coalesce(
    jsonb_array_length(coalesce(payload -> 'reservations', '[]'::jsonb)),
    0
  );
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
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333333',
    '13', null, 2, 'b1b1b1b1-1111-4111-8111-111111111111'
  ),
  (
    'cccccccc-cccc-cccc-cccc-cccccccccccc',
    '22222222-2222-2222-2222-222222222222',
    '44444444-4444-4444-4444-444444444444',
    '1', null, 4, 'c1c1c1c1-1111-4111-8111-111111111111'
  ),
  (
    'dddddddd-dddd-dddd-dddd-dddddddddddd',
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333333',
    '99', null, 4, 'd1d1d1d1-1111-4111-8111-111111111111'
  );

update public.tables
   set is_active = false
 where id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';

-- A second table for restaurant A that stays active.
update public.tables
   set is_active = true
 where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

-- The composite key that keeps a reservation from mixing restaurants.
do $$
begin
  perform pg_temp.assert_fails_with(
    $stmt$
      insert into public.reservations (
        access_token, restaurant_id, branch_id, table_id,
        reserved_date, reserved_time, guest_name, guest_count
      )
      select
        'probe', '11111111-1111-1111-1111-111111111111',
        '44444444-4444-4444-4444-444444444444',
        'cccccccc-cccc-cccc-cccc-cccccccccccc',
        current_date + 1, '19:00', 'Probe', 2
    $stmt$,
    '23503',
    'a table from another restaurant cannot be attached to a reservation'
  );
end;
$$;

-- An anonymous guest with no session at all.
set local role anon;

do $$
begin
  perform pg_temp.assert_denied(
    'select * from public.reservations',
    'anon cannot select reservations'
  );
  perform pg_temp.assert_denied(
    'insert into public.reservations default values',
    'anon cannot insert reservations'
  );
  perform pg_temp.assert_denied(
    'update public.reservations set status = ''CANCELLED''',
    'anon cannot update reservations'
  );
  perform pg_temp.assert_denied(
    'delete from public.reservations',
    'anon cannot delete reservations'
  );
  perform pg_temp.assert_denied(
    'select * from public.reservation_access',
    'anon cannot read reservation access tokens'
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

-- Creating a reservation as an anonymous guest.
do $$
declare
  v_result jsonb;
  v_token text;
  v_reservation jsonb;
begin
  v_result := public.create_table_reservation(
    'a1a1a1a1-1111-4111-8111-111111111111',
    current_date + 3,
    '19:00',
    'Askar',
    3
  );

  perform pg_temp.assert_true(v_result is not null, 'a valid qr token creates a reservation');

  v_token := v_result ->> 'access_token';
  v_reservation := v_result -> 'reservation';

  perform pg_temp.assert_true(
    v_token is not null and length(v_token) = 72,
    'the response carries a 72 character access token (244 bits)'
  );
  perform pg_temp.assert_equals(
    v_reservation ->> 'restaurant_name',
    'Ala-Too',
    'the reservation names the restaurant'
  );
  perform pg_temp.assert_equals(
    v_reservation ->> 'branch_name',
    'Center',
    'the reservation names the branch'
  );
  perform pg_temp.assert_equals(
    v_reservation -> 'table' ->> 'number',
    '12',
    'the reservation names the table'
  );
  perform pg_temp.assert_equals(
    v_reservation ->> 'status',
    'CONFIRMED',
    'a new reservation is confirmed'
  );

  -- The payload must stay as narrow as the public menu payload.
  perform pg_temp.assert_true(
    not (v_reservation ? 'restaurant_id')
      and not (v_reservation ? 'branch_id')
      and not (v_reservation ? 'table_id')
      and not (v_reservation ? 'access_token')
      and not (v_reservation ? 'capacity')
      and not (v_reservation ? 'qr_token'),
    'the response exposes no restaurant, branch or table id'
  );

  -- A returning guest keeps one identity, so both reservations show up together.
  v_result := public.create_table_reservation(
    'a1a1a1a1-1111-4111-8111-111111111111',
    current_date + 4,
    '13:30',
    'Askar',
    2,
    v_token
  );
  perform pg_temp.assert_equals(
    v_result ->> 'access_token',
    v_token,
    'a second reservation reuses the guest''s own access token'
  );

  perform pg_temp.assert_equals(
    pg_temp.list_size(public.guest_reservations(v_token))::text,
    '2',
    'the guest sees both of their own reservations'
  );
end;
$$;

-- The guest token is the only thing that opens a guest's list.
do $$
begin
  perform pg_temp.assert_equals(
    pg_temp.list_size(public.guest_reservations('not-a-real-token'))::text,
    '0',
    'an unknown token returns an empty list instead of an error'
  );
  perform pg_temp.assert_equals(
    pg_temp.list_size(public.guest_reservations(null))::text,
    '0',
    'a missing token returns an empty list'
  );
end;
$$;

-- Another guest, on the same table and in the same restaurant.
do $$
declare
  v_other_token text;
  v_other_reservation_id uuid;
  v_first_token text;
  v_first_reservation_id uuid;
begin
  select
    public.create_table_reservation(
      'a1a1a1a1-1111-4111-8111-111111111111',
      current_date + 5,
      '20:00',
      'Nurlan',
      2
    ) ->> 'access_token'
    into v_other_token;

  select id
    into v_first_reservation_id
    from public.reservations
   where guest_name = 'Askar'
   order by created_at
   limit 1;

  select id
    into v_other_reservation_id
    from public.reservations
   where guest_name = 'Nurlan'
   limit 1;

  perform pg_temp.assert_equals(
    pg_temp.list_size(public.guest_reservations(v_other_token))::text,
    '1',
    'a second guest sees only their own reservation'
  );

  -- A known reservation id from another guest must not cancel anything.
  perform pg_temp.assert_equals(
    public.cancel_guest_reservation(v_other_token, v_first_reservation_id)::text,
    'false',
    'a guest cannot cancel a reservation that is not theirs'
  );
  perform pg_temp.assert_equals(
    (
      select status from public.reservations where id = v_first_reservation_id
    ),
    'CONFIRMED',
    'the other guest''s reservation is untouched'
  );

  -- Their own reservation cancels.
  perform pg_temp.assert_equals(
    public.cancel_guest_reservation(v_other_token, v_other_reservation_id)::text,
    'true',
    'a guest can cancel their own reservation'
  );
  perform pg_temp.assert_equals(
    (
      select status from public.reservations where id = v_other_reservation_id
    ),
    'CANCELLED',
    'the cancelled reservation keeps its row and is marked cancelled'
  );
  perform pg_temp.assert_equals(
    public.cancel_guest_reservation(v_other_token, v_other_reservation_id)::text,
    'false',
    'cancelling twice reports no further change'
  );

  -- The slot is bookable again once the reservation is cancelled.
  perform pg_temp.assert_true(
    public.create_table_reservation(
      'a1a1a1a1-1111-4111-8111-111111111111',
      current_date + 5,
      '20:00',
      'Timur',
      1
    ) is not null,
    'a cancelled slot can be booked again'
  );
end;
$$;

-- Two parties cannot hold the same table at the same minute.
do $$
begin
  perform pg_temp.assert_true(
    public.create_table_reservation(
      'a1a1a1a1-1111-4111-8111-111111111111',
      current_date + 6,
      '19:00',
      'Original',
      1
    ) is not null,
    'the first booking of a slot succeeds'
  );

  perform pg_temp.assert_fails_with(
    $stmt$
      select public.create_table_reservation(
        'a1a1a1a1-1111-4111-8111-111111111111',
        current_date + 6,
        '19:00',
        'Duplicate',
        1
      )
    $stmt$,
    '23505',
    'the same table cannot be booked twice at the same minute'
  );

  -- A different time on the same day is not a conflict, because the project has
  -- no rule about how long a reservation lasts.
  perform pg_temp.assert_true(
    public.create_table_reservation(
      'a1a1a1a1-1111-4111-8111-111111111111',
      current_date + 6,
      '19:01',
      'One minute later',
      1
    ) is not null,
    'a different time on the same day is a separate booking'
  );
end;
$$;

-- Tokens and inputs that must not resolve.
do $$
begin
  perform pg_temp.assert_true(
    public.create_table_reservation(
      'not-a-uuid', current_date + 1, '19:00', 'Askar', 1
    ) is null,
    'a malformed qr token resolves to nothing'
  );
  perform pg_temp.assert_true(
    public.create_table_reservation(
      'e1e1e1e1-1111-4111-8111-111111111111',
      current_date + 1, '19:00', 'Askar', 1
    ) is null,
    'an unknown qr token resolves to nothing'
  );
  perform pg_temp.assert_true(
    public.create_table_reservation(
      'd1d1d1d1-1111-4111-8111-111111111111',
      current_date + 1, '19:00', 'Askar', 1
    ) is null,
    'an inactive table cannot be reserved'
  );
  perform pg_temp.assert_fails_with(
    $stmt$
      select public.create_table_reservation(
        'a1a1a1a1-1111-4111-8111-111111111111',
        current_date - 1, '19:00', 'Askar', 1
      )
    $stmt$,
    'P0001',
    'a day in the past is rejected'
  );
  perform pg_temp.assert_fails_with(
    $stmt$
      select public.create_table_reservation(
        'a1a1a1a1-1111-4111-8111-111111111111',
        current_date + 1, '19:00', '   ', 1
      )
    $stmt$,
    'P0001',
    'an empty guest name is rejected'
  );
  perform pg_temp.assert_fails_with(
    $stmt$
      select public.create_table_reservation(
        'b1b1b1b1-1111-4111-8111-111111111111',
        current_date + 1, '19:00', 'Askar', 9
      )
    $stmt$,
    'P0001',
    'more guests than the table seats is rejected'
  );
end;
$$;

-- Another restaurant's qr token books that restaurant's own table, and only it.
do $$
declare
  v_result jsonb;
begin
  v_result := public.create_table_reservation(
    'c1c1c1c1-1111-4111-8111-111111111111',
    current_date + 2,
    '18:00',
    'Aizada',
    2
  );

  perform pg_temp.assert_equals(
    v_result -> 'reservation' ->> 'restaurant_name',
    'Beshkempir',
    'the other restaurant''s token books its own restaurant'
  );
  perform pg_temp.assert_true(
    (
      select bool_and(reservation.restaurant_id <> '11111111-1111-1111-1111-111111111111')
        from pg_temp.reservation_rows(
          public.guest_reservations(v_result ->> 'access_token')
        ) as listed
        join public.reservations as reservation
          on reservation.id = (listed ->> 'id')::uuid
    ),
    'the other restaurant''s guest never sees a reservation of the first'
  );
  perform pg_temp.assert_equals(
    pg_temp.list_size(public.guest_reservations(v_result ->> 'access_token'))::text,
    '1',
    'the other restaurant''s guest sees only their own reservation'
  );
end;
$$;

-- A signed-in staff member is not a guest: the token model is the only path.
set local role authenticated;

do $$
begin
  perform pg_temp.assert_denied(
    'select * from public.reservations',
    'a signed-in user cannot select reservations directly'
  );
  perform pg_temp.assert_denied(
    'select * from public.reservation_access',
    'a signed-in user cannot read reservation access tokens'
  );
end;
$$;

do $$
begin
  perform pg_temp.assert_equals(
    pg_temp.list_size(public.guest_reservations('not-a-real-token'))::text,
    '0',
    'a signed-in user gets the same empty list for an unknown guest token'
  );
end;
$$;

reset role;

rollback;
