-- Paper delivery does not require uploaded task content or answer keys.
begin;
do $patch$
declare src text;updated text;begin
src:=pg_get_functiondef('public.ng_api(text,uuid,text,jsonb)'::regprocedure);
updated:=replace(src,'end if;if exists(select 1 from public.ng_slots s left join public.mg_task_copies c','end if;if gg.online and exists(select 1 from public.ng_slots s left join public.mg_task_copies c');
if updated=src and position('if gg.online and exists(select 1 from public.ng_slots' in src)=0 then raise exception 'Unexpected ng_api start guard';end if;
execute updated;
execute $ivdef$create or replace function public.iv_api(op text,game uuid default null,token text default '',payload jsonb default '{}')returns jsonb language plpgsql security definer set search_path=''as $$
#variable_conflict use_column
declare gg public.ng_games;tm public.ng_teams;host boolean;cell public.iv_cells;existing public.iv_captures;pid uuid;ids jsonb;required int;valid int;total int;xx int;yy int;v int;begin
if op='create'then return public.iv_create(payload);end if;
if op='state'then return public.iv_state(game,token);end if;
select *into strict gg from public.ng_games where id=game and kind='iv'for update;host:=public.ng_host('iv',game,token);select *into tm from public.ng_teams where game_id=game and ng_teams.token=iv_api.token;
if not host and tm.id is null then raise exception 'Нет доступа';end if;
if exists(select 1 from public.ng_lifecycle where game_id=game and archived)then raise exception 'Подробные данные уже очищены';end if;
if op='delivery'then
if not host or gg.started_at is not null or jsonb_typeof(payload->'online')is distinct from 'boolean' then raise exception 'Режим выбирается ведущим до старта';end if;
update public.ng_games set online=(payload->>'online')::boolean where id=game;
insert into public.ng_events(game_id,action,data)values(game,'delivery',jsonb_build_object('online',payload->'online'));
return public.iv_state(game,token);
end if;
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
insert into public.ng_events(game_id,action,data)values(game,'iv_'||op,jsonb_build_object('team',tm.id,'x',xx,'y',yy,'id',pid));update public.ng_lifecycle set activity_at=now()where game_id=game;return public.iv_state(game,token);end $$;$ivdef$;
src:=pg_get_functiondef('public.ab_api(text,uuid,text,jsonb)'::regprocedure);
updated:=replace(src,'if snapshot is null or jsonb_array_length(snapshot)<>g.themes*g.tasks_per_theme or exists(', 'if g.online and (snapshot is null or jsonb_array_length(snapshot)<>g.themes*g.tasks_per_theme or exists(');
if updated<>src then updated:=replace(updated,$old$then raise exception 'Заполните и сохраните все условия и ключи';$old$,$new$) then raise exception 'Заполните и сохраните все условия и ключи';$new$);execute updated;elsif position('if g.online and (snapshot is null' in src)=0 then raise exception 'Unexpected ab_api start guard';end if;
end $patch$;
commit;
