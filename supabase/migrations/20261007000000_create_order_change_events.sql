-- The realtime representation of an order change: five fields, one row per order.
--
-- A kitchen or waiter screen has to react to an order changing without polling.
-- The mechanism Supabase Realtime offers for that is postgres_changes: the
-- database streams the rows of tables that are members of the `supabase_realtime`
-- publication, and Realtime authorizes every event against every subscriber with
-- row level security before anything is delivered.
--
-- public.orders is not that table, and this migration does not make it one. The
-- orders table is deliberately unpublished, has row level security enabled with
-- no policy at all, and carries `access_token`: the guest's own credential for
-- reading their order back. Publishing it would need a client-facing SELECT
-- policy on the table itself — the direct door the staff order migration
-- refused to open, and which its header says so — and every insert and status
-- change would push the whole row, token included, through the realtime channel.
-- Neither happens here.
--
-- What is added instead is the smallest thing a staff screen needs in order to
-- decide to re-read:
--
--   order_id       which order moved
--   restaurant_id  whose order it is — the column authorization checks
--   branch_id      which branch it belongs to
--   status         where it is in the lifecycle now
--   updated_at     when it last moved
--
-- Five columns and no others: no access token, no guest data, no table id, no
-- amounts, no line items — nothing a staff screen does not already fetch
-- through `staff_list_orders`. This representation is a signal. The order data
-- itself still comes from that one authorized read path, which this migration
-- does not touch.
--
-- How it is kept true: a single row-level trigger on public.orders upserts the
-- row above after an insert or a status change. None of the write paths move:
-- `create_table_order`, `guest_orders`, `staff_list_orders` and
-- `staff_set_order_status` are what they were, their grants are reasserted
-- unchanged at the end of this file, and guard_order_status_transition still
-- decides every status move before any copy is written. The trigger copies what
-- happened; it authorizes nobody and it refuses nothing. One row per order, so
-- ten moves are still one row and the table stays a mirror of the orders table
-- rather than a log of it.
--
-- Who may read a row: an active member of that row's restaurant whose role
-- works orders — OWNER, MANAGER, WAITER, KITCHEN, the same four roles
-- `staff_list_orders` answers to — and nobody else. The policy is expressed with
-- `private.has_restaurant_role`, the primitive every other policy in this
-- schema already uses with its roles written out. The one helper that says this
-- exact sentence in one place, `private.can_read_restaurant_orders`, is
-- deliberately not executable by client roles, and this migration does not grant
-- it: the test suite asserts that the role list here and the one inside that
-- helper are the same list, so the two cannot drift apart quietly. CASHIER is
-- excluded, as it is from reading orders at all. This is restaurant-wide
-- membership, as everywhere in this schema — no branch-level authorization is
-- invented for the representation to pretend with.
--
-- What each role holds on the table: `authenticated` may select and nothing
-- else; `anon` nothing at all; and no client role any insert, update or delete,
-- because there is no policy for those commands either and the only writer is
-- the trigger running for whoever wrote the order. An outsider's read comes back
-- empty rather than refused, exactly like every other membership policy here.
--
-- The publication: `supabase_realtime` gains this table and is set to publish
-- inserts and updates only. Deletes are turned off deliberately. Realtime
-- cannot apply row level security to a delete — there is no row left to check,
-- which its own documentation warns about — so the one event kind the security
-- model does not cover is the one kind this representation never legitimately
-- produces. Orders are never deleted by anything in this product; if a table
-- owner ever deleted one, its row here would disappear by the foreign key below,
-- silently, for everybody, and nobody would be told a row they could not have
-- read is gone. A later feature that genuinely needs delete events must turn
-- them back on knowingly, with that caveat in hand.
--
-- Deliberately NOT in this migration: the Flutter subscription itself, sound,
-- polling or any timer, an item-level status, priority or station columns, a
-- unified kitchen repository, any change to the lifecycle, any new grant that
-- opens public.orders to a client role, and any policy shaped like
-- `using (true)` or reaching `anon`.

-- The order tables stay exactly as closed as every order migration before this
-- one left them. Repeated on purpose: putting a new table beside them widens
-- nothing on their side.
revoke all on table public.orders from public, anon, authenticated;
revoke all on table public.order_access from public, anon, authenticated;
revoke all on table public.order_items from public, anon, authenticated;
revoke all on table public.order_status_history from public, anon, authenticated;

-- The representation itself.
--
-- The composite foreign key is what makes a mismatched row unrepresentable: the
-- pair (order_id, restaurant_id) has to name one real order of that same
-- restaurant, so a row can never claim an order belongs to a restaurant it does
-- not — the same device order_items uses, for the same reason. The status check
-- mirrors orders_status_check, so the copy can only ever hold a state the
-- lifecycle itself recognises.
create table public.order_change_events (
  order_id uuid primary key,
  restaurant_id uuid not null,
  branch_id uuid not null,
  status text not null,
  updated_at timestamptz not null default now(),
  constraint order_change_events_order_id_restaurant_id_fkey
    foreign key (order_id, restaurant_id)
    references public.orders (id, restaurant_id)
    on delete cascade,
  constraint order_change_events_status_check
    check (status in (
      'PENDING',
      'ACCEPTED',
      'PREPARING',
      'READY',
      'SERVED',
      'CANCELLED'
    ))
);

comment on table public.order_change_events is
  'One row per order carrying only what a staff screen needs to know that it changed: which order, whose, which branch, where it is in the lifecycle, and when it moved. Written only by the trigger on public.orders. Holds no guest token, no order lines and no amounts, and is published for Realtime behind a membership policy.';

comment on column public.order_change_events.order_id is
  'The order this row mirrors, and the primary key: an order has exactly one row here however many times it moves.';

comment on column public.order_change_events.restaurant_id is
  'The restaurant the order belongs to. This is the column the read policy checks, so a row is only ever visible to an active member of that restaurant.';

comment on column public.order_change_events.branch_id is
  'The branch the order belongs to, copied from the order. A screen watching one branch filters on it; the policy does not narrow by branch, because this schema has no branch-level authorization for it to narrow with.';

comment on column public.order_change_events.status is
  'The status the order holds now, constrained to the same lifecycle as public.orders.status.';

comment on column public.order_change_events.updated_at is
  'When the order last changed, copied from the order rather than taken anew, so the representation never disagrees with the row it mirrors.';

-- The read is always by restaurant, which is also what the policy below is
-- evaluated against, so the index serves both the membership check's input and
-- the filter a subscribing client applies.
create index idx_order_change_events_restaurant_id
  on public.order_change_events (restaurant_id, updated_at);

-- Row level security on before anything can be granted, as on every other table
-- in this schema, and no grant to `public` or to `anon` at all: a guest cannot
-- reach an order change, with or without a session.
alter table public.order_change_events enable row level security;

revoke all on table public.order_change_events from public, anon, authenticated;

-- The one privilege any client role gets: selecting, and only for `authenticated`.
-- Realtime authorizes a postgres_changes subscriber by running the table's select
-- policy as that subscriber's role, so this grant plus the policy below is the
-- whole of who may receive an event. No insert, update or delete is granted to
-- anyone, so a member can read their own restaurant's changes and can neither
-- forge one nor edit one.
grant select on table public.order_change_events to authenticated;

-- The entire access rule for the representation.
--
-- `private.has_restaurant_role` is the primitive the policies in
-- 20260918000100_enable_core_rls.sql all use, executable by `authenticated`, and
-- it answers with the caller's own membership only. The four roles are spelled
-- out here rather than delegated to `private.can_read_restaurant_orders` because
-- that helper is deliberately kept out of client hands (20261002040000 revokes
-- it from `public` and its test asserts a client cannot call it), and widening
-- it would be a second change to an existing authorization surface for one
-- policy's convenience. The two role lists are asserted equal by the test suite.
--
-- No `to anon`, no `using (true)`, no column of public.orders anywhere in the
-- expression: a caller with no session, a signed-in user with no membership, a
-- member of another restaurant, a deactivated member and a CASHIER all read
-- zero rows through this line and nothing else.
create policy order_change_events_select_order_staff
on public.order_change_events
for select
to authenticated
using (
  private.has_restaurant_role(
    restaurant_id,
    array['OWNER', 'MANAGER', 'WAITER', 'KITCHEN']::text[]
  )
);

-- Copies the order into the representation, after the row is stored.
--
-- AFTER, so it sees the row that was actually written rather than the one that
-- was asked for: the lifecycle guard has already refused an illegal move, and
-- updated_at has already been set by its own trigger, so this copies the outcome
-- of the whole statement. The upsert is what keeps the table one row per order —
-- the first change inserts, every later change refreshes the same row.
--
-- Not SECURITY DEFINER, like the two trigger functions already on the orders
-- table. Every writer of an order is either the owner or a security definer
-- function running as the owner, so this runs with enough rights to write its
-- own table, and it cannot be walked into anything: its search path is empty and
-- every reference is schema-qualified. It takes no input a caller controls
-- beyond the row itself, and it returns null because an AFTER trigger's return
-- value is ignored.
create or replace function public.record_order_change_event()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into public.order_change_events as change
    (order_id, restaurant_id, branch_id, status, updated_at)
  values
    (new.id, new.restaurant_id, new.branch_id, new.status, new.updated_at)
  on conflict (order_id) do update
    set status = excluded.status,
        branch_id = excluded.branch_id,
        updated_at = excluded.updated_at;

  -- restaurant_id is not refreshed on purpose: it is part of the order's
  -- identity through the composite foreign keys, an order cannot be moved
  -- between restaurants, and the conflicting row's is the one that was checked
  -- against the order when this row was first written.
  return null;
end;
$$;

comment on function public.record_order_change_event() is
  'After-insert and after-update trigger on public.orders. Upserts the five-field row of public.order_change_events that mirrors the order, so the representation always holds the status and updated_at the orders row really has. Runs for every writer, including the owner, and authorizes nothing: the lifecycle guard and the staff function have already decided the write.';

create trigger record_orders_change_event
after insert or update on public.orders
for each row execute function public.record_order_change_event();

-- Orders that exist before this migration get their row too, so the mirror is
-- complete from the first read and never has a hole the trigger only fills when
-- such an order next moves. The table is empty at this point in a migration, so
-- there is nothing to conflict with; the values are read from the orders rows
-- themselves, never from a client.
insert into public.order_change_events (
  order_id,
  restaurant_id,
  branch_id,
  status,
  updated_at
)
select
  existing.id,
  existing.restaurant_id,
  existing.branch_id,
  existing.status,
  existing.updated_at
from public.orders as existing;

-- The publication.
--
-- Adding the table is what makes postgres_changes deliver its inserts and
-- updates. Setting the publication to insert and update removes delete from
-- every table in it, which for this project means from this table: see the
-- header — Realtime cannot apply row level security to a delete, and nothing
-- here ever deletes. The flags are stated in one place so the next feature that
-- wants a different mix changes them deliberately rather than inheriting them.
alter publication supabase_realtime add table public.order_change_events;

alter publication supabase_realtime set (publish = 'insert, update');

-- The client paths are reasserted with their grants exactly as before this
-- migration: no new function was created, none of these four is executable by a
-- role that could not already execute it, and no argument of any of them
-- changed. This is repeated at the end of every order migration in this project
-- so that "widens nothing" is a property of the file itself, not of a reader's
-- comparison.
revoke all on function public.create_table_order(text, jsonb, text)
  from public, anon;
grant execute on function public.create_table_order(text, jsonb, text)
  to anon, authenticated;

revoke all on function public.guest_orders(text) from public, anon;
grant execute on function public.guest_orders(text)
  to anon, authenticated;

revoke all on function public.staff_list_orders(uuid, uuid, integer)
  from public, anon;
grant execute on function public.staff_list_orders(uuid, uuid, integer)
  to authenticated;

revoke all on function public.staff_set_order_status(uuid, text)
  from public, anon;
grant execute on function public.staff_set_order_status(uuid, text)
  to authenticated;
