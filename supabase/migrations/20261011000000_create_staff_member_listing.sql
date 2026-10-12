-- Restaurant staff management, foundation: the read-only member list.
--
-- Owners and managers may see who belongs to their restaurant and what role each
-- member holds. This is the first and, in this step, the only staff-management
-- operation: there is no invitation, no member creation, no role change and no
-- activation or deactivation. It adds exactly one function:
--
--   * `public.staff_list_restaurant_members(p_restaurant_id uuid)`
--
--     returns the members of one restaurant as jsonb. It is SECURITY DEFINER with an
--     empty search path, requires a session, and answers only for an active OWNER or
--     MANAGER of that restaurant.
--
-- Why a new function instead of a direct select. `public.restaurant_members` and
-- `public.profiles` already carry grants and RLS policies for `authenticated`
-- (20260918000100_enable_core_rls.sql). A screen could read them directly. It does
-- not, for two reasons:
--
--   1. A join over two tables, scoped to a restaurant the caller names, is a
--      read shape a policy has to describe twice, once per table, and the two
--      descriptions can drift apart. One function states the rule once.
--   2. The list must never carry a field this step has not approved. A table grant
--      hands a client every column the grant covers; a function chooses the exact
--      keys it returns. The payload below is four fields per member and a wrapper,
--      and a future column on `restaurant_members` or `profiles` cannot appear in it
--      by accident.
--
-- Nothing is widened to add the function. No table grant, no RLS policy, no existing
-- helper and no existing function is altered. The two tables stay exactly as closed
-- to a direct client read as 20260918000100 left them; this function is a new, narrow
-- door beside them, not a change to them.
--
-- Authorization. `private.has_restaurant_role(p_restaurant_id, array['OWNER',
-- 'MANAGER'])` (20260918000100) is the existing helper every other management read
-- uses. It reads `restaurant_members` for `(select auth.uid())` and answers true only
-- for an active row whose role is in the list. Reusing it rather than repeating the
-- query here means a deactivated member, a member of another restaurant, a waiter, a
-- kitchen worker and a cashier are all refused by the same rule that already refuses
-- them elsewhere, and a MANAGER is authorized as a manager, never as an owner: the
-- helper is asked only the two roles, and this function reads; it never writes a role
-- or a membership.
--
-- The refusal is one answer for every way a caller can fail to be an owner or manager
-- of the restaurant: a non-member, a member of another restaurant, a cashier, a
-- deactivated manager and a restaurant that does not exist. It is `42501`
-- (`staff_member_access_denied`) in each case, so the function cannot be used to find
-- out which restaurants exist. No session is `28000`, as every other staff function
-- answers.
--
-- What is returned. For each membership of the restaurant, active or deactivated:
--
--   * `id`           the `restaurant_members.id`, the member record's own id, which a
--                    later activation/deactivation step will name;
--   * `user_id`      the profile id behind the membership, so a screen can key a
--                    person across the restaurant's memberships;
--   * `display_name` the profile's `full_name`, or null when the profile holds none.
--                    `profiles` has no email column; the email lives in
--                    `auth.users`, which this function does not read and does not
--                    need for a staff list, so it is not exposed;
--   * `role`         the stored role, one of OWNER, MANAGER, WAITER, KITCHEN, CASHIER;
--   * `is_active`    the membership's stored active flag, so a deactivated member is
--                    listed and marked rather than omitted.
--
-- Nothing else is read. There is no password, no token, no phone, no avatar, no
-- preference and no unrelated profile column in the payload; the function's select
-- list is the set of keys above and the wrapper, and it cannot return a column a
-- later migration adds.
--
-- Inactive members are included on purpose. This is the screen from which a
-- deactivated member is later reactivated, so hiding them would hide the members a
-- manager most needs to see. The caller must be active to ask; the people listed need
-- not be.
--
-- Ordering is deterministic so a screen and a test see the same list every time:
-- management roles first (OWNER, MANAGER), then WAITER, KITCHEN, CASHIER, and a role
-- the project later adds last; within a role by display name, with a nameless profile
-- after a named one, and by `user_id` to break the last tie. `(restaurant_id,
-- user_id)` is unique, so the order never leaves two rows dependent on the database's
-- whim.

create or replace function public.staff_list_restaurant_members(
  p_restaurant_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_members jsonb;
begin
  if (select auth.uid()) is null then
    raise exception using
      errcode = '28000',
      message = 'Authentication is required to read restaurant members.';
  end if;

  -- An unknown restaurant, a restaurant that does not exist and a restaurant the
  -- caller is not an active owner or manager of are one answer on purpose: this
  -- function is for a restaurant's management, and it is not a way to find out which
  -- restaurants exist.
  if p_restaurant_id is null
     or not private.has_restaurant_role(
       p_restaurant_id,
       array['OWNER', 'MANAGER']::text[]
     ) then
    raise exception using
      errcode = '42501',
      message = 'staff_member_access_denied';
  end if;

  select coalesce(
           pg_catalog.jsonb_agg(
             pg_catalog.jsonb_build_object(
               'id', member.id,
               'user_id', member.user_id,
               'display_name', member_profile.full_name,
               'role', member.role,
               'is_active', member.is_active
             )
             order by
               case member.role
                 when 'OWNER' then 1
                 when 'MANAGER' then 2
                 when 'WAITER' then 3
                 when 'KITCHEN' then 4
                 when 'CASHIER' then 5
                 else 6
               end,
               member_profile.full_name nulls last,
               member.user_id
           ),
           '[]'::jsonb
         )
    into v_members
    from public.restaurant_members as member
    left join public.profiles as member_profile
      on member_profile.id = member.user_id
   where member.restaurant_id = p_restaurant_id;

  return pg_catalog.jsonb_build_object(
    'restaurant_id', p_restaurant_id,
    'members', v_members
  );
end;
$$;

comment on function public.staff_list_restaurant_members(uuid) is
  'Returns the members of one restaurant for an active OWNER or MANAGER of it: each member''s restaurant_members id, profile user id, profile display name (or null), stored role and stored active flag, ordered management roles first then by name and user id. Active and deactivated members are both listed; there is no email, token, password or unrelated profile field in the payload. Raises staff_member_access_denied (42501) for a caller who is not an active owner or manager of the restaurant and for a restaurant that does not exist, and 28000 without a session.';

-- Callable by a signed-in owner or manager and by nobody else. `anon` is refused
-- here as it is elsewhere: a guest holds no session and no membership, so the checks
-- above would answer 28000 or 42501 anyway, and a guest is not offered the door.
revoke all on function public.staff_list_restaurant_members(uuid)
  from public, anon;

grant execute on function public.staff_list_restaurant_members(uuid)
  to authenticated;
