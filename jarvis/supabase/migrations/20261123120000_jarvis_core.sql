-- JARVIS · núcleo de datos único (fase 1)
-- Supabase pasa a ser la única fuente de verdad: salud (ya existía) + salidas
-- de los agentes (MIDAS, Donna, AURA, ARES, ULTRÓN, JARVIS) + dispositivos.
-- Entorno de un solo usuario: el acceso se concede solo al propietario
-- registrado en private.owner. Los agentes y las funciones usan service_role.
-- Todo es aditivo: no modifica ni borra datos existentes.

create schema if not exists private;

create table if not exists private.owner (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
revoke all on schema private from anon, authenticated;

create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.owner o where o.user_id = (select auth.uid()));
$$;
revoke all on function public.is_owner() from public, anon;
grant execute on function public.is_owner() to authenticated;

-- ── lectura de las tablas de salud existentes para el propietario ──────────
do $$
declare t text;
begin
  foreach t in array array['daily_metrics','sleep_logs','workouts','workout_sets','health_metrics_raw'] loop
    execute format('drop policy if exists owner_read on public.%I', t);
    execute format('create policy owner_read on public.%I for select to authenticated using ((select public.is_owner()))', t);
  end loop;
end $$;

-- ── MIDAS ──────────────────────────────────────────────────────────────────
create table if not exists public.midas_editions (
  id text primary key,                         -- <YYYY-MM-DD>-morning | -update-<HHMM>
  date date not null,
  kind text not null check (kind in ('morning','update')),
  generated_at timestamptz not null,
  stories jsonb not null default '[]'::jsonb
);
create index if not exists midas_editions_date_idx on public.midas_editions (date desc, generated_at desc);

create table if not exists public.midas_pills (
  id text primary key,
  kind text not null check (kind in ('concepto','idea')),
  topic text,
  domain text not null,
  title text not null,
  body text not null,
  apply text,
  validity text,
  source jsonb not null default '{}'::jsonb,
  edition_date date,
  generated boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.midas_watchlist (
  symbol text primary key,
  name text,
  keywords text[] not null default '{}'
);

-- ── Donna ──────────────────────────────────────────────────────────────────
create table if not exists public.donna_orders (
  id text primary key,                         -- <tienda>-<nº pedido>
  shop text not null,
  order_no text,
  status text not null check (status in
    ('pendiente_pago','preparando','enviado','en_reparto','incidencia','entregado','devuelto','cancelado')),
  carrier text,
  tracking text,
  last_event date,
  eta date,
  note text check (char_length(note) <= 80),
  updated_at timestamptz not null default now()
);

-- ── AURA ───────────────────────────────────────────────────────────────────
create table if not exists public.aura_inbox (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  meal text not null check (meal in ('desayuno','comida','merienda','cena','otro')),
  answers jsonb not null default '{}'::jsonb,  -- {racion, grasa, resto, nota}
  image text,                                  -- data URL JPEG; AURA la borra al procesarla
  status text not null default 'pending' check (status in ('pending','error')),
  reason text,
  created_at timestamptz not null default now()
);

create table if not exists public.aura_meals (
  id text primary key,
  date date not null,
  meal text not null,
  kcal numeric,
  protein_g numeric,
  carbs_g numeric,
  fat_g numeric,
  label text check (char_length(label) <= 40),
  confidence text check (confidence in ('alta','media','baja')),
  source text not null default 'foto',
  created_at timestamptz not null default now()
);
create index if not exists aura_meals_date_idx on public.aura_meals (date desc);

-- ── ARES (tracker de fuerza) ───────────────────────────────────────────────
create table if not exists public.ares_program (
  id text primary key default 'current',
  program jsonb not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.ares_sessions (
  id text primary key,
  date date not null,
  day text not null,
  abs boolean not null default false,
  entries jsonb not null,                      -- {"<ex>-<mode>": {sets:[{w,r}], uni, note}}
  ts bigint not null,
  created_at timestamptz not null default now()
);
create index if not exists ares_sessions_date_idx on public.ares_sessions (date desc);

create table if not exists public.ares_flags (
  key text primary key,
  forced_up boolean not null default false,
  unilateral boolean not null default false
);

-- ── JARVIS / ULTRÓN ────────────────────────────────────────────────────────
create table if not exists public.briefings (
  date date primary key,
  generated_at timestamptz not null default now(),
  headline text not null,
  body jsonb not null default '{}'::jsonb
);

create table if not exists public.alerts (
  id bigint generated always as identity primary key,
  agent text not null check (agent in ('jarvis','ultron','ares','aura','ray','midas','donna')),
  level text not null default 'info' check (level in ('info','warn','critical')),
  text text not null check (char_length(text) <= 160),
  ref text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  pushed_at timestamptz
);
create index if not exists alerts_open_idx on public.alerts (created_at desc) where resolved_at is null;

create table if not exists public.sync_log (
  id bigint generated always as identity primary key,
  source text not null,                        -- healthkit | hae | agent:<nombre>
  received_at timestamptz not null default now(),
  stats jsonb not null default '{}'::jsonb
);
create index if not exists sync_log_source_idx on public.sync_log (source, received_at desc);

create table if not exists public.devices (
  token text primary key,                      -- token APNs
  platform text not null default 'ios',
  environment text not null default 'production' check (environment in ('sandbox','production')),
  updated_at timestamptz not null default now()
);

-- ── RLS: solo el propietario; los agentes entran con service_role ──────────
do $$
declare t text;
begin
  foreach t in array array['midas_editions','midas_pills','midas_watchlist','donna_orders',
    'aura_inbox','aura_meals','ares_program','ares_sessions','ares_flags',
    'briefings','alerts','sync_log','devices'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists owner_all on public.%I', t);
    execute format('create policy owner_all on public.%I for all to authenticated using ((select public.is_owner())) with check ((select public.is_owner()))', t);
  end loop;
end $$;
