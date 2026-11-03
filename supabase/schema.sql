create extension if not exists pgcrypto;

create table if not exists public.tasks (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(trim(title)) > 0),
  description text not null default '',
  due_at timestamptz not null,
  completed boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.subtasks (
  id text primary key,
  task_id text not null references public.tasks(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(trim(title)) > 0),
  completed boolean not null default false
);

create index if not exists tasks_user_due_idx on public.tasks(user_id, due_at);
create index if not exists subtasks_task_idx on public.subtasks(task_id);
alter table public.tasks enable row level security;
alter table public.subtasks enable row level security;
drop policy if exists "users manage own tasks" on public.tasks;
drop policy if exists "users manage own subtasks" on public.subtasks;
create policy "users manage own tasks" on public.tasks for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "users manage own subtasks" on public.subtasks for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
