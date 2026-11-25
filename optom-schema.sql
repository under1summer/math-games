-- Оптом дороже. Version 1. Run once in Supabase SQL Editor.
begin;
create table public.od_games (
 id uuid primary key default gen_random_uuid(), host_hash bytea not null,
 created_at timestamptz not null default now(), title text not null,
 started_at timestamptz, ends_at timestamptz, closed boolean not null default false,
 tasks jsonb not null default '[]'
);
create table public.od_teams (
 id uuid primary key default gen_random_uuid(), game_id uuid not null references public.od_games(id),
 name text not null check(length(name) between 1 and 50), token text not null unique,
 unique(game_id,name)
);
create table public.od_packets (
 id uuid primary key, game_id uuid not null references public.od_games(id),
 team_id uuid not null references public.od_teams(id), created_at timestamptz not null default now(),
 answers jsonb not null, image text not null default '' check(length(image)<=2800000)
);
create index on public.od_packets(game_id,team_id);
alter table public.od_games enable row level security;
alter table public.od_teams enable row level security;
alter table public.od_packets enable row level security;
revoke all on public.od_games,public.od_teams,public.od_packets from anon,authenticated;

create function public.od_normal(s text, mode text) returns text language plpgsql immutable set search_path='' as $$
declare x text; a text[]; item text; r text[] := '{}';
begin
 x:=lower(replace(replace(replace(trim(s),'ё','е'),'−','-'),'–','-'));
 x:=regexp_replace(x,'^(ответы?|числа|число)\s*:?\s*','','i');
 x:=regexp_replace(x,'[()\[\]{}]','','g');
 if mode='text' then return regexp_replace(x,'[\s,;:.→>\-]+','','g'); end if;
 x:=regexp_replace(x,'(минут[а-я]*|мин\.?|секунд[а-я]*|сек\.?|часа?|часов|человек[а-я]*|девоч[а-я]*|ученик[а-я]*|школьник[а-я]*|животн[а-я]*|треугольник[а-я]*|плит[а-я]*|гном[а-я]*)','','g');
 x:=regexp_replace(x,'[xхnаa]\s*=\s*','','g'); x:=trim(x);
 if mode='number' then
  if x ~ '^[+-]?[0-9]{1,3}([   ][0-9]{3})+([.,][0-9]+)?$' then x:=regexp_replace(x,'[   ]','','g'); end if;
  x:=replace(x,',','.');
  if x !~ '^[+-]?[0-9]+(\.[0-9]+)?$' or length(x)>100 then return null; end if;
  return trim_scale(x::numeric)::text;
 end if;
 x:=regexp_replace(x,'либо|или|и',';','g'); x:=regexp_replace(trim(x),'[.;]+$','');
 if x !~ '^[+-]?[0-9]+([\s,;|*×хx·]+[+-]?[0-9]+)*$' or length(x)>1000 then return null; end if;
 a:=regexp_split_to_array(x,'[\s,;|*×хx·]+');
 foreach item in array a loop
  if length(item)>100 then return null; end if;
  r:=array_append(r,trim_scale(item::numeric)::text);
 end loop;
 return (select string_agg(v,';' order by v) from unnest(r) v);
end $$;

create function public.od_score(a jsonb) returns integer language sql immutable set search_path='' as $$
 select case when count(*)=0 then 0 when bool_or(e->>'status'='pending') then null else
 ('[[0],[0,2],[0,1,6],[-1,0,2,12],[-2,0,1,6,20],[-5,0,0,2,12,34],[-10,0,0,1,6,20,52],[-10,0,0,0,2,12,34,76],[-10,0,0,0,1,6,20,52,106]]'::jsonb -> count(*)::int -> (count(*) filter(where e->>'status'='yes'))::int)::text::int end
 from jsonb_array_elements(a) e where coalesce(e->>'cancelled','false')<>'true'
$$;

create function public.od_api(op text, game uuid default null, token text default '', payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.od_games; t public.od_teams; p public.od_packets; host boolean:=false;
 secret text; names jsonb; task_list jsonb; a jsonb; entry jsonb; task jsonb; outa jsonb:='[]';
 n int; st text; val text; img text; pid uuid; k text; idx int; result jsonb; ts jsonb; ps jsonb;
begin
 if op='create' then
  secret:=gen_random_uuid()::text||gen_random_uuid()::text;
  insert into public.od_games(host_hash,title) values(sha256(convert_to(secret,'UTF8')),left(coalesce(nullif(trim(payload->>'title'),''),'Оптом дороже'),100)) returning * into g;
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
 if op='configure' then
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
  if not host then raise exception 'Нет доступа ведущего'; end if;
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
   if n is null or n not between 1 and 24 or length(val)>3000 or (val='' and img='') then raise exception 'Неверный номер или пустой ответ'; end if;
   if exists(select 1 from public.od_packets q cross join lateral jsonb_array_elements(q.answers) e where q.team_id=t.id and (e->>'n')::int=n and coalesce(e->>'cancelled','false')<>'true') then raise exception 'Задача №% уже сдана',n; end if;
   task:=g.tasks->(n-1); st:='pending';
   if task->>'mode'<>'manual' then
    k:=public.od_normal(val,task->>'mode');
    if k is not null and k<>'' then
     if exists(select 1 from unnest(string_to_array(task->>'key','|')) v where public.od_normal(v,task->>'mode')=k) then st:='yes';
     elsif task->>'mode'<>'text' then st:='no'; end if;
    end if;
   end if;
   outa:=outa||jsonb_build_array(jsonb_build_object('n',n,'text',val,'status',st,'cancelled',false));
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
 result:=jsonb_build_object('game',g.id,'title',g.title,'start',g.started_at,'end',g.ends_at,'closed',g.closed,'now',clock_timestamp(),'teams',ts);
 if host or t.id is not null then
  select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'team',q.team_id,'time',q.created_at,'answers',q.answers,'photo',q.image<>'','score',public.od_score(q.answers)) order by q.created_at),'[]') into ps from public.od_packets q where q.game_id=g.id and (host or q.team_id=t.id);
  result:=result||jsonb_build_object('packets',ps,'tasks',(select jsonb_agg(case when host then x else x-'key'-'mode' end order by (x->>'n')::int) from jsonb_array_elements(g.tasks) x));
 end if;
 if host then
  result:=result||jsonb_build_object('host',true,'links',(select coalesce(jsonb_agg(jsonb_build_object('name',name,'token',tm.token) order by name),'[]') from public.od_teams tm where game_id=g.id));
 elsif t.id is not null then result:=result||jsonb_build_object('me',jsonb_build_object('id',t.id,'name',t.name)); end if;
 return result;
end $$;
revoke all on function public.od_api(text,uuid,text,jsonb) from public;
revoke all on function public.od_normal(text,text),public.od_score(jsonb) from public;
grant execute on function public.od_api(text,uuid,text,jsonb) to anon,authenticated;
commit;
