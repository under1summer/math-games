-- Private Storage attachments. Apply after task-module.sql. Deploy game-files.ts separately.
begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)values('game-solutions','game-solutions',false,20971520,array['image/jpeg','image/png','image/heic','image/heif','application/pdf'])on conflict(id)do nothing;
create table public.mg_files(id uuid primary key default gen_random_uuid(),game_kind text not null,game_id uuid not null,team_id uuid not null,task_code text not null,name text not null,mime text not null,size int not null check(size between 1 and 20971520),path text not null unique,created_at timestamptz not null default now(),ready boolean not null default false,answer_id uuid,expires_at timestamptz);
create index on public.mg_files(game_kind,game_id,team_id,task_code);
create table public.mg_file_config(id boolean primary key default true check(id),cleanup_token text not null default gen_random_uuid()::text||gen_random_uuid()::text);
insert into public.mg_file_config(id)values(true);
alter table public.mg_files enable row level security;alter table public.mg_file_config enable row level security;revoke all on public.mg_files,public.mg_file_config from anon,authenticated;
-- Only Edge Function service role may operate these RPCs. Each ordinary request still validates the game capability.
create or replace function public.mg_files_access(op text,k text default '',g uuid default null,t text default '',p jsonb default '{}')returns jsonb language plpgsql security definer set search_path=''as $$
#variable_conflict use_column
declare host boolean;team uuid;row public.mg_files;fid uuid;task jsonb;requested_code text:=p->>'code';online boolean;ended boolean;secret text;begin
if op in('cleanup','purged')then select cleanup_token into secret from public.mg_file_config where id=true;if t is distinct from secret then raise exception 'Нет доступа';end if;
if op='cleanup'then
-- New Storage files expire even when a legacy game's earlier database records are protected.
update public.mg_files f set expires_at=now()where f.expires_at is null and public.mg_finished(f.game_kind,f.game_id)<=now()-interval '7 days';
return coalesce((select jsonb_agg(to_jsonb(x))from(select id,path from public.mg_files where expires_at<=now()or(answer_id is null and created_at<now()-interval '1 day')order by created_at limit 1000)x),'[]');end if;
delete from public.mg_files where id in(select value::text::uuid from jsonb_array_elements_text(p->'ids'));return '{}';end if;
host:=public.mg_host(k,g,t);
case k when 'od'then select id into team from public.od_teams where game_id=g and token=t;select online,closed or started_at is null or ends_at<=now()into online,ended from public.od_games where id=g;
when 'ab'then select id into team from public.ab_teams where game_id=g and token=t;select online,closed or start_ms is null or end_ms<=extract(epoch from now())*1000 into online,ended from public.ab_games where id=g;
when 'ps'then select id into team from public.ps_teams where game_id=g and token=t;select online,status<>'RUNNING'or (public.ps_clock(ps_games,floor(extract(epoch from now())*1000)::bigint)->>'status')<>'RUNNING'into online,ended from public.ps_games where id=g;
else if not host then raise exception 'Нет доступа';end if;ended:=true;end case;
if not host and(team is null or online is false)then raise exception 'Нет доступа';end if;
if op='upload'then
if coalesce(ended,true)then raise exception 'Приём файлов закрыт';end if;
if host then if online then raise exception 'Используйте ссылку команды';end if;team:=(p->>'team')::uuid;end if;
if not exists(select 1 from public.od_teams where k='od'and game_id=g and id=team union all select 1 from public.ab_teams where k='ab'and game_id=g and id=team union all select 1 from public.ps_teams where k='ps'and game_id=g and id=team)then raise exception 'Нет команды';end if;
case k when 'od'then select x into task from public.od_games gg cross join lateral jsonb_array_elements(gg.tasks)x where gg.id=g and x->>'n'=requested_code;
when 'ab'then select x into task from public.ab_games gg cross join lateral jsonb_array_elements(gg.frozen_tasks)x where gg.id=g and(x->>'theme')||':'||(x->>'n')=requested_code;
when 'ps'then select to_jsonb(x)into task from public.ps_tasks x join public.ps_games gg on gg.id=x.game_id where x.game_id=g and x.code=requested_code and(x.task_type='med'or x.round_no<=(public.ps_clock(gg,floor(extract(epoch from now())*1000)::bigint)->>'issued')::int);else null;end case;
if task is null or coalesce(task->>'attachments','optional')='forbidden'then raise exception 'Вложения запрещены или задача недоступна';end if;
-- Bound repeated/duplicate attempt upload is rejected at submit; cap unbound upload footprint to 60 MB per team.
if (select coalesce(sum(size),0)from public.mg_files where game_kind=k and game_id=g and team_id=team and answer_id is null and created_at>now()-interval '1 day')+(p->>'size')::int>62914560 then raise exception 'Слишком много неотправленных файлов. Отправьте или удалите вложения';end if;
if coalesce(p->>'mime','')not in('image/jpeg','image/png','image/heic','image/heif','application/pdf')then raise exception 'Неподдерживаемый формат';end if;
fid:=gen_random_uuid();insert into public.mg_files(id,game_kind,game_id,team_id,task_code,name,mime,size,path)values(fid,k,g,team,requested_code,left(coalesce(p->>'name','file'),200),p->>'mime',(p->>'size')::int,k||'/'||g||'/'||fid)returning *into row;return to_jsonb(row);
end if;
select *into row from public.mg_files where id=(p->>'id')::uuid and game_kind=k and game_id=g for update;
if not found or not(host or row.team_id=team)or row.expires_at is not null then raise exception 'Файл недоступен';end if;
if op='ready'then update public.mg_files set ready=true where id=row.id;return to_jsonb(row);elsif op='get'then if not row.ready then raise exception 'Файл не загружен';end if;return to_jsonb(row);
elsif op='discard'then if row.answer_id is not null then raise exception 'Отправленное вложение нельзя удалить отдельно';end if;update public.mg_files set expires_at=now()where id=row.id;return to_jsonb(row);end if;raise exception 'Неизвестное действие';end $$;
create or replace function public.mg_bind_files(k text,g uuid,team uuid,code text,answer uuid,ids jsonb,policy text,legacy boolean default false)returns void language plpgsql set search_path=''as $$
#variable_conflict use_column
declare item text;row public.mg_files;begin
if ids is null then ids:='[]';end if;if jsonb_typeof(ids)<>'array'or jsonb_array_length(ids)>6 or(select count(distinct x)from jsonb_array_elements_text(ids)x)<>jsonb_array_length(ids)then raise exception 'Не больше 6 разных файлов к ответу';end if;
if policy='forbidden'and(jsonb_array_length(ids)>0 or legacy)then raise exception 'К этой задаче файлы прикреплять нельзя';end if;
if policy='required'and jsonb_array_length(ids)=0 and not legacy then raise exception 'Прикрепите файл решения';end if;
for item in select jsonb_array_elements_text(ids)loop select *into row from public.mg_files where id=item::uuid for update;
if not found or row.game_kind<>k or row.game_id<>g or row.team_id<>team or row.task_code<>code or not row.ready or row.expires_at is not null or(row.answer_id is not null and row.answer_id<>answer)then raise exception 'Вложение недоступно';end if;update public.mg_files set answer_id=answer where id=row.id;end loop;end $$;
revoke all on function public.mg_files_access(text,text,uuid,text,jsonb),public.mg_bind_files(text,uuid,uuid,text,uuid,jsonb,text,boolean)from public;
grant execute on function public.mg_files_access(text,text,uuid,text,jsonb)to service_role;
alter table public.ab_tasks add column attachments text not null default 'optional'check(attachments in('forbidden','optional','required'));
alter table public.ps_tasks add column attachments text not null default 'optional'check(attachments in('forbidden','optional','required'));
alter table public.ab_submissions add column files jsonb not null default '[]';alter table public.ps_submissions add column files jsonb not null default '[]';
alter table public.ps_submissions drop constraint if exists ps_submissions_answer_check;
alter table public.ps_submissions add constraint ps_submissions_answer_check check(length(answer)<=6000 and(length(answer)>0 or solution is not null or jsonb_array_length(files)>0));
create extension if not exists pg_net with schema extensions;
select cron.schedule('math-games-file-retention','27 * * * *',$cron$select net.http_post(url:='https://qavxgdmiqtguplnamybd.supabase.co/functions/v1/game-files',headers:='{"Content-Type":"application/json","apikey":"sb_publishable_xJGfu2sgjl9Ix6rGkiTtgA_vu5wrwzO","Authorization":"Bearer sb_publishable_xJGfu2sgjl9Ix6rGkiTtgA_vu5wrwzO"}'::jsonb,body:=jsonb_build_object('op','cleanup','token',(select cleanup_token from public.mg_file_config where id=true)),timeout_milliseconds:=55000);$cron$);
commit;

begin;
create or replace function public.mg_validate(c jsonb)returns jsonb language plpgsql immutable set search_path='' as $$
begin
if jsonb_typeof(c)is distinct from 'object' or coalesce(c->>'mode','')not in('number','text','set','manual')or coalesce(c->>'kind','standard')not in('standard','cutting')or length(coalesce(c->>'condition',''))>20000 or length(coalesce(c->>'key',''))>2000 then raise exception 'Неверная задача';end if;
if coalesce(c->>'attachments','optional')not in('forbidden','optional','required')then raise exception 'Неверная настройка вложений';end if;
if c->>'kind'='cutting'then perform public.mg_cut_check(c->'module_config',null);c:=c||jsonb_build_object('mode','manual','key','','module_id','cutting','module_version','1');
elsif c->>'mode'<>'manual'and nullif(trim(c->>'key'),'')is null then raise exception 'Нет ключа автопроверки';end if;
return jsonb_build_object('attachments',coalesce(c->>'attachments','optional'),'title',left(coalesce(c->>'title',''),200),'condition',coalesce(c->>'condition',''),'mode',c->>'mode','key',coalesce(c->>'key',''),'kind',coalesce(c->>'kind','standard'),'module_id',case when c->>'kind'='cutting'then 'cutting'end,'module_version',case when c->>'kind'='cutting'then '1'end,'module_config',case when c->>'kind'='cutting'then c->'module_config'else '{}'::jsonb end);end $$;
create or replace function public.mg_tasks(k text,g uuid,t text,op text,payload jsonb default '{}')returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare r jsonb;a jsonb:='[]';b jsonb;c jsonb;native jsonb:='[]';row jsonb;code text;st jsonb;secret text;wb public.mg_workbenches;ref uuid;ver int;v public.mg_bank_versions;
begin
if k='birzha'and op='create'then secret:=gen_random_uuid()::text||gen_random_uuid()::text;insert into public.mg_workbenches(host_hash)values(sha256(convert_to(secret,'UTF8')))returning * into wb;return jsonb_build_object('id',wb.id,'hostToken',secret);end if;
if not public.mg_host(k,g,t)then raise exception 'Нужна ссылка ведущего';end if;
-- Same row lock as native mutations: no save/start race.
case k when 'od'then perform 1 from public.od_games where id=g for update;r:=public.od_api('state',g,t);for b in select * from jsonb_array_elements(r->'tasks')loop a:=a||jsonb_build_array(jsonb_build_object('code',b->>'n','number',b->'n','content',jsonb_build_object('attachments',coalesce(b->>'attachments','optional'),'condition',b->>'title','mode',b->>'mode','key',b->>'key','kind',coalesce(b->>'kind','standard'),'module_config',coalesce(b->'module_config','{}'))));end loop;
when 'ab'then perform 1 from public.ab_games where id=g for update;r:=public.ab_api('state',g,t);for b in select * from jsonb_array_elements(r->'draftTasks')loop a:=a||jsonb_build_array(jsonb_build_object('code',(b->>'theme')||':'||(b->>'n'),'number',b->'n','theme',b->'theme','topic',b->'topic','content',jsonb_build_object('attachments',coalesce(b->>'attachments','optional'),'condition',b->>'text','mode',case b->>'mode'when 'Число'then 'number'when 'Текст'then 'text'when 'Набор чисел'then 'set'else 'manual'end,'key',b->>'key','kind',b->>'kind','module_config',b->'module_config')));end loop;
when 'ps'then perform 1 from public.ps_games where id=g for update;r:=public.ps_api('state',g,t);for b in select * from jsonb_array_elements(r->'draftTasks')loop a:=a||jsonb_build_array(jsonb_build_object('code',b->>'code','number',b->'n','round',b->'round_no','type',b->'task_type','content',jsonb_build_object('attachments',coalesce(b->>'attachments','optional'),'condition',b->>'statement','mode',b->>'mode','key',b->>'key','kind',b->>'kind','module_config',b->'module_config')));end loop;
when 'birzha'then perform 1 from public.mg_workbenches where id=g for update;select coalesce(jsonb_agg(jsonb_build_object('code',code,'content',content)order by code),'[]')into a from public.mg_task_copies where game_kind=k and game_id=g;r:='{}';
else raise exception 'Неизвестная игра';end case;
if op='get'then return jsonb_build_object('rows',(select coalesce(jsonb_agg(x||coalesce((select jsonb_build_object('bank_id',bank_id,'bank_version',bank_version,'content',(x->'content')||jsonb_build_object('title',coalesce(content->>'title','')))from public.mg_task_copies where game_kind=k and game_id=g and mg_task_copies.code=x->>'code'),'{}')),'[]')from jsonb_array_elements(a)x),'locked',case k when 'od'then r->'start'<>'null'::jsonb when 'ab'then (r->>'start')::bigint>0 when 'ps'then r->'clock'->>'status'<>'READY'else false end);end if;
if op<>'save'then raise exception 'Неизвестное действие';end if;
if k='od'and (r->>'start')is not null or k='ab'and(r->>'start')::bigint>0 or k='ps'and r->'clock'->>'status'<>'READY'then raise exception 'Задачи зафиксированы после старта';end if;
b:=payload->'rows';if jsonb_typeof(b)is distinct from 'array'or jsonb_array_length(b)>1000 or(k<>'birzha'and jsonb_array_length(b)<>jsonb_array_length(a))or(select count(distinct x->>'code')from jsonb_array_elements(b)x)<>jsonb_array_length(b)then raise exception 'Нужно сохранить все разные позиции задач';end if;
for row in select * from jsonb_array_elements(b)loop
code:=row->>'code';if code is null or length(code)not between 1 and 50 or(k<>'birzha'and not exists(select 1 from jsonb_array_elements(a)x where x->>'code'=code))then raise exception 'Неизвестный код задачи';end if;
c:=public.mg_validate(row->'content');ref:=(row->>'bank_id')::uuid;ver:=(row->>'bank_version')::int;
if ref is not null and not exists(select 1 from public.mg_task_copies cp where cp.game_kind=k and cp.game_id=g and cp.code=code and cp.bank_id=ref and cp.bank_version=ver and cp.content=c)then select bv.* into v from public.mg_bank_versions bv join public.mg_bank_tasks bt on bt.id=bv.task_id where bt.owner_id=auth.uid()and bv.task_id=ref and bv.version=ver;if not found or v.content<>c then raise exception 'Версия банка недоступна или изменена. Сохраните копию без привязки';end if;c:=v.content;end if;
insert into public.mg_task_copies values(k,g,code,c,ref,ver)on conflict(game_kind,game_id,code)do update set content=excluded.content,bank_id=excluded.bank_id,bank_version=excluded.bank_version;
case k when 'od'then if length(c->>'condition')>5000 then raise exception 'Оптом дороже: условие до 5000 символов';end if;native:=native||jsonb_build_array(jsonb_build_object('attachments',c->>'attachments','n',code::int,'title',c->>'condition','mode',c->>'mode','key',c->>'key','kind',c->>'kind','module_id',c->>'module_id','module_version',c->>'module_version','module_config',c->'module_config'));
when 'ab'then native:=native||jsonb_build_array(jsonb_build_object('theme',split_part(code,':',1)::int,'n',split_part(code,':',2)::int,'topic',coalesce(nullif(row->>'topic',''),'Тема '||split_part(code,':',1)),'text',c->>'condition','mode',case c->>'mode'when 'number'then 'Число'when 'text'then 'Текст'when 'set'then 'Набор чисел'else 'Вручную'end,'key',c->>'key'));
when 'ps'then native:=native||jsonb_build_array(jsonb_build_object('code',code,'statement',c->>'condition','mode',c->>'mode','key',c->>'key'));else null;end case;end loop;
case k when 'od'then select jsonb_agg(x order by(x->>'n')::int)into native from jsonb_array_elements(native)x;perform public.od_api('tasks',g,t,jsonb_build_object('tasks',native));
when 'ab'then perform public.ab_api('tasks',g,t,jsonb_build_object('tasks',native));update public.ab_tasks at set attachments=cp.content->>'attachments',kind=cp.content->>'kind',module_id=cp.content->>'module_id',module_version=cp.content->>'module_version',module_config=cp.content->'module_config',bank_task_id=cp.bank_id,bank_version=cp.bank_version::text from public.mg_task_copies cp where cp.game_kind=k and cp.game_id=g and at.game_id=g and cp.code=at.theme||':'||at.n;
when 'ps'then perform public.ps_api('tasks',g,t,jsonb_build_object('tasks',native));update public.ps_tasks at set attachments=cp.content->>'attachments',kind=cp.content->>'kind',module_id=cp.content->>'module_id',module_version=cp.content->>'module_version',module_config=cp.content->'module_config',bank_task_id=cp.bank_id,bank_version=cp.bank_version::text from public.mg_task_copies cp where cp.game_kind=k and cp.game_id=g and at.game_id=g and at.code=cp.code;
else delete from public.mg_task_copies where game_kind=k and game_id=g and code not in(select x->>'code'from jsonb_array_elements(b)x);end case;
return public.mg_tasks(k,g,t,'get');end $$;
create or replace function public.od_api(op text, game uuid default null, token text default '', payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.od_games; t public.od_teams; p public.od_packets; host boolean:=false;
 secret text; names jsonb; task_list jsonb; a jsonb; entry jsonb; task jsonb; outa jsonb:='[]';
 n int; st text; val text; img text; pid uuid; k text; idx int; result jsonb; ts jsonb; ps jsonb;
begin
 if game is not null and exists(select 1 from public.mg_lifecycle where game_kind='od'and game_id=game and archived)then
  if op not in('state','export')then raise exception 'Подробные данные удалены по сроку хранения';end if;
  return (select lc.result||jsonb_build_object('archived',true)from public.mg_lifecycle lc where game_kind='od'and game_id=game);
 end if;
 if op='create' then
  secret:=gen_random_uuid()::text||gen_random_uuid()::text;
  insert into public.od_games(host_hash,title,tasks) values(sha256(convert_to(secret,'UTF8')),left(coalesce(nullif(trim(payload->>'title'),''),'Оптом дороже'),100),coalesce((select tasks from public.od_templates where id=true),'[]'::jsonb)) returning * into g;
  return jsonb_build_object('game',g.id,'host',secret);
 end if;
 select * into g from public.od_games where id=game;
 if not found then raise exception 'Игра не найдена'; end if;
 host:=length(token)>0 and sha256(convert_to(token,'UTF8'))=g.host_hash;
 if not host and token<>'' then
  select * into t from public.od_teams where game_id=g.id and od_teams.token=od_api.token;
  if not found then raise exception 'Неверная ссылка команды'; end if;
 end if;
 if op not in ('state','photo') then
  select * into g from public.od_games where id=g.id for update;
 end if;
 if op='delivery' then
  if not host or g.started_at is not null or jsonb_typeof(payload->'online') is distinct from 'boolean' then raise exception 'Режим выбирается ведущим до старта';end if;
  update public.od_games set online=(payload->>'online')::boolean where id=g.id;
 elsif op='configure' then
  if not host then raise exception 'Нет доступа ведущего'; end if;
  if g.started_at is not null then raise exception 'После старта команды менять нельзя'; end if;
  names:=payload->'names';
  if coalesce(jsonb_typeof(names),'null')<>'array' or jsonb_array_length(names) not between 3 and 6 then raise exception 'Нужно 3–6 команд'; end if;
  if exists(select 1 from jsonb_array_elements_text(names) x where length(trim(x)) not between 1 and 50) or (select count(distinct trim(x)) from jsonb_array_elements_text(names) x)<>jsonb_array_length(names) then raise exception 'Нужны разные названия до 50 символов'; end if;
  if exists(select 1 from public.od_packets where game_id=g.id) then raise exception 'Уже есть сдачи'; end if;
  -- Reconfigure before start; old capabilities are intentionally invalidated.
  delete from public.od_teams where game_id=g.id;
  for k in select trim(x) from jsonb_array_elements_text(names) x loop
   insert into public.od_teams(game_id,name,token) values(g.id,k,gen_random_uuid()::text||gen_random_uuid()::text);
  end loop;
 elsif op='tasks' then
  if not host or g.started_at is not null then raise exception 'Задачи меняются ведущим до старта'; end if;
  task_list:=payload->'tasks';
  if coalesce(jsonb_typeof(task_list),'null')<>'array' or jsonb_array_length(task_list)<>24 then raise exception 'Нужно 24 задачи'; end if;
  for n in 1..24 loop
   task:=task_list->(n-1);
   if (task->>'n')::int is distinct from n or coalesce(task->>'mode','') not in ('number','set','text','manual') or length(coalesce(task->>'title',''))>5000 or length(coalesce(task->>'key',''))>3000 then raise exception 'Неверные настройки задачи %',n; end if;
   if task->>'mode'<>'manual' then
    if nullif(trim(task->>'key'),'') is null then raise exception 'Нет ключа №%',n; end if;
    for k in select unnest(string_to_array(task->>'key','|')) loop
     if public.od_normal(k,task->>'mode') is null then raise exception 'Непонятный ключ №%',n; end if;
    end loop;
   end if;
  end loop;
  update public.od_games set tasks=task_list where id=g.id;
 elsif op='start' then
  if not host then raise exception 'Нет доступа ведущего'; end if;
  if g.started_at is not null then raise exception 'Игра уже запускалась'; end if;
  if jsonb_array_length(g.tasks)<>24 or (select count(*) from public.od_teams where game_id=g.id) not between 3 and 6 then raise exception 'Сохраните команды и 24 задачи'; end if;
  update public.od_games set started_at=clock_timestamp(),ends_at=clock_timestamp()+interval '90 minutes',closed=false where id=g.id;
 elsif op='close' then
  if not host then raise exception 'Нет доступа ведущего'; end if;
  update public.od_games set closed=true where id=g.id;
 elsif op='submit' then
  if host and not g.online then select * into t from public.od_teams where id=(payload->>'team')::uuid and game_id=g.id;
  elsif not g.online then raise exception 'Игра в аудитории: сдайте ответ на листочке ведущему';end if;
  if t.id is null then raise exception 'Нужна ссылка команды'; end if;
  pid:=(payload->>'id')::uuid;
  select * into p from public.od_packets where id=pid;
  if found then
   if p.team_id<>t.id then raise exception 'ID уже занят'; end if;
   return jsonb_build_object('id',pid);
  end if;
  if g.started_at is null or g.closed or clock_timestamp()>=g.ends_at then raise exception 'Приём ответов закрыт'; end if;
  a:=payload->'answers'; img:=coalesce(payload->>'image','');
  if coalesce(jsonb_typeof(a),'null')<>'array' or jsonb_array_length(a) not between 1 and 8 then raise exception 'Нужно от 1 до 8 задач'; end if;
  if img<>'' and (length(img)>2800000 or img !~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$') then raise exception 'Неверный формат или размер фото'; end if;
  if (select count(distinct (e->>'n')::int) from jsonb_array_elements(a) e)<>jsonb_array_length(a) then raise exception 'Номера повторяются'; end if;
  for entry in select * from jsonb_array_elements(a) loop
   n:=(entry->>'n')::int; val:=trim(coalesce(entry->>'text',''));
   if n is null or n not between 1 and 24 or length(val)>3000 or (val='' and img='' and entry->'solution' is null and coalesce(jsonb_array_length(entry->'files'),0)=0) then raise exception 'Неверный номер или пустой ответ'; end if;
   if exists(select 1 from public.od_packets q cross join lateral jsonb_array_elements(q.answers) e where q.team_id=t.id and (e->>'n')::int=n and coalesce(e->>'cancelled','false')<>'true') then raise exception 'Задача №% уже сдана',n; end if;
   task:=g.tasks->(n-1); st:='pending';
   perform public.mg_bind_files('od',g.id,t.id,n::text,pid,entry->'files',case when host and not g.online then 'optional'else coalesce(task->>'attachments','optional')end,img<>'');
   if task->>'kind'='cutting' then
    if entry->'solution' is not null then st:=public.mg_cut_check(task->'module_config',entry->'solution');elsif not(host and not g.online)and coalesce(jsonb_array_length(entry->'files'),0)=0 and img=''then raise exception 'Нужно интерактивное решение';end if;
   elsif task->>'mode'<>'manual' then
    k:=public.od_normal(val,task->>'mode');
    if k is not null and k<>'' then
     if exists(select 1 from unnest(string_to_array(task->>'key','|')) v where public.od_normal(v,task->>'mode')=k) then st:='yes';
     elsif task->>'mode'<>'text' then st:='no'; end if;
    end if;
   end if;
   outa:=outa||jsonb_build_array(jsonb_build_object('n',n,'text',val,'solution',entry->'solution','files',coalesce(entry->'files','[]'),'status',st,'cancelled',false));
  end loop;
  insert into public.od_packets(id,game_id,team_id,answers,image) values(pid,g.id,t.id,outa,img);
  return jsonb_build_object('id',pid);
 elsif op in ('judge','cancel') then
  if not host then raise exception 'Нет доступа ведущего'; end if;
  select * into p from public.od_packets where id=(payload->>'id')::uuid and game_id=g.id for update;
  if not found then raise exception 'Комплект не найден'; end if;
  n:=(payload->>'n')::int;
  select ordinality::int-1 into idx from jsonb_array_elements(p.answers) with ordinality where (value->>'n')::int=n;
  if idx is null then raise exception 'Ответ не найден'; end if;
  if op='cancel' then
   outa:=jsonb_set(p.answers,array[idx::text,'cancelled'],'true');
  else
   st:=payload->>'status';
   if st not in ('yes','no','pending') or st is null then raise exception 'Неверный вердикт'; end if;
   outa:=jsonb_set(p.answers,array[idx::text,'status'],to_jsonb(st));
  end if;
  update public.od_packets set answers=outa where id=p.id;
 elsif op='photo' then
  select * into p from public.od_packets where id=(payload->>'id')::uuid and game_id=g.id;
  if not found or not(host or t.id=p.team_id) then raise exception 'Нет доступа к фото'; end if;
  return jsonb_build_object('image',p.image);
 elsif op<>'state' then raise exception 'Неизвестная команда';
 end if;
 select * into g from public.od_games where id=g.id;
 select coalesce(jsonb_agg(x order by (x->>'score')::int desc,x->>'name'),'[]') into ts from (
  select jsonb_build_object('id',tm.id,'name',tm.name,'score',coalesce(sum(public.od_score(q.answers)),0),
   'sent',coalesce(sum((select count(*) from jsonb_array_elements(q.answers) e where coalesce(e->>'cancelled','false')<>'true')),0),
   'pending',count(q.id) filter(where public.od_score(q.answers) is null)) x
  from public.od_teams tm left join public.od_packets q on q.team_id=tm.id where tm.game_id=g.id group by tm.id
 ) z;
 result:=jsonb_build_object('game',g.id,'title',g.title,'online',g.online,'start',g.started_at,'end',g.ends_at,'closed',g.closed,'now',clock_timestamp(),'teams',ts);
 if host or t.id is not null then
  select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'team',q.team_id,'time',q.created_at,'answers',q.answers,'photo',q.image<>'','score',public.od_score(q.answers)) order by q.created_at),'[]') into ps from public.od_packets q where q.game_id=g.id and (host or q.team_id=t.id);
  result:=result||jsonb_build_object('packets',ps,'tasks',(select jsonb_agg(case when host then x else x-'key'-'mode' end order by (x->>'n')::int) from jsonb_array_elements(g.tasks) x));
 end if;
 if host then
  result:=result||jsonb_build_object('host',true,'links',(select coalesce(jsonb_agg(jsonb_build_object('name',name,'token',tm.token) order by name),'[]') from public.od_teams tm where game_id=g.id));
 elsif t.id is not null then result:=result||jsonb_build_object('me',jsonb_build_object('id',t.id,'name',t.name)); end if;
 return result;
end $$;
create or replace function public.ab_api(op text, game uuid default null, token text default '', payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.ab_games; team public.ab_teams; rec public.ab_submissions; host boolean:=false;
 received bigint:=floor(extract(epoch from clock_timestamp())*1000); secret text; gid uuid; names jsonb; task_list jsonb; task jsonb;
 a int; b int; i int; v text; value text; st text; pid uuid; photo jsonb; bytes bytea; mime text; r jsonb; info jsonb; snapshot jsonb;
 nt int; nn int; mins int;
begin
 if game is not null and exists(select 1 from public.mg_lifecycle where game_kind='ab'and game_id=game and archived)then
  if op not in('state','export')then raise exception 'Подробные данные удалены по сроку хранения';end if;
  return (select lc.result||jsonb_build_object('archived',true)from public.mg_lifecycle lc where game_kind='ab'and game_id=game);
 end if;
 if op='create' then
  secret:=gen_random_uuid()::text||gen_random_uuid()::text;
  insert into public.ab_games(host_hash,title) values(sha256(convert_to(secret,'UTF8')),left(coalesce(nullif(trim(payload->>'title'),''),'Математическая абака'),100)) returning * into g;
  insert into public.ab_tasks(game_id,theme,n,topic) select g.id,aa.a,bb.b,'Тема '||aa.a from generate_series(1,5) aa(a) cross join generate_series(1,5) bb(b);
  insert into public.ab_teams(game_id,position,name,token) select g.id,n,'Команда '||n,gen_random_uuid()::text||gen_random_uuid()::text from generate_series(1,3) n;
  insert into public.ab_events(game_id,action) values(g.id,'create');
  return jsonb_build_object('id',g.id,'hostToken',secret);
 end if;
 select * into g from public.ab_games where id=game;
 if not found then raise exception 'Игра не найдена'; end if;
 host:=length(token)>0 and sha256(convert_to(token,'UTF8'))=g.host_hash;
 if not host and token<>'' then
  select * into team from public.ab_teams t where t.game_id=g.id and t.token=ab_api.token;
  if not found then raise exception 'Ссылка команды недействительна'; end if;
 end if;
 if op not in ('state','picture') then select * into g from public.ab_games where id=g.id for update; end if;
 if op in ('configure','tasks','start','close','new','review','export','delivery') and not host then raise exception 'Нет доступа ведущего'; end if;
 if op='delivery' then
  if not host or g.start_ms is not null or jsonb_typeof(payload->'online') is distinct from 'boolean' then raise exception 'Режим выбирается ведущим до старта';end if;
  update public.ab_games set online=(payload->>'online')::boolean where id=g.id;
 elsif op='configure' then
  if g.start_ms is not null then raise exception 'Настройки меняются только до старта'; end if;
  nt:=(payload->>'themes')::int;nn:=(payload->>'tasks')::int;mins:=(payload->>'minutes')::int;names:=payload->'names';
  if nt is null or nt not between 1 and 12 or nn is null or nn not between 1 and 12 or mins is null or mins not between 1 and 300 then raise exception 'Тем: 1–12, задач в теме: 1–12, время: 1–300 минут'; end if;
  if coalesce(jsonb_typeof(names),'null')<>'array' or jsonb_array_length(names) not between 1 and 32 then raise exception 'Нужно 1–32 названия'; end if;
  if exists(select 1 from jsonb_array_elements_text(names) x where x is null or length(trim(x)) not between 1 and 60) or (select count(distinct trim(x)) from jsonb_array_elements_text(names) x)<>jsonb_array_length(names) then raise exception 'Нужны разные названия до 60 символов'; end if;
  delete from public.ab_teams where game_id=g.id and position>jsonb_array_length(names);
  for i in 1..jsonb_array_length(names) loop
   insert into public.ab_teams(game_id,position,name,token) values(g.id,i,trim(names->>(i-1)),gen_random_uuid()::text||gen_random_uuid()::text)
   on conflict(game_id,position) do update set name=excluded.name;
  end loop;
  update public.ab_games set themes=nt,tasks_per_theme=nn,minutes=mins where id=g.id;
  insert into public.ab_tasks(game_id,theme,n,topic) select g.id,aa.a,bb.b,'Тема '||aa.a from generate_series(1,nt) aa(a) cross join generate_series(1,nn) bb(b) on conflict do nothing;
  insert into public.ab_events(game_id,action,data) values(g.id,'configure',payload);
 elsif op='tasks' then
  if g.start_ms is not null then raise exception 'Условия и ключи уже зафиксированы на старте'; end if;
  task_list:=payload->'tasks';
  if coalesce(jsonb_typeof(task_list),'null')<>'array' or jsonb_array_length(task_list)<>g.themes*g.tasks_per_theme then raise exception 'Нужно заполнить всё поле задач'; end if;
  if (select count(distinct (x->>'theme',x->>'n')) from jsonb_array_elements(task_list) x)<>jsonb_array_length(task_list) then raise exception 'Повторяются номера задач'; end if;
  for task in select * from jsonb_array_elements(task_list) loop
   a:=(task->>'theme')::int;b:=(task->>'n')::int;
   if a is null or a not between 1 and g.themes or b is null or b not between 1 and g.tasks_per_theme then raise exception 'Неверный номер задачи'; end if;
   if length(trim(coalesce(task->>'topic',''))) not between 1 and 200 or length(coalesce(task->>'text',''))>20000 or length(coalesce(task->>'key',''))>2000 or coalesce(task->>'mode','') not in ('Число','Текст','Набор чисел','Вручную') then raise exception 'Неверные данные задачи %:%',a,b; end if;
   if coalesce(task->>'kind','standard')<>'standard' or task->>'module_id' is not null or coalesce(task->'module_config','{}')<>'{}'::jsonb then raise exception 'Интерактивные модули пока не подключены'; end if;
   if task->>'mode'<>'Вручную' then
    for v in select unnest(string_to_array(coalesce(task->>'key',''),'|')) loop
     if nullif(trim(v),'') is null or public.ab_normal(v,task->>'mode') is null then raise exception 'Некорректный ключ %:%',a,b; end if;
    end loop;
    if nullif(trim(task->>'key'),'') is null then raise exception 'Нет ключа %:%',a,b; end if;
   end if;
   update public.ab_tasks set topic=trim(task->>'topic'),text=coalesce(task->>'text',''),mode=task->>'mode',key=coalesce(task->>'key',''),bank_task_id=(task->>'bank_task_id')::uuid,bank_version=left(task->>'bank_version',100),kind='standard' where game_id=g.id and theme=a and n=b;
  end loop;
  if exists(select 1 from public.ab_tasks where game_id=g.id and theme<=g.themes and n<=g.tasks_per_theme group by theme having count(distinct topic)>1) then raise exception 'В одной теме должны совпадать названия'; end if;
  insert into public.ab_events(game_id,action,data) values(g.id,'tasks_saved',jsonb_build_object('count',jsonb_array_length(task_list)));
 elsif op='start' then
  if g.start_ms is not null then raise exception 'Игра уже запускалась'; end if;
  select jsonb_agg(to_jsonb(t)-'game_id' order by theme,n) into snapshot from public.ab_tasks t where game_id=g.id and theme<=g.themes and n<=g.tasks_per_theme;
  if snapshot is null or jsonb_array_length(snapshot)<>g.themes*g.tasks_per_theme or exists(select 1 from jsonb_array_elements(snapshot) t where nullif(trim(t->>'text'),'') is null or (t->>'mode'<>'Вручную' and nullif(trim(t->>'key'),'') is null)) then raise exception 'Заполните и сохраните все условия и ключи'; end if;
  update public.ab_games set start_ms=received,end_ms=received+minutes*60000,closed=false,frozen_tasks=snapshot where id=g.id;
  insert into public.ab_events(game_id,action) values(g.id,'start');
 elsif op='close' then
  if g.start_ms is null then raise exception 'Игра ещё не началась'; end if;
  update public.ab_games set closed=true where id=g.id;
  insert into public.ab_events(game_id,action) values(g.id,'close');
 elsif op='new' then
  if g.start_ms is not null and not g.closed and received<g.end_ms then raise exception 'Сначала завершите текущую игру'; end if;
  secret:=gen_random_uuid()::text||gen_random_uuid()::text;
  insert into public.ab_games(host_hash,title,themes,tasks_per_theme,minutes,online) values(sha256(convert_to(secret,'UTF8')),g.title,g.themes,g.tasks_per_theme,g.minutes,g.online) returning id into gid;
  insert into public.ab_teams(game_id,position,name,token) select gid,position,name,gen_random_uuid()::text||gen_random_uuid()::text from public.ab_teams where game_id=g.id;
  insert into public.ab_tasks select gid,theme,n,topic,text,mode,key,bank_task_id,bank_version,kind,module_id,module_version,module_config,attachments from public.ab_tasks where game_id=g.id;
  insert into public.ab_events(game_id,action,data) values(gid,'copy',jsonb_build_object('source',g.id));
  return jsonb_build_object('id',gid,'hostToken',secret);
 elsif op='submit' then
  if host and not g.online then select * into team from public.ab_teams where id=(payload->>'team')::uuid and game_id=g.id;
  elsif not g.online then raise exception 'Игра в аудитории: сдайте ответ на листочке ведущему';end if;
  if team.id is null then raise exception 'Нужна ссылка команды'; end if;
  pid:=(payload->>'id')::uuid;
  select * into rec from public.ab_submissions where id=pid;
  if found then
   if rec.team_id<>team.id then raise exception 'ID уже занят'; end if;
   return jsonb_build_object('id',rec.id,'status',rec.status);
  end if;
  if g.start_ms is null or received<g.start_ms or g.closed or received>=g.end_ms then raise exception 'Приём ответов закрыт'; end if;
  a:=(payload->>'theme')::int;b:=(payload->>'n')::int;
  if a is null or a not between 1 and g.themes or b is null or b not between 1 and g.tasks_per_theme then raise exception 'Неверный номер задачи'; end if;
  if exists(select 1 from public.ab_submissions where team_id=team.id and theme=a and n=b and status<>'cancelled') then raise exception 'На эту задачу ответ уже отправлен'; end if;
  if exists(select 1 from generate_series(1,b-1) j where not exists(select 1 from public.ab_submissions where team_id=team.id and theme=a and n=j and status<>'cancelled')) then raise exception 'Сначала отправьте предыдущие задачи этой темы'; end if;
  value:=trim(coalesce(payload->>'answer',''));photo:=nullif(payload->'file','null'::jsonb);
  if length(value)>4000 or (value='' and photo is null and payload->'solution' is null and coalesce(jsonb_array_length(payload->'files'),0)=0) then raise exception 'Введите ответ или приложите картинку'; end if;
  task:=(select x from jsonb_array_elements(g.frozen_tasks) x where (x->>'theme')::int=a and (x->>'n')::int=b);
  st:='pending';
  perform public.mg_bind_files('ab',g.id,team.id,a||':'||b,pid,payload->'files',case when host and not g.online then 'optional'else coalesce(task->>'attachments','optional')end,photo is not null);
  if photo is not null then
   mime:=photo->>'type';v:=photo->>'data';
   if mime is null or mime not in ('image/jpeg','image/png','image/webp') or v is null or length(v)>5600000 or v !~ '^[A-Za-z0-9+/]+={0,2}$' then raise exception 'Картинка: JPG, PNG или WebP до 4 МБ'; end if;
   bytes:=decode(v,'base64');
   if octet_length(bytes) not between 12 and 4194304 or not(case mime when 'image/jpeg' then substring(bytes from 1 for 3)=decode('ffd8ff','hex') when 'image/png' then substring(bytes from 1 for 8)=decode('89504e470d0a1a0a','hex') else substring(bytes from 1 for 4)=convert_to('RIFF','UTF8') and substring(bytes from 9 for 4)=convert_to('WEBP','UTF8') end) then raise exception 'Файл не соответствует формату картинки'; end if;
  end if;
  if task->>'kind'='cutting' then
   if payload->'solution' is not null then st:=public.mg_cut_check(task->'module_config',payload->'solution');elsif not(host and not g.online)and coalesce(jsonb_array_length(payload->'files'),0)=0 and photo is null then raise exception 'Нужно интерактивное решение';end if;
  elsif photo is null and coalesce(jsonb_array_length(payload->'files'),0)=0 and task->>'mode'<>'Вручную' then
   v:=public.ab_normal(value,task->>'mode');
   if v is not null then
    if exists(select 1 from unnest(string_to_array(task->>'key','|')) k where public.ab_normal(k,task->>'mode')=v) then st:='yes';
    elsif task->>'mode'<>'Текст' then st:='no'; end if;
   end if;
  end if;
  insert into public.ab_submissions(id,game_id,team_id,received_ms,theme,n,answer,status,solution,files) values(pid,g.id,team.id,received,a,b,value,st,payload->'solution',coalesce(payload->'files','[]'));
  if photo is not null then insert into public.ab_photos(submission_id,mime,data) values(pid,mime,bytes); end if;
  return jsonb_build_object('id',pid,'status',st);
 elsif op='review' then
  pid:=(payload->>'id')::uuid;st:=payload->>'status';v:=trim(coalesce(payload->>'note',''));
  if st is null or st not in ('yes','no','pending','cancelled') or length(v)>1000 then raise exception 'Неверная оценка или длинный комментарий'; end if;
  select * into rec from public.ab_submissions where id=pid and game_id=g.id for update;
  if not found then raise exception 'Сдача не найдена'; end if;
  if rec.status='cancelled' then raise exception 'Сдача уже отменена; команда может ответить заново'; end if;
  update public.ab_submissions set status=st,note=v where id=pid;
  insert into public.ab_events(game_id,action,data) values(g.id,'review',jsonb_build_object('id',pid,'from',rec.status,'to',st,'note',v));
 elsif op='picture' then
  select * into rec from public.ab_submissions where id=(payload->>'id')::uuid and game_id=g.id;
  if not found or not(host or team.id=rec.team_id) or (not host and team.id is null) then raise exception 'Картинка недоступна'; end if;
  select jsonb_build_object('type',ph.mime,'data',encode(ph.data,'base64')) into r from public.ab_photos ph where ph.submission_id=rec.id;
  if r is null then raise exception 'Картинка не найдена'; end if;return r;
 elsif op='export' then
  return jsonb_build_object('game',to_jsonb(g)-'host_hash','tasks',(select jsonb_agg(to_jsonb(t)-'game_id') from public.ab_tasks t where game_id=g.id),
  'teams',(select jsonb_agg(to_jsonb(t)-'token') from public.ab_teams t where game_id=g.id),'results',public.ab_calculate(g.id),
  'submissions',(select coalesce(jsonb_agg(to_jsonb(s) order by received_ms),'[]') from public.ab_submissions s where game_id=g.id),
  'events',(select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]') from public.ab_events e where game_id=g.id));
 elsif op<>'state' or op is null then raise exception 'Неизвестное действие'; end if;
 select * into g from public.ab_games where id=g.id;
 r:=public.ab_calculate(g.id)||jsonb_build_object('id',g.id,'title',g.title,'online',g.online,'now',floor(extract(epoch from clock_timestamp())*1000),
 'start',coalesce(g.start_ms,0),'end',coalesce(g.end_ms,0),'closed',g.closed,'themes',g.themes,'tasksPerTheme',g.tasks_per_theme,'minutes',g.minutes);
 if host or team.id is not null then
  if g.start_ms is null then
   select coalesce(jsonb_agg(to_jsonb(t)-'game_id' order by theme,n),'[]') into info from public.ab_tasks t where game_id=g.id and theme<=g.themes and n<=g.tasks_per_theme;
  else info:=g.frozen_tasks; end if;
  r:=r||jsonb_build_object('taskInfo',case when not host and g.start_ms is null then '[]'::jsonb else (select coalesce(jsonb_agg(x-'key'-'mode' order by (x->>'theme')::int,(x->>'n')::int),'[]') from jsonb_array_elements(info) x) end,
  'records',(select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'time',s.received_ms,'team',s.team_id,'theme',s.theme,'n',s.n,'answer',s.answer,'solution',s.solution,'files',s.files,'hasFile',exists(select 1 from public.ab_photos where submission_id=s.id),'status',s.status,'note',s.note) order by s.received_ms,s.id),'[]') from public.ab_submissions s where game_id=g.id and (host or s.team_id=team.id)));
 end if;
 if host then
  r:=r||jsonb_build_object('admin',true,'names',(select jsonb_agg(name order by position) from public.ab_teams where game_id=g.id),
  'links',(select jsonb_agg(jsonb_build_object('name',name,'token',t.token) order by position) from public.ab_teams t where game_id=g.id),
  'draftTasks',info);
 elsif team.id is not null then r:=r||jsonb_build_object('me',jsonb_build_object('id',team.id,'name',team.name)); end if;
 return r;
end $$;
create or replace function public.ps_api(op text,game uuid default null,token text default '',payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare g public.ps_games;tm public.ps_teams;task public.ps_tasks;ev public.ps_events;sub public.ps_submissions;host boolean:=false;now_ms bigint:=floor(extract(epoch from clock_timestamp())*1000);
 secret text;gid uuid;clock jsonb;result jsonb;names jsonb;rounds_new int;interval_new int;issued int;i int;req uuid;actor_id uuid;target_id uuid;reason text;delta numeric;correct boolean;val text;e_id bigint;task_list jsonb;j jsonb;norm text;st text;
begin
 if game is not null and exists(select 1 from public.mg_lifecycle where game_kind='ps'and game_id=game and archived)then
  if op not in('state','export')then raise exception 'Подробные данные удалены по сроку хранения';end if;
  return (select lc.result||jsonb_build_object('archived',true)from public.mg_lifecycle lc where game_kind='ps'and game_id=game);
 end if;
 if op='create' then
  secret:=gen_random_uuid()::text||gen_random_uuid()::text;
  insert into public.ps_games(host_hash,title) values(sha256(convert_to(secret,'UTF8')),left(coalesce(nullif(trim(payload->>'title'),''),'Перестрелка'),100)) returning * into g;
  insert into public.ps_teams(game_id,position,name,token) select g.id,nn.n,'Команда '||nn.n,gen_random_uuid()::text||gen_random_uuid()::text from generate_series(1,4) nn(n);
  perform public.ps_seed(g.id,g.rounds);return jsonb_build_object('id',g.id,'hostToken',secret);
 end if;
 select * into g from public.ps_games where id=game;
 if not found then raise exception 'Игра не найдена'; end if;
 host:=length(token)>0 and sha256(convert_to(token,'UTF8'))=g.host_hash;
 if not host and token<>'' then select * into tm from public.ps_teams t where t.game_id=g.id and t.token=ps_api.token;if not found then raise exception 'Неверная ссылка команды';end if;end if;
 if op is null or op not in ('state','configure','start','pause','resume','finish','rounds','issue','answer','hp','cancel','undo','new','export','submit','judge','cancelSubmission','tasks','delivery') then raise exception 'Неизвестное действие';end if;
 if op not in ('state','submit') and not host then raise exception 'Действие доступно только ведущему';end if;
 if op<>'state' then select * into g from public.ps_games where id=g.id for update;end if;
 clock:=public.ps_clock(g,now_ms);issued:=(clock->>'issued')::int;
 if op='delivery' then
  if g.status<>'READY' or jsonb_typeof(payload->'online') is distinct from 'boolean' then raise exception 'Режим выбирается до старта';end if;
  update public.ps_games set online=(payload->>'online')::boolean where id=g.id;
 elsif op='submit' then
  if host and not g.online then select * into tm from public.ps_teams where id=(payload->>'team')::uuid and game_id=g.id;
  elsif not g.online then raise exception 'Игра в аудитории: сдайте ответ на листочке ведущему';end if;
  if tm.id is null then raise exception 'Используйте личную ссылку команды';end if;
  req:=(payload->>'id')::uuid;if req is null then raise exception 'Нужен ID запроса';end if;
  select * into sub from public.ps_submissions where id=req;
  if found then
   if sub.game_id<>g.id or sub.team_id<>tm.id then raise exception 'ID уже занят';end if;
   return public.ps_api('state',g.id,token);
  end if;
  if clock->>'status'<>'RUNNING' then raise exception 'Приём ответов закрыт или приостановлен';end if;
  select * into task from public.ps_tasks where game_id=g.id and code=payload->>'task';
  if not found or (task.task_type='shot' and task.round_no>issued) then raise exception 'Задача ещё не выдана';end if;
  if task.kind not in('standard','cutting')then raise exception 'Неизвестный интерактивный модуль';end if;
  if exists(select 1 from public.ps_events where game_id=g.id and kind='answer' and not cancelled and data->>'team'=tm.id::text and data->>'task'=task.code)
   or exists(select 1 from public.ps_submissions where game_id=g.id and team_id=tm.id and task_code=task.code and status<>'CANCELLED') then raise exception 'Команда уже отправляла ответ на эту задачу';end if;
  val:=trim(coalesce(payload->>'answer',''));if (length(val) not between 1 and 6000)and payload->'solution' is null and coalesce(jsonb_array_length(payload->'files'),0)=0 then raise exception 'Введите ответ: до 6000 символов';end if;
  target_id:=null;
  if task.task_type='shot' then
   target_id:=(payload->>'target')::uuid;
   if target_id is null or target_id=tm.id or not exists(select 1 from public.ps_teams where id=target_id and game_id=g.id) then raise exception 'Выберите соперника';end if;
  end if;
  perform public.mg_bind_files('ps',g.id,tm.id,task.code,req,payload->'files',case when host and not g.online then 'optional'else task.attachments end);
  insert into public.ps_submissions(id,game_id,team_id,task_code,target_id,answer,time_ms,solution,files) values(req,g.id,tm.id,task.code,target_id,val,now_ms,payload->'solution',coalesce(payload->'files','[]'));
  if task.kind='cutting'then
   if payload->'solution' is not null then st:=public.mg_cut_check(task.module_config,payload->'solution');if st<>'pending'then perform public.ps_decide(req,st='yes','auto');end if;elsif not(host and not g.online)and coalesce(jsonb_array_length(payload->'files'),0)=0 then raise exception 'Нужно интерактивное решение';end if;
  elsif task.mode<>'manual' then
   norm:=public.ps_normal(val,task.mode);
   if norm is not null then
    if exists(select 1 from unnest(string_to_array(task.key,'|')) k where public.ps_normal(k,task.mode)=norm) then perform public.ps_decide(req,true,'auto');
    elsif task.mode<>'text' then perform public.ps_decide(req,false,'auto');end if;
   end if;
  end if;
 elsif op='judge' then
  select * into sub from public.ps_submissions where id=(payload->>'submission')::uuid and game_id=g.id for update;
  if not found or sub.status='CANCELLED' then raise exception 'Сдача не найдена или отменена';end if;
  if jsonb_typeof(payload->'correct') is distinct from 'boolean' then raise exception 'Укажите вердикт';end if;
  perform public.ps_decide(sub.id,(payload->>'correct')::boolean,'manual');
 elsif op='tasks' then
  if g.status<>'READY' then raise exception 'Условия и ключи фиксируются после старта';end if;
  task_list:=payload->'tasks';
  if coalesce(jsonb_typeof(task_list),'')<>'array' or jsonb_array_length(task_list)<>g.rounds*6+20 then raise exception 'Заполните все задачи и аптечки';end if;
  if (select count(distinct x->>'code') from jsonb_array_elements(task_list) x)<>jsonb_array_length(task_list) then raise exception 'Повторяются задачи';end if;
  for j in select * from jsonb_array_elements(task_list) loop
   select * into task from public.ps_tasks where game_id=g.id and code=j->>'code' and (task_type='med' or round_no<=g.rounds);
   if not found or length(coalesce(j->>'statement',''))>20000 or coalesce(j->>'mode','') not in ('number','text','set','manual') or length(coalesce(j->>'key',''))>2000 then raise exception 'Неверные данные задачи';end if;
   if j->>'mode'<>'manual' then
    if nullif(trim(j->>'key'),'') is null then raise exception 'Укажите ключ для автопроверки';end if;
    for val in select unnest(string_to_array(j->>'key','|')) loop
     if nullif(trim(val),'') is null or public.ps_normal(val,j->>'mode') is null then raise exception 'Некорректный ключ';end if;
    end loop;
   end if;
   update public.ps_tasks set statement=coalesce(j->>'statement',''),mode=j->>'mode',key=coalesce(j->>'key','') where game_id=g.id and code=task.code;
  end loop;
 elsif op='cancelSubmission' then
  select * into sub from public.ps_submissions where id=(payload->>'submission')::uuid and game_id=g.id for update;
  if not found then raise exception 'Сдача не найдена';end if;
  if sub.status='CANCELLED' then return public.ps_api('state',g.id,token);end if;
  if sub.status='JUDGED' then raise exception 'Отмените проверенный ответ в журнале';end if;
  reason:=trim(coalesce(payload->>'reason',''));if length(reason) not between 1 and 500 then raise exception 'Укажите причину';end if;
  update public.ps_submissions set status='CANCELLED',note=reason where id=sub.id;
 elsif op='configure' then
  if g.status<>'READY' then raise exception 'Команды и интервал меняются только до старта';end if;
  names:=payload->'names';rounds_new:=(payload->>'rounds')::int;interval_new:=(payload->>'interval')::int;
  if rounds_new is null or rounds_new not between 1 and 120 or interval_new is null or interval_new not between 1 and 120 then raise exception 'Обойм: 1–120, интервал: 1–120 минут';end if;
  if coalesce(jsonb_typeof(names),'null')<>'array' or jsonb_array_length(names) not between 2 and 16 then raise exception 'Нужно 2–16 команд';end if;
  if exists(select 1 from jsonb_array_elements_text(names) x where x is null or length(trim(x)) not between 1 and 45) or (select count(distinct trim(x)) from jsonb_array_elements_text(names) x)<>jsonb_array_length(names) then raise exception 'Нужны разные названия до 45 символов';end if;
  delete from public.ps_teams where game_id=g.id and position>jsonb_array_length(names);
  for i in 1..jsonb_array_length(names) loop
   insert into public.ps_teams(game_id,position,name,token) values(g.id,i,trim(names->>(i-1)),gen_random_uuid()::text||gen_random_uuid()::text) on conflict(game_id,position) do update set name=excluded.name;
  end loop;
  update public.ps_games set rounds=rounds_new,interval_min=interval_new where id=g.id;perform public.ps_seed(g.id,rounds_new);
 elsif op='start' then
  if g.status<>'READY' then raise exception 'Игра уже запускалась';end if;
  update public.ps_games set status='RUNNING',start_ms=now_ms,manual_rounds=1 where id=g.id;
 elsif op='pause' then
  if clock->>'status'<>'RUNNING' then raise exception 'Игра не идёт';end if;
  update public.ps_games set status='PAUSED',paused_at_ms=now_ms where id=g.id;
 elsif op='resume' then
  if g.status<>'PAUSED' then raise exception 'Игра не на паузе';end if;
  update public.ps_games set status='RUNNING',pause_total_ms=pause_total_ms+now_ms-paused_at_ms,paused_at_ms=null where id=g.id;
 elsif op='finish' then
  if clock->>'status' not in ('RUNNING','PAUSED') then raise exception 'Игра уже завершена или не начиналась';end if;
  update public.ps_games set status='FINISHED',finished_elapsed_ms=(clock->>'elapsed')::bigint where id=g.id;
 elsif op='rounds' then
  rounds_new:=(payload->>'rounds')::int;
  if clock->>'status' not in ('READY','RUNNING','PAUSED') or rounds_new is null or rounds_new not between greatest(1,issued) and 120 then raise exception 'Нельзя установить лимит меньше уже выданных обойм';end if;
  update public.ps_games set rounds=rounds_new where id=g.id;perform public.ps_seed(g.id,rounds_new);
 elsif op='issue' then
  if clock->>'status' not in ('RUNNING','PAUSED') or issued>=g.rounds then raise exception 'Следующая обойма недоступна';end if;
  update public.ps_games set manual_rounds=issued+1 where id=g.id;
 elsif op in ('answer','hp') then
  req:=(payload->>'id')::uuid;if req is null then raise exception 'Нужен ID запроса';end if;
  select * into ev from public.ps_events where request_id=req;
  if found then if ev.game_id<>g.id then raise exception 'ID уже занят';end if;return public.ps_api('state',g.id,token);end if;
  actor_id:=(payload->>'team')::uuid;
  if not exists(select 1 from public.ps_teams where id=actor_id and game_id=g.id) then raise exception 'Команда не найдена';end if;
  if op='answer' then
   if clock->>'status'<>'RUNNING' then raise exception 'Приём ответов закрыт или приостановлен';end if;
   select * into task from public.ps_tasks where game_id=g.id and code=payload->>'task';
   if not found or (task.task_type='shot' and task.round_no>issued) then raise exception 'Задача ещё не выдана';end if;
   if task.kind not in('standard','cutting')then raise exception 'Неизвестный интерактивный модуль';end if;
   if exists(select 1 from public.ps_events where game_id=g.id and kind='answer' and not cancelled and data->>'team'=actor_id::text and data->>'task'=task.code) or exists(select 1 from public.ps_submissions where game_id=g.id and team_id=actor_id and task_code=task.code and status<>'CANCELLED') then raise exception 'Команда уже сдавала эту задачу';end if;
   if jsonb_typeof(payload->'correct') is distinct from 'boolean' then raise exception 'Укажите вердикт';end if;correct:=(payload->>'correct')::boolean;
   target_id:=null;if task.task_type='shot' then target_id:=(payload->>'target')::uuid;if target_id is null or target_id=actor_id or not exists(select 1 from public.ps_teams where id=target_id and game_id=g.id) then raise exception 'Выберите соперника';end if;end if;
   insert into public.ps_events(request_id,game_id,time_ms,kind,data) values(req,g.id,now_ms,'answer',jsonb_build_object('team',actor_id,'task',task.code,'target',target_id,'correct',correct,'roll',case when correct and task.task_type='shot' then random() else null end));
  else
   if g.start_ms is null then raise exception 'Игра ещё не началась';end if;
   reason:=trim(coalesce(payload->>'reason',''));val:=payload->>'delta';
   if length(reason) not between 1 and 500 or coalesce(val,'')!~'^-?[0-9]+(\.[0-9]+)?$' or length(val)>30 then raise exception 'Укажите изменение HP и причину';end if;delta:=val::numeric;
   if abs(delta)>1000000 then raise exception 'Слишком большая коррекция';end if;
   insert into public.ps_events(request_id,game_id,time_ms,kind,data) values(req,g.id,now_ms,'hp',jsonb_build_object('team',actor_id,'delta',delta,'reason',reason));
  end if;
 elsif op in ('cancel','undo') then
  req:=(payload->>'id')::uuid;if req is null then raise exception 'Нужен ID запроса';end if;
  if exists(select 1 from public.ps_events where request_id=req and game_id=g.id) then return public.ps_api('state',g.id,token);end if;
  reason:=trim(coalesce(payload->>'reason','Отмена ведущим'));if length(reason) not between 1 and 500 then raise exception 'Укажите причину';end if;
  if op='undo' then select * into ev from public.ps_events where game_id=g.id and kind in ('answer','hp') and not cancelled order by id desc limit 1 for update;
  else select * into ev from public.ps_events where id=(payload->>'event')::bigint and game_id=g.id and kind in ('answer','hp') for update;end if;
  if not found or ev.cancelled then raise exception 'Нет действия для отмены';end if;
  update public.ps_events set cancelled=true,cancel_reason=reason where id=ev.id;
  update public.ps_submissions set status='CANCELLED',note=reason where event_id=ev.id;
  insert into public.ps_events(request_id,game_id,time_ms,kind,data) values(req,g.id,now_ms,'cancel',jsonb_build_object('event',ev.id,'reason',reason));
 elsif op='new' then
  if clock->>'status' in ('RUNNING','PAUSED') then raise exception 'Сначала завершите текущую игру';end if;
  secret:=gen_random_uuid()::text||gen_random_uuid()::text;
  insert into public.ps_games(host_hash,title,rounds,interval_min,online) values(sha256(convert_to(secret,'UTF8')),g.title,g.rounds,g.interval_min,g.online) returning id into gid;
  insert into public.ps_teams(game_id,position,name,token) select gid,position,name,gen_random_uuid()::text||gen_random_uuid()::text from public.ps_teams where game_id=g.id;
  insert into public.ps_tasks(game_id,code,task_type,round_no,n,power,statement,mode,key,bank_task_id,bank_version,kind,module_id,module_version,module_config,attachments) select gid,code,task_type,round_no,n,power,statement,mode,key,bank_task_id,bank_version,kind,module_id,module_version,module_config,attachments from public.ps_tasks where game_id=g.id;
  return jsonb_build_object('id',gid,'hostToken',secret);
 elsif op='export' then
  return jsonb_build_object('game',to_jsonb(g)-'host_hash','teams',(select jsonb_agg(to_jsonb(t)-'token') from public.ps_teams t where game_id=g.id),'tasks',(select jsonb_agg(to_jsonb(t)) from public.ps_tasks t where game_id=g.id),'ledger',(select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]') from public.ps_events e where game_id=g.id),'submissions',(select coalesce(jsonb_agg(to_jsonb(q) order by time_ms,id),'[]') from public.ps_submissions q where game_id=g.id),'result',public.ps_replay(g.id));
 end if;
 if op in ('configure','start','pause','resume','finish','rounds','issue') then insert into public.ps_events(request_id,game_id,time_ms,kind,data) values(gen_random_uuid(),g.id,now_ms,op,case when op='configure' then payload else payload-'id' end);end if;
 select * into g from public.ps_games where id=g.id;clock:=public.ps_clock(g,now_ms);
 result:=public.ps_replay(g.id)||jsonb_build_object('id',g.id,'title',g.title,'now',now_ms,'clock',clock,'rounds',g.rounds,'interval',g.interval_min,'online',g.online,'pendingCount',(select count(*) from public.ps_submissions where game_id=g.id and status='PENDING'),
 'tasks',(select coalesce(jsonb_agg(to_jsonb(t)-'game_id'-'key'-'mode' order by task_type,round_no,n),'[]') from public.ps_tasks t where game_id=g.id and g.start_ms is not null and (task_type='med' or round_no<=(clock->>'issued')::int)));
 if host or tm.id is not null then result:=result||jsonb_build_object('submissions',(select coalesce(jsonb_agg(to_jsonb(q)-'game_id' order by time_ms,id),'[]') from public.ps_submissions q where game_id=g.id and (host or team_id=tm.id)));end if;
 if host then result:=result||jsonb_build_object('host',true,'draftTasks',(select jsonb_agg(to_jsonb(t)-'game_id' order by task_type,round_no,n) from public.ps_tasks t where game_id=g.id and (task_type='med' or round_no<=g.rounds)),'names',(select jsonb_agg(name order by position) from public.ps_teams where game_id=g.id),'links',(select jsonb_agg(jsonb_build_object('name',name,'token',t.token,'id',t.id) order by position) from public.ps_teams t where game_id=g.id));
 elsif tm.id is not null then result:=result||jsonb_build_object('me',jsonb_build_object('id',tm.id,'name',tm.name));end if;
 return result;
end $$;
create or replace function public.mg_remove(k text,g uuid,details_only boolean default false)returns void language plpgsql set search_path=''as $$begin
update public.mg_files set expires_at=now()where game_kind=k and game_id=g;
case k when 'od'then delete from public.od_packets where game_id=g;if details_only then update public.od_games set tasks='[]',closed=true where id=g;else delete from public.od_teams where game_id=g;delete from public.od_games where id=g;end if;
when 'ab'then delete from public.ab_photos where submission_id in(select id from public.ab_submissions where game_id=g);delete from public.ab_submissions where game_id=g;delete from public.ab_events where game_id=g;delete from public.ab_tasks where game_id=g;if details_only then update public.ab_games set frozen_tasks='[]',closed=true where id=g;else delete from public.ab_teams where game_id=g;delete from public.ab_games where id=g;end if;
when 'ps'then delete from public.ps_submissions where game_id=g;delete from public.ps_events where game_id=g;delete from public.ps_tasks where game_id=g;if details_only then update public.ps_games set status='FINISHED'where id=g;else delete from public.ps_teams where game_id=g;delete from public.ps_games where id=g;end if;
else if not details_only then delete from public.mg_workbenches where id=g;end if;end case;
delete from public.mg_task_copies where game_kind=k and game_id=g;if not details_only then delete from public.mg_lifecycle where game_kind=k and game_id=g;end if;end $$;
commit;

create or replace function public.mg_bank(op text,payload jsonb default '{}')returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare u uuid:=auth.uid();b public.mg_bank_tasks;c jsonb;fp text;bid uuid;v int;begin
if u is null then raise exception 'Войдите в личный банк задач';end if;
if op='search'then return coalesce((select jsonb_agg(to_jsonb(z))from(select b.id,b.version,b.updated_at,v.content from public.mg_bank_tasks b join public.mg_bank_versions v on v.task_id=b.id and v.version=b.version where b.owner_id=u and(position(lower(left(coalesce(payload->>'query',''),200))in lower(v.content->>'condition'))>0 or position(lower(left(coalesce(payload->>'query',''),200))in lower(v.content->>'title'))>0)order by b.updated_at desc limit 100)z),'[]');end if;
bid:=(payload->>'id')::uuid;
if bid is not null then select * into b from public.mg_bank_tasks where id=bid and owner_id=u for update;if not found then raise exception 'Задача недоступна';end if;end if;
if op='delete'then if bid is null then raise exception 'Выберите задачу';end if;delete from public.mg_bank_tasks where id=bid;return '{}'::jsonb;end if;
if op<>'save'then raise exception 'Неизвестное действие';end if;c:=public.mg_validate(payload->'content');fp:=public.mg_fingerprint(c);
if bid is null then
insert into public.mg_bank_tasks(owner_id,fingerprint)values(u,fp)on conflict(owner_id,fingerprint)do nothing returning * into b;
if not found then select * into b from public.mg_bank_tasks where owner_id=u and fingerprint=fp;return jsonb_build_object('id',b.id,'version',b.version,'duplicate',true,'content',(select content from public.mg_bank_versions where task_id=b.id and version=b.version));end if;
else
if exists(select 1 from public.mg_bank_tasks where owner_id=u and fingerprint=fp and id<>bid)then raise exception 'В банке уже есть такая задача';end if;
if c=(select content from public.mg_bank_versions where task_id=b.id and version=b.version)then return jsonb_build_object('id',b.id,'version',b.version,'content',c);end if;
update public.mg_bank_tasks set fingerprint=fp,version=version+1,updated_at=now()where id=bid returning * into b;end if;
insert into public.mg_bank_versions(task_id,version,content)values(b.id,b.version,c);return jsonb_build_object('id',b.id,'version',b.version,'content',c,'duplicate',false);end $$;
