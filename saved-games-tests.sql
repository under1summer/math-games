-- Transactional regression: no test accounts or games remain after rollback.
begin;
do $$declare u uuid:=gen_random_uuid();other_user uuid:=gen_random_uuid();k text;r jsonb;c jsonb;b jsonb;g uuid;h text;rows jsonb;tid uuid;run1 jsonb;run2 jsonb;req uuid;state jsonb;denied boolean;begin
insert into auth.users(id,email)values(u,u||'@example.invalid'),(other_user,other_user||'@example.invalid');perform set_config('request.jwt.claim.sub',u::text,true);
c:=public.mg_validate('{"title":"Regression scenario","condition":"2 + 2 = ?","mode":"number","key":"4","kind":"standard","attachments":"required"}');
b:=public.mg_bank_batch(jsonb_build_array(jsonb_build_object('content',c),jsonb_build_object('content',c)));assert jsonb_array_length(b)=2 and(b->1->>'duplicate')::boolean;assert(select count(*)=1 from public.mg_bank_tasks where owner_id=u);
foreach k in array array['od','ab','ps','birzha']loop
case k when 'od'then r:=public.od_api('create');g:=(r->>'game')::uuid;h:=r->>'host';perform public.od_api('configure',g,h,'{"names":["Альфа","Бета","Гамма"]}');
when 'ab'then r:=public.ab_api('create');g:=(r->>'id')::uuid;h:=r->>'hostToken';perform public.ab_api('configure',g,h,'{"names":["Альфа","Бета"],"themes":2,"tasks":3,"minutes":45}');
when 'ps'then r:=public.ps_api('create');g:=(r->>'id')::uuid;h:=r->>'hostToken';perform public.ps_api('configure',g,h,'{"names":["Альфа","Бета"],"rounds":3,"interval":5}');
else r:=public.mg_tasks(k,null,'','create');g:=(r->>'id')::uuid;h:=r->>'hostToken';end case;
if k<>'birzha'then execute format('select public.%I($1,$2,$3,$4)',k||'_api')using 'delivery',g,h,'{"online":false}'::jsonb;end if;
rows:=public.mg_tasks(k,g,h,'get')->'rows';if k='birzha'then rows:='[{"code":"1"}]';end if;
select jsonb_agg(x||jsonb_build_object('content',c,'bank_id',b->0->>'id','bank_version',1))into rows from jsonb_array_elements(rows)x;perform public.mg_tasks(k,g,h,'save',jsonb_build_object('rows',rows));
r:=public.mg_templates('save',jsonb_build_object('kind',k,'game',g,'token',h,'title','Test '||k));tid:=(r->>'id')::uuid;
-- Snapshot survives changes in the source game.
select jsonb_agg(x||jsonb_build_object('content',c||'{"condition":"Changed","key":"5"}','bank_id',null,'bank_version',null))into rows from jsonb_array_elements(rows)x;perform public.mg_tasks(k,g,h,'save',jsonb_build_object('rows',rows));
req:=gen_random_uuid();run1:=public.mg_templates('launch',jsonb_build_object('id',tid,'request',req));run2:=public.mg_templates('launch',jsonb_build_object('id',tid,'request',req));assert run1=run2;assert(run1->>'id')::uuid<>g and run1->>'hostToken'<>h;
state:=public.mg_tasks(k,(run1->>'id')::uuid,run1->>'hostToken','get');assert state->'rows'->0->'content'->>'key'='4';assert state->'rows'->0->'content'->>'attachments'='required';assert not coalesce((state->>'locked')::boolean,false);
if k='ab'then assert(select themes=2 and tasks_per_theme=3 and minutes=45 and not online and start_ms is null from public.ab_games where id=(run1->>'id')::uuid);assert not exists(select 1 from public.ab_teams a join public.ab_teams z on a.token=z.token where a.game_id=g and z.game_id=(run1->>'id')::uuid);end if;
if k='ps'then assert(select rounds=3 and interval_min=5 and not online and status='READY'from public.ps_games where id=(run1->>'id')::uuid);assert not exists(select 1 from public.ps_submissions where game_id=(run1->>'id')::uuid);end if;
if k='od'then assert(select not online and started_at is null from public.od_games where id=(run1->>'id')::uuid);assert not exists(select 1 from public.od_packets where game_id=(run1->>'id')::uuid);end if;
perform set_config('request.jwt.claim.sub',other_user::text,true);assert public.mg_templates('list')='[]'::jsonb;denied:=false;begin perform public.mg_templates('get',jsonb_build_object('id',tid));exception when others then denied:=true;end;assert denied;perform set_config('request.jwt.claim.sub',u::text,true);
run2:=public.mg_templates('launch',jsonb_build_object('id',tid,'request',gen_random_uuid()));assert run2->>'id'<>run1->>'id';
perform public.mg_remove(k,g,false);assert public.mg_templates('get',jsonb_build_object('id',tid))->>'title'='Test '||k;
perform public.mg_templates('delete',jsonb_build_object('id',tid));assert public.mg_host(k,(run1->>'id')::uuid,run1->>'hostToken');perform public.mg_remove(k,(run1->>'id')::uuid,false);assert not exists(select 1 from public.mg_template_runs where game_id=(run1->>'id')::uuid);
end loop;
assert not has_table_privilege('anon','public.mg_game_templates','SELECT');assert not has_table_privilege('authenticated','public.mg_template_runs','SELECT');assert not has_function_privilege('anon','public.mg_templates(text,jsonb)','EXECUTE');
end $$;
select 'PASS: four scenario adapters; snapshots; new teams; idempotent launches; owner isolation; private answers; retention; bank import duplicates' as result;
rollback;
