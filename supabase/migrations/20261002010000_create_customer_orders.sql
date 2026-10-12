-- Customer orders placed from a table's menu.
--
-- The access model is the one this project has already proved twice. The public
-- menu and table reservations both work for a signed-out guest, and both treat an
-- unguessable token as the credential instead of inventing a customer account the
-- rest of the project does not have. An order follows the same rule: the QR token
-- of the table is the only restaurant/branch/table context a guest supplies, and
-- the database decides what that token may reach.
--
-- An order therefore cannot be pointed at another restaurant. The guest sends a
-- QR token and a list of menu item ids; the database resolves the table from the
-- token, resolves every item against *that* restaurant's live menu, and refuses
-- anything it cannot find there. A guest cannot name a price, cannot order a dish
-- that is switched off, and cannot order a dish of a competitor's restaurant, and
-- none of those attempts produces a distinguishable error.
--
-- Every amount is snapshotted. public.order_items stores the product name, the
-- unit price and the quantity as they were when the order was placed, plus a
-- line total derived from those two numbers. Historical orders never read the
-- current menu again, so renaming a dish or changing its price cannot rewrite what
-- a guest ordered, and the order total is a sum of the stored line totals rather
-- than anything the client sent.
--
-- Deliberately NOT in this migration, because the project has not defined them:
-- staff-side or waiter-side order handling, kitchen display, order status
-- transitions beyond the single initial PENDING state, payment, notifications,
-- discounts, taxes, tips, delivery or takeaway addresses, and any way for a guest
-- to edit an order after placing it.
--
-- Deliberately NOT exposed, as with the public menu and the reservations:
-- restaurant, branch and table ids, contact details, and any table-level access.

-- One row per guest who can reach their own orders, addressed by an opaque
-- unguessable token, exactly as public.reservation_access works.
--
-- It is a separate table on purpose. An order and a reservation are different
-- capabilities with different lifecycles, and keeping the credentials apart means
-- one of them can be revoked or expired later without touching the other, and
-- without rewriting the reservation functions that already exist.
create table public.order_access (
  access_token text primary key,
  created_at timestamptz not null default now()
);

comment on table public.order_access is
  'One row per guest who can reach their own orders, addressed by an opaque unguessable token. Reached only through create_table_order; no table grant exists.';

-- Per-restaurant order numbering.
--
-- A guest needs a short code to read out and staff need a short code to write on
-- a receipt, so the number cannot be a uuid. A single global sequence would do
-- that but would also tell a guest how many orders the whole platform has taken,
-- which is a competitor's business, so the counter is kept per restaurant and
-- bumped atomically inside the create function.
create table public.restaurant_order_counters (
  restaurant_id uuid primary key
    references public.restaurants (id) on delete cascade,
  last_number bigint not null default 0,
  constraint restaurant_order_counters_last_number_check check (last_number >= 0)
);

comment on table public.restaurant_order_counters is
  'Last order number handed out for a restaurant. Only written by create_table_order, which bumps it in a single atomic statement.';

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  -- What the guest reads out and staff write down. Unique within a restaurant.
  order_number bigint not null,
  access_token text not null,
  restaurant_id uuid not null,
  branch_id uuid not null,
  -- Optional: an order may belong to no table in future, for example a takeaway
  -- order made from the same menu. A null table passes the composite foreign key
  -- below, which is the standard SQL behaviour for a null in a composite key.
  table_id uuid,
  status text not null default 'PENDING',
  -- Snapshot of the restaurant currency at the time of the order, so an order
  -- read back years later is not relabelled by a later settings change.
  currency text not null,
  -- Sum of the stored order_items line totals, computed by the database.
  total numeric(12, 2) not null,
  -- Sum of the stored order_items quantities, computed by the database.
  item_count integer not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint orders_id_restaurant_id_key unique (id, restaurant_id),
  constraint orders_restaurant_id_order_number_key
    unique (restaurant_id, order_number),
  constraint orders_access_token_fkey
    foreign key (access_token)
    references public.order_access (access_token)
    on delete cascade,
  constraint orders_restaurant_id_fkey
    foreign key (restaurant_id)
    references public.restaurants (id)
    on delete restrict,
  -- Both of these are what keep a branch or a table from another restaurant out
  -- of an order: a plain branch_id or table_id would accept one, the pair
  -- (branch_id, restaurant_id) cannot.
  constraint orders_branch_id_restaurant_id_fkey
    foreign key (branch_id, restaurant_id)
    references public.branches (id, restaurant_id)
    on delete restrict,
  constraint orders_table_id_restaurant_id_fkey
    foreign key (table_id, restaurant_id)
    references public.tables (id, restaurant_id)
    on delete restrict,
  constraint orders_currency_check check (char_length(currency) = 3),
  constraint orders_total_check check (total >= 0),
  constraint orders_item_count_check check (item_count > 0),
  -- Only the initial state exists. The lifecycle states (accepted, preparing,
  -- ready, served, cancelled) belong to a later migration, together with the
  -- staff-side code that moves an order between them.
  constraint orders_status_check check (status in ('PENDING'))
);

comment on table public.orders is
  'A customer order. Reachable only through the guest token that created it. Amounts and item names are snapshots taken when the order was placed.';

comment on column public.orders.order_number is
  'Short per-restaurant sequence, for example 1043, shown to the guest as #1043. Generated by the database; the client never chooses it.';

comment on column public.orders.total is
  'Sum of the order_items line totals. Never accepted from the client.';

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null,
  -- Carried on the line as well as the order so the composite foreign keys below
  -- can exist. An order_item can only ever point at an order of the same
  -- restaurant and at a menu item of the same restaurant.
  restaurant_id uuid not null,
  -- Nullable only because a restaurant may delete a product later. The snapshot
  -- columns below are what the order history is built from, so deleting a dish
  -- does not delete the orders it was sold in, and does not fail the staff
  -- product delete that already exists in the app.
  menu_item_id uuid,
  -- The restaurant a line belongs to. It is carried on the line rather than read
  -- through the order so the composite foreign keys below can exist at all, and
  -- it is what makes a cross-restaurant line unrepresentable.
  -- The name as it was when the guest ordered it.
  product_name text not null,
  -- The price as it was when the guest ordered it, in the restaurant currency.
  unit_price numeric(12, 2) not null,
  quantity integer not null,
  -- The position the guest ordered this line in. It keeps a printed order and a
  -- later staff screen in the order the guest chose, and it makes the payload
  -- deterministic: two lines added in the same statement share a created_at, so
  -- ordering by id would shuffle them.
  sort_order smallint not null,
  -- unit_price * quantity, stored rather than derived on read, so a line can
  -- never be read with a total that disagrees with its own price and quantity.
  line_total numeric(12, 2) not null,
  created_at timestamptz not null default now(),
  constraint order_items_order_sort_order_key unique (order_id, sort_order),
  constraint order_items_order_id_fkey
    foreign key (order_id)
    references public.orders (id)
    on delete cascade,
  constraint order_items_order_id_restaurant_id_fkey
    foreign key (order_id, restaurant_id)
    references public.orders (id, restaurant_id)
    on delete cascade,
  -- Only menu_item_id is cleared when a product is deleted. A plain
  -- `on delete set null` on a composite key would null both columns, and
  -- restaurant_id is not null: deleting any dish would fail. The column list is
  -- PostgreSQL 15+, and the target platform is 17.
  constraint order_items_menu_item_id_restaurant_id_fkey
    foreign key (menu_item_id, restaurant_id)
    references public.menu_items (id, restaurant_id)
    on delete set null (menu_item_id),
  constraint order_items_product_name_check
    check (char_length(btrim(product_name)) between 1 and 200),
  constraint order_items_unit_price_check check (unit_price >= 0),
  constraint order_items_quantity_check check (quantity > 0),
  constraint order_items_sort_order_check check (sort_order >= 0),
  constraint order_items_line_total_check check (line_total >= 0)
);

comment on table public.order_items is
  'One ordered line: the product as it was, its snapshot price, the quantity and the resulting line total. Historical orders never read the live menu again.';

comment on column public.order_items.menu_item_id is
  'The product this line was ordered from, or null if that product has since been deleted. The snapshot columns are what the order history depends on.';

create index idx_order_access_created_at
  on public.order_access (created_at);

create index idx_orders_access_token
  on public.orders (access_token, created_at desc);

create index idx_orders_restaurant_id
  on public.orders (restaurant_id, created_at desc);

create index idx_orders_table_id
  on public.orders (table_id, created_at desc)
  where table_id is not null;

create index idx_order_items_order_id
  on public.order_items (order_id);

create trigger set_orders_updated_at
before update on public.orders
for each row execute function public.set_updated_at();

alter table public.order_access enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.restaurant_order_counters enable row level security;

-- No grants at all, to anon or to authenticated. RLS is enabled on all four
-- tables as well, so a later migration that adds a grant still cannot expose
-- them without also adding a policy. Note that this migration deliberately adds
-- no staff policy for orders: staff-side order handling is a later step, and a
-- policy written here would be a guess at it.
--
-- Existing grants and policies on restaurants, branches, tables, categories,
-- menu_items and the rest are not touched by this migration.
revoke all on table public.order_access from public, anon, authenticated;
revoke all on table public.orders from public, anon, authenticated;
revoke all on table public.order_items from public, anon, authenticated;
revoke all on table public.restaurant_order_counters from public, anon, authenticated;

-- Places an order for the table whose QR code the guest scanned.
--
-- p_items is a json array of { "item_id": "<uuid>", "quantity": <int> } objects,
-- which is how a postgrest client passes a list to a function. Nothing else about
-- a line is accepted: the product name, the price and the line total are all read
-- from the live menu of the restaurant the token resolved to, so a guest cannot
-- send a price, a name, a quantity of their choosing beyond the guardrails below,
-- or an item that restaurant does not serve.
create or replace function public.create_table_order(
  p_qr_token text,
  p_items jsonb,
  p_access_token text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  -- Upper bounds that keep one request from becoming an unbounded insert. They
  -- are input sanity limits, not business rules: no business rule in this project
  -- says how many dishes a guest may order.
  v_max_lines constant integer := 50;
  v_max_quantity constant integer := 99;

  v_token uuid;
  v_table public.tables%rowtype;
  v_restaurant public.restaurants%rowtype;
  v_branch public.branches%rowtype;
  v_menu_item public.menu_items%rowtype;
  v_access_token text;
  v_order public.orders%rowtype;
  v_line jsonb;
  v_item_id_text text;
  v_quantity_text text;
  v_menu_item_id uuid;
  v_quantity integer;
  v_seen_ids text[] := '{}';
  v_items jsonb := '[]'::jsonb;
  v_item_count integer := 0;
  v_total numeric(12, 2) := 0;
  v_order_number bigint;
begin
  -- A malformed token is reported as "no order" instead of a cast error, so the
  -- public flow cannot be probed for database internals through error text. It is
  -- deliberately indistinguishable from an unknown token.
  if p_qr_token is null
    or pg_catalog.btrim(p_qr_token) !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  then
    return null;
  end if;

  v_token := pg_catalog.btrim(p_qr_token)::uuid;

  select *
    into v_table
    from public.tables as t
   where t.qr_token = v_token
     and t.is_active
   limit 1;

  if not found then
    return null;
  end if;

  select *
    into v_restaurant
    from public.restaurants as r
   where r.id = v_table.restaurant_id
     and r.is_active;

  if not found then
    return null;
  end if;

  -- Re-checks that the branch belongs to the same restaurant as the table.
  select *
    into v_branch
    from public.branches as b
   where b.id = v_table.branch_id
     and b.restaurant_id = v_table.restaurant_id
     and b.is_active;

  if not found then
    return null;
  end if;

  if p_items is null or pg_catalog.jsonb_typeof(p_items) <> 'array' then
    raise exception 'invalid_order_request' using errcode = 'P0001';
  end if;

  if pg_catalog.jsonb_array_length(p_items) = 0
    or pg_catalog.jsonb_array_length(p_items) > v_max_lines
  then
    raise exception 'invalid_order_request' using errcode = 'P0001';
  end if;

  for v_line in
    select element
      from pg_catalog.jsonb_array_elements(p_items) as line(element)
  loop
    if v_line is null or pg_catalog.jsonb_typeof(v_line) <> 'object' then
      raise exception 'invalid_order_request' using errcode = 'P0001';
    end if;

    -- Validated as text before it is cast, so a malformed id is the same safe
    -- rejection as an unknown one instead of a cast error the guest can read.
    v_item_id_text := pg_catalog.btrim(coalesce(v_line ->> 'item_id', ''));

    if v_item_id_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'invalid_order_request' using errcode = 'P0001';
    end if;

    v_menu_item_id := v_item_id_text::uuid;

    v_quantity_text := pg_catalog.btrim(coalesce(v_line ->> 'quantity', ''));

    if v_quantity_text !~ '^[0-9]{1,3}$' then
      raise exception 'invalid_order_request' using errcode = 'P0001';
    end if;

    v_quantity := v_quantity_text::integer;

    if v_quantity < 1 or v_quantity > v_max_quantity then
      raise exception 'invalid_order_request' using errcode = 'P0001';
    end if;

    -- The cart merges a dish into a single line, so a repeated id is a malformed
    -- request rather than a second line for the same dish.
    if v_menu_item_id::text = any(v_seen_ids) then
      raise exception 'invalid_order_request' using errcode = 'P0001';
    end if;

    v_seen_ids := array_append(v_seen_ids, v_menu_item_id::text);

    -- The whole of the tenant isolation for order items: only an item of this
    -- restaurant, still available, and offered to this branch. A dish of another
    -- restaurant, a switched-off dish and a dish from another branch are all the
    -- same "not found" here, and none of them reveals whether the id exists.
    select *
      into v_menu_item
      from public.menu_items as m
     where m.id = v_menu_item_id
       and m.restaurant_id = v_table.restaurant_id
       and m.is_available
       and (m.branch_id is null or m.branch_id = v_table.branch_id);

    if not found then
      raise exception 'unavailable_menu_item' using errcode = 'P0001';
    end if;

    v_items := v_items || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'menu_item_id', v_menu_item.id,
        'product_name', v_menu_item.name,
        'unit_price', v_menu_item.price,
        'quantity', v_quantity
      )
    );

    v_item_count := v_item_count + v_quantity;
    v_total := v_total + (v_menu_item.price * v_quantity);
  end loop;

  -- Reuses the guest's own token when they already have one, so a second order
  -- lands under the same identity a later read or cancel will scope by. A token
  -- that does not exist, or that the guest does not have yet, mints a new one:
  -- 244 bits from Postgres, so it cannot be guessed or enumerated, and nothing in
  -- the request can influence or predict it.
  select pg_catalog.btrim(p_access_token)
    into v_access_token
   where exists (
     select 1
       from public.order_access as access
      where access.access_token = pg_catalog.btrim(p_access_token)
   );

  if v_access_token is null then
    v_access_token :=
      pg_catalog.gen_random_uuid()::text || pg_catalog.gen_random_uuid()::text;

    insert into public.order_access (access_token)
    values (v_access_token);
  end if;

  -- Bumped in one atomic statement, so two guests ordering at the same moment
  -- are given different numbers and the unique constraint settles nothing.
  insert into public.restaurant_order_counters as counter (restaurant_id, last_number)
  values (v_restaurant.id, 1)
  on conflict (restaurant_id)
  do update set last_number = counter.last_number + 1
  returning last_number into v_order_number;

  insert into public.orders (
    order_number,
    access_token,
    restaurant_id,
    branch_id,
    table_id,
    status,
    currency,
    total,
    item_count
  )
  values (
    v_order_number,
    v_access_token,
    v_restaurant.id,
    v_branch.id,
    v_table.id,
    'PENDING',
    v_restaurant.currency,
    v_total,
    v_item_count
  )
  returning * into v_order;

  -- The line total is computed here from the snapshot unit price and quantity, in
  -- the same statement that stores them, so the stored line can never disagree
  -- with its own numbers.
  insert into public.order_items (
    order_id,
    restaurant_id,
    menu_item_id,
    product_name,
    unit_price,
    quantity,
    sort_order,
    line_total
  )
  select
    v_order.id,
    v_restaurant.id,
    (entry.value ->> 'menu_item_id')::uuid,
    entry.value ->> 'product_name',
    (entry.value ->> 'unit_price')::numeric,
    (entry.value ->> 'quantity')::integer,
    (entry.ordinality - 1)::smallint,
    (entry.value ->> 'unit_price')::numeric * (entry.value ->> 'quantity')::integer
  from pg_catalog.jsonb_array_elements(v_items) with ordinality as entry(value, ordinality);

  return pg_catalog.jsonb_build_object(
    'access_token', v_access_token,
    'order', pg_catalog.jsonb_build_object(
      'id', v_order.id,
      'order_number', v_order.order_number,
      'status', v_order.status,
      'currency', v_order.currency,
      'total', v_order.total,
      'item_count', v_order.item_count,
      'restaurant_name', v_restaurant.name,
      'branch_name', v_branch.name,
      'table', pg_catalog.jsonb_build_object(
        'number', v_table.table_number,
        'name', v_table.name
      ),
      'items', (
        select coalesce(
                 pg_catalog.jsonb_agg(
                   pg_catalog.jsonb_build_object(
                     'menu_item_id', stored.menu_item_id,
                     'product_name', stored.product_name,
                     'unit_price', stored.unit_price,
                     'quantity', stored.quantity,
                     'line_total', stored.line_total
                   )
                   order by stored.sort_order
                 ),
                 '[]'::jsonb
               )
          from public.order_items as stored
         where stored.order_id = v_order.id
      ),
      'created_at', v_order.created_at
    )
  );
end;
$$;

comment on function public.create_table_order(text, jsonb, text) is
  'Places an order for the table resolved from p_qr_token, with p_items a json array of {item_id, quantity}. Prices, names and line totals are read from the live menu of that restaurant and snapshotted; the client sends no amount. Reuses p_access_token when the guest already has one and mints a new token otherwise. Returns null when the token is malformed or its table, branch or restaurant is inactive, and raises for an empty, malformed, duplicated or unavailable item list.';

-- Defence in depth: the order tables stay unreadable and unwritable for anon and
-- for signed-in users, so this function remains the only path into order data.
revoke all on function public.create_table_order(text, jsonb, text) from public, anon;

grant execute on function public.create_table_order(text, jsonb, text)
  to anon, authenticated;
