-- Run as owner after platform-update.sql. All test data rolls back.
begin;
create function pg_temp.rejected(op text,g uuid,t text,p jsonb,which_game text default 'ps') returns void language plpgsql as $$
begin
 begin
  if which_game='ps' then perform public.ps_api(op,g,t,p);elsif which_game='od' then perform public.od_api(op,g,t,p);else perform public.ab_api(op,g,t,p);end if;
 exception when others then return;end;
 raise exception 'Expected rejection: % %',which_game,op;
end $$;
do $$
declare c jsonb;s jsonb;d jsonb;g uuid;h text;t text;t2 text;a uuid;b uuid;sid uuid;r uuid;e bigint;roll_before numeric;tasks jsonb;
begin
 c:=public.ps_api('create');g:=(c->>'id')::uuid;h:=c->>'hostToken';
 s:=public.ps_api('configure',g,h,'{"names":["A","B"],"rounds":1,"interval":15}');t:=s->'links'->0->>'token';t2:=s->'links'->1->>'token';a:=(s->'links'->0->>'id')::uuid;b:=(s->'links'->1->>'id')::uuid;
 select jsonb_agg(x||jsonb_build_object('statement','Test task','mode',case when x->>'code'='m:3' then 'text' when x->>'code'='m:4' then 'manual' else 'number' end,'key','2')) into tasks from jsonb_array_elements(s->'draftTasks') x;
 perform public.ps_api('tasks',g,h,jsonb_build_object('tasks',tasks));s:=public.ps_api('start',g,h);
 s:=public.ps_api('state',g,t);assert not(s?'draftTasks');assert not(s->'tasks'->0?'key');assert not(s->'tasks'->0?'mode');
 sid:=gen_random_uuid();s:=public.ps_api('submit',g,t,jsonb_build_object('id',sid,'task','m:1','answer','2','team',b));
 assert s->'submissions'->0->>'team_id'=a::text;assert s->'submissions'->0->>'status'='JUDGED';assert (s->'submissions'->0->>'correct')::boolean;
 s:=public.ps_api('submit',g,t,jsonb_build_object('id',sid,'task','m:1','answer','2'));assert jsonb_array_length(s->'submissions')=1;
 s:=public.ps_api('state',g,t2);assert jsonb_array_length(s->'submissions')=0;
 perform pg_temp.rejected('judge',g,t,jsonb_build_object('submission',sid,'correct',true));
 perform pg_temp.rejected('submit',g,t,jsonb_build_object('id',gen_random_uuid(),'task','m:1','answer','2'));
 -- Manual recheck changes the existing event, not the number of attempts.
 s:=public.ps_api('judge',g,h,jsonb_build_object('submission',sid,'correct',false));
 select x into d from jsonb_array_elements(s->'teams') x where x->>'id'=a::text;assert (d->>'hp')::numeric=100;assert (d->>'n')::int=1;assert (d->>'k')::int=0;
 s:=public.ps_api('judge',g,h,jsonb_build_object('submission',sid,'correct',true));
 select x into d from jsonb_array_elements(s->'teams') x where x->>'id'=a::text;assert (d->>'hp')::numeric=102;assert (d->>'n')::int=1;
 sid:=gen_random_uuid();s:=public.ps_api('submit',g,t,jsonb_build_object('id',sid,'task','s:1:1','target',b,'answer','2'));
 select id,(data->>'roll')::numeric into e,roll_before from public.ps_events where request_id=sid;
 perform public.ps_api('judge',g,h,jsonb_build_object('submission',sid,'correct',false));perform public.ps_api('judge',g,h,jsonb_build_object('submission',sid,'correct',true));
 assert (select (data->>'roll')::numeric=roll_before from public.ps_events where id=e);
 s:=public.ps_api('cancel',g,h,jsonb_build_object('id',gen_random_uuid(),'event',e,'reason','fixture'));assert (select status='CANCELLED' from public.ps_submissions where id=sid);
 perform public.ps_api('submit',g,t,jsonb_build_object('id',gen_random_uuid(),'task','s:1:1','target',b,'answer','3'));
 sid:=gen_random_uuid();s:=public.ps_api('submit',g,t,jsonb_build_object('id',sid,'task','m:3','answer','different text'));assert (select status='PENDING' from public.ps_submissions where id=sid);
 s:=public.ps_api('finish',g,h);s:=public.ps_api('judge',g,h,jsonb_build_object('submission',sid,'correct',true));assert (select status='JUDGED' from public.ps_submissions where id=sid);
 perform pg_temp.rejected('delivery',g,h,'{"online":false}');
 -- Offline: server denies team submissions; host enters a paper answer.
 c:=public.ps_api('create');g:=(c->>'id')::uuid;h:=c->>'hostToken';s:=public.ps_api('delivery',g,h,'{"online":false}');a:=(s->'links'->0->>'id')::uuid;t:=s->'links'->0->>'token';perform public.ps_api('start',g,h);
 perform pg_temp.rejected('submit',g,t,jsonb_build_object('id',gen_random_uuid(),'task','m:1','answer','2'));
 sid:=gen_random_uuid();s:=public.ps_api('submit',g,h,jsonb_build_object('id',sid,'team',a,'task','m:1','answer','2'));assert (select status='PENDING' from public.ps_submissions where id=sid);
 perform public.ps_api('judge',g,h,jsonb_build_object('submission',sid,'correct',true));
 assert not has_table_privilege('anon','public.ps_submissions','SELECT');assert not has_function_privilege('anon','public.ps_decide(uuid,boolean,text)','EXECUTE');
 -- Optom: auto result + manual correction and offline gate.
 c:=public.od_api('create');g:=(c->>'game')::uuid;h:=c->>'host';s:=public.od_api('configure',g,h,'{"names":["A","B","C"]}');t:=s->'links'->0->>'token';a:=(s->'links'->0->>'id')::uuid;
 if a is null then select id into a from public.od_teams where game_id=g order by name limit 1;end if;
 select jsonb_agg(jsonb_build_object('n',n,'title','Test','mode','number','key','2') order by n) into tasks from generate_series(1,24) n;
 perform public.od_api('tasks',g,h,jsonb_build_object('tasks',tasks));perform public.od_api('delivery',g,h,'{"online":false}');perform public.od_api('start',g,h);
 perform pg_temp.rejected('submit',g,t,jsonb_build_object('id',gen_random_uuid(),'answers',jsonb_build_array(jsonb_build_object('n',1,'text','2'))),'od');
 sid:=gen_random_uuid();perform public.od_api('submit',g,h,jsonb_build_object('id',sid,'team',a,'answers',jsonb_build_array(jsonb_build_object('n',1,'text','2'))));assert (select answers->0->>'status'='yes' from public.od_packets where id=sid);
 perform public.od_api('judge',g,h,jsonb_build_object('id',sid,'n',1,'status','no'));assert (select answers->0->>'status'='no' from public.od_packets where id=sid);
 -- Abaka: auto result + manual correction and offline gate.
 c:=public.ab_api('create');g:=(c->>'id')::uuid;h:=c->>'hostToken';s:=public.ab_api('configure',g,h,'{"names":["A","B"],"themes":1,"tasks":1,"minutes":15}');t:=s->'links'->0->>'token';select id into a from public.ab_teams where game_id=g order by position limit 1;
 perform public.ab_api('tasks',g,h,'{"tasks":[{"theme":1,"n":1,"topic":"Test","text":"1+1","mode":"Число","key":"2"}]}');perform public.ab_api('delivery',g,h,'{"online":false}');perform public.ab_api('start',g,h);
 perform pg_temp.rejected('submit',g,t,jsonb_build_object('id',gen_random_uuid(),'theme',1,'n',1,'answer','2'),'ab');
 sid:=gen_random_uuid();s:=public.ab_api('submit',g,h,jsonb_build_object('id',sid,'team',a,'theme',1,'n',1,'answer','2'));assert s->>'status'='yes';
 s:=public.ab_api('review',g,h,jsonb_build_object('id',sid,'status','no','note','fixture'));assert (select status='no' from public.ab_submissions where id=sid);
end $$;
select 'PASS: submissions, automatic and manual review, key privacy, all three classroom modes' as result;
rollback;
