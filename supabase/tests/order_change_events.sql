-- Realtime order-change representation checks: what the representation is, who
-- may see a row of it, what reaches the realtime publication, and what must not.
--
-- Runs against a database where supabase/migrations has been applied, as the
-- table owner (who is also the writer of the trigger that maintains the
-- representation) and as the `anon` and `authenticated` roles with a chosen
-- identity, which is what a real call looks like:
--
--   * the representation holds exactly five fields — order id, restaurant id,
--     branch id, status and updated_at — and no access_token column exists on
--     it, so no realtime payload can carry a guest credential
--   * public.orders, order_items, order_access and order_status_history are in
--     no publication at all, hold no policy, and grant nothing to anon or to
--     authenticated: the existing deny-by-default is asserted unchanged
--   * only this table is in supabase_realtime, and the publication publishes
--     inserts and updates only — never deletes, the one event Realtime cannot
--     authorize with row level security
--   * anon reaches nothing: no grant, no policy, and not the authorization
--     helper the policy runs on
--   * a signed-in user with no session, a signed-in non-member, a deactivated
--     member and a CASHIER each read zero rows
--   * every active role that works orders — OWNER, MANAGER, WAITER, KITCHEN —
--     reads exactly its own restaurant's events and nothing from the other
--     restaurant, in both directions, plus the member who belongs to both
--   * a member's read is restaurant-wide across branches, because the schema
--     has no branch-level authorization and the policy does not pretend it has
--   * no client role may insert, update or delete a row: the trigger is the
--     only writer, and forging an event is refused
--   * placing an order creates its row, a staff status change refreshes the
--     same single row, a refused transition changes nothing, a cancellation
--     reaches the representation, and the row count equals the order count
--   * the policy's role list and the one inside
--     private.can_read_restaurant_orders are the same list, asserted so they
--     cannot drift apart
--   * the staff and guest order functions keep exactly their old grants
--
-- Usage, against a database where supabase/migrations has been applied:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/order_change_events.sql
--
-- On Supabase the auth schema and the anon/authenticated roles already exist and
-- the guard below does nothing. Against a plain Postgres it creates a minimal
-- stand-in, as the other scripts do. Everything runs in one transaction that is
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

-- Asserts that [statement] is refused for the current role. Any error passes,
-- which is intentional: a permission error and a rule refusing the statement are
-- both answers, and both mean the statement did not happen.
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
-- Null signs nobody out, which is the anonymous call a client makes with no
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

-- A freshly placed order, through the guest's own function, so every check below
-- starts from a real order rather than a hand-built row. SECURITY DEFINER
-- because the caller may be a client role with no grant on the order tables.
create or replace function pg_temp.placed_order(
  p_qr_token text default 'a1a1a1a1-1111-4111-8111-111111111111',
  p_item text default '77777777-7777-7777-7777-777777777777',
  p_quantity integer default 1
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
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

-- ---------------------------------------------------------------------------
-- Fixtures
--
-- Two restaurants, so a leak between them is a wrong answer rather than an empty
-- one. Restaurant A has two branches, so restaurant-wide visibility has two
-- branches to be wrong about. Twelve identities cover every way a caller can
-- fail to see a row: no session, no membership, a deactivated membership, a role
-- that does not work orders, the four roles that do, a second restaurant with
-- the same spread, and one person who belongs to both restaurants.
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
  ('e0000000-0000-4000-8000-000000000010'::uuid),
  ('e0000000-0000-4000-8000-000000000011'::uuid),
  ('e0000000-0000-4000-8000-000000000012'::uuid)
) as staff(id);

insert into public.profiles (id)
select id from auth.users;

insert into public.restaurant_members (restaurant_id, user_id, role, is_active)
values
  -- Restaurant A: the four roles that work orders, a cashier, and a deactivated
  -- member who is still a member on paper with no access of any kind.
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
  ('11111111-1111-1111-1111-111111111111',
   'e0000000-0000-4000-8000-000000000006', 'WAITER', false),
  -- Restaurant B, with the same spread so the isolation runs both ways.
  ('22222222-2222-2222-2222-222222222222',
   'e0000000-0000-4000-8000-000000000007', 'OWNER', true),
  ('22222222-2222-2222-2222-222222222222',
   'e0000000-0000-4000-8000-000000000010', 'KITCHEN', true),
  ('22222222-2222-2222-2222-222222222222',
   'e0000000-0000-4000-8000-000000000011', 'CASHIER', true),
  ('22222222-2222-2222-2222-222222222222',
   'e0000000-0000-4000-8000-000000000012', 'MANAGER', true),
  -- One member of both restaurants: membership, not ownership, is what grants
  -- access, and belonging to two restaurants is two grants and not a leak.
  ('22222222-2222-2222-2222-222222222222',
   'e0000000-0000-4000-8000-000000000009', 'OWNER', true),
  ('11111111-1111-1111-1111-111111111111',
   'e0000000-0000-4000-8000-000000000009', 'WAITER', true);
-- e0000000-0000-4000-8000-000000000008 has no membership anywhere.

-- Seven orders: three in A's first branch, two in its second, two in the other
-- restaurant. The representation must mirror all of them before a single staff
-- move happens, which is what proves the trigger fires on placement and not
-- only on a status change.
select pg_temp.placed_order(p_quantity => 2);
select pg_temp.placed_order(p_quantity => 1);
select pg_temp.placed_order(p_quantity => 3);
select pg_temp.placed_order('a2a2a2a2-2222-4222-8222-222222222222',
                            p_quantity => 1);
select pg_temp.placed_order('a2a2a2a2-2222-4222-8222-222222222222',
                            p_quantity => 2);
select pg_temp.placed_order('b1b1b1b1-1111-4111-8111-111111111111',
                            '77777777-7777-7777-7777-777777777778', 1);
select pg_temp.placed_order('b1b1b1b1-1111-4111-8111-111111111111',
                            '77777777-7777-7777-7777-777777777778', 2);

-- ---------------------------------------------------------------------------
-- What the representation is, what is published, and what stays closed
-- ---------------------------------------------------------------------------
do $$
declare
  v_columns text;
  v_policies integer;
  v_policy record;
  v_table text;
  v_priv text;
  v_role text;
  v_rls boolean;
  v_count integer;
  v_policy_qual text;
  v_helper_source text;
  v_helper_array text;
  v_policy_array text;
  v_publication_tables text;
  v_event_keys text;
  v_trigger record;
  v_function record;
begin
  -- Five fields and no others, in creation order. The exact list is the whole
  -- answer to "what reaches the realtime payload": if a column is not here it
  -- cannot be in an event, and access_token is deliberately not here.
  select coalesce(
           string_agg(
             att.attname || ':' || pg_catalog.format_type(att.atttypid, null),
             ',' order by att.attnum
           ),
           ''
         )
    into v_columns
    from pg_catalog.pg_attribute as att
   where att.attrelid = 'public.order_change_events'::regclass
     and att.attnum > 0
     and not att.attisdropped;

  perform pg_temp.assert_equals(
    v_columns,
    'order_id:uuid,restaurant_id:uuid,branch_id:uuid,status:text,' ||
    'updated_at:timestamp with time zone',
    'the representation is exactly order id, restaurant, branch, status and updated_at'
  );

  perform pg_temp.assert_true(
    not exists (
      select 1
        from pg_catalog.pg_attribute as att
       where att.attrelid = 'public.order_change_events'::regclass
         and att.attnum > 0
         and not att.attisdropped
         and att.attname in ('access_token', 'token', 'qr_token', 'table_id')
    ),
    'no guest credential, token or table identifier exists on the representation'
  );

  perform pg_temp.assert_true(
    exists (
      select 1
        from pg_catalog.pg_constraint as con
       where con.conrelid = 'public.order_change_events'::regclass
         and con.contype = 'p'
         and pg_catalog.pg_get_constraintdef(con.oid)
           = 'PRIMARY KEY (order_id)'
    ),
    'the primary key is the order id, so an order has one row however it moves'
  );

  perform pg_temp.assert_true(
    exists (
      select 1
        from pg_catalog.pg_constraint as con
       where con.conrelid = 'public.order_change_events'::regclass
         and con.contype = 'f'
         and pg_catalog.pg_get_constraintdef(con.oid) like
           '%FOREIGN KEY (order_id, restaurant_id) REFERENCES orders(id, restaurant_id)%'
    ),
    'a row can only name an order of the same restaurant it claims'
  );

  select relrowsecurity
    into v_rls
    from pg_catalog.pg_class
   where oid = 'public.order_change_events'::regclass;

  perform pg_temp.assert_true(
    v_rls,
    'row level security is enabled on the representation'
  );

  -- One policy, and only one: select, for the signed-in role, and nothing for
  -- anybody else. There is no insert, update or delete policy, so even a role
  -- that somehow held the privilege would have no rule allowing the write.
  select count(*)
    into v_policies
    from pg_catalog.pg_policies
   where schemaname = 'public'
     and tablename = 'order_change_events';

  perform pg_temp.assert_equals(
    v_policies::text,
    '1',
    'the representation has exactly one policy'
  );

  select policyname, cmd, roles, permissive, qual
    into v_policy
    from pg_catalog.pg_policies
   where schemaname = 'public'
     and tablename = 'order_change_events';

  perform pg_temp.assert_equals(
    v_policy.policyname,
    'order_change_events_select_order_staff',
    'the policy is the named membership policy'
  );
  perform pg_temp.assert_equals(
    v_policy.cmd,
    'SELECT',
    'the policy covers selecting only'
  );
  perform pg_temp.assert_equals(
    v_policy.roles::text,
    '{authenticated}',
    'the policy applies to the signed-in role only'
  );
  perform pg_temp.assert_equals(
    v_policy.permissive,
    'PERMISSIVE',
    'the policy is permissive, so rows are allowed by it and by nothing else'
  );

  v_policy_qual := pg_catalog.regexp_replace(v_policy.qual, '\s+', '', 'g');

  perform pg_temp.assert_true(
    v_policy_qual like '%private.has_restaurant_role(restaurant_id,%',
    'the policy checks the row''s restaurant against the caller'
  );
  perform pg_temp.assert_true(
    v_policy_qual not like '%public.orders%',
    'the policy never reaches into the orders table'
  );
  perform pg_temp.assert_true(
    v_policy_qual not like '%using(true)%',
    'the policy is not a blanket using (true)'
  );
  perform pg_temp.assert_true(
    v_policy_qual like '%''OWNER''%'
      and v_policy_qual like '%''MANAGER''%'
      and v_policy_qual like '%''WAITER''%'
      and v_policy_qual like '%''KITCHEN''%',
    'the policy names the four roles that work orders'
  );
  perform pg_temp.assert_true(
    v_policy_qual not like '%''CASHIER''%',
    'the policy does not admit the role that may not read orders'
  );

  -- The publication: this table and nothing else, ever. The order tables are in
  -- no publication at all, which is what keeps their full rows — token
  -- included — out of every realtime payload there is.
  select coalesce(
           string_agg(tablename, ',' order by tablename),
           'none'
         )
    into v_publication_tables
    from pg_catalog.pg_publication_tables
   where pubname = 'supabase_realtime';

  perform pg_temp.assert_equals(
    v_publication_tables,
    'order_change_events',
    'the realtime publication holds this table and no other'
  );

  perform pg_temp.assert_true(
    not exists (
      select 1
        from pg_catalog.pg_publication_tables
       where tablename in (
         'orders', 'order_items', 'order_access', 'order_status_history'
       )
    ),
    'no order table is in any publication'
  );

  perform pg_temp.assert_true(
    exists (
      select 1
        from pg_catalog.pg_publication
       where pubname = 'supabase_realtime'
         and not puballtables
         and pubinsert
         and pubupdate
         and not pubdelete
    ),
    'the publication publishes inserts and updates, and never deletes'
  );

  -- The existing deny-by-default, asserted table by table and privilege by
  -- privilege: RLS on, no policy, nothing granted to either client role. This
  -- is the state every order migration left behind, and the new table beside
  -- them must not have moved it.
  foreach v_table in array array[
    'orders', 'order_items', 'order_access', 'order_status_history'
  ]
  loop
    select c.relrowsecurity
      into v_rls
      from pg_catalog.pg_class as c
     where c.oid = ('public.' || v_table)::regclass;

    perform pg_temp.assert_true(
      v_rls,
      'row level security is still enabled on ' || v_table
    );

    select count(*)
      into v_count
      from pg_catalog.pg_policies
     where schemaname = 'public'
       and tablename = v_table;

    perform pg_temp.assert_equals(
      v_count::text,
      '0',
      v_table || ' still has no policy at all'
    );

    foreach v_role in array array['anon', 'authenticated']
    loop
      foreach v_priv in array array['select', 'insert', 'update', 'delete']
      loop
        perform pg_temp.assert_true(
          not has_table_privilege(v_role, ('public.' || v_table)::regclass, v_priv),
          v_role || ' holds no ' || v_priv || ' privilege on ' || v_table
        );
      end loop;
    end loop;
  end loop;

  -- The representation's own grants: a guest has nothing at all, and a
  -- signed-in caller reads and cannot write. The realtime authorization runs
  -- this select as the subscriber, so this pair — grant plus policy — is the
  -- whole of who may receive an event.
  foreach v_role in array array['anon', 'authenticated']
  loop
    foreach v_priv in array array['select', 'insert', 'update', 'delete']
    loop
      perform pg_temp.assert_equals(
        has_table_privilege(
          v_role, 'public.order_change_events'::regclass, v_priv
        )::text,
        case
          when v_role = 'authenticated' and v_priv = 'select' then 'true'
          else 'false'
        end,
        v_role || ' holds exactly the expected ' || v_priv ||
          ' privilege on the representation'
      );
    end loop;
  end loop;

  -- The trigger that writes it: a copy, not a decision. After, row level,
  -- insert and update, not security definer, empty search path, and no token
  -- anywhere in its body.
  select tgname, tgtype::integer as tgtype, tgenabled
    into v_trigger
    from pg_catalog.pg_trigger
   where tgrelid = 'public.orders'::regclass
     and tgname = 'record_orders_change_event'
     and not tgisinternal;

  perform pg_temp.assert_true(
    v_trigger.tgname is not null,
    'the copy trigger is on the orders table'
  );
  perform pg_temp.assert_equals(
    v_trigger.tgenabled,
    'O',
    'the copy trigger is enabled for every writer'
  );
  perform pg_temp.assert_true(
    (v_trigger.tgtype & 1) <> 0,
    'the copy trigger fires per row'
  );
  perform pg_temp.assert_true(
    (v_trigger.tgtype & 2) = 0,
    'the copy trigger is after the write, so it copies what was stored'
  );
  perform pg_temp.assert_true(
    (v_trigger.tgtype & 4) <> 0 and (v_trigger.tgtype & 16) <> 0,
    'the copy trigger fires on insert and on update'
  );
  perform pg_temp.assert_true(
    (v_trigger.tgtype & 8) = 0,
    'the copy trigger never fires on a delete'
  );

  select p.prosecdef,
         p.prorettype = 'trigger'::regtype as is_trigger,
         coalesce(p.proconfig::text, '') as config,
         pg_catalog.pg_get_functiondef(p.oid) as source
    into v_function
    from pg_catalog.pg_proc as p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'record_order_change_event';

  perform pg_temp.assert_true(
    v_function.is_trigger,
    'the copy function is a trigger function, so it cannot be called directly'
  );
  perform pg_temp.assert_true(
    not v_function.prosecdef,
    'the copy function runs as its caller, the writer of the order'
  );
  perform pg_temp.assert_true(
    v_function.config like '%search_path=\\"\\"%',
    'the copy function pins its search path'
  );
  perform pg_temp.assert_true(
    v_function.source not like '%access_token%',
    'the copy function never mentions the guest token'
  );
  perform pg_temp.assert_true(
    v_function.source like '%public.order_change_events%',
    'the copy function writes the representation by its qualified name'
  );

  -- The two role lists are one list in two places: the policy above, and the
  -- helper the staff functions use. Asserted here so neither can gain or lose a
  -- role on its own.
  v_helper_source := pg_catalog.regexp_replace(
    pg_catalog.pg_get_functiondef(
      'private.can_read_restaurant_orders(uuid)'::regprocedure
    ),
    '\s+', '', 'g'
  );

  perform pg_temp.assert_true(
    v_helper_source like '%''OWNER''%'
      and v_helper_source like '%''MANAGER''%'
      and v_helper_source like '%''WAITER''%'
      and v_helper_source like '%''KITCHEN''%',
    'the staff read helper names the same four roles'
  );
  perform pg_temp.assert_true(
    v_helper_source not like '%''CASHIER''%',
    'the staff read helper excludes the same role'
  );
  -- The two role lists are one list in two places: the policy above, and the
  -- helper the staff functions use. Both are read as source, their array
  -- literal is extracted and normalised, and the two normalised forms must be
  -- equal — asserted so neither can gain or lose a role on its own.
  v_helper_array := pg_catalog.regexp_replace(
    pg_catalog.substring(lower(v_helper_source), 'array\[[^\]]*\]'),
    '::text|\s+', '', 'g'
  );
  v_policy_array := pg_catalog.regexp_replace(
    pg_catalog.substring(lower(v_policy_qual), 'array\[[^\]]*\]'),
    '::text|\s+', '', 'g'
  );

  perform pg_temp.assert_true(
    v_helper_array is not null and v_policy_array is not null,
    'both role lists are written as an array literal that can be compared'
  );
  perform pg_temp.assert_equals(
    v_helper_array,
    v_policy_array,
    'the policy and the helper carry the same role list'
  );

  -- The helper the policy runs is executable by the signed-in role and by
  -- nobody else; the staff read helper stays out of client hands exactly as its
  -- migration left it.
  perform pg_temp.assert_true(
    has_function_privilege(
      'authenticated', 'private.has_restaurant_role(uuid,text[])', 'execute'
    ),
    'the policy primitive is executable by the signed-in role'
  );
  perform pg_temp.assert_true(
    not has_function_privilege(
      'anon', 'private.has_restaurant_role(uuid,text[])', 'execute'
    ),
    'the policy primitive is not executable by a guest'
  );
  perform pg_temp.assert_true(
    not has_function_privilege(
      'authenticated', 'private.can_read_restaurant_orders(uuid)', 'execute'
    ),
    'the staff read helper is still not executable by a client'
  );
  perform pg_temp.assert_true(
    not has_function_privilege(
      'authenticated', 'private.can_manage_restaurant_orders(uuid,text,text)',
      'execute'
    ),
    'the staff move helper is still not executable by a client'
  );

  -- The client paths keep exactly the grants they arrived with.
  perform pg_temp.assert_true(
    has_function_privilege(
      'authenticated', 'public.staff_list_orders(uuid,uuid,integer)', 'execute'
    ),
    'a signed-in member may still list orders'
  );
  perform pg_temp.assert_true(
    has_function_privilege(
      'authenticated', 'public.staff_set_order_status(uuid,text)', 'execute'
    ),
    'a signed-in member may still move an order'
  );
  perform pg_temp.assert_true(
    not has_function_privilege(
      'anon', 'public.staff_list_orders(uuid,uuid,integer)', 'execute'
    ),
    'a guest still may not list orders'
  );
  perform pg_temp.assert_true(
    not has_function_privilege(
      'anon', 'public.staff_set_order_status(uuid,text)', 'execute'
    ),
    'a guest still may not move an order'
  );
  perform pg_temp.assert_true(
    has_function_privilege(
      'anon', 'public.create_table_order(text,jsonb,text)', 'execute'
    ),
    'a guest may still place an order'
  );
  perform pg_temp.assert_true(
    has_function_privilege('anon', 'public.guest_orders(text)', 'execute'),
    'a guest may still read their own orders back'
  );

  -- Every order already has its row: the backfill covered the rows that existed
  -- before the migration, and the trigger has covered the seven just placed.
  select count(*)
    into v_count
    from public.orders as order_row
   where not exists (
     select 1
       from public.order_change_events as event_row
      where event_row.order_id = order_row.id
   );

  perform pg_temp.assert_equals(
    v_count::text,
    '0',
    'every order has a row in the representation'
  );

  select count(*)
    into v_count
    from public.order_change_events as event_row
   where not exists (
     select 1
       from public.orders as order_row
      where order_row.id = event_row.order_id
   );

  perform pg_temp.assert_equals(
    v_count::text,
    '0',
    'the representation holds no row for an order that does not exist'
  );

  select count(*)
    into v_count
    from public.order_change_events as event_row
    join public.orders as order_row
      on order_row.id = event_row.order_id
   where event_row.restaurant_id is distinct from order_row.restaurant_id
      or event_row.branch_id is distinct from order_row.branch_id
      or event_row.status is distinct from order_row.status
      or event_row.updated_at is distinct from order_row.updated_at;

  perform pg_temp.assert_equals(
    v_count::text,
    '0',
    'every field of every row matches the order it mirrors'
  );

  -- The payload of one row, as an event would carry it.
  select coalesce(
           string_agg(key, ',' order by key),
           ''
         )
    into v_event_keys
    from jsonb_object_keys(
      (select to_jsonb(event_row)
         from public.order_change_events as event_row
        limit 1)
    ) as key;

  perform pg_temp.assert_equals(
    v_event_keys,
    'branch_id,order_id,restaurant_id,status,updated_at',
    'the json payload of a row carries exactly the five expected keys'
  );

  perform pg_temp.assert_true(
    not exists (
      select 1
        from public.order_change_events as event_row
       where (to_jsonb(event_row)::text) like '%access_token%'
    ),
    'no row of the representation serialises a token'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- A guest reaches nothing, with or without the helper the policy runs on
-- ---------------------------------------------------------------------------
set local role anon;

do $$
begin
  perform pg_temp.assert_denied(
    'select * from public.order_change_events',
    'anon cannot read the representation'
  );
  perform pg_temp.assert_denied(
    'insert into public.order_change_events default values',
    'anon cannot forge an event'
  );
  perform pg_temp.assert_denied(
    'update public.order_change_events set status = ''SERVED''',
    'anon cannot rewrite an event'
  );
  perform pg_temp.assert_denied(
    'delete from public.order_change_events',
    'anon cannot remove an event'
  );
  perform pg_temp.assert_denied(
    'select private.has_restaurant_role(
       ''11111111-1111-1111-1111-111111111111'', array[''KITCHEN'']::text[])',
    'anon cannot run the authorization the policy is built on'
  );

  perform pg_temp.assert_true(
    not has_table_privilege(
      'anon', 'public.order_change_events'::regclass, 'select'
    ),
    'anon holds no select privilege on the representation'
  );
end;
$$;

reset role;

-- ---------------------------------------------------------------------------
-- Who sees what: every role, every membership, both restaurants
--
-- The expected counts are read as the owner first, in their own block, and
-- kept in transaction-local settings: a block that switches roles must not
-- also read the representation as the owner, so no plan ever has to serve two
-- roles. Then the same query runs under each identity and is compared. An
-- identity that should see nothing must read zero rows rather than be
-- refused: an empty read is what every membership policy in this schema
-- answers with.
-- ---------------------------------------------------------------------------
do $$
declare
  v_events_a integer;
  v_events_b integer;
  v_total integer;
begin
  select count(*),
         count(*) filter (
           where restaurant_id = '11111111-1111-1111-1111-111111111111'
         ),
         count(*) filter (
           where restaurant_id = '22222222-2222-2222-2222-222222222222'
         )
    into v_total, v_events_a, v_events_b
    from public.order_change_events;

  perform pg_temp.assert_true(
    v_events_a >= 5 and v_events_b >= 2,
    'the fixtures produced events in both restaurants'
  );
  perform pg_temp.assert_equals(
    (v_events_a + v_events_b)::text,
    v_total::text,
    'every event belongs to one of the two restaurants'
  );

  perform set_config('menukg.events_a', v_events_a::text, true);
  perform set_config('menukg.events_b', v_events_b::text, true);
end;
$$;

do $$
declare
  v_events_a integer;
  v_events_b integer;
  v_visible integer;
  v_visible_a integer;
  v_visible_b integer;
  v_branches integer;
  v_case record;
  v_expected integer;
begin
  v_events_a := current_setting('menukg.events_a')::integer;
  v_events_b := current_setting('menukg.events_b')::integer;

  for v_case in
    select *
      from (values
        ('e0000000-0000-4000-8000-000000000001'::uuid, 'A',
         'an OWNER of the restaurant reads its events'),
        ('e0000000-0000-4000-8000-000000000002'::uuid, 'A',
         'a MANAGER of the restaurant reads its events'),
        ('e0000000-0000-4000-8000-000000000003'::uuid, 'A',
         'a WAITER of the restaurant reads its events'),
        ('e0000000-0000-4000-8000-000000000004'::uuid, 'A',
         'a KITCHEN member of the restaurant reads its events'),
        ('e0000000-0000-4000-8000-000000000005'::uuid, 'ZERO',
         'a CASHIER reads nothing, as from the orders themselves'),
        ('e0000000-0000-4000-8000-000000000006'::uuid, 'ZERO',
         'a deactivated member reads nothing'),
        ('e0000000-0000-4000-8000-000000000007'::uuid, 'B',
         'an OWNER of the other restaurant reads only its own events'),
        ('e0000000-0000-4000-8000-000000000008'::uuid, 'ZERO',
         'a signed-in user with no membership reads nothing'),
        ('e0000000-0000-4000-8000-000000000009'::uuid, 'AB',
         'a member of both restaurants reads both, and only both'),
        ('e0000000-0000-4000-8000-000000000010'::uuid, 'B',
         'a KITCHEN member of the other restaurant reads only its own'),
        ('e0000000-0000-4000-8000-000000000011'::uuid, 'ZERO',
         'a CASHIER of the other restaurant reads nothing'),
        ('e0000000-0000-4000-8000-000000000012'::uuid, 'B',
         'a MANAGER of the other restaurant reads only its own events'),
        (null::uuid, 'ZERO',
         'a signed-in caller with no session reads nothing')
      ) as cases(user_id, scope, label)
  loop
    set local role authenticated;
    perform pg_temp.sign_in(v_case.user_id);

    select count(*),
           count(*) filter (
             where restaurant_id = '11111111-1111-1111-1111-111111111111'
           ),
           count(*) filter (
             where restaurant_id = '22222222-2222-2222-2222-222222222222'
           )
      into v_visible, v_visible_a, v_visible_b
      from public.order_change_events;

    reset role;

    v_expected := case v_case.scope
      when 'A' then v_events_a
      when 'B' then v_events_b
      when 'AB' then v_events_a + v_events_b
      else 0
    end;

    perform pg_temp.assert_equals(
      v_visible::text,
      v_expected::text,
      v_case.label
    );

    perform pg_temp.assert_equals(
      (v_visible_a + v_visible_b)::text,
      v_visible::text,
      v_case.label || ': nothing from an unknown restaurant'
    );
  end loop;

  -- The read is restaurant-wide across branches, because the membership is
  -- restaurant-wide: a KITCHEN member of A sees the events of both of A's
  -- branches, which is what the schema's model actually says.
  set local role authenticated;
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000004');

  select count(distinct branch_id)
    into v_branches
    from public.order_change_events
   where restaurant_id = '11111111-1111-1111-1111-111111111111';

  reset role;

  perform pg_temp.assert_equals(
    v_branches::text,
    '2',
    'a member reads every branch of their own restaurant'
  );

  -- Deactivating a membership revokes the read at once, without any change to
  -- the representation itself.
  update public.restaurant_members
     set is_active = false
   where restaurant_id = '11111111-1111-1111-1111-111111111111'
     and user_id = 'e0000000-0000-4000-8000-000000000002';

  set local role authenticated;
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000002');

  select count(*) into v_visible from public.order_change_events;

  reset role;

  perform pg_temp.assert_equals(
    v_visible::text,
    '0',
    'deactivating a member takes their read away immediately'
  );

  update public.restaurant_members
     set is_active = true
   where restaurant_id = '11111111-1111-1111-1111-111111111111'
     and user_id = 'e0000000-0000-4000-8000-000000000002';

  -- An outsider who names the other restaurant's id in a filter still reads
  -- nothing: the policy runs on the row, not on the caller's wish.
  set local role authenticated;
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000008');

  select count(*)
    into v_visible
    from public.order_change_events
   where restaurant_id = '22222222-2222-2222-2222-222222222222';

  -- And a member of one restaurant naming the other's reads nothing either.
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000004');

  select count(*)
    into v_visible_a
    from public.order_change_events
   where restaurant_id = '22222222-2222-2222-2222-222222222222';

  reset role;

  perform pg_temp.assert_equals(
    v_visible::text,
    '0',
    'a filter naming the other restaurant matches nothing for a non-member'
  );
  perform pg_temp.assert_equals(
    v_visible_a::text,
    '0',
    'a member filtering on the other restaurant reads nothing'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- What the trigger does: placements, moves, refusals, and no other writer
-- ---------------------------------------------------------------------------
do $$
declare
  v_order uuid;
  v_restaurant uuid;
  v_branch uuid;
  v_event jsonb;
  v_keys text;
  v_status text;
  v_count integer;
  v_same boolean;
  v_result jsonb;
begin
  -- A placement creates the row, with the state the order entered the world in
  -- and the same instant the orders row holds.
  v_order := pg_temp.placed_order(p_quantity => 1);

  select to_jsonb(event_row)
    into v_event
    from public.order_change_events as event_row
   where event_row.order_id = v_order;

  perform pg_temp.assert_true(
    v_event is not null,
    'placing an order creates its row in the representation'
  );
  perform pg_temp.assert_equals(
    v_event ->> 'status',
    'PENDING',
    'the new row carries the status the order was placed with'
  );
  perform pg_temp.assert_equals(
    v_event ->> 'restaurant_id',
    '11111111-1111-1111-1111-111111111111',
    'the new row carries the restaurant the order belongs to'
  );
  perform pg_temp.assert_equals(
    v_event ->> 'branch_id',
    '33333333-3333-3333-3333-333333333333',
    'the new row carries the branch the order belongs to'
  );

  select coalesce(string_agg(key, ',' order by key), '')
    into v_keys
    from jsonb_object_keys(v_event) as key;

  perform pg_temp.assert_equals(
    v_keys,
    'branch_id,order_id,restaurant_id,status,updated_at',
    'the payload of the new row carries exactly the five expected keys'
  );

  -- Three real staff moves refresh one row: the representation is a mirror, not
  -- a log, so ten moves are still one row per order.
  set local role authenticated;
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000003');
  v_result := public.staff_set_order_status(v_order, 'ACCEPTED');

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000004');
  perform public.staff_set_order_status(v_order, 'PREPARING');
  v_result := public.staff_set_order_status(v_order, 'READY');

  reset role;

  perform pg_temp.assert_equals(
    v_result ->> 'status',
    'READY',
    'staff moved the order to ready through the existing path'
  );

  select count(*)
    into v_count
    from public.order_change_events
   where order_id = v_order;

  perform pg_temp.assert_equals(
    v_count::text,
    '1',
    'three moves leave exactly one row for the order'
  );

  select event_row.status,
         event_row.updated_at = order_row.updated_at
    into v_status, v_same
    from public.order_change_events as event_row
    join public.orders as order_row
      on order_row.id = event_row.order_id
   where event_row.order_id = v_order;

  perform pg_temp.assert_equals(
    v_status,
    'READY',
    'the row carries the status the order really holds'
  );
  perform pg_temp.assert_true(
    v_same,
    'the row carries the same instant the orders row does'
  );

  -- The audit trail is untouched: the history trigger that already lived on the
  -- orders table still records every one of those moves, one row each.
  select count(*)
    into v_count
    from public.order_status_history
   where order_id = v_order;

  perform pg_temp.assert_equals(
    v_count::text,
    '3',
    'the history still records one row per accepted move'
  );

  -- A move the lifecycle refuses changes nothing: not the order, not the
  -- history, and not the representation. The attempt is made by an OWNER,
  -- because an OWNER is a role the authorization helper lets through to the
  -- lifecycle, which is where this refusal has to come from.
  v_order := pg_temp.placed_order(p_quantity => 1);

  set local role authenticated;
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  perform pg_temp.assert_fails_with(
    format(
      'select public.staff_set_order_status(%L, ''PREPARING'')',
      v_order
    ),
    'P0001',
    'invalid_order_status_transition',
    'an illegal move is still refused by the lifecycle, not by the copy'
  );

  reset role;

  select event_row.status
    into v_status
    from public.order_change_events as event_row
   where event_row.order_id = v_order;

  perform pg_temp.assert_equals(
    v_status,
    'PENDING',
    'a refused move leaves the row exactly as it was'
  );

  select count(*)
    into v_count
    from public.order_status_history
   where order_id = v_order;

  perform pg_temp.assert_equals(
    v_count::text,
    '0',
    'a refused move still records no history'
  );

  -- A cancellation reaches the representation like any other accepted move.
  v_order := pg_temp.placed_order(p_quantity => 1);

  set local role authenticated;
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000003');
  perform public.staff_set_order_status(v_order, 'ACCEPTED');

  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000004');
  perform public.staff_set_order_status(v_order, 'CANCELLED');
  reset role;

  select event_row.status
    into v_status
    from public.order_change_events as event_row
   where event_row.order_id = v_order;

  perform pg_temp.assert_equals(
    v_status,
    'CANCELLED',
    'a cancellation reaches the representation'
  );

  -- No client role is a writer, not even a member with the select privilege in
  -- their hands: the only writer is the trigger.
  set local role authenticated;
  perform pg_temp.sign_in('e0000000-0000-4000-8000-000000000001');

  perform pg_temp.assert_denied(
    format(
      'insert into public.order_change_events
         (order_id, restaurant_id, branch_id, status, updated_at)
       values (%L, ''11111111-1111-1111-1111-111111111111'',
               ''33333333-3333-3333-3333-333333333333'',
               ''SERVED'', now())',
      v_order
    ),
    'a member cannot forge an event for their own restaurant'
  );
  perform pg_temp.assert_denied(
    'update public.order_change_events set status = ''SERVED''',
    'a member cannot rewrite an event'
  );
  perform pg_temp.assert_denied(
    'delete from public.order_change_events',
    'a member cannot remove an event'
  );
  reset role;

  -- The shape of a row is decided by the table, not by the trigger: a row that
  -- pairs an order with another restaurant, a row that repeats an order, and a
  -- row claiming a status the lifecycle does not have are all unrepresentable.
  select order_row.id
    into v_order
    from public.orders as order_row
   where order_row.restaurant_id = '11111111-1111-1111-1111-111111111111'
   order by order_row.order_number desc
   limit 1;

  perform pg_temp.assert_denied(
    format(
      'insert into public.order_change_events
         (order_id, restaurant_id, branch_id, status, updated_at)
       values (%L, ''22222222-2222-2222-2222-222222222222'',
               ''44444444-4444-4444-4444-444444444444'',
               ''PENDING'', now())',
      v_order
    ),
    'a row cannot pair an order with another restaurant'
  );

  select order_row.id, order_row.restaurant_id, order_row.branch_id
    into v_order, v_restaurant, v_branch
    from public.orders as order_row
   where order_row.restaurant_id = '11111111-1111-1111-1111-111111111111'
   order by order_row.order_number desc
   limit 1;

  perform pg_temp.assert_denied(
    format(
      'insert into public.order_change_events
         (order_id, restaurant_id, branch_id, status, updated_at)
       values (%L, %L, %L, ''PENDING'', now())',
      v_order, v_restaurant, v_branch
    ),
    'an order cannot appear twice in the representation'
  );

  perform pg_temp.assert_denied(
    format(
      'insert into public.order_change_events
         (order_id, restaurant_id, branch_id, status, updated_at)
       values (%L, %L, %L, ''IN_THE_OVEN'', now())',
      v_order, v_restaurant, v_branch
    ),
    'a status the lifecycle does not know cannot be represented'
  );

  -- The mirror is still whole after everything above.
  select count(*)
    into v_count
    from public.orders as order_row
   where not exists (
     select 1
       from public.order_change_events as event_row
      where event_row.order_id = order_row.id
   );

  perform pg_temp.assert_equals(
    v_count::text,
    '0',
    'every order, including the ones just placed, still has its row'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- The whole schema, after everything above has run
-- ---------------------------------------------------------------------------
do $$
declare
  v_orders integer;
  v_events integer;
  v_mismatched integer;
begin
  select count(*) into v_orders from public.orders;
  select count(*) into v_events from public.order_change_events;

  perform pg_temp.assert_equals(
    v_events::text,
    v_orders::text,
    'the representation holds exactly one row per order'
  );

  select count(*)
    into v_mismatched
    from public.order_change_events as event_row
    join public.orders as order_row
      on order_row.id = event_row.order_id
   where event_row.status is distinct from order_row.status
      or event_row.restaurant_id is distinct from order_row.restaurant_id
      or event_row.branch_id is distinct from order_row.branch_id
      or event_row.updated_at is distinct from order_row.updated_at;

  perform pg_temp.assert_equals(
    v_mismatched::text,
    '0',
    'after placements, moves, refusals and cancellations, every row still mirrors its order'
  );
end;
$$;

rollback;
