-- Core multi-tenant foundation for menu.kg.
-- This migration is additive and is intended to be applied through Supabase's
-- migration workflow. It deliberately does not enable RLS or create policies.

create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table public.restaurants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  logo_url text,
  cover_url text,
  description text,
  phone text,
  address text,
  latitude numeric(9, 6),
  longitude numeric(9, 6),
  currency text not null default 'KGS',
  default_language text not null default 'ky',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint restaurants_latitude_check
    check (latitude is null or latitude between -90 and 90),
  constraint restaurants_longitude_check
    check (longitude is null or longitude between -180 and 180),
  constraint restaurants_currency_check
    check (char_length(currency) = 3)
);

create table public.branches (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null,
  name text not null,
  address text,
  phone text,
  latitude numeric(9, 6),
  longitude numeric(9, 6),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branches_restaurant_id_fkey
    foreign key (restaurant_id)
    references public.restaurants (id)
    on delete restrict,
  constraint branches_id_restaurant_id_key unique (id, restaurant_id),
  constraint branches_latitude_check
    check (latitude is null or latitude between -90 and 90),
  constraint branches_longitude_check
    check (longitude is null or longitude between -180 and 180)
);

create table public.profiles (
  id uuid primary key,
  full_name text,
  phone text,
  avatar_url text,
  preferred_language text not null default 'ky',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_id_fkey
    foreign key (id)
    references auth.users (id)
    on delete cascade
);

create table public.restaurant_members (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null,
  user_id uuid not null,
  role text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint restaurant_members_restaurant_id_fkey
    foreign key (restaurant_id)
    references public.restaurants (id)
    on delete restrict,
  constraint restaurant_members_user_id_fkey
    foreign key (user_id)
    references public.profiles (id)
    on delete cascade,
  constraint restaurant_members_restaurant_id_user_id_key
    unique (restaurant_id, user_id),
  constraint restaurant_members_role_check
    check (role in ('OWNER', 'MANAGER', 'WAITER', 'KITCHEN', 'CASHIER'))
);

create table public.tables (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null,
  branch_id uuid not null,
  table_number text not null,
  name text,
  capacity integer not null default 1,
  zone text,
  status text not null default 'AVAILABLE',
  qr_token uuid not null default gen_random_uuid(),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tables_restaurant_id_fkey
    foreign key (restaurant_id)
    references public.restaurants (id)
    on delete restrict,
  constraint tables_branch_id_restaurant_id_fkey
    foreign key (branch_id, restaurant_id)
    references public.branches (id, restaurant_id)
    on delete restrict,
  constraint tables_capacity_check check (capacity > 0),
  constraint tables_status_check
    check (
      status in (
        'AVAILABLE',
        'OCCUPIED',
        'RESERVED',
        'CLEANING',
        'OUT_OF_SERVICE'
      )
    )
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null,
  branch_id uuid,
  name text not null,
  description text,
  image_url text,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint categories_restaurant_id_fkey
    foreign key (restaurant_id)
    references public.restaurants (id)
    on delete restrict,
  constraint categories_branch_id_restaurant_id_fkey
    foreign key (branch_id, restaurant_id)
    references public.branches (id, restaurant_id)
    on delete restrict,
  constraint categories_id_restaurant_id_key unique (id, restaurant_id),
  constraint categories_sort_order_check check (sort_order >= 0)
);

create table public.menu_items (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null,
  branch_id uuid,
  category_id uuid not null,
  name text not null,
  description text,
  price numeric(12, 2) not null,
  old_price numeric(12, 2),
  main_image_url text,
  is_available boolean not null default true,
  is_popular boolean not null default false,
  is_new boolean not null default false,
  preparation_time_minutes integer not null default 0,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint menu_items_restaurant_id_fkey
    foreign key (restaurant_id)
    references public.restaurants (id)
    on delete restrict,
  constraint menu_items_branch_id_restaurant_id_fkey
    foreign key (branch_id, restaurant_id)
    references public.branches (id, restaurant_id)
    on delete restrict,
  constraint menu_items_category_id_restaurant_id_fkey
    foreign key (category_id, restaurant_id)
    references public.categories (id, restaurant_id)
    on delete restrict,
  constraint menu_items_id_restaurant_id_key unique (id, restaurant_id),
  constraint menu_items_price_check check (price >= 0),
  constraint menu_items_old_price_check
    check (old_price is null or old_price >= 0),
  constraint menu_items_preparation_time_minutes_check
    check (preparation_time_minutes >= 0),
  constraint menu_items_sort_order_check check (sort_order >= 0)
);

create table public.menu_item_images (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null,
  menu_item_id uuid not null,
  image_url text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  constraint menu_item_images_restaurant_id_fkey
    foreign key (restaurant_id)
    references public.restaurants (id)
    on delete restrict,
  constraint menu_item_images_menu_item_id_restaurant_id_fkey
    foreign key (menu_item_id, restaurant_id)
    references public.menu_items (id, restaurant_id)
    on delete cascade,
  constraint menu_item_images_sort_order_check check (sort_order >= 0)
);

create index idx_branches_restaurant_id
  on public.branches (restaurant_id);

create index idx_restaurant_members_restaurant_id
  on public.restaurant_members (restaurant_id);

create index idx_restaurant_members_user_id
  on public.restaurant_members (user_id);

create index idx_tables_restaurant_id
  on public.tables (restaurant_id);

create index idx_tables_branch_id
  on public.tables (branch_id);

create unique index idx_tables_qr_token
  on public.tables (qr_token);

create index idx_categories_restaurant_id
  on public.categories (restaurant_id);

create index idx_categories_branch_id
  on public.categories (branch_id);

create index idx_categories_menu_filter
  on public.categories (restaurant_id, branch_id, is_active, sort_order);

create index idx_menu_items_restaurant_id
  on public.menu_items (restaurant_id);

create index idx_menu_items_branch_id
  on public.menu_items (branch_id);

create index idx_menu_items_category_id
  on public.menu_items (category_id);

create index idx_menu_items_menu_filter
  on public.menu_items (
    restaurant_id,
    branch_id,
    category_id,
    is_available,
    sort_order
  );

create index idx_menu_item_images_restaurant_id
  on public.menu_item_images (restaurant_id);

create index idx_menu_item_images_menu_item_id
  on public.menu_item_images (menu_item_id);

create trigger set_restaurants_updated_at
before update on public.restaurants
for each row execute function public.set_updated_at();

create trigger set_branches_updated_at
before update on public.branches
for each row execute function public.set_updated_at();

create trigger set_profiles_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create trigger set_restaurant_members_updated_at
before update on public.restaurant_members
for each row execute function public.set_updated_at();

create trigger set_tables_updated_at
before update on public.tables
for each row execute function public.set_updated_at();

create trigger set_categories_updated_at
before update on public.categories
for each row execute function public.set_updated_at();

create trigger set_menu_items_updated_at
before update on public.menu_items
for each row execute function public.set_updated_at();
