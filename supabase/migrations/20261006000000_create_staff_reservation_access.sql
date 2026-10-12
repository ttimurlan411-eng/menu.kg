-- Staff reservation access: the read path and the one status change, for signed-in
-- staff only.
--
-- Guest reservations already exist. A guest books a table through
-- `create_table_reservation`, reads their own through `guest_reservations` and
-- cancels through `cancel_guest_reservation`, all three addressed by the guest's
-- opaque token — so the only ways into `public.reservations` were the guest's own.
-- No member of the restaurant could see what had been booked at their tables, which
-- is the half of the feature the floor actually works from.
--
-- This migration adds exactly two staff entry points and the authorization they
-- share:
--
--   * `public.staff_list_reservations(p_restaurant_id, p_branch_id, p_date,
--     p_limit)` reads the reservations of one restaurant, optionally narrowed to one
--     branch and to one date;
--   * `public.staff_set_reservation_status(p_reservation_id, p_new_status)` cancels
--     one reservation, and nothing else.
--
-- Both authenticate with the existing Supabase Auth session. There is no second
-- sign-in and no staff token: the caller is `auth.uid()`, and the membership row in
-- `public.restaurant_members` is the whole of what they are. That table already
-- exists with roles OWNER, MANAGER, WAITER, KITCHEN and CASHIER, so nothing here
-- creates a role or an enum.
--
-- Who may do what. Reading is for the roles that seat and serve guests, and the one
-- move is for the same roles:
--
--   role      may read                    may cancel
--   OWNER     yes                         yes
--   MANAGER   yes                         yes
--   WAITER    yes                         yes
--   KITCHEN   no                          no
--   CASHIER   no                          no
--
-- KITCHEN is excluded on purpose: a reservation is who is coming to sit down, not
-- what the kitchen has to cook, and the kitchen already sees everything it works on
-- through the order read path. CASHIER is excluded for the reason
-- `20261002040000_create_staff_order_access.sql` gives for orders: payment and cash
-- handling do not exist in this project yet, so the role has no reservation duties
-- either. Both are a one-line change here if that changes.
--
-- One authorization helper, not two. The order migration splits "may this member's
-- role read" from "may this member's role make this move" because its role sets
-- genuinely differ per move: every order role may cancel, but only some may serve.
-- Here the two answers are the same roles for both questions — this phase defines
-- exactly one staff move — so a second helper would be a second copy of the same
-- role list, kept in step by hand, with a refusal branch nothing could ever reach.
-- `private.can_read_restaurant_reservations` is therefore the whole of the role
-- matrix above, and it is asked before the write as well as before the read. The
-- separation returns the moment a second move exists.
--
-- The status rule lives here rather than in a trigger, which is the opposite of the
-- orders lifecycle and for the same reason in reverse: `public.orders` has many
-- writers (the guest function writes it, and a later step may add more) and
-- `guard_order_status_transition` has to vet every one of them, so it sits on the
-- table. `public.reservations` has no writer at all — no grant, no policy, not even
-- for its owner's clients — and this function is the only way a status can change,
-- so the rule it refuses is the rule nobody can bypass:
--
--   CONFIRMED -> CANCELLED
--
-- and nothing else. CANCELLED is terminal, CONFIRMED is not a move to itself, and a
-- status the schema cannot hold is refused first so an unknown word is never read as
-- a transition question. No PENDING and no REJECTED exist, because the project has
-- defined no approval step: a reservation is confirmed when it is stored, and the
-- only thing anybody may do to it afterwards is release the table. The unique index
-- `idx_reservations_active_slot` keeps the slot of a cancelled reservation
-- bookable, so this move is also the one that gives a table back.
--
-- What the staff payload may contain. Unlike the guest payload, this one carries ids:
-- restaurant, branch and table are what a staff screen works with, and a member of
-- the restaurant can already read all three through the policies in
-- `20260918000100_enable_core_rls.sql`. What it does not carry is anything that
-- belongs to the guest: no `access_token`, no `reservation_access` row. The guest's
-- read path is not widened by this migration and the token is not readable from
-- here. Table display labels (number, name) are not duplicated into the payload
-- either: `public.tables` is already readable by an active member, so a screen
-- resolves them the way the rest of the admin area does.
--
-- Refusals are deliberately undifferentiated where being precise would leak. A
-- caller who is not an active member of the restaurant asked for, and a caller who
-- names a restaurant id that does not exist, both get
-- `staff_reservation_access_denied` (42501): whether some other restaurant exists is
-- not something this function answers for anyone. The same holds for the write,
-- which takes no restaurant argument at all — the restaurant is read from the
-- reservation itself, exactly as the order status function reads it from the order,
-- so there is no scope a client can name wrongly and no cross-restaurant write to
-- attempt.
--
-- Defence in depth, repeated on purpose. `reservations` and `reservation_access`
-- keep no grant at all and keep RLS enabled, so the two functions below are the only
-- way an authenticated member reaches reservation data, and adding a grant later
-- cannot expose the tables without also adding a policy. The three guest functions
-- are reasserted unchanged with their grants, so this migration provably widens
-- nothing on the guest side.
--
-- Deliberately NOT in this migration, because the project has not defined them:
--
--   * any approval flow. No PENDING, no REJECTED, no request-to-book: a reservation
--     is CONFIRMED the moment it exists and this migration does not change that;
--   * any Bookings screen. Nothing here is reachable from the UI yet, and no page is
--     expected to exist for it yet;
--   * date ranges, recurring schedules, opening hours, party-size rules beyond
--     `tables.capacity`, and any staff-side editing of a reservation's date, time,
--     party size or table. A staff screen may release a booking, never rewrite one;
--   * `changed_by` on `public.reservations`. The status move records what happened
--     and when but not who, exactly as `order_status_history` does today, because
--     no screen reads an identity off it yet;
--   * payment, discounts, notifications, or any change on the order side.

-- Defence in depth on the reservation tables, as in every staff migration before
-- this one.
revoke all on table public.reservation_access from public, anon, authenticated;
revoke all on table public.reservations from public, anon, authenticated;

-- Whether the caller may read this restaurant's reservations at all.
--
-- Built on `private.has_restaurant_role` rather than written out again, so the answer
-- to "is this user an active member of this restaurant with this role" stays in the
-- one function the existing policies already trust. Inactive memberships are
-- excluded there, which is what makes deactivating a member revoke reservation
-- access as well as menu and order access.
--
-- KITCHEN and CASHIER are absent by design, as the header says.
create or replace function private.can_read_restaurant_reservations(
  target_restaurant_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_restaurant_role(
    target_restaurant_id,
    array['OWNER', 'MANAGER', 'WAITER']::text[]
  );
$$;

comment on function private.can_read_restaurant_reservations(uuid) is
  'True when the caller has an active membership of this restaurant with a role that works reservations: OWNER, MANAGER or WAITER. Used by staff_list_reservations and staff_set_reservation_status only.';

-- Neither helper is a client-callable function. It is used inside the security
-- definer functions below, which run as the owner, so `revoke from public` is enough:
-- `public` includes `authenticated`, so no grant is issued to any client role and
-- there is no path to the helper from postgrest.
revoke all on function private.can_read_restaurant_reservations(uuid)
  from public, anon;

-- One restaurant's reservations, in the order the floor works them.
--
-- p_restaurant_id is the restaurant being worked and p_branch_id narrows that to one
-- branch, both supplied by the caller and both authorized against `auth.uid()` before
-- anything is read. p_date narrows to one day; null means every day the restaurant
-- has bookings, which is the answer a screen asks for when it has no date yet. p_limit
-- is clamped to 1..100 rather than trusted, because a limit a client chose is also a
-- limit the database has to answer.
--
-- The answer is chronological rather than newest-first, which is the one place this
-- function departs from `staff_list_orders`: an order feed is a stream of what just
-- happened, while a booking list is a schedule, and a schedule in creation order is
-- in no order anybody seats a guest in. The day, then the time, then creation time
-- and the row id as tie-breaks so two reservations at the same minute keep a stable
-- order on every read. The limit is applied in the CTE, before the aggregation, so it
-- bounds the rows read and not the array.
--
-- There is no filter on branch or table activity. A reservation belongs to the
-- restaurant that took it whatever has happened since: a booking made for a table
-- that has since been deactivated is still a booking the restaurant has to answer
-- for, exactly as the guest's own read keeps it.
--
-- The branch filter cannot reach another restaurant's branch. A reservation carries
-- the composite foreign key (branch_id, restaurant_id) into branches, so a
-- reservation already filtered to p_restaurant_id can only be in one of that
-- restaurant's branches; naming a foreign branch id therefore matches no row and
-- returns an empty list, which is the same answer as a branch with no bookings and
-- says nothing about whether that branch exists.
create or replace function public.staff_list_reservations(
  p_restaurant_id uuid,
  p_branch_id uuid default null,
  p_date date default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 100);
  v_reservations jsonb;
begin
  if (select auth.uid()) is null then
    raise exception using
      errcode = '28000',
      message = 'Authentication is required to read restaurant reservations.';
  end if;

  -- An unknown restaurant, a restaurant with no such id and a restaurant the caller
  -- is not an active member of are one answer on purpose. This function is for staff
  -- of a restaurant they belong to, and it is not a way to find out which
  -- restaurants exist.
  if p_restaurant_id is null
     or not private.can_read_restaurant_reservations(p_restaurant_id) then
    raise exception using
      errcode = '42501',
      message = 'staff_reservation_access_denied';
  end if;

  with scoped as (
    select
      booked.id,
      booked.restaurant_id,
      booked.branch_id,
      booked.table_id,
      booked.reserved_date,
      booked.reserved_time,
      booked.guest_name,
      booked.guest_count,
      booked.status,
      booked.created_at,
      booked.updated_at
    from public.reservations as booked
    where booked.restaurant_id = p_restaurant_id
      and (p_branch_id is null or booked.branch_id = p_branch_id)
      and (p_date is null or booked.reserved_date = p_date)
    order by
      booked.reserved_date,
      booked.reserved_time,
      booked.created_at,
      booked.id
    limit v_limit
  )
  select coalesce(
           pg_catalog.jsonb_agg(
             pg_catalog.jsonb_build_object(
               'id', scoped.id,
               'restaurant_id', scoped.restaurant_id,
               'branch_id', scoped.branch_id,
               'table_id', scoped.table_id,
               'reserved_date', scoped.reserved_date,
               'reserved_time', scoped.reserved_time,
               'guest_name', scoped.guest_name,
               'guest_count', scoped.guest_count,
               'status', scoped.status,
               'created_at', scoped.created_at,
               'updated_at', scoped.updated_at
             )
             order by
               scoped.reserved_date,
               scoped.reserved_time,
               scoped.created_at,
               scoped.id
           ),
           '[]'::jsonb
         )
    into v_reservations
    from scoped;

  -- The restaurant, the branch and the day are echoed back from the request, not
  -- looked up: they are the caller's own scope, already authorized above. No access
  -- token and no `reservation_access` row is in this payload, and none can be added
  -- to it by a caller.
  return pg_catalog.jsonb_build_object(
    'restaurant_id', p_restaurant_id,
    'branch_id', p_branch_id,
    'date', p_date,
    'reservations', v_reservations
  );
end;
$$;

comment on function public.staff_list_reservations(uuid, uuid, date, integer) is
  'Returns up to p_limit (clamped to 1..100) of one restaurant''s reservations, oldest booking first (reserved_date, then reserved_time), optionally narrowed to p_branch_id and to p_date, for an active OWNER, MANAGER or WAITER member of that restaurant. Carries the reservation header the Bookings screen renders, and no guest access token and no reservation_access row. Raises staff_reservation_access_denied (42501) for a restaurant the caller is not an active member of and for one that does not exist, and 28000 without a session.';

-- Cancels one reservation, and only that.
--
-- Deliberately no p_restaurant_id and no p_branch_id: every function in this schema
-- that reaches another restaurant's rows carries the restaurant or a token that
-- resolves to one, because a guest has nothing else to be addressed by. A staff
-- member does: the reservation id. The restaurant is read from the row itself and
-- the membership is checked against that, so there is no scope here for a client to
-- get wrong, and no reservation of another restaurant can be named as this
-- restaurant's by anyone.
--
-- The check order is the same order as in `staff_set_order_status`: a session, then
-- the row, then the role, then the rule, then the write. A caller who is not a
-- member — or whose role is not one that works reservations — learns only that the
-- reservation is not theirs; a member who asks for a move this phase has not defined
-- learns only that; and neither answer says whether some other reservation id exists.
create or replace function public.staff_set_reservation_status(
  p_reservation_id uuid,
  p_new_status text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_restaurant_id uuid;
  -- What the row really holds now, read rather than trusted from the caller.
  v_current_status text;
  v_new_status text;
  -- What the write below stored, which is not what was asked for if the write
  -- found nothing.
  v_stored_id uuid;
  v_stored_status text;
  v_updated_at timestamptz;
begin
  if (select auth.uid()) is null then
    raise exception using
      errcode = '28000',
      message = 'Authentication is required to change a reservation status.';
  end if;

  if p_reservation_id is null
     or p_new_status is null
     or pg_catalog.btrim(p_new_status) = '' then
    raise exception using
      errcode = '22023',
      message = 'A reservation id and a status are required.';
  end if;

  v_new_status := pg_catalog.btrim(p_new_status);

  select booked.restaurant_id, booked.status
    into v_restaurant_id, v_current_status
    from public.reservations as booked
   where booked.id = p_reservation_id;

  -- No reservation, a reservation id that does not exist and a reservation of a
  -- restaurant this caller is not an active member of are one answer, and a role
  -- with no reservation duties (KITCHEN, CASHIER, an inactive membership) is that
  -- same answer: it is not this function's business to say which of them it was.
  if v_restaurant_id is null
     or not private.can_read_restaurant_reservations(v_restaurant_id) then
    raise exception using
      errcode = '42501',
      message = 'staff_reservation_access_denied';
  end if;

  -- The word first: a status the schema cannot hold is not a transition question,
  -- and answering it as one would report a rule about states that do not exist.
  if v_new_status not in ('CONFIRMED', 'CANCELLED') then
    raise exception using
      errcode = 'P0001',
      message = 'invalid_reservation_status';
  end if;

  -- Then the rule: this phase defines one move, CONFIRMED -> CANCELLED. A cancelled
  -- reservation is final, and re-confirming, cancelling twice or writing the status
  -- a row already holds are all refusals rather than no-ops, because "it changed
  -- nothing" is not an answer a screen can show for a button it pressed.
  if v_current_status <> 'CONFIRMED' or v_new_status <> 'CANCELLED' then
    raise exception using
      errcode = 'P0001',
      message = 'invalid_reservation_status_transition';
  end if;

  -- A plain update, and the only write path in the project: the table has no grant
  -- and no policy for any client role, so nothing else can reach it. There is no
  -- status predicate in the where clause because the two checks above already hold
  -- for the row read in this same transaction, and because the only competing write
  -- anybody can make is this very one — cancelling a reservation that is already
  -- cancelled stores the same value rather than resurrecting it.
  update public.reservations as booked
     set status = v_new_status
   where booked.id = p_reservation_id
     and booked.restaurant_id = v_restaurant_id
  returning booked.id, booked.status, booked.updated_at
    into v_stored_id, v_stored_status, v_updated_at;

  -- Nothing can delete a reservation, so this write found the row it read above. It
  -- is still checked, because a write that changed no row must not be answered with
  -- a status nobody stored.
  if v_stored_id is null then
    raise exception using
      errcode = '42501',
      message = 'staff_reservation_access_denied';
  end if;

  -- The id, the state it is now in and when the row changed. Nothing else: a staff
  -- screen updates the reservation it already holds rather than re-reading the
  -- guest's details, and no guest field is repeated in an answer about a status.
  return pg_catalog.jsonb_build_object(
    'id', v_stored_id,
    'status', v_stored_status,
    'updated_at', v_updated_at
  );
end;
$$;

comment on function public.staff_set_reservation_status(uuid, text) is
  'Cancels one CONFIRMED reservation for an active OWNER, MANAGER or WAITER member of the reservation''s own restaurant, and changes nothing else. The only move this phase defines: CONFIRMED to CANCELLED. Raises staff_reservation_access_denied (42501) for a reservation of another restaurant, for one that does not exist and for a role with no reservation duties, 22023 for a missing argument, invalid_reservation_status (P0001) for a status the schema cannot hold and invalid_reservation_status_transition (P0001) for any other move. Returns the reservation id, its new status and updated_at, and never an access token.';

-- Both functions are callable by a signed-in member and by nobody else. Never
-- granted to `anon`: a guest is not staff, holds no membership and no session that
-- would pass the checks above, so the functions refuse them as they refuse a null
-- restaurant id.
revoke all on function public.staff_list_reservations(uuid, uuid, date, integer)
  from public, anon;

grant execute on function public.staff_list_reservations(uuid, uuid, date, integer)
  to authenticated;

revoke all on function public.staff_set_reservation_status(uuid, text)
  from public, anon;

grant execute on function public.staff_set_reservation_status(uuid, text)
  to authenticated;

-- The guest side is reasserted unchanged, with the same grants as before this
-- migration: no guest-executable function has gained a status parameter, and the two
-- functions above are not executable by `anon`.
revoke all on function public.create_table_reservation(text, date, time, text, integer, text)
  from public, anon;
grant execute on function public.create_table_reservation(text, date, time, text, integer, text)
  to anon, authenticated;

revoke all on function public.guest_reservations(text) from public, anon;
grant execute on function public.guest_reservations(text)
  to anon, authenticated;

revoke all on function public.cancel_guest_reservation(text, uuid) from public, anon;
grant execute on function public.cancel_guest_reservation(text, uuid)
  to anon, authenticated;
