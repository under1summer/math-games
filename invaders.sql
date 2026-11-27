-- Захватчики. Requires the existing new-games engine; only new tables and narrow rule hooks.
begin;
alter table public.ng_games drop constraint ng_games_kind_check;
alter table public.ng_games add constraint ng_games_kind_check check(kind in('p52','xo','maze','bonus','domino','iv'));
alter table public.ng_game_templates drop constraint ng_game_templates_game_kind_check;
alter table public.ng_game_templates add constraint ng_game_templates_game_kind_check check(game_kind in('p52','xo','maze','bonus','domino','iv'));
create table public.iv_cells(game_id uuid references public.ng_games(id)on delete cascade,x int,y int,price int not null check(price between 1 and 15),owner_id uuid references public.ng_teams(id),start_team uuid references public.ng_teams(id),bid int not null default 0 check(bid>=0),version int not null default 0,primary key(game_id,x,y));
create unique index iv_one_start on public.iv_cells(game_id,start_team)where start_team is not null;
create table public.iv_captures(id uuid primary key,game_id uuid references public.ng_games(id)on delete cascade,team_id uuid references public.ng_teams(id),x int,y int,bid int,previous_owner uuid,task_ids jsonb not null,created_at timestamptz not null default clock_timestamp());
create index on public.iv_captures(game_id,created_at);
create table public.iv_spends(answer_id uuid primary key references public.ng_submissions(id)on delete cascade,capture_id uuid not null references public.iv_captures(id)on delete cascade);
alter table public.iv_cells enable row level security;alter table public.iv_captures enable row level security;alter table public.iv_spends enable row level security;
revoke all on public.iv_cells,public.iv_captures,public.iv_spends from public,anon,authenticated;
-- Opaque revision signals contain no game IDs, team identities, answers or capabilities.
create table public.iv_signals(channel text primary key,revision bigint not null default 0);
alter table public.iv_signals enable row level security;
revoke all on public.iv_signals from public,anon,authenticated;
grant select on public.iv_signals to anon,authenticated;
create policy iv_signal_read on public.iv_signals for select to anon,authenticated using(true);
alter publication supabase_realtime add table public.iv_signals;
create function public.iv_channel(g uuid)returns text language sql immutable set search_path=''as $$select encode(sha256(convert_to(g::text,'UTF8')),'hex')$$;
create function public.iv_notify()returns trigger language plpgsql security definer set search_path=''as $$begin
if exists(select 1 from public.ng_games where id=new.game_id and kind='iv')then update public.iv_signals set revision=revision+1 where channel=public.iv_channel(new.game_id);end if;return new;end $$;
create trigger iv_event_signal after insert on public.ng_events for each row execute function public.iv_notify();
create function public.iv_review_guard()returns trigger language plpgsql set search_path=''as $$begin
if new.status<>'yes'and exists(select 1 from public.iv_spends where answer_id=old.id)then raise exception 'Задача уже потрачена на захват. Изменение оценки запрещено';end if;return new;end $$;
create trigger iv_used_answer before update of status on public.ng_submissions for each row execute function public.iv_review_guard();
create function public.iv_save_layout(g uuid)returns void language sql set search_path=''as $$update public.ng_games set settings=settings||jsonb_build_object('board',(select jsonb_agg(jsonb_build_object('x',c.x,'y',c.y,'price',c.price,'start',t.position)order by c.y,c.x)from public.iv_cells c left join public.ng_teams t on t.id=c.start_team where c.game_id=g))where id=g$$;
create function public.iv_create(p jsonb)returns jsonb language plpgsql set search_path=''as $$
#variable_conflict use_column
declare g uuid;secret text:=gen_random_uuid()::text||gen_random_uuid()::text;names jsonb:=coalesce(p->'names','["Команда 1","Команда 2","Команда 3","Команда 4","Команда 5","Команда 6"]');counts jsonb:=coalesce(p->'counts','[5,5,5,5,5]');w int:=coalesce((p->>'width')::int,12);h int:=coalesce((p->>'height')::int,8);minutes int:=coalesce((p->>'minutes')::int,90);prices int[]:=array[3,5,8,11,15];i int;j int;n int:=0;a int;b int;tm public.ng_teams;cell jsonb;px int;py int;v int;board jsonb:=p->'board';begin
if w not between 3 and 30 or h not between 3 and 30 or minutes not between 1 and 1440 then raise exception 'Поле: 3–30 клеток по каждой стороне; время: 1–1440 минут';end if;
if jsonb_typeof(names)is distinct from 'array'or jsonb_array_length(names)not between 2 and 12 or jsonb_array_length(names)>w*h or exists(select 1 from jsonb_array_elements_text(names)x where x is null or length(trim(x))not between 1 and 60)or(select count(distinct trim(x))from jsonb_array_elements_text(names)x)<>jsonb_array_length(names)then raise exception 'Нужно 2–12 разных названий команд до 60 символов';end if;
if jsonb_typeof(counts)is distinct from 'array'or jsonb_array_length(counts)<>5 then raise exception 'Укажите количество задач каждой из пяти стоимостей';end if;for i in 0..4 loop if(counts->>i)::int not between 1 and 50 then raise exception 'По 1–50 задач каждой стоимости';end if;end loop;
insert into public.ng_games(kind,host_hash,title,minutes,online,settings)values('iv',sha256(convert_to(secret,'UTF8')),left(coalesce(nullif(trim(p->>'title'),''),'Захватчики'),100),minutes,coalesce((p->>'online')::boolean,true),jsonb_build_object('width',w,'height',h,'counts',counts))returning id into g;
for i in 1..jsonb_array_length(names)loop insert into public.ng_teams(game_id,position,name,token)values(g,i,trim(names->>(i-1)),gen_random_uuid()::text||gen_random_uuid()::text);end loop;
for i in 1..5 loop for j in 1..(counts->>(i-1))::int loop n:=n+1;insert into public.ng_slots values(g,n::text,n,jsonb_build_object('price',prices[i]));insert into public.mg_task_copies(game_kind,game_id,code,content)values('iv',g,n::text,public.mg_validate('{"condition":"","mode":"manual","key":"","kind":"standard"}'));end loop;end loop;
if board is not null then
if jsonb_typeof(board)is distinct from 'array'or jsonb_array_length(board)<>w*h then raise exception 'Неверный размер сохранённого поля';end if;
for cell in select *from jsonb_array_elements(board)loop px:=(cell->>'x')::int;py:=(cell->>'y')::int;v:=(cell->>'price')::int;if px is null or py is null or v is null or px not between 0 and w-1 or py not between 0 and h-1 then raise exception 'Неверная клетка';end if;tm.id:=null;if cell->>'start'is not null then select *into tm from public.ng_teams where game_id=g and position=(cell->>'start')::int;if not found then raise exception 'Неверный старт команды';end if;end if;insert into public.iv_cells(game_id,x,y,price,owner_id,start_team)values(g,px,py,v,tm.id,tm.id);end loop;
if exists(select 1 from public.ng_teams t where game_id=g and not exists(select 1 from public.iv_cells c where c.game_id=g and c.start_team=t.id))then raise exception 'Каждой команде нужен один старт';end if;
else
for b in 0..h-1 loop for a in 0..w-1 loop v:=prices[1+least(4,(5*least(a,b,w-1-a,h-1-b)/greatest(1,least(w,h)/2)))];insert into public.iv_cells(game_id,x,y,price)values(g,a,b,v);end loop;end loop;
for tm in select *from public.ng_teams where game_id=g order by position loop select c.x,c.y into px,py from public.iv_cells c where c.game_id=g and c.start_team is null order by case when c.x in(0,w-1)or c.y in(0,h-1)then 0 else 1 end,coalesce((select min(abs(c.x-s.x)+abs(c.y-s.y))from public.iv_cells s where s.game_id=g and s.start_team is not null),999)desc,c.y,c.x limit 1;update public.iv_cells set start_team=tm.id,owner_id=tm.id where game_id=g and x=px and y=py;end loop;end if;
perform public.iv_save_layout(g);insert into public.iv_signals values(public.iv_channel(g),0);return jsonb_build_object('id',g,'hostToken',secret,'kind','iv');end $$;
create function public.iv_state(g uuid,t text default '')returns jsonb language plpgsql stable set search_path=''as $$
#variable_conflict use_column
declare s jsonb;host boolean;me uuid;teams jsonb;stocks jsonb;used jsonb;cells jsonb;begin
if not exists(select 1 from public.ng_games where id=g and kind='iv')then raise exception 'Игра не найдена';end if;s:=public.ng_state(g,t);if coalesce((s->>'archived')::boolean,false)then return s;end if;host:=(s->>'host')::boolean;me:=(s->'me'->>'id')::uuid;
select jsonb_agg(team||jsonb_build_object('territories',(select count(*)from public.iv_cells where game_id=g and owner_id=(team->>'id')::uuid),'reserve',(select count(*)from public.ng_submissions q where q.game_id=g and q.team_id=(team->>'id')::uuid and q.status='yes'and not exists(select 1 from public.iv_spends z where z.answer_id=q.id)))order by(team->>'position')::int)into teams from jsonb_array_elements(s->'teams')team;
select coalesce(jsonb_object_agg(id,stock),'{}')into stocks from(select tm.id,(select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'code',q.code,'price',(sl.meta->>'price')::int)order by(sl.meta->>'price')::int,sl.position),'[]')from public.ng_submissions q join public.ng_slots sl on sl.game_id=g and sl.code=q.code where q.game_id=g and q.team_id=tm.id and q.status='yes'and not exists(select 1 from public.iv_spends z where z.answer_id=q.id))stock from public.ng_teams tm where game_id=g and(host or id=me))v;
select coalesce(jsonb_agg(z.answer_id),'[]')into used from public.iv_spends z join public.iv_captures c on c.id=z.capture_id where c.game_id=g and(host or c.team_id=me);
select jsonb_agg(to_jsonb(c)-'game_id'order by c.y,c.x)into cells from public.iv_cells c where game_id=g;
return s||jsonb_build_object('teams',teams,'map',cells,'stocks',stocks,'used_tasks',used,'signal',public.iv_channel(g));end $$;
create function public.iv_api(op text,game uuid default null,token text default '',payload jsonb default '{}')returns jsonb language plpgsql security definer set search_path=''as $$
#variable_conflict use_column
declare gg public.ng_games;tm public.ng_teams;host boolean;cell public.iv_cells;existing public.iv_captures;pid uuid;ids jsonb;required int;valid int;total int;xx int;yy int;v int;begin
if op='create'then return public.iv_create(payload);end if;
if op='state'then return public.iv_state(game,token);end if;
select *into strict gg from public.ng_games where id=game and kind='iv'for update;host:=public.ng_host('iv',game,token);select *into tm from public.ng_teams where game_id=game and ng_teams.token=iv_api.token;
if not host and tm.id is null then raise exception 'Нет доступа';end if;
if exists(select 1 from public.ng_lifecycle where game_id=game and archived)then raise exception 'Подробные данные уже очищены';end if;
if op in('paint','place_start')then
if not host or gg.started_at is not null then raise exception 'Поле меняет ведущий до старта';end if;xx:=(payload->>'x')::int;yy:=(payload->>'y')::int;select *into cell from public.iv_cells where game_id=game and x=xx and y=yy;if not found then raise exception 'Нет клетки';end if;
if op='paint'then v:=(payload->>'price')::int;if v is null or v not between 1 and 15 then raise exception 'Стоимость клетки: 1–15';end if;update public.iv_cells set price=v,version=version+1 where game_id=game and x=xx and y=yy;
else select *into tm from public.ng_teams where game_id=game and id=(payload->>'team')::uuid;if not found then raise exception 'Нет команды';end if;if cell.start_team is not null and cell.start_team<>tm.id then raise exception 'Здесь уже старт другой команды';end if;update public.iv_cells set start_team=null,owner_id=null,version=version+1 where game_id=game and start_team=tm.id;update public.iv_cells set start_team=tm.id,owner_id=tm.id,version=version+1 where game_id=game and x=xx and y=yy;end if;
perform public.iv_save_layout(game);
elsif op='capture'then
if host then select *into tm from public.ng_teams where game_id=game and id=(payload->>'team')::uuid;if not found then raise exception 'Выберите команду';end if;end if;
pid:=(payload->>'id')::uuid;ids:=payload->'tasks';xx:=(payload->>'x')::int;yy:=(payload->>'y')::int;
if pid is null then raise exception 'Нужен идентификатор захвата';end if;select *into existing from public.iv_captures where id=pid;
if found then if existing.game_id<>game or existing.team_id<>tm.id or existing.x is distinct from xx or existing.y is distinct from yy or existing.task_ids is distinct from ids then raise exception 'Идентификатор уже использован';end if;return public.iv_state(game,token);end if;
if gg.started_at is null or gg.closed or gg.ends_at<=clock_timestamp()then raise exception 'Игра не идёт';end if;
select *into cell from public.iv_cells where game_id=game and x=xx and y=yy;if not found then raise exception 'Нет клетки';end if;
if cell.version is distinct from(payload->>'version')::int then raise exception 'Клетка уже изменилась. Обновите поле; задачи не списаны';end if;
if cell.start_team is not null then raise exception 'Стартовые клетки нельзя захватывать';end if;
if cell.owner_id=tm.id then raise exception 'Клетка уже ваша';end if;
if exists(select 1 from public.iv_cells s where s.game_id=game and s.start_team<>tm.id and abs(s.x-xx)+abs(s.y-yy)=1)then raise exception 'Клетка защищена чужим стартом';end if;
if not exists(select 1 from public.iv_cells n where n.game_id=game and n.owner_id=tm.id and abs(n.x-xx)+abs(n.y-yy)=1)then raise exception 'Нужен сосед по стороне вашей территории';end if;
required:=case when cell.owner_id is null then 1 else cell.bid+1 end;
if jsonb_typeof(ids)is distinct from 'array'or jsonb_array_length(ids)<>required then raise exception 'Нужно потратить % задач стоимостью не ниже % каждая',required,cell.price;end if;
select count(*),count(distinct value)into total,valid from jsonb_array_elements_text(ids);if valid<>total then raise exception 'Нельзя повторять задачи';end if;
select count(*)into valid from public.ng_submissions q join public.ng_slots sl on sl.game_id=game and sl.code=q.code where q.id in(select value::uuid from jsonb_array_elements_text(ids))and q.game_id=game and q.team_id=tm.id and q.status='yes'and(sl.meta->>'price')::int>=cell.price and not exists(select 1 from public.iv_spends z where z.answer_id=q.id);
if valid<>required then raise exception 'Выберите свои верные непотраченные задачи нужной стоимости';end if;
insert into public.iv_captures(id,game_id,team_id,x,y,bid,previous_owner,task_ids)values(pid,game,tm.id,xx,yy,required,cell.owner_id,ids);
insert into public.iv_spends select value::uuid,pid from jsonb_array_elements_text(ids);
update public.iv_cells set owner_id=tm.id,bid=required,version=version+1 where game_id=game and x=xx and y=yy;
else
if op not in('start','finish','submit','review','return')then raise exception 'Неизвестное действие';end if;
perform public.ng_api(op,game,token,payload);return public.iv_state(game,token);end if;
insert into public.ng_events(game_id,action,data)values(game,'iv_'||op,jsonb_build_object('team',tm.id,'x',xx,'y',yy,'id',pid));update public.ng_lifecycle set activity_at=now()where game_id=game;return public.iv_state(game,token);end $$;

create or replace function public.ng_board(g uuid,team uuid)returns jsonb language plpgsql stable set search_path=''as $$
#variable_conflict use_column
declare gg public.ng_games;slot public.ng_slots;first_yes bigint;yes_count int;no_count int;pending_count int;tries int;value int;total int:=0;sent int:=0;pending_all int:=0;available_count int:=0;done_count int:=0;done boolean;allowed boolean;st text;cells jsonb:='[]';remaining jsonb;left_count int;bon text;lim int;begin
select *into strict gg from public.ng_games where id=g;
for slot in select *from public.ng_slots where game_id=g order by position loop
select count(*),count(*)filter(where status='yes'),count(*)filter(where status='no'),count(*)filter(where status='pending'),min(seq)filter(where status='yes')into tries,yes_count,no_count,pending_count,first_yes from public.ng_submissions where game_id=g and team_id=team and code=slot.code and status<>'cancelled';
value:=0;lim:=case when gg.kind='domino'and slot.meta->>'left'='0'and slot.meta->>'right'='0'then 1 when gg.kind='domino'then 2 else 1 end;
if gg.kind='p52' then
if first_yes is not null then select count(*)into no_count from public.ng_submissions where game_id=g and team_id=team and code=slot.code and status='no'and seq<first_yes;value:=5-2*no_count;else value:=-2*no_count;end if;done:=first_yes is not null;
elsif gg.kind='xo'then done:=tries>0;if yes_count>0 then select 1+count(*)into value from public.ng_slots s where s.game_id=g and abs((s.meta->>'row')::int-(slot.meta->>'row')::int)+abs((s.meta->>'col')::int-(slot.meta->>'col')::int)=1 and exists(select 1 from public.ng_submissions q where q.game_id=g and q.team_id=team and q.code=s.code and q.status='yes');end if;
elsif gg.kind='iv'then done:=tries>0;if yes_count>0 then value:=(slot.meta->>'price')::int;end if;
elsif gg.kind='maze'then done:=tries>0;if yes_count>0 then value:=(slot.meta->>'price')::int;end if;
elsif gg.kind='bonus'then done:=tries>0;if yes_count>0 then select bonus into bon from public.ng_submissions where game_id=g and team_id=team and code=slot.code and status='yes'order by seq limit 1;value:=case left(bon,1)when '+'then(slot.meta->>'price')::int+substring(bon,2)::int else(slot.meta->>'price')::int*substring(bon,2)::int end;end if;
else done:=yes_count>0 or tries>=lim;select seq into first_yes from public.ng_submissions where game_id=g and team_id=team and code=slot.code and status='yes'order by seq limit 1;if first_yes is not null then select count(*)into no_count from public.ng_submissions where game_id=g and team_id=team and code=slot.code and status<>'cancelled'and seq<first_yes;value:=case when lim=1 then 10 when no_count=0 then(slot.meta->>'left')::int+(slot.meta->>'right')::int else greatest((slot.meta->>'left')::int,(slot.meta->>'right')::int)end;elsif tries>=lim and pending_count=0 then value:=-least((slot.meta->>'left')::int,(slot.meta->>'right')::int);end if;end if;
st:=case when pending_count>0 then 'pending'when yes_count>0 then 'yes'when no_count>0 then 'no'else 'empty'end;
allowed:=not done and pending_count=0 and case when gg.kind='domino'then exists(select 1 from public.ng_leases where game_id=g and team_id=team and code=slot.code)else exists(select 1 from public.ng_issued where game_id=g and team_id=team and code=slot.code)end;
if gg.kind='p52' then allowed:=allowed and yes_count=0;end if;
total:=total+value;sent:=sent+tries;pending_all:=pending_all+pending_count;if allowed then available_count:=available_count+1;end if;if done and pending_count=0 then done_count:=done_count+1;end if;
cells:=cells||jsonb_build_array(jsonb_build_object('code',slot.code,'status',st,'score',value,'attempts',tries,'wrong',no_count,'done',done,'available',allowed,'meta',slot.meta));
end loop;
remaining:='{}';for bon,lim in select *from(values('+1',6),('+2',4),('+3',2),('x2',6),('x3',4),('x4',2))v(b,n)loop select lim-count(*)into left_count from public.ng_submissions where game_id=g and team_id=team and bonus=bon and status<>'cancelled';remaining:=remaining||jsonb_build_object(bon,left_count);end loop;
if gg.kind='iv'then select coalesce(sum(price),0)into total from public.iv_cells where game_id=g and owner_id=team;end if;
return jsonb_build_object('total',total,'score',total,'sent',sent,'pending',pending_all,'available',available_count,'done',done_count,'cells',cells,'bonuses',remaining,'finished',done_count=jsonb_array_length(cells));end $$;
create or replace function public.ng_api(op text,game uuid default null,token text default '',payload jsonb default '{}')returns jsonb language plpgsql security definer set search_path=''as $$
#variable_conflict use_column
declare gg public.ng_games;tm public.ng_teams;host boolean;secret text;k text;minutes int;settings jsonb;names jsonb;n int;i int;slot public.ng_slots;cell jsonb;board jsonb;pid uuid;sub public.ng_submissions;st text;c jsonb;answer text;example text;files jsonb;sol jsonb;bon text;reason text;begin
if op='create'and payload->>'kind'='iv'then return public.iv_create(payload);end if;
if op='create'then
k:=payload->>'kind';if k not in('p52','xo','maze','bonus','domino')or k is null then raise exception 'Выберите игру';end if;
minutes:=case when k='bonus'then 120 else coalesce((payload->>'minutes')::int,90)end;if minutes not between 1 and 1440 then raise exception 'Время: 1–1440 минут';end if;
settings:=jsonb_build_object('count',coalesce((payload->>'count')::int,12),'max_pip',coalesce((payload->>'max_pip')::int,6));if(settings->>'count')::int not between 1 and 1000 or(settings->>'max_pip')::int not between 1 and 12 then raise exception 'Задач: 1–1000; максимум на домино: 1–12';end if;
names:=coalesce(payload->'names','["Команда 1","Команда 2","Команда 3"]');if jsonb_typeof(names)is distinct from 'array'or jsonb_array_length(names)not between 1 and 32 or exists(select 1 from jsonb_array_elements_text(names)x where x is null or length(trim(x))not between 1 and 60)or(select count(distinct trim(x))from jsonb_array_elements_text(names)x)<>jsonb_array_length(names)then raise exception 'Нужно 1–32 разных названия команд до 60 символов';end if;
secret:=gen_random_uuid()::text||gen_random_uuid()::text;insert into public.ng_games(kind,host_hash,title,minutes,settings,online)values(k,sha256(convert_to(secret,'UTF8')),left(coalesce(nullif(trim(payload->>'title'),''),case k when 'p52'then 'Плюс 5 — минус 2'when 'xo'then 'Математические крестики-нолики'when 'maze'then 'Лабиринт'when 'bonus'then 'Бонусы'else 'Математическое домино'end),100),minutes,settings,coalesce((payload->>'online')::boolean,true))returning *into gg;
for i in 1..jsonb_array_length(names)loop insert into public.ng_teams(game_id,position,name,token)values(gg.id,i,trim(names->>(i-1)),gen_random_uuid()::text||gen_random_uuid()::text);end loop;perform public.ng_setup(gg.id);return jsonb_build_object('id',gg.id,'hostToken',secret,'kind',k);
end if;
select *into gg from public.ng_games where id=game;if not found then raise exception 'Игра не найдена';end if;
if op='state'then return public.ng_state(game,token);end if;
select *into gg from public.ng_games where id=game for update;host:=public.ng_host(gg.kind,game,token);if not host then select *into tm from public.ng_teams where game_id=game and ng_teams.token=ng_api.token;if not found then raise exception 'Нет доступа';end if;end if;
if exists(select 1 from public.ng_lifecycle where game_kind=gg.kind and game_id=game and archived)then raise exception 'Подробные данные игры уже очищены';end if;
if op in('start','finish','review','return')and not host then raise exception 'Нужна ссылка ведущего';end if;
if op='start'then
if gg.started_at is not null then raise exception 'Игра уже запускалась';end if;if exists(select 1 from public.ng_slots s left join public.mg_task_copies c on c.game_kind=gg.kind and c.game_id=game and c.code=s.code where s.game_id=game and(nullif(trim(c.content->>'condition'),'')is null or(c.content->>'kind'<>'cutting'and c.content->>'mode'<>'manual'and nullif(trim(c.content->>'key'),'')is null)))then raise exception 'Заполните и сохраните все условия и ключи';end if;
update public.ng_games set started_at=clock_timestamp(),ends_at=clock_timestamp()+make_interval(mins=>gg.minutes)where id=game;
insert into public.ng_issued select game,t.id,s.code from public.ng_teams t cross join public.ng_slots s where t.game_id=game and s.game_id=game and(gg.kind in('p52','xo','iv')or gg.kind='maze'and s.position=1 or gg.kind='bonus'and s.position in(1,9,17))on conflict do nothing;
elsif op='finish'then if gg.started_at is null then raise exception 'Игра ещё не началась';end if;update public.ng_games set closed=true where id=game;
elsif op in('submit','choose')then
if gg.started_at is null or gg.closed or gg.ends_at<=clock_timestamp()then raise exception 'Приём ответов закрыт';end if;
if host then if gg.online then raise exception 'Используйте личную ссылку команды';end if;select *into tm from public.ng_teams where game_id=game and id=(payload->>'team')::uuid;if not found then raise exception 'Нет команды';end if;elsif not gg.online then raise exception 'Сдайте ответ на листочке ведущему';end if;
select *into slot from public.ng_slots where game_id=game and code=payload->>'code';if not found then raise exception 'Нет задачи';end if;board:=public.ng_board(game,tm.id);select x into cell from jsonb_array_elements(board->'cells')x where x->>'code'=slot.code;
if op='choose'then
if gg.kind<>'domino'then raise exception 'Выбор карточки доступен только в домино';end if;if(cell->>'done')::boolean or(board->>'pending')::int>0 then raise exception 'Карточка уже завершена или есть ответ на проверке';end if;if exists(select 1 from public.ng_leases where game_id=game and team_id=tm.id and code=slot.code)then return public.ng_state(game,token);end if;if exists(select 1 from public.ng_leases where game_id=game and(team_id=tm.id or code=slot.code))then raise exception 'Карточка занята или у команды уже есть карточка';end if;insert into public.ng_leases values(game,slot.code,tm.id);insert into public.ng_issued values(game,tm.id,slot.code)on conflict do nothing;
else
pid:=(payload->>'id')::uuid;if pid is null then raise exception 'Нужен ID отправки';end if;select *into sub from public.ng_submissions where id=pid;if found then if sub.game_id<>game or sub.team_id<>tm.id then raise exception 'Отправка недоступна';end if;return public.ng_state(game,token);end if;
if not(cell->>'available')::boolean then raise exception 'Задача недоступна для сдачи';end if;
answer:=coalesce(payload->>'answer','');example:=coalesce(payload->>'example','');files:=coalesce(payload->'files','[]');sol:=payload->'solution';if length(answer)>6000 or length(example)>6000 or(length(trim(answer))=0 and length(trim(example))=0 and jsonb_array_length(files)=0 and(sol is null or sol='null'))then raise exception 'Добавьте ответ, решение или файл';end if;
if gg.kind='p52'and not host and length(trim(example))=0 and jsonb_array_length(files)=0 and(sol is null or sol='null')then raise exception 'Добавьте пример реализации: текст, интерактивное решение или файл';end if;
select content into c from public.mg_task_copies where game_kind=gg.kind and game_id=game and code=slot.code;perform public.mg_bind_files(gg.kind,game,tm.id,slot.code,pid,files,case when host and not gg.online then 'optional'else c->>'attachments'end);
if c->>'kind'='cutting'and sol is not null and sol<>'null'::jsonb then st:=public.mg_cut_check(c->'module_config',sol);elsif c->>'mode'='manual'or length(trim(answer))=0 then st:='pending';else st:=case when public.od_normal(answer,c->>'mode')is null then 'pending'when public.od_normal(answer,c->>'mode')=any(select public.od_normal(x,c->>'mode')from unnest(string_to_array(c->>'key','|'))x)then 'yes'else 'no'end;end if;
-- In +5/-2 an example must be judged as well: matching a number is never sufficient.
if gg.kind='p52'and st='yes'then st:='pending';end if;
if host and not gg.online then st:=coalesce(payload->>'verdict','pending');if st not in('yes','no','pending')then raise exception 'Неверный вердикт';end if;end if;
bon:=payload->>'bonus';if gg.kind='bonus'then if bon is null or coalesce((board->'bonuses'->>bon)::int,0)<=0 then raise exception 'Этот бонус закончился или не выбран';end if;else bon:=null;end if;
insert into public.ng_submissions(id,game_id,team_id,code,answer,example,solution,files,bonus,status)values(pid,game,tm.id,slot.code,answer,example,sol,files,bon,st);perform public.ng_issue(game,tm.id,slot.code,st);
end if;
elsif op in('review','return')then
select *into sub from public.ng_submissions where game_id=game and id=(payload->>'id')::uuid for update;if not found or sub.status='cancelled'then raise exception 'Сдача недоступна или уже отменена';end if;st:=case when op='return'then 'cancelled'else payload->>'status'end;if st is null or st not in('yes','no','pending','cancelled')then raise exception 'Неверная оценка';end if;reason:=left(coalesce(payload->>'note',''),1000);
if gg.kind='domino'and st in('pending','cancelled')then
if exists(select 1 from public.ng_leases where game_id=game and(code=sub.code and team_id<>sub.team_id or team_id=sub.team_id and code<>sub.code))then raise exception 'Карточка уже передана другой команде или команда взяла следующую. Завершите текущую карточку перед возвратом';end if;
if st='cancelled'and exists(select 1 from public.ng_submissions where game_id=game and team_id=sub.team_id and code=sub.code and status<>'cancelled'and seq>sub.seq)then raise exception 'Сначала верните последнюю попытку по этой карточке';end if;insert into public.ng_leases values(game,sub.code,sub.team_id)on conflict do nothing;end if;
update public.ng_submissions set status=st,note=reason where id=sub.id;if st<>'cancelled'then perform public.ng_issue(game,sub.team_id,sub.code,st);end if;
else raise exception 'Неизвестное действие';end if;
-- A jury return/correction may reopen an automatically finished game while time remains.
-- Explicit host finishes and expired timers always remain closed.
if op in('review','return')and gg.closed and gg.ends_at>clock_timestamp()and not exists(select 1 from public.ng_events where game_id=game and action='finish')and exists(select 1 from public.ng_teams t where t.game_id=game and not(public.ng_board(game,t.id)->>'finished')::boolean)then
update public.ng_games set closed=false where id=game;update public.ng_lifecycle set finished_at=null where game_id=game;end if;
if gg.kind not in('p52','iv')and gg.started_at is not null and not gg.closed and not exists(select 1 from public.ng_teams t where t.game_id=game and not(public.ng_board(game,t.id)->>'finished')::boolean)then update public.ng_games set closed=true where id=game;end if;
insert into public.ng_events(game_id,action,data)values(game,op,case when op in('submit','review','return')then jsonb_build_object('id',pid,'submission',sub.id,'status',st)else '{}'end);
update public.ng_lifecycle set activity_at=now()where game_kind=gg.kind and game_id=game;
return public.ng_state(game,token);end $$;
create or replace function public.ng_remove(g uuid,details_only boolean default false)returns void language plpgsql set search_path=''as $$declare k text;begin
select kind into strict k from public.ng_games where id=g;
if k='iv'then delete from public.iv_captures where game_id=g;delete from public.iv_cells where game_id=g;if not details_only then delete from public.iv_signals where channel=public.iv_channel(g);else update public.iv_signals set revision=revision+1 where channel=public.iv_channel(g);end if;end if;
update public.mg_files set expires_at=now()where game_kind=k and game_id=g;delete from public.ng_submissions where game_id=g;delete from public.ng_events where game_id=g;delete from public.ng_leases where game_id=g;delete from public.ng_issued where game_id=g;delete from public.ng_slots where game_id=g;delete from public.mg_task_copies where game_kind=k and game_id=g;
if details_only then update public.ng_games set closed=true where id=g;else delete from public.ng_games where id=g;end if;end $$;
revoke all on function public.iv_channel(uuid),public.iv_notify(),public.iv_review_guard(),public.iv_save_layout(uuid),public.iv_create(jsonb),public.iv_state(uuid,text),public.iv_api(text,uuid,text,jsonb)from public,anon,authenticated;
grant execute on function public.iv_api(text,uuid,text,jsonb)to anon,authenticated;
commit;
