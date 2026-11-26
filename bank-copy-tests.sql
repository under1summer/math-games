-- Existing game copies survive bank deletion and bank sign-out. All data rolls back.
begin;
do $$declare u uuid:=gen_random_uuid();b jsonb;c jsonb;g uuid;h text;r jsonb;rows jsonb;copies jsonb:='[]';k text;one jsonb;bid uuid;begin
insert into auth.users(id,email)values(u,u||'@example.invalid');perform set_config('request.jwt.claim.sub',u::text,true);
c:=public.mg_validate('{"title":"Independent snapshot","condition":"2 + 2 = ?","mode":"number","key":"4","kind":"standard","attachments":"optional"}');b:=public.mg_bank('save',jsonb_build_object('content',c));bid:=(b->>'id')::uuid;
foreach k in array array['od','ab','ps','birzha']loop
case k when 'od'then r:=public.od_api('create');g:=(r->>'game')::uuid;h:=r->>'host';when 'ab'then r:=public.ab_api('create');g:=(r->>'id')::uuid;h:=r->>'hostToken';when 'ps'then r:=public.ps_api('create');g:=(r->>'id')::uuid;h:=r->>'hostToken';else r:=public.mg_tasks(k,null,'','create');g:=(r->>'id')::uuid;h:=r->>'hostToken';end case;
r:=public.mg_tasks(k,g,h,'get');if k='birzha'then rows:='[{"code":"1"}]';else rows:=r->'rows';end if;select jsonb_agg(x||jsonb_build_object('content',c,'bank_id',bid,'bank_version',1))into rows from jsonb_array_elements(rows)x;perform public.mg_tasks(k,g,h,'save',jsonb_build_object('rows',rows));copies:=copies||jsonb_build_array(jsonb_build_object('k',k,'g',g,'h',h));end loop;
perform public.mg_bank('delete',jsonb_build_object('id',bid));perform set_config('request.jwt.claim.sub','',true);
for one in select * from jsonb_array_elements(copies)loop k:=one->>'k';g:=(one->>'g')::uuid;h:=one->>'h';r:=public.mg_tasks(k,g,h,'get');perform public.mg_tasks(k,g,h,'save',jsonb_build_object('rows',r->'rows'));assert not exists(select 1 from public.mg_task_copies where game_kind=k and game_id=g and content->>'key'<>'4');end loop;
end $$;
select 'PASS: four adapters retain versioned game copies after bank deletion/sign-out' as result;
rollback;
