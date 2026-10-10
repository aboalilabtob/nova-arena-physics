-- NOVA ARENA central platform — Supabase SQL setup
-- Run in Supabase Dashboard > SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.admin_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('admin','operator')),
  created_at timestamptz not null default now()
);

create table if not exists public.competitions (
  slug text primary key,
  title text not null default 'NOVA ARENA Physics LAB',
  created_at timestamptz not null default now()
);

insert into public.competitions(slug,title)
values ('nova-arena','NOVA ARENA Physics LAB')
on conflict (slug) do nothing;

create table if not exists public.competition_drafts (
  competition_slug text primary key references public.competitions(slug) on delete cascade,
  payload jsonb not null,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create table if not exists public.competition_publications (
  competition_slug text primary key references public.competitions(slug) on delete cascade,
  version integer not null default 1,
  published_payload jsonb not null,
  published_by uuid references auth.users(id),
  published_at timestamptz not null default now()
);

-- Codes are only read by Edge Functions using the service role.
create table if not exists public.team_join_codes (
  id bigint generated always as identity primary key,
  competition_slug text not null references public.competitions(slug) on delete cascade,
  team_id text not null,
  team_name text not null,
  code_hash text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (competition_slug, team_id),
  unique (competition_slug, code_hash)
);

create table if not exists public.participant_sessions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  competition_slug text not null references public.competitions(slug) on delete cascade,
  team_id text not null,
  team_name text not null,
  joined_at timestamptz not null default now(),
  active boolean not null default true
);

create table if not exists public.answer_submissions (
  id bigint generated always as identity primary key,
  competition_slug text not null references public.competitions(slug) on delete cascade,
  participant_id uuid not null references auth.users(id) on delete cascade,
  team_id text not null,
  question_id text not null,
  answer_index integer not null check (answer_index between 0 and 7),
  submitted_at timestamptz not null default now(),
  processed boolean not null default false,
  unique (competition_slug, participant_id, question_id)
);

create or replace function public.nova_is_staff()
returns boolean language sql stable security definer set search_path = public
as $$
  select exists(select 1 from public.admin_profiles p where p.user_id = auth.uid() and p.role in ('admin','operator'));
$$;

create or replace function public.nova_is_admin()
returns boolean language sql stable security definer set search_path = public
as $$
  select exists(select 1 from public.admin_profiles p where p.user_id = auth.uid() and p.role = 'admin');
$$;

alter table public.admin_profiles enable row level security;
alter table public.competitions enable row level security;
alter table public.competition_drafts enable row level security;
alter table public.competition_publications enable row level security;
alter table public.team_join_codes enable row level security;
alter table public.participant_sessions enable row level security;
alter table public.answer_submissions enable row level security;

-- Staff can read their own profile; only admins manage staff profiles.
drop policy if exists "staff read own profile" on public.admin_profiles;
create policy "staff read own profile" on public.admin_profiles for select to authenticated using (user_id = auth.uid() or public.nova_is_admin());
drop policy if exists "admins manage profiles" on public.admin_profiles;
create policy "admins manage profiles" on public.admin_profiles for all to authenticated using (public.nova_is_admin()) with check (public.nova_is_admin());

drop policy if exists "public can read competition metadata" on public.competitions;
create policy "public can read competition metadata" on public.competitions for select to anon, authenticated using (true);
drop policy if exists "admins manage competition metadata" on public.competitions;
create policy "admins manage competition metadata" on public.competitions for all to authenticated using (public.nova_is_admin()) with check (public.nova_is_admin());

drop policy if exists "staff read drafts" on public.competition_drafts;
create policy "staff read drafts" on public.competition_drafts for select to authenticated using (public.nova_is_staff());
drop policy if exists "staff write drafts" on public.competition_drafts;
create policy "staff write drafts" on public.competition_drafts for insert to authenticated with check (public.nova_is_staff() and updated_by = auth.uid());
drop policy if exists "staff update drafts" on public.competition_drafts;
create policy "staff update drafts" on public.competition_drafts for update to authenticated using (public.nova_is_staff()) with check (public.nova_is_staff() and updated_by = auth.uid());

drop policy if exists "public read published snapshots" on public.competition_publications;
create policy "public read published snapshots" on public.competition_publications for select to anon, authenticated using (true);
drop policy if exists "admins publish snapshots" on public.competition_publications;
create policy "admins publish snapshots" on public.competition_publications for insert to authenticated with check (public.nova_is_admin() and published_by = auth.uid());
drop policy if exists "admins update publications" on public.competition_publications;
create policy "admins update publications" on public.competition_publications for update to authenticated using (public.nova_is_admin()) with check (public.nova_is_admin() and published_by = auth.uid());

-- No browser-role policies on join codes. Edge Functions access these with service role only.
drop policy if exists "participants read own session" on public.participant_sessions;
create policy "participants read own session" on public.participant_sessions for select to authenticated using (user_id = auth.uid() or public.nova_is_staff());
drop policy if exists "staff read all sessions" on public.participant_sessions;
create policy "staff read all sessions" on public.participant_sessions for select to authenticated using (public.nova_is_staff());

drop policy if exists "participants read own submissions" on public.answer_submissions;
create policy "participants read own submissions" on public.answer_submissions for select to authenticated using (participant_id = auth.uid());
drop policy if exists "staff read submissions" on public.answer_submissions;
create policy "staff read submissions" on public.answer_submissions for select to authenticated using (public.nova_is_staff());
drop policy if exists "staff update submissions" on public.answer_submissions;
create policy "staff update submissions" on public.answer_submissions for update to authenticated using (public.nova_is_admin()) with check (public.nova_is_admin());

-- Realtime publication. Ignore if already present in the publication.
do $$ begin
  alter publication supabase_realtime add table public.competition_publications;
exception when duplicate_object then null;
when undefined_object then null;
end $$;

-- IMPORTANT: Create the first admin user in Authentication > Users first.
-- Then copy their UUID and run:
-- insert into public.admin_profiles(user_id, role) values ('PASTE-AUTH-USER-UUID-HERE','admin');
--
-- Example team access code (change the code and team id to match your Teams panel):
-- insert into public.team_join_codes(competition_slug,team_id,team_name,code_hash)
-- values ('nova-arena','1','الفريق الأول',encode(digest('CHANGE-THIS-TEAM-CODE','sha256'),'hex'));
