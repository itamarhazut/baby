-- התינוק שלנו: סכמת מסד נתונים
-- מריצים פעם אחת ב-Supabase: SQL Editor -> New query -> הדבקה -> Run

-- משפחה: קבוצה שחולקת את אותם נתונים
create table if not exists public.families (
  id uuid primary key default gen_random_uuid(),
  invite_code text not null unique default upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  created_at timestamptz not null default now()
);

create table if not exists public.family_members (
  family_id uuid not null references public.families(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (family_id, user_id)
);
-- משתמש שייך למשפחה אחת בלבד
create unique index if not exists family_members_one_family_per_user on public.family_members(user_id);

-- פרטי התינוק, משימות ברית, בדיקות ומעקב גדילה (מסמך JSON לכל חלק)
create table if not exists public.app_state (
  family_id uuid not null references public.families(id) on delete cascade,
  section text not null,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (family_id, section)
);

-- יומן יומי: רישום לכל שורה
create table if not exists public.log_entries (
  id text primary key,
  family_id uuid not null references public.families(id) on delete cascade,
  t bigint not null,
  type text not null,
  note text not null default ''
);
create index if not exists log_entries_family_t on public.log_entries(family_id, t);

-- בדיקת חברות במשפחה (security definer כדי למנוע רקורסיה במדיניות)
create or replace function public.is_member(fid uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.family_members
    where family_id = fid and user_id = auth.uid()
  );
$$;

-- הרשאות ברמת שורה: רק חברי המשפחה רואים וכותבים
alter table public.families enable row level security;
alter table public.family_members enable row level security;
alter table public.app_state enable row level security;
alter table public.log_entries enable row level security;

drop policy if exists "members read own membership" on public.family_members;
create policy "members read own membership" on public.family_members
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "family read state" on public.app_state;
drop policy if exists "family insert state" on public.app_state;
drop policy if exists "family update state" on public.app_state;
drop policy if exists "family delete state" on public.app_state;
create policy "family read state" on public.app_state
  for select to authenticated using (public.is_member(family_id));
create policy "family insert state" on public.app_state
  for insert to authenticated with check (public.is_member(family_id));
create policy "family update state" on public.app_state
  for update to authenticated using (public.is_member(family_id)) with check (public.is_member(family_id));
create policy "family delete state" on public.app_state
  for delete to authenticated using (public.is_member(family_id));

drop policy if exists "family read log" on public.log_entries;
drop policy if exists "family insert log" on public.log_entries;
drop policy if exists "family update log" on public.log_entries;
drop policy if exists "family delete log" on public.log_entries;
create policy "family read log" on public.log_entries
  for select to authenticated using (public.is_member(family_id));
create policy "family insert log" on public.log_entries
  for insert to authenticated with check (public.is_member(family_id));
create policy "family update log" on public.log_entries
  for update to authenticated using (public.is_member(family_id)) with check (public.is_member(family_id));
create policy "family delete log" on public.log_entries
  for delete to authenticated using (public.is_member(family_id));

-- לטבלת families אין מדיניות גישה ישירה. הגישה רק דרך הפונקציות הבאות.

create or replace function public.create_family()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare fid uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select family_id into fid from public.family_members where user_id = auth.uid() limit 1;
  if fid is not null then
    return fid;
  end if;
  insert into public.families default values returning id into fid;
  insert into public.family_members(family_id, user_id) values (fid, auth.uid());
  return fid;
end;
$$;

create or replace function public.join_family(code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare fid uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select family_id into fid from public.family_members where user_id = auth.uid() limit 1;
  if fid is not null then
    return fid;
  end if;
  select id into fid from public.families where invite_code = upper(trim(code));
  if fid is null then
    raise exception 'invalid code';
  end if;
  insert into public.family_members(family_id, user_id) values (fid, auth.uid())
    on conflict do nothing;
  return fid;
end;
$$;

create or replace function public.my_family()
returns table (id uuid, invite_code text)
language sql
security definer
stable
set search_path = public
as $$
  select f.id, f.invite_code
  from public.families f
  join public.family_members m on m.family_id = f.id
  where m.user_id = auth.uid()
  limit 1;
$$;

revoke all on function public.create_family() from public, anon;
revoke all on function public.join_family(text) from public, anon;
revoke all on function public.my_family() from public, anon;
grant execute on function public.create_family() to authenticated;
grant execute on function public.join_family(text) to authenticated;
grant execute on function public.my_family() to authenticated;
grant execute on function public.is_member(uuid) to authenticated;

-- סנכרון חי בין המכשירים
do $$
begin
  begin
    alter publication supabase_realtime add table public.app_state;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.log_entries;
  exception when duplicate_object then null;
  end;
end $$;
