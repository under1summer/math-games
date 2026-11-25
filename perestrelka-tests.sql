-- Run in Supabase SQL Editor as owner. All fixtures roll back.
begin;
create temporary table ps_old_snapshot(name text, fingerprint text);
do $$ declare t record; f text; begin
 for t in select tablename from pg_tables where schemaname='public' and (tablename like 'od\_%' escape '\' or tablename like 'ab\_%' escape '\') loop
 execute format('select md5(coalesce(string_agg(x::text,''|'' order by x::text),'''')) from (select to_jsonb(t) x from public.%I t) s',t.tablename) into f;
 insert into ps_old_snapshot values(t.tablename,f);
 end loop;
end $$;
create function pg_temp.expect_error(op text,g uuid,t text,p jsonb) returns void language plpgsql as $$
begin
 begin perform public.ps_api(op,g,t,p); exception when others then return; end;
 raise exception 'Expected rejection: %',op;
end $$;
do $$
declare c jsonb;s jsonb;g uuid;h text;a uuid;b uuid;tt text;r uuid;e bigint;v numeric;oldhp numeric;newg uuid;cl jsonb;gr public.ps_games;
begin
 c:=public.ps_api('create',null,'','{"title":"SQL regression fixture"}');g:=(c->>'id')::uuid;h:=c->>'hostToken';
 s:=public.ps_api('state',g,h);a:=(s->'teams'->0->>'id')::uuid;b:=(s->'teams'->1->>'id')::uuid;tt:=s->'links'->0->>'token';
 assert s->'teams'->0->>'hp'='100';assert (s->'teams'->0->>'accuracy')::numeric=.5;
 assert jsonb_array_length(s->'tasks')=0;
 perform pg_temp.expect_error('start',g,tt,'{}');perform pg_temp.expect_error('start',g,'','{}');perform pg_temp.expect_error('state',g,'forged','{}');
 s:=public.ps_api('state',g,tt);assert not(s?'links');assert not(s?'host');assert s->'me'->>'id'=a::text;
 perform public.ps_api('configure',g,h,'{"names":["A","B"],"rounds":2,"interval":1}');
 s:=public.ps_api('start',g,h);assert jsonb_array_length(s->'tasks')=26;
 assert (select count(*)=4 from jsonb_array_elements(s->'tasks') x where x->>'power'='2');
 perform pg_temp.expect_error('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'task','s:2:1','target',b,'correct',true));
 r:=gen_random_uuid();s:=public.ps_api('answer',g,h,jsonb_build_object('id',r,'team',a,'task','m:1','correct',true));
 s:=public.ps_api('answer',g,h,jsonb_build_object('id',r,'team',a,'task','m:1','correct',true));
 select x into c from jsonb_array_elements(s->'teams') x where x->>'id'=a::text;
 assert (c->>'hp')::numeric=102;assert (c->>'n')::int=1;assert abs((c->>'accuracy')::numeric-2::numeric/3)<.0000001;
 perform pg_temp.expect_error('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'task','m:1','correct',false));
 s:=public.ps_api('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'task','s:1:1','target',b,'correct',true));
 -- Owner-only deterministic fixture. Clients never supply rolls.
 update public.ps_events set data=jsonb_set(data,'{roll}','0') where game_id=g and kind='answer' and data->>'task'='s:1:1';
 s:=public.ps_api('state',g,h);
 select x into c from jsonb_array_elements(s->'history') x where x->>'task'='s:1:1';
 assert abs((c->>'chance')::numeric-2::numeric/3)<.0000001;assert (c->>'damage')::numeric=20.4;assert (c->>'hit')::boolean;
 select (x->>'hp')::numeric into v from jsonb_array_elements(s->'teams') x where x->>'id'=b::text;assert v=79.6;
 s:=public.ps_api('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'task','m:2','correct',false));
 select x into c from jsonb_array_elements(s->'teams') x where x->>'id'=a::text;assert (c->>'n')::int=3;assert (c->>'k')::int=2;assert (c->>'hp')::numeric=102;
 -- Cancelling medkit recalculates subsequent damage, retaining shot roll.
 select id into e from public.ps_events where game_id=g and data->>'task'='m:1';r:=gen_random_uuid();
 s:=public.ps_api('cancel',g,h,jsonb_build_object('id',r,'event',e,'reason','fixture'));
 s:=public.ps_api('cancel',g,h,jsonb_build_object('id',r,'event',e,'reason','fixture'));
 select (x->>'hp')::numeric into v from jsonb_array_elements(s->'teams') x where x->>'id'=b::text;assert v=80;
 select x into c from jsonb_array_elements(s->'history') x where x->>'task'='s:1:1';assert (c->>'roll')::numeric=0;assert (c->>'chance')::numeric=.5;
 perform public.ps_api('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'task','m:1','correct',true));
 -- Miss is deterministic too; wrong answers never fire.
 perform public.ps_api('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'task','s:1:2','target',b,'correct',true));
 update public.ps_events set data=jsonb_set(data,'{roll}','0.999999') where game_id=g and data->>'task'='s:1:2';
 s:=public.ps_api('state',g,h);select x into c from jsonb_array_elements(s->'history') x where x->>'task'='s:1:2';assert not(c->>'hit')::boolean;
 s:=public.ps_api('hp',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'delta',-10000,'reason','fixture'));r:=gen_random_uuid();
 s:=public.ps_api('undo',g,h,jsonb_build_object('id',r,'reason','fixture'));s:=public.ps_api('undo',g,h,jsonb_build_object('id',r,'reason','fixture'));
 select (x->>'hp')::numeric into v from jsonb_array_elements(s->'teams') x where x->>'id'=a::text;assert v=102;
 -- Zero HP can still answer, min damage 3, no negative HP.
 perform public.ps_api('hp',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'delta',-10000,'reason','fixture'));
 perform public.ps_api('hp',g,h,jsonb_build_object('id',gen_random_uuid(),'team',b,'delta',-10000,'reason','fixture'));
 perform public.ps_api('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'task','s:1:3','target',b,'correct',true));
 update public.ps_events set data=jsonb_set(data,'{roll}','0') where game_id=g and data->>'task'='s:1:3';
 s:=public.ps_api('state',g,h);select x into c from jsonb_array_elements(s->'history') x where x->>'task'='s:1:3';assert (c->>'damage')::numeric=3;
 select (x->>'hp')::numeric into v from jsonb_array_elements(s->'teams') x where x->>'id'=b::text;assert v=0;
 s:=public.ps_api('pause',g,h);assert s->'clock'->>'status'='PAUSED';
 perform pg_temp.expect_error('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'task','m:3','correct',true));
 select * into gr from public.ps_games where id=g;cl:=public.ps_clock(gr,gr.paused_at_ms+1000000);assert cl->>'elapsed'=s->'clock'->>'elapsed';
 perform public.ps_api('resume',g,h);s:=public.ps_api('issue',g,h);assert (s->'clock'->>'issued')::int=2;
 perform pg_temp.expect_error('rounds',g,h,'{"rounds":1}');
 -- Previous clip remains available.
 perform public.ps_api('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',b,'task','s:1:1','target',a,'correct',false));
 s:=public.ps_api('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',b,'task','s:2:1','target',a,'correct',false));
 s:=public.ps_api('finish',g,h);assert s->'clock'->>'status'='FINISHED';
 perform pg_temp.expect_error('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'task','m:3','correct',true));
 c:=public.ps_api('new',g,h);newg:=(c->>'id')::uuid;assert newg<>g;s:=public.ps_api('state',newg,c->>'hostToken');assert s->'clock'->>'status'='READY';assert jsonb_array_length(s->'history')=0;
 s:=public.ps_api('state',g,h);assert s->'clock'->>'status'='FINISHED';assert jsonb_array_length(s->'history')>0;
 -- Natural deadline and automatic second clip, with owner-only clock fixture.
 c:=public.ps_api('create',null,'','{}');g:=(c->>'id')::uuid;h:=c->>'hostToken';perform public.ps_api('configure',g,h,'{"names":["A","B"],"rounds":2,"interval":1}');s:=public.ps_api('start',g,h);
 update public.ps_games set start_ms=start_ms-65000 where id=g;s:=public.ps_api('state',g,h);assert (s->'clock'->>'issued')::int=2;assert s->'clock'->>'status'='RUNNING';
 update public.ps_games set start_ms=start_ms-65000 where id=g;s:=public.ps_api('state',g,h);assert s->'clock'->>'status'='FINISHED';
 a:=(s->'teams'->0->>'id')::uuid;perform pg_temp.expect_error('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'task','m:3','correct',true));
 assert not has_table_privilege('anon','public.ps_games','SELECT');assert not has_table_privilege('authenticated','public.ps_events','INSERT');
 assert not has_function_privilege('anon','public.ps_replay(uuid)','EXECUTE');assert has_function_privilege('anon','public.ps_api(text,uuid,text,jsonb)','EXECUTE');
 assert (select bool_and(relrowsecurity) from pg_class where oid in ('public.ps_games'::regclass,'public.ps_teams'::regclass,'public.ps_tasks'::regclass,'public.ps_events'::regclass));
end $$;
do $$ declare t record;f text;begin
 for t in select * from ps_old_snapshot loop
 execute format('select md5(coalesce(string_agg(x::text,''|'' order by x::text),'''')) from (select to_jsonb(t) x from public.%I t) s',t.name) into f;
 assert f=t.fingerprint,'Other game data changed';
 end loop;
end $$;
select 'PASS: mechanics, permissions, timers, cancellation, archive, isolation' as result;
rollback;
