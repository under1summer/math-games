-- Run as owner after perestrelka-review.sql. No fixtures retained.
begin;
do $$
declare c jsonb;s jsonb;g uuid;h text;a uuid;b uuid;t text;e bigint;r numeric;row_json jsonb;sid uuid;
begin
 c:=public.ps_api('create');g:=(c->>'id')::uuid;h:=c->>'hostToken';s:=public.ps_api('start',g,h);a:=(s->'links'->0->>'id')::uuid;b:=(s->'links'->1->>'id')::uuid;t:=s->'links'->0->>'token';
 s:=public.ps_api('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'task','m:1','correct',false));
 select id into e from public.ps_events where game_id=g and kind='answer';
 begin perform public.ps_review_event(g,t,e,true);raise exception 'Team must not grade';exception when raise_exception then if sqlerrm='Team must not grade' then raise;end if;end;
 s:=public.ps_review_event(g,h,e,true);select x into row_json from jsonb_array_elements(s->'teams') x where x->>'id'=a::text;assert (row_json->>'hp')::numeric=102;assert (row_json->>'n')::int=1;assert (row_json->>'k')::int=1;
 s:=public.ps_review_event(g,h,e,false);select x into row_json from jsonb_array_elements(s->'teams') x where x->>'id'=a::text;assert (row_json->>'hp')::numeric=100;assert (row_json->>'n')::int=1;
 perform public.ps_api('answer',g,h,jsonb_build_object('id',gen_random_uuid(),'team',a,'task','s:1:1','target',b,'correct',true));
 select id,(data->>'roll')::numeric into e,r from public.ps_events where game_id=g and kind='answer' and data->>'task'='s:1:1';
 perform public.ps_review_event(g,h,e,false);perform public.ps_review_event(g,h,e,true);assert (select (data->>'roll')::numeric=r from public.ps_events where id=e);
 sid:=gen_random_uuid();perform public.ps_api('submit',g,t,jsonb_build_object('id',sid,'task','m:2','answer','paper'));
 perform public.ps_api('judge',g,h,jsonb_build_object('submission',sid,'correct',true));select event_id into e from public.ps_submissions where id=sid;
 perform public.ps_review_event(g,h,e,false);assert (select correct=false and review_source='manual' from public.ps_submissions where id=sid);
 perform public.ps_api('finish',g,h);s:=public.ps_review_event(g,h,e,true);assert s->'clock'->>'status'='FINISHED';
 perform public.ps_api('cancel',g,h,jsonb_build_object('id',gen_random_uuid(),'event',e,'reason','fixture'));
 begin perform public.ps_review_event(g,h,e,true);raise exception 'Cancelled answer must stay cancelled';exception when raise_exception then if sqlerrm='Cancelled answer must stay cancelled' then raise;end if;end;
 assert not has_table_privilege('anon','public.ps_events','UPDATE');
end $$;
select 'PASS: review preserves attempts, HP, rolls, deadlines and host permissions' as result;
rollback;
