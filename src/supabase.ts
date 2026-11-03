import { createClient } from '@supabase/supabase-js';
import type { Subtask, Task } from './types';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined;
export const supabaseConfigured = Boolean(url && key);
export const supabase = supabaseConfigured ? createClient(url!, key!) : null;

type TaskRow = { id: string; title: string; description: string | null; due_at: string; completed: boolean; created_at: string; subtasks?: { id: string; title: string; completed: boolean }[] };
export const rowsToTasks = (rows: TaskRow[]): Task[] => rows.map(row => ({ id: row.id, title: row.title, description: row.description ?? '', dueAt: row.due_at, completed: row.completed, createdAt: row.created_at, subtasks: (row.subtasks ?? []).map(s => ({ id: s.id, title: s.title, completed: s.completed })) }));
export async function fetchTasks(userId: string) { if (!supabase) throw new Error('Supabase 환경변수가 없습니다.'); const { data, error } = await supabase.from('tasks').select('id,title,description,due_at,completed,created_at,subtasks(id,title,completed)').eq('user_id', userId).order('due_at', { ascending: true }); if (error) throw error; return rowsToTasks((data ?? []) as TaskRow[]); }
export async function saveTask(userId: string, task: Task) { if (!supabase) throw new Error('Supabase 환경변수가 없습니다.'); const { error } = await supabase.from('tasks').upsert({ id: task.id, user_id: userId, title: task.title, description: task.description, due_at: task.dueAt, completed: task.completed, created_at: task.createdAt }); if (error) throw error; const { error: deleteError } = await supabase.from('subtasks').delete().eq('task_id', task.id); if (deleteError) throw deleteError; if (task.subtasks.length) { const { error: subError } = await supabase.from('subtasks').insert(task.subtasks.map(s => ({ id: s.id, task_id: task.id, user_id: userId, title: s.title, completed: s.completed }))); if (subError) throw subError; } }
export async function deleteTask(userId: string, taskId: string) { if (!supabase) throw new Error('Supabase 환경변수가 없습니다.'); const { error } = await supabase.from('tasks').delete().eq('id', taskId).eq('user_id', userId); if (error) throw error; }
export async function importTasks(userId: string, tasks: Task[]) { for (const task of tasks) await saveTask(userId, task); }
