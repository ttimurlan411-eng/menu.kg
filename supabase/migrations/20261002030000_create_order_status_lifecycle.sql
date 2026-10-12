-- Order lifecycle: the states an order can hold, the moves between them, and the
-- record of what moved.
--
-- Until now `public.orders.status` was constrained to the single value PENDING:
-- the database could store an order and nothing else, because no part of the
-- product could change a status yet. This migration keeps the value column and
-- replaces that one-state constraint with the lifecycle the planned waiter and
-- kitchen workflow needs, so the states can be stored, read and reasoned about
-- before any staff app exists to write them.
--
-- The states, and the moves the database allows between them:
--
--   PENDING   -> ACCEPTED, CANCELLED
--   ACCEPTED  -> PREPARING, CANCELLED
--   PREPARING -> READY, CANCELLED
--   READY     -> SERVED
--   SERVED    -> nothing: terminal
--   CANCELLED -> nothing: terminal
--
-- The normal path is therefore the single forward chain PENDING -> ACCEPTED ->
-- PREPARING -> READY -> SERVED. Cancellation is reachable from the three states
-- before the food is ready and from nowhere else, so an order that has been
-- served, or one that has already been cancelled, is final.
--
-- What the migration deliberately does NOT do:
--
--   * it adds no staff RPC, no waiter or kitchen screen, and no way for a client
--     to move an order. The guard below refuses an invalid move for whoever tries
--     one, and orders stay PENDING until a later step adds the staff path;
--   * it does not let a guest cancel or advance an order. `create_table_order` and
--     `guest_orders` are still the only functions either role can execute on order
--     data, and neither writes a status;
--   * it adds no payment, discount, tax or tip state, and no order-total field to
--     carry one. This is about the food's progress through the restaurant;
--   * it does not touch the reservation tables, functions or token.
--
-- Enforcement is in the database rather than in any client, because a lifecycle
-- rule a staff screen merely remembers to follow is not a rule. Every write of a
-- status goes past guard_order_status_transition, including a future staff RPC
-- running as the owner, so an invalid transition is rejected even by code that
-- never heard of the enum.

-- The lifecycle states replace the single initial one.
--
-- Every order that exists today is 'PENDING', which is a member of the new set, so
-- no row is rewritten, no order number moves and no guest loses an order: the
-- migration widens what the column may hold and leaves the data alone.
alter table public.orders
  drop constraint orders_status_check;

alter table public.orders
  add constraint orders_status_check
    check (status in (
      'PENDING',
      'ACCEPTED',
      'PREPARING',
      'READY',
      'SERVED',
      'CANCELLED'
    ));

comment on constraint orders_status_check on public.orders is
  'The order lifecycle: PENDING, ACCEPTED, PREPARING, READY, SERVED, CANCELLED. Which moves between them are allowed is enforced by guard_order_status_transition, not here.';

comment on column public.orders.status is
  'Where the order is in its life: PENDING, ACCEPTED, PREPARING, READY, SERVED or CANCELLED. Moved by the database only; see guard_order_status_transition for the allowed transitions.';

-- What moved, and when.
--
-- One row per accepted transition, written by a trigger in the same transaction
-- as the change it records, so the history cannot disagree with the orders table:
-- if the status update commits, the row is there, and if it is rolled back, the row
-- is not. Nothing in the schema rewrites or removes a row — there is no update or
-- delete path, no grant and no policy — so an order's path through the restaurant is
-- a record of what happened rather than a description of it. Going around that
-- would take table ownership, which can delete the orders themselves anyway.
--
-- Only real changes are recorded. Creating an order is not a transition: the order
-- row itself is the record that it entered the world PENDING, and a write that
-- leaves the status alone is not a change, so neither writes a row. That is what
-- lets old_status stay not null: every row here is a move from one state to
-- another, and the check constraint below says so.
--
-- There is no staff identity column, on purpose. No staff authentication exists in
-- this project, so there is no id to store and nothing truthful to put in one; a
-- nullable "changed_by" filled in by nobody would only invite a later migration to
-- treat an empty value as a waiter who has since been deleted. The step that adds
-- staff accounts can add the column with the identity it actually has.
create table public.order_status_history (
  -- A plain counter rather than a uuid, because it is also what orders the trail.
  -- now() is one instant per transaction, so several moves made together would
  -- otherwise share a changed_at and the order they happened in would be lost.
  id bigint generated always as identity primary key,
  order_id uuid not null,
  -- The state the order left, and the state it entered. Both are constrained to
  -- the lifecycle above, so a history row can never name a state the orders table
  -- would reject.
  old_status text not null,
  new_status text not null,
  changed_at timestamptz not null default now(),
  constraint order_status_history_order_id_fkey
    foreign key (order_id)
    references public.orders (id)
    on delete cascade,
  constraint order_status_history_old_status_check
    check (old_status in (
      'PENDING',
      'ACCEPTED',
      'PREPARING',
      'READY',
      'SERVED',
      'CANCELLED'
    )),
  constraint order_status_history_new_status_check
    check (new_status in (
      'PENDING',
      'ACCEPTED',
      'PREPARING',
      'READY',
      'SERVED',
      'CANCELLED'
    )),
  -- A row that does not change anything is not a transition, so it is refused at
  -- the type level as well as skipped by the trigger that writes the rows.
  constraint order_status_history_change_check
    check (old_status <> new_status)
);

comment on table public.order_status_history is
  'One row per accepted order status transition, appended by record_order_status_change in the same transaction as the change. No update or delete path, no grant and no policy, so nothing rewrites it; there is no staff identity column yet because there is no staff authentication.';

comment on column public.order_status_history.old_status is
  'The state the order was in before this change. Never null: creating an order is not a transition, so only real changes are recorded.';

comment on column public.order_status_history.changed_at is
  'When the transition was committed, as an absolute instant. One instant per transaction, as everywhere in this schema, so moves made in the same transaction share it and id orders them.';

comment on column public.order_status_history.id is
  'Insertion order. A counter rather than a uuid so the order moves happened in survives the shared changed_at.';

create index idx_order_status_history_order_id_changed_at
  on public.order_status_history (order_id, changed_at);

alter table public.order_status_history enable row level security;

-- No grants at all, to anon or to authenticated, exactly as on the order tables.
-- RLS is enabled as well, so a later migration that adds a grant still cannot
-- expose the audit trail without also adding a policy. The guest read path does not
-- need it: a guest is shown where their order is now, not how it got there, and a
-- status a staff app does not exist to change yet cannot be forged by a client.
revoke all on table public.order_status_history from public, anon, authenticated;

-- Refuses a status the lifecycle does not allow.
--
-- before update, so an invalid move never reaches the table at all: not the row,
-- not the history, not updated_at. The check constraint above still decides which
-- *values* may be stored; this decides which *moves* may be made between them, and
-- it applies to every writer, including the owner a future staff RPC runs as.
--
-- A write that does not touch the status is not a transition and is allowed
-- through untouched. The orders table carries an updated_at trigger that fires on
-- every write, and a later step editing some other column must not be refused for
-- having nothing to do with the lifecycle.
--
-- The raised message is a fixed identifier a client can map without parsing prose;
-- the two states involved are reported in the detail for a server log. No guest can
-- reach this: neither client role has a grant on orders, and neither of the two
-- functions they can call writes a status.
create or replace function public.guard_order_status_transition()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  -- The states the lifecycle has. This list mirrors the check constraint on the
  -- column: it is here so a value that is not a state can be told apart from an
  -- illegal move, which the two layers otherwise both answer for. The lifecycle
  -- tests assert that the same values are accepted and refused by both, so the two
  -- cannot drift apart unnoticed.
  v_states constant text[] := array[
    'PENDING', 'ACCEPTED', 'PREPARING', 'READY', 'SERVED', 'CANCELLED'
  ];
  -- The single forward chain, plus cancellation while the food is still on its way.
  -- READY -> SERVED is the only move out of READY, and both SERVED and CANCELLED
  -- fall through to false: they are terminal, so nothing leaves them, not even
  -- back to PENDING.
  v_allowed boolean;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  -- "There is no such state" is a different mistake from "an order cannot go from
  -- here to there", and a client that has to show the guest something needs to know
  -- which one it hit. A write that reached here with an unknown value is refused
  -- here rather than by the constraint, because this trigger runs first.
  if not (new.status = any(v_states)) then
    raise exception 'invalid_order_status'
      using
        errcode = 'P0001',
        detail = pg_catalog.format('%s is not an order status', new.status);
  end if;

  v_allowed := case
    when old.status = 'PENDING' then new.status in ('ACCEPTED', 'CANCELLED')
    when old.status = 'ACCEPTED' then new.status in ('PREPARING', 'CANCELLED')
    when old.status = 'PREPARING' then new.status in ('READY', 'CANCELLED')
    when old.status = 'READY' then new.status = 'SERVED'
    else false
  end;

  if v_allowed then
    return new;
  end if;

  raise exception 'invalid_order_status_transition'
    using
      errcode = 'P0001',
      detail = pg_catalog.format('%s -> %s', old.status, new.status);
end;
$$;

comment on function public.guard_order_status_transition() is
  'Before-update trigger on public.orders. Allows PENDING to ACCEPTED or CANCELLED, ACCEPTED to PREPARING or CANCELLED, PREPARING to READY or CANCELLED, READY to SERVED, and nothing out of SERVED or CANCELLED. A write that leaves the status alone is not a transition and is passed through. Raises invalid_order_status (P0001) for a value that is not a lifecycle state, and invalid_order_status_transition (P0001) for a move the lifecycle does not allow.';

create trigger guard_orders_status_transition
before update on public.orders
for each row execute function public.guard_order_status_transition();

-- Records the transitions the guard allowed.
--
-- after update, so a row exists only for a change that passed both the lifecycle
-- rule and the check constraint. The insert is part of the same statement as the
-- update, so it shares the transaction: a refused transition leaves no history,
-- and a committed one always leaves exactly one row.
--
-- Trigger functions are left executable by the writer of the table, following
-- public.set_updated_at: PostgreSQL checks EXECUTE when the trigger fires, so
-- revoking it from the client roles would turn the future staff write into a
-- permission error instead of the business rule above. The function cannot be
-- called directly, needs no privileges of its own, and touches nothing but the
-- table the caller is already allowed to write.
create or replace function public.record_order_status_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    insert into public.order_status_history (order_id, old_status, new_status)
    values (old.id, old.status, new.status);
  end if;

  return null;
end;
$$;

comment on function public.record_order_status_change() is
  'After-update trigger on public.orders. Appends one order_status_history row per accepted status change, in the same transaction as the change. Writes nothing when the status is unchanged, which is why a creation is not recorded either.';

create trigger record_orders_status_change
after update on public.orders
for each row execute function public.record_order_status_change();

-- Defence in depth, repeated for the third time on orders. A later migration that
-- adds a staff path still cannot expose the orders table itself without also adding
-- a policy, and the guard above applies to whatever it does.
revoke all on table public.orders from public, anon, authenticated;

-- The two client-callable order functions are reasserted unchanged, with their
-- grants, so this migration provably widens nothing on the guest side: no new
-- function is executable by anon or authenticated, and neither of these can write
-- a status.
revoke all on function public.create_table_order(text, jsonb, text) from public, anon;
grant execute on function public.create_table_order(text, jsonb, text)
  to anon, authenticated;

revoke all on function public.guest_orders(text) from public, anon;
grant execute on function public.guest_orders(text)
  to anon, authenticated;