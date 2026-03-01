-- ============================================================
-- Т-Путешествия: Supabase Schema
-- Запусти в: Supabase Dashboard → SQL Editor → New Query
-- ============================================================

-- ── 1. PROFILES ────────────────────────────────────────────
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  full_name  text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Индекс по email (query-missing-indexes)
create index if not exists profiles_email_idx on public.profiles (email);

-- RLS (security-rls-basics)
alter table public.profiles enable row level security;

-- Политики: пользователь видит/меняет только свой профиль
-- (select auth.uid()) — cached, не per-row (security-rls-performance)
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
  for select to authenticated
  using ((select auth.uid()) = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own" on public.profiles
  for insert with check (true);


-- ── 2. WISHLISTS ───────────────────────────────────────────
create table if not exists public.wishlists (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  hotel_id   text not null,
  hotel_name text not null,
  hotel_img  text,
  price      text,
  created_at timestamptz not null default now(),
  unique (user_id, hotel_id)
);

create index if not exists wishlists_user_id_idx on public.wishlists (user_id);

alter table public.wishlists enable row level security;

drop policy if exists "wishlists_own" on public.wishlists;
create policy "wishlists_own" on public.wishlists
  for all to authenticated
  using      ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);


-- ── 3. COPILOT SESSIONS ────────────────────────────────────
create table if not exists public.copilot_sessions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references public.profiles(id) on delete set null,
  messages   jsonb not null default '[]',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists copilot_sessions_user_id_idx on public.copilot_sessions (user_id);
-- GIN индекс для поиска по сообщениям (advanced-jsonb-indexing)
create index if not exists copilot_sessions_messages_gin
  on public.copilot_sessions using gin (messages);

alter table public.copilot_sessions enable row level security;

drop policy if exists "copilot_sessions_own" on public.copilot_sessions;
create policy "copilot_sessions_own" on public.copilot_sessions
  for all to authenticated
  using      ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);


-- ── 4. ТРИГГЕР: auto-create profile при регистрации ────────
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ── 5. USER MOMENTS (загруженные видео) ───────────────────
create table if not exists public.user_moments (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  video_url  text,
  location   text not null,
  caption    text,
  tags       text,
  status     text not null default 'pending'   -- pending | published | rejected
               check (status in ('pending','published','rejected')),
  views      bigint not null default 0,
  likes      bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists user_moments_user_id_idx on public.user_moments (user_id);
create index if not exists user_moments_status_idx  on public.user_moments (status);

alter table public.user_moments enable row level security;

-- Владелец видит свои моменты в любом статусе
drop policy if exists "moments_own" on public.user_moments;
create policy "moments_own" on public.user_moments
  for all to authenticated
  using      ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- Все авторизованные пользователи видят опубликованные моменты
drop policy if exists "moments_published" on public.user_moments;
create policy "moments_published" on public.user_moments
  for select to authenticated
  using (status = 'published');


-- ── 6. STORAGE BUCKETS ─────────────────────────────────────
-- Запусти отдельно в SQL Editor:

-- Бакет для видео Moments
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'moments-videos',
  'moments-videos',
  true,
  104857600,     -- 100 МБ
  array['video/mp4','video/quicktime','video/x-msvideo','video/webm']
)
on conflict (id) do nothing;

-- Бакет для аватаров
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars',
  'avatars',
  true,
  5242880,       -- 5 МБ
  array['image/jpeg','image/png','image/webp','image/gif']
)
on conflict (id) do nothing;

-- RLS для storage moments-videos
drop policy if exists "moments_upload_own" on storage.objects;
create policy "moments_upload_own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'moments-videos' AND
    (select auth.uid())::text = split_part(name, '/', 1)
  );

drop policy if exists "moments_read_public" on storage.objects;
create policy "moments_read_public" on storage.objects
  for select using (bucket_id = 'moments-videos');

drop policy if exists "moments_delete_own" on storage.objects;
create policy "moments_delete_own" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'moments-videos' AND
    (select auth.uid())::text = split_part(name, '/', 1)
  );

-- RLS для storage avatars
drop policy if exists "avatars_upload_own" on storage.objects;
create policy "avatars_upload_own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'avatars' AND
    (select auth.uid())::text = split_part(name, '/', 1)
  );

drop policy if exists "avatars_update_own" on storage.objects;
create policy "avatars_update_own" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'avatars' AND
    (select auth.uid())::text = split_part(name, '/', 1)
  );

drop policy if exists "avatars_read_public" on storage.objects;
create policy "avatars_read_public" on storage.objects
  for select using (bucket_id = 'avatars');


-- ── 7. UPDATED_AT автообновление ───────────────────────────
create or replace function public.set_updated_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at
  before update on public.profiles
  for each row execute procedure public.set_updated_at();

drop trigger if exists copilot_sessions_updated_at on public.copilot_sessions;
create trigger copilot_sessions_updated_at
  before update on public.copilot_sessions
  for each row execute procedure public.set_updated_at();

drop trigger if exists user_moments_updated_at on public.user_moments;
create trigger user_moments_updated_at
  before update on public.user_moments
  for each row execute procedure public.set_updated_at();
