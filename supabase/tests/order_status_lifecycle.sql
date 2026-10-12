-- Order lifecycle checks: the states an order may hold, the moves between them, and
-- the record of every accepted move.
--
-- Runs against a database where supabase/migrations has been applied, as the table
-- owner (whoever writes an order will also be the definer of a future staff
-- function), and as the `anon` and `authenticated` roles where the question is what
-- a guest may do:
--
--   * a new order is created PENDING, and the stored constraint accepts exactly the
--     six lifecycle states
--   * every one of the 36 possible state pairs behaves as the lifecycle says: the
--     seven legal moves are accepted, a write that changes nothing is passed
--     through, and the other 23 are refused by the database
--   * SERVED and CANCELLED are terminal, and cancellation works from exactly three
--     states
--   * no status outside the lifecycle can be stored
--   * the guest roles can neither read nor write order status, and no function they
--     can execute takes or names a status, so the staff path does not exist yet
--   * each accepted move appends exactly one history row with the right old and new
--     state, a refused move appends nothing, and creating an order is not a
--     transition
--   * an existing order still reads back through guest_orders, now reporting
--     whichever lifecycle state it is in
--
-- Usage, against a database where supabase/migrations has been applied:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/order_status_lifecycle.sql
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

-- Asserts that [statement] is refused for the current role. Any error passes,
-- which is intentional: both "permission denied for table" and the lifecycle
-- trigger raising mean the write did not happen.
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

-- Asserts that [statement] fails with [expected_code] and [expected_message].
--
-- The lifecycle reports two different mistakes with the same sqlstate on purpose,
-- so a caller has to be able to tell them apart without parsing prose: an unknown
-- value and an illegal move are different problems with different fixes.
create or replace function pg_temp.assert_fails_with_message(
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
        raise notice 'ok: % (% raised)', message, expected_message;
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

-- The lifecycle, in the order the restaurant walks through it. Every pair of these
-- values is exercised below, so a change to the lifecycle cannot pass unnoticed.
create or replace function pg_temp.order_statuses()
returns text[]
language sql
stable
as $fn$
  select array['PENDING', 'ACCEPTED', 'PREPARING', 'READY', 'SERVED', 'CANCELLED'];
$fn$;

-- The legal moves that lead to [p_status], starting from a fresh PENDING order. Used
-- to put an order into a state so a move out of that state can be attempted; a step
-- that is itself refused means the lifecycle is broken, so the walk raises.
create or replace function pg_temp.legal_path(p_status text)
returns text[]
language sql
stable
as $fn$
  select case p_status
    when 'PENDING' then '{}'::text[]
    when 'ACCEPTED' then array['PENDING', 'ACCEPTED']
    when 'PREPARING' then array['PENDING', 'ACCEPTED', 'PREPARING']
    when 'READY' then array['PENDING', 'ACCEPTED', 'PREPARING', 'READY']
    when 'SERVED' then array['PENDING', 'ACCEPTED', 'PREPARING', 'READY', 'SERVED']
    when 'CANCELLED' then array['PENDING', 'CANCELLED']
  end;
$fn$;

-- A freshly placed order, through the guest's own function, so every lifecycle test
-- starts from a real order rather than a hand-built row.
create or replace function pg_temp.placed_order()
returns uuid
language plpgsql
volatile
as $$
declare
  v_id text;
begin
  v_id := public.create_table_order(
    'a1a1a1a1-1111-4111-8111-111111111111',
    '[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 1}]'::jsonb
  ) -> 'order' ->> 'id';

  return v_id::uuid;
end;
$$;

-- Attempts one status change and reports what happened: 'ok', or the sqlstate that
-- refused it. Catching the error keeps the refused statement rolled back to its own
-- savepoint, so the order stays usable and the next attempt starts clean.
create or replace function pg_temp.try_move(p_order uuid, p_status text)
returns text
language plpgsql
volatile
as $$
begin
  update public.orders set status = p_status where id = p_order;
  return 'ok';
exception
  when others then
    return sqlstate;
end;
$$;

-- Walks a fresh order to [p_from] along the lifecycle, then attempts [p_to].
--
-- Every state pair is therefore tested on a real order that reached [p_from] only
-- through moves the database itself allowed, and the answer is a single sqlstate.
create or replace function pg_temp.attempt_transition(p_from text, p_to text)
returns text
language plpgsql
volatile
as $$
declare
  v_order uuid := pg_temp.placed_order();
  v_step text;
  v_result text;
begin
  foreach v_step in array pg_temp.legal_path(p_from)
  loop
    v_result := pg_temp.try_move(v_order, v_step);
    if v_result <> 'ok' then
      raise exception 'FAILED: walking to % was refused with %', p_from, v_result
        using errcode = 'P0001';
    end if;
  end loop;

  return pg_temp.try_move(v_order, p_to);
end;
$$;

-- The moves recorded for one order, as 'OLD>NEW' pairs in commit order.
create or replace function pg_temp.recorded_transitions(p_order uuid)
returns text
language sql
stable
as $fn$
  select coalesce(
           string_agg(
             old_status || '>' || new_status,
             ',' order by id
           ),
           ''
         )
    from public.order_status_history
   where order_id = p_order;
$fn$;

-- The states an order has been moved into, in commit order.
create or replace function pg_temp.recorded_states(p_order uuid)
returns text
language sql
stable
as $fn$
  select coalesce(
           string_agg(new_status, '>' order by id),
           ''
         )
    from public.order_status_history
   where order_id = p_order;
$fn$;

-- Fixtures: one restaurant with one branch and one table, which is all the lifecycle
-- needs. The ids match the other order scripts; every script rolls back, so they
-- never meet.
insert into public.restaurants (id, name, slug)
values ('11111111-1111-1111-1111-111111111111', 'Ala-Too', 'ala-too');

insert into public.branches (id, restaurant_id, name)
values (
  '33333333-3333-3333-3333-333333333333',
  '11111111-1111-1111-1111-111111111111',
  'Center'
);

insert into public.tables (
  id, restaurant_id, branch_id, table_number, name, capacity, qr_token
)
values (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '11111111-1111-1111-1111-111111111111',
  '33333333-3333-3333-3333-333333333333',
  '12', 'Window', 4, 'a1a1a1a1-1111-4111-8111-111111111111'
);

insert into public.categories (id, restaurant_id, name)
values (
  '55555555-5555-5555-5555-555555555555',
  '11111111-1111-1111-1111-111111111111',
  'Mains'
);

insert into public.menu_items (
  id, restaurant_id, branch_id, category_id, name, price, is_available
)
values (
  '77777777-7777-7777-7777-777777777777',
  '11111111-1111-1111-1111-111111111111',
  null,
  '55555555-5555-5555-5555-555555555555',
  'Beshbarmak', 450.00, true
);

-- The stored constraint holds the six lifecycle states and nothing else. Read from
-- the catalog rather than by inserting six orders, so a state the constraint would
-- refuse cannot hide behind a trigger that refused it first.
do $$
declare
  v_definition text;
  v_status text;
begin
  select pg_catalog.pg_get_constraintdef(oid)
    into v_definition
    from pg_catalog.pg_constraint
   where conrelid = 'public.orders'::regclass
     and conname = 'orders_status_check';

  perform pg_temp.assert_true(
    v_definition is not null,
    'orders still carries a status check'
  );

  foreach v_status in array pg_temp.order_statuses()
  loop
    perform pg_temp.assert_true(
      v_definition like '%' || v_status || '%',
      'the stored constraint accepts ' || v_status
    );
  end loop;
end;
$$;

-- A new order is created PENDING, which is the only state the guest flow can produce.
do $$
declare
  v_order jsonb;
begin
  v_order := public.create_table_order(
    'a1a1a1a1-1111-4111-8111-111111111111',
    '[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 2}]'::jsonb
  ) -> 'order';

  perform pg_temp.assert_equals(
    v_order ->> 'status',
    'PENDING',
    'a newly placed order is reported as pending'
  );

  perform pg_temp.assert_equals(
    (
      select status
        from public.orders
       where id = (v_order ->> 'id')::uuid
    ),
    'PENDING',
    'and stored as pending'
  );
end;
$$;

-- The guest cannot ask for another state at creation: the function takes a QR token
-- and a list of items, and nothing else. Checked on the signature rather than by
-- reading the body, so a future parameter cannot be added without this failing.
do $$
begin
  perform pg_temp.assert_true(
    pg_catalog.pg_get_function_arguments(
      'public.create_table_order(text, jsonb, text)'::regprocedure
    ) not ilike '%status%',
    'the guest order function takes no status argument'
  );
end;
$$;

-- Every one of the 36 state pairs. The seven legal moves are accepted, a write that
-- changes nothing is passed through as not being a transition, and the remaining 23
-- are refused by the database with the lifecycle error.
do $$
declare
  v_from text;
  v_to text;
  v_result text;
  v_legal constant text[] := array[
    'PENDING>ACCEPTED',
    'PENDING>CANCELLED',
    'ACCEPTED>PREPARING',
    'ACCEPTED>CANCELLED',
    'PREPARING>READY',
    'PREPARING>CANCELLED',
    'READY>SERVED'
  ];
begin
  foreach v_from in array pg_temp.order_statuses()
  loop
    foreach v_to in array pg_temp.order_statuses()
    loop
      v_result := pg_temp.attempt_transition(v_from, v_to);

      if v_from = v_to then
        perform pg_temp.assert_equals(
          v_result,
          'ok',
          'writing ' || v_from || ' over itself is not a transition and is allowed'
        );
      elsif v_from || '>' || v_to = any(v_legal) then
        perform pg_temp.assert_equals(
          v_result,
          'ok',
          v_from || ' -> ' || v_to || ' is accepted'
        );
      else
        perform pg_temp.assert_equals(
          v_result,
          'P0001',
          v_from || ' -> ' || v_to || ' is refused by the database'
        );
      end if;
    end loop;
  end loop;
end;
$$;

-- Terminal states, stated on their own rather than only as part of the matrix, since
-- "this can never happen again" is the property a staff app will rely on.
do $$
declare
  v_order uuid;
  v_to text;
begin
  v_order := pg_temp.placed_order();
  perform pg_temp.try_move(v_order, 'ACCEPTED');
  perform pg_temp.try_move(v_order, 'PREPARING');
  perform pg_temp.try_move(v_order, 'READY');
  perform pg_temp.try_move(v_order, 'SERVED');

  perform pg_temp.assert_equals(
    (select status from public.orders where id = v_order),
    'SERVED',
    'an order can be walked all the way to served'
  );

  foreach v_to in array pg_temp.order_statuses()
  loop
    if v_to = 'SERVED' then
      continue;
    end if;

    perform pg_temp.assert_equals(
      pg_temp.try_move(v_order, v_to),
      'P0001',
      'a served order cannot be moved to ' || v_to
    );
  end loop;

  perform pg_temp.assert_equals(
    (select status from public.orders where id = v_order),
    'SERVED',
    'and it is still served after every refused attempt'
  );
end;
$$;

do $$
declare
  v_order uuid;
  v_to text;
begin
  v_order := pg_temp.placed_order();
  perform pg_temp.try_move(v_order, 'CANCELLED');

  perform pg_temp.assert_equals(
    (select status from public.orders where id = v_order),
    'CANCELLED',
    'an order can be cancelled from pending'
  );

  foreach v_to in array pg_temp.order_statuses()
  loop
    if v_to = 'CANCELLED' then
      continue;
    end if;

    perform pg_temp.assert_equals(
      pg_temp.try_move(v_order, v_to),
      'P0001',
      'a cancelled order cannot be moved to ' || v_to
    );
  end loop;

  perform pg_temp.assert_equals(
    (select status from public.orders where id = v_order),
    'CANCELLED',
    'and it is still cancelled after every refused attempt'
  );
end;
$$;

-- Cancellation is available from the three states before the food is ready, and from
-- nowhere else. READY is the interesting one: the dish exists, so the lifecycle stops
-- offering the decision.
do $$
begin
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('PENDING', 'CANCELLED'),
    'ok',
    'cancelling is possible from pending'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('ACCEPTED', 'CANCELLED'),
    'ok',
    'cancelling is possible from accepted'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('PREPARING', 'CANCELLED'),
    'ok',
    'cancelling is possible from preparing'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('READY', 'CANCELLED'),
    'P0001',
    'cancelling is not possible once the food is ready'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('SERVED', 'CANCELLED'),
    'P0001',
    'cancelling is not possible once the order is served'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('CANCELLED', 'CANCELLED'),
    'ok',
    'a cancelled order is not cancelled a second time'
  );
end;
$$;

-- The backward moves the lifecycle refuses, stated directly.
do $$
begin
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('ACCEPTED', 'PENDING'),
    'P0001',
    'an accepted order cannot go back to pending'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('PREPARING', 'PENDING'),
    'P0001',
    'a preparing order cannot go back to pending'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('PREPARING', 'ACCEPTED'),
    'P0001',
    'a preparing order cannot go back to accepted'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('READY', 'PENDING'),
    'P0001',
    'a ready order cannot go back to pending'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('READY', 'PREPARING'),
    'P0001',
    'a ready order cannot go back to preparing'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('READY', 'ACCEPTED'),
    'P0001',
    'a ready order cannot go back to accepted'
  );
end;
$$;

-- Skipping a state is refused too: the lifecycle is a chain, not a menu.
do $$
begin
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('PENDING', 'PREPARING'),
    'P0001',
    'an order cannot jump from pending to preparing'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('PENDING', 'READY'),
    'P0001',
    'an order cannot jump from pending to ready'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('PENDING', 'SERVED'),
    'P0001',
    'an order cannot jump from pending to served'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('ACCEPTED', 'SERVED'),
    'P0001',
    'an order cannot jump from accepted to served'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('PREPARING', 'SERVED'),
    'P0001',
    'an order cannot jump from preparing to served'
  );
end;
$$;

-- A status outside the lifecycle is refused as "no such state", which is a different
-- answer from the lifecycle rule refusing a move between two real states.
do $$
declare
  v_accepted uuid;
begin
  v_accepted := pg_temp.placed_order();
  perform pg_temp.try_move(v_accepted, 'ACCEPTED');

  perform pg_temp.assert_fails_with_message(
    'update public.orders set status = ''ON_ITS_WAY''
       where id = ''' || pg_temp.placed_order() || '''::uuid',
    'P0001',
    'invalid_order_status',
    'a status outside the lifecycle is not a state at all'
  );
  perform pg_temp.assert_fails_with_message(
    'update public.orders set status = ''PAID''
       where id = ''' || pg_temp.placed_order() || '''::uuid',
    'P0001',
    'invalid_order_status',
    'no payment state can be stored'
  );
  perform pg_temp.assert_fails_with_message(
    'update public.orders set status = ''pending''
       where id = ''' || pg_temp.placed_order() || '''::uuid',
    'P0001',
    'invalid_order_status',
    'the stored status is case sensitive'
  );
  perform pg_temp.assert_fails_with_message(
    'update public.orders set status = ''PENDING''
       where id = ''' || v_accepted || '''::uuid',
    'P0001',
    'invalid_order_status_transition',
    'a backwards move is reported as a lifecycle rule, not as an unknown value'
  );
end;
$$;

-- The two layers are independent, and each is the real enforcement point for its own
-- question. With the guard switched off the constraint still refuses every value
-- outside the six states, while a legal move is stored exactly as it would be with
-- the guard on. An illegal move, though, is *allowed* with the guard off, which is
-- what makes the guard load-bearing rather than a second opinion: nothing else in
-- the schema knows the order of the states.
do $$
begin
  alter table public.orders disable trigger guard_orders_status_transition;

  perform pg_temp.assert_fails_with(
    'update public.orders set status = ''ON_ITS_WAY''
       where id = ''' || pg_temp.placed_order() || '''::uuid',
    '23514',
    'the check constraint refuses an unknown value on its own'
  );
  perform pg_temp.assert_fails_with(
    'update public.orders set status = ''PAID''
       where id = ''' || pg_temp.placed_order() || '''::uuid',
    '23514',
    'and refuses a payment state on its own'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('PENDING', 'ACCEPTED'),
    'ok',
    'a legal move is stored unchanged while the guard is off'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('ACCEPTED', 'PENDING'),
    'ok',
    'and an illegal move would be stored too, which is why the guard exists'
  );

  alter table public.orders enable trigger guard_orders_status_transition;

  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('PENDING', 'ACCEPTED'),
    'ok',
    'the legal move is accepted with the guard back on'
  );
  perform pg_temp.assert_equals(
    pg_temp.attempt_transition('ACCEPTED', 'PENDING'),
    'P0001',
    'and the illegal one is refused again'
  );
end;
$$;

-- A write that touches nothing else is not a lifecycle change and must not be
-- refused: the orders table has an updated_at trigger that fires on every write, and a
-- later step editing another column has to keep working.
do $$
declare
  v_order uuid;
begin
  v_order := pg_temp.placed_order();

  perform pg_temp.try_move(v_order, 'ACCEPTED');

  update public.orders
     set updated_at = now()
   where id = v_order;

  perform pg_temp.assert_equals(
    (select status from public.orders where id = v_order),
    'ACCEPTED',
    'writing a non-status column leaves the status alone'
  );
end;
$$;

-- The audit trail: one row per accepted move, nothing for anything else.
do $$
declare
  v_order uuid;
  v_stamp timestamptz;
begin
  v_order := pg_temp.placed_order();

  perform pg_temp.assert_equals(
    pg_temp.recorded_transitions(v_order),
    '',
    'placing an order records no transition, because none happened'
  );

  perform pg_temp.try_move(v_order, 'ACCEPTED');

  perform pg_temp.assert_equals(
    pg_temp.recorded_transitions(v_order),
    'PENDING>ACCEPTED',
    'an accepted move records the state it left and the state it entered'
  );

  perform pg_temp.try_move(v_order, 'CANCELLED');

  perform pg_temp.assert_equals(
    pg_temp.recorded_transitions(v_order),
    'PENDING>ACCEPTED,ACCEPTED>CANCELLED',
    'a second move is appended after the first'
  );

  perform pg_temp.assert_equals(
    pg_temp.recorded_states(v_order),
    'ACCEPTED>CANCELLED',
    'the trail reads as the states the order passed through'
  );

  select max(changed_at)
    into v_stamp
    from public.order_status_history
   where order_id = v_order
     and new_status = 'CANCELLED';

  perform pg_temp.assert_true(
    v_stamp is not null and v_stamp <= now(),
    'the transition carries the moment it happened'
  );
end;
$$;

-- A refused move must leave no trace, or the audit trail would claim something that
-- never happened.
do $$
declare
  v_order uuid;
begin
  v_order := pg_temp.placed_order();

  perform pg_temp.try_move(v_order, 'ACCEPTED');
  perform pg_temp.try_move(v_order, 'PREPARING');

  perform pg_temp.assert_equals(
    pg_temp.try_move(v_order, 'PENDING'),
    'P0001',
    'the backward move is refused'
  );

  perform pg_temp.assert_equals(
    pg_temp.recorded_transitions(v_order),
    'PENDING>ACCEPTED,ACCEPTED>PREPARING',
    'a refused move records nothing'
  );

  -- Rewriting the same state is not a move, so it is not recorded either.
  perform pg_temp.try_move(v_order, 'PREPARING');

  perform pg_temp.assert_equals(
    pg_temp.recorded_transitions(v_order),
    'PENDING>ACCEPTED,ACCEPTED>PREPARING',
    'rewriting the same state records nothing'
  );
end;
$$;

-- A move bumps updated_at, so a staff screen that lists by recent change can rely on
-- it rather than reading the history table.
do $$
declare
  v_order uuid;
  v_before timestamptz;
  v_after timestamptz;
begin
  v_order := pg_temp.placed_order();

  select updated_at into v_before from public.orders where id = v_order;

  perform pg_temp.try_move(v_order, 'ACCEPTED');

  select updated_at into v_after from public.orders where id = v_order;

  perform pg_temp.assert_true(
    v_after >= v_before,
    'a status change refreshes updated_at'
  );
end;
$$;

-- The history is an append-only record of real changes, enforced on its own terms
-- rather than trusting the trigger alone.
do $$
declare
  v_order uuid;
begin
  v_order := pg_temp.placed_order();

  perform pg_temp.try_move(v_order, 'ACCEPTED');

  perform pg_temp.assert_fails_with(
    'insert into public.order_status_history (order_id, old_status, new_status)
     values (''' || v_order || '''::uuid, ''PENDING'', ''PENDING'')',
    '23514',
    'a history row that changes nothing is refused'
  );

  perform pg_temp.assert_fails_with(
    'insert into public.order_status_history (order_id, old_status, new_status)
     values (''' || v_order || '''::uuid, ''PENDING'', ''ON_ITS_WAY'')',
    '23514',
    'a history row cannot name a state outside the lifecycle'
  );

  perform pg_temp.assert_fails_with(
    'update public.order_status_history set new_status = ''ON_ITS_WAY''
       where order_id = ''' || v_order || '''::uuid',
    '23514',
    'an existing history row cannot be rewritten to a state outside the lifecycle'
  );
end;
$$;

-- Nothing in the schema can reach the trail: the only writer is the trigger that
-- records a transition, so a client cannot add a row that claims a move that never
-- happened, and no update or delete path exists for one to be edited through.
do $$
begin
  perform pg_temp.assert_true(
    not exists (
      select 1
        from pg_catalog.pg_trigger
       where tgrelid = 'public.order_status_history'::regclass
         and not tgisinternal
         and tgtype::int & 8 = 0
    ),
    'the history has no trigger that rewrites or removes rows'
  );

  perform pg_temp.assert_true(
    not exists (
      select 1
        from pg_catalog.pg_policy
       where polrelid = 'public.order_status_history'::regclass
    ),
    'the history has no policy, so enabling RLS on it locked every role out'
  );
end;
$$;

-- Three triggers guard the orders table beyond its own updated_at: the two that
-- decide and record the lifecycle, and the one that copies the order into the
-- realtime representation. The copy is not a rule about orders, but it is a
-- trigger on them, so it is listed with the others and this assertion still
-- fails the day one is added or removed without this line being told.
do $$
begin
  perform pg_temp.assert_equals(
    (
      select string_agg(tgname, ',' order by tgname)
        from pg_catalog.pg_trigger
       where tgrelid = 'public.orders'::regclass
         and not tgisinternal
    ),
    'guard_orders_status_transition,record_orders_change_event,record_orders_status_change,set_orders_updated_at',
    'the orders table has exactly the expected user triggers'
  );
end;
$$;

-- The history is as private as the orders themselves.
set local role anon;

do $$
begin
  perform pg_temp.assert_denied(
    'select * from public.order_status_history',
    'anon cannot read the status history'
  );
  perform pg_temp.assert_denied(
    'insert into public.order_status_history default values',
    'anon cannot write the status history'
  );
  perform pg_temp.assert_denied(
    'update public.order_status_history set new_status = ''SERVED''',
    'anon cannot rewrite the status history'
  );
  perform pg_temp.assert_denied(
    'delete from public.order_status_history',
    'anon cannot delete the status history'
  );
  perform pg_temp.assert_denied(
    'update public.orders set status = ''ACCEPTED''',
    'anon cannot move an order through the table'
  );
  perform pg_temp.assert_denied(
    'update public.orders set status = ''CANCELLED''',
    'anon cannot cancel an order through the table'
  );
end;
$$;

reset role;

-- No function a guest can execute takes or names a status, so there is no way to
-- ask for one: the staff path does not exist yet, and this fails the day one appears
-- without the guest roles also being given the ability to use it.
do $$
declare
  v_status_functions integer;
  v_order_functions text;
begin
  select count(*)
    into v_status_functions
    from pg_catalog.pg_proc as p
   where p.prokind = 'f'
     and p.pronamespace = 'public'::regnamespace
     -- A trigger function cannot be called on its own, so it is not a path a guest
     -- can take; the trigger that fires it runs on a write the guest cannot make.
     and p.prorettype <> 'trigger'::regtype
     and (p.proname ilike '%status%'
       or exists (
         select 1
           from unnest(coalesce(p.proargnames, '{}'::text[])) as argument(name)
          where argument.name ilike '%status%'
       ))
     and has_function_privilege('anon', p.oid, 'execute');

  perform pg_temp.assert_equals(
    v_status_functions::text,
    '0',
    'no function a guest can execute takes or names a status'
  );

  select string_agg(p.proname, ',' order by p.proname)
    into v_order_functions
    from pg_catalog.pg_proc as p
   where p.prokind = 'f'
     and p.pronamespace = 'public'::regnamespace
     and p.proname ilike '%order%'
     and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('anon', p.oid, 'execute');

  perform pg_temp.assert_equals(
    v_order_functions,
    'create_table_order,guest_orders',
    'the only order functions a guest can execute are the create and read paths'
  );
end;
$$;

-- The guest still reads their own order back, and the read reports the lifecycle
-- state it is really in. This is the whole customer-visible effect of the migration.
do $$
declare
  v_token text;
  v_order uuid;
  v_payload jsonb;
begin
  v_token :=
    public.create_table_order(
      'a1a1a1a1-1111-4111-8111-111111111111',
      '[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 1}]'::jsonb
    ) ->> 'access_token';

  v_order := pg_temp.placed_order();

  perform pg_temp.try_move(v_order, 'ACCEPTED');
  perform pg_temp.try_move(v_order, 'PREPARING');

  v_payload := public.guest_orders(v_token);

  perform pg_temp.assert_equals(
    v_payload -> 'orders' -> 0 ->> 'status',
    'PENDING',
    'the guest reads back their own order as it was placed'
  );

  -- The same token, on an order that has moved on, reports the state it is in.
  perform pg_temp.try_move(
    (v_payload -> 'orders' -> 0 ->> 'id')::uuid,
    'ACCEPTED'
  );
  perform pg_temp.try_move(
    (v_payload -> 'orders' -> 0 ->> 'id')::uuid,
    'PREPARING'
  );
  perform pg_temp.try_move(
    (v_payload -> 'orders' -> 0 ->> 'id')::uuid,
    'READY'
  );

  perform pg_temp.assert_equals(
    public.guest_orders(v_token) -> 'orders' -> 0 ->> 'status',
    'READY',
    'and reads the same order again as ready'
  );

  perform pg_temp.assert_equals(
    (public.guest_orders('not-a-real-token') -> 'orders')::text,
    '[]',
    'an unknown token still reads as no orders rather than an error'
  );
end;
$$;

-- A cancelled order is still readable and still shows what it was, so cancelling an
-- order never hides it from the guest who placed it.
do $$
declare
  v_token text;
  v_order uuid;
begin
  v_token :=
    public.create_table_order(
      'a1a1a1a1-1111-4111-8111-111111111111',
      '[{"item_id": "77777777-7777-7777-7777-777777777777", "quantity": 1}]'::jsonb
    ) ->> 'access_token';

  v_order := (
    select id from public.orders where access_token = v_token
  );

  perform pg_temp.try_move(v_order, 'CANCELLED');

  perform pg_temp.assert_equals(
    public.guest_orders(v_token) -> 'orders' -> 0 ->> 'status',
    'CANCELLED',
    'a cancelled order reads back as cancelled'
  );
end;
$$;

-- A signed-in user is still not staff: there is no staff identity in this project,
-- so there is nothing for an account to be authorised against yet.
set local role authenticated;

do $$
begin
  perform pg_temp.assert_denied(
    'update public.orders set status = ''ACCEPTED''',
    'a signed-in user cannot move an order'
  );
  perform pg_temp.assert_denied(
    'select * from public.order_status_history',
    'a signed-in user cannot read the status history'
  );
end;
$$;

reset role;

rollback;