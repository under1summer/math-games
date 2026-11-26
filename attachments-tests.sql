begin;
do $$declare r jsonb;s jsonb;g uuid;h text;tt text;tt2 text;tid uuid;fid uuid;sid uuid;rows jsonb;secret text;begin
r:=public.ps_api('create');g:=(r->>'id')::uuid;h:=r->>'hostToken';s:=public.ps_api('configure',g,h,'{"names":["A","B"],"rounds":1,"interval":30}');tt:=s->'links'->0->>'token';tt2:=s->'links'->1->>'token';tid:=(s->'links'->0->>'id')::uuid;
s:=public.mg_tasks('ps',g,h,'get');select jsonb_agg(x||jsonb_build_object('content',(x->'content')||jsonb_build_object('attachments',case when x->>'code'='m:1'then 'required'when x->>'code'='m:2'then 'forbidden'else 'optional'end,'condition','File fixture','mode','manual','key','')))into rows from jsonb_array_elements(s->'rows')x;perform public.mg_tasks('ps',g,h,'save',jsonb_build_object('rows',rows));perform public.ps_api('start',g,h);
begin perform public.ps_api('submit',g,tt,jsonb_build_object('id',gen_random_uuid(),'task','m:1','answer','text'));raise check_violation;exception when raise_exception then null;end;
begin perform public.mg_files_access('upload','ps',g,tt,jsonb_build_object('code','m:2','name','x.pdf','mime','application/pdf','size',100));raise check_violation;exception when raise_exception then null;end;
r:=public.mg_files_access('upload','ps',g,tt,jsonb_build_object('code','m:1','name','x.pdf','mime','application/pdf','size',100));fid:=(r->>'id')::uuid;perform public.mg_files_access('ready','ps',g,tt,jsonb_build_object('id',fid));
begin perform public.mg_files_access('get','ps',g,tt2,jsonb_build_object('id',fid));raise check_violation;exception when raise_exception then null;end;
sid:=gen_random_uuid();s:=public.ps_api('submit',g,tt,jsonb_build_object('id',sid,'task','m:1','answer','','files',jsonb_build_array(fid)));assert s->'submissions'->0->>'status'='PENDING';assert(select answer_id=sid from public.mg_files where id=fid);
r:=public.mg_files_access('get','ps',g,h,jsonb_build_object('id',fid));assert r->>'name'='x.pdf';
begin perform public.mg_files_access('discard','ps',g,tt,jsonb_build_object('id',fid));raise check_violation;exception when raise_exception then null;end;
perform public.ps_api('finish',g,h);update public.mg_lifecycle set protected=true,finished_at=now()-interval '8 days'where game_kind='ps'and game_id=g;perform public.mg_cleanup();assert exists(select 1 from public.ps_submissions where id=sid);
select cleanup_token into secret from public.mg_file_config where id=true;r:=public.mg_files_access('cleanup','',null,secret);assert exists(select 1 from jsonb_array_elements(r)x where x->>'id'=fid::text);assert(select expires_at is not null from public.mg_files where id=fid);
assert not has_function_privilege('anon','public.mg_files_access(text,text,uuid,text,jsonb)','EXECUTE');assert not has_table_privilege('authenticated','public.mg_files','SELECT');assert(select public=false from storage.buckets where id='game-solutions');
end $$;
select 'PASS: file policy, file-only answer, ownership, immutable bound files, expiry queue, private bucket' as result;
rollback;
