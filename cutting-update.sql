-- Cutting constraints v2. Optional config fields preserve existing tasks. No data changes.
begin;
create or replace function public.mg_cut_variant(c jsonb,solution jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare w int;h int;np int;rule text;cells text[]:='{}';cuts text[]:='{}';remaining text[];queue text[];part text[];shapes text[]:='{}';areas int[]:='{}';p text;q text;e text;x int;y int;item jsonb;countparts int:=0;ab text[];removed text[]:='{}';partitions text[]:='{}';color_mode text:=coalesce(c->>'color_rule','none');target text:=coalesce(c->>'target_color','green');ways int:=coalesce((c->>'ways')::int,1);remove_count int:=coalesce((c->>'remove_cells')::int,0);minimum int:=coalesce((c->>'min_distinct')::int,0);col text;color_ok boolean:=true;signature text;st text;entry record;
begin
w:=(c->>'width')::int;h:=(c->>'height')::int;np:=(c->>'parts')::int;rule:=c->>'rule';
if w is null or h is null or w not between 1 and 30 or h not between 1 and 30 or np is null or np not between 1 and 64 or rule is null or rule not in('congruent','equal_area','distinct','manual') or jsonb_typeof(c->'cells') is distinct from 'array' or jsonb_array_length(c->'cells') not between 1 and 900 then raise exception 'Некорректная фигура';end if;
for item in select * from jsonb_array_elements(c->'cells')loop
if jsonb_typeof(item) is distinct from 'array' or jsonb_array_length(item)<>2 or (item->>0)!~'^[0-9]+$' or (item->>1)!~'^[0-9]+$' then raise exception 'Неверная клетка';end if;
x:=(item->>0)::int;y:=(item->>1)::int;p:=x||','||y;if x not between 0 and w-1 or y not between 0 and h-1 or p=any(cells)then raise exception 'Неверная клетка';end if;cells:=array_append(cells,p);end loop;
if np>cardinality(cells)then raise exception 'Слишком много частей';end if;
if ways not between 1 and 10 or remove_count not between 0 and 10 or remove_count>cardinality(cells)-np or minimum not between 0 and np or(rule='congruent'and minimum>1)then raise exception 'Неверное число способов, исключаемых клеток или разных форм';end if;
if color_mode not in('none','each','selected')or target not in('green','red','blue','yellow','purple','orange')or jsonb_typeof(coalesce(c->'colors','{}'))is distinct from 'object'then raise exception 'Некорректные цветовые требования';end if;
for entry in select *from jsonb_each_text(coalesce(c->'colors','{}'))loop
if not(entry.key=any(cells))or entry.value is null or entry.value not in('green','red','blue','yellow','purple','orange')then raise exception 'Цвет можно задать только клетке фигуры';end if;end loop;
if color_mode='each'and coalesce(c->'colors','{}')='{}'::jsonb or color_mode='selected'and not exists(select 1 from jsonb_each_text(coalesce(c->'colors','{}'))z where z.value=target)then raise exception 'Раскрасьте клетки для цветового условия';end if;

if solution is not null then
if jsonb_typeof(coalesce(solution->'removed','[]'))is distinct from 'array'or jsonb_array_length(coalesce(solution->'removed','[]'))>10 then raise exception 'Неверные исключённые клетки';end if;
for item in select *from jsonb_array_elements(coalesce(solution->'removed','[]'))loop
p:=item#>>'{}';if jsonb_typeof(item)<>'string'or not(p=any(cells))or p=any(removed)then raise exception 'Неверные исключённые клетки';end if;removed:=array_append(removed,p);end loop;
select coalesce(array_agg(z.p),'{}')into cells from unnest(cells)z(p)where not(z.p=any(removed));
if jsonb_typeof(solution->'cuts')is distinct from 'array' or jsonb_array_length(solution->'cuts')>1800 then raise exception 'Неверные разрезы';end if;
for e in select jsonb_array_elements_text(solution->'cuts')loop
ab:=string_to_array(e,'|');if cardinality(ab)<>2 or not(ab[1]=any(cells)and ab[2]=any(cells))or ab[1] collate "C">=ab[2] collate "C"or e=any(cuts)then raise exception 'Неверная граница';end if;
if abs(split_part(ab[1],',',1)::int-split_part(ab[2],',',1)::int)+abs(split_part(ab[1],',',2)::int-split_part(ab[2],',',2)::int)<>1 then raise exception 'Неверная граница';end if;cuts:=array_append(cuts,e);end loop;end if;
remaining:=cells;while cardinality(remaining)>0 loop
queue:=array[remaining[1]];remaining:=array_remove(remaining,remaining[1]);part:='{}';
while cardinality(queue)>0 loop p:=queue[1];queue:=queue[2:];part:=array_append(part,p);x:=split_part(p,',',1)::int;y:=split_part(p,',',2)::int;
foreach q in array array[(x+1)||','||y,(x-1)||','||y,x||','||(y+1),x||','||(y-1)]loop
e:=least(p collate "C",q collate "C")||'|'||greatest(p collate "C",q collate "C");if q=any(remaining)and not(e=any(cuts))then remaining:=array_remove(remaining,q);queue:=array_append(queue,q);end if;end loop;end loop;
countparts:=countparts+1;shapes:=array_append(shapes,public.mg_cut_shape(part));areas:=array_append(areas,cardinality(part));
partitions:=array_append(partitions,(select string_agg(z.p,';'order by z.p collate "C")from unnest(part)z(p)));
for col in select distinct z.value from jsonb_each_text(coalesce(c->'colors','{}'))z where color_mode='each'or(color_mode='selected'and z.value=target)loop
if(select count(*)from unnest(part)z(p)where c->'colors'->>z.p=col)<>1 then color_ok:=false;end if;end loop;
end loop;
if solution is null then if countparts<>1 then raise exception 'Фигура должна быть связна по сторонам';end if;return jsonb_build_object('status','valid');end if;
signature:=(select coalesce(string_agg(z.p,';'order by z.p collate "C"),'')from unnest(removed)z(p))||':'||(select coalesce(string_agg(z.p,'/'order by z.p collate "C"),'')from unnest(partitions)z(p));
st:='yes';if countparts<>np or cardinality(removed)<>remove_count or not color_ok or(select count(distinct z.p)from unnest(shapes)z(p))<minimum then st:='no';end if;
if rule='congruent'and(select count(distinct z.p)from unnest(shapes)z(p))<>1 or rule='equal_area'and(select count(distinct z.p)from unnest(areas)z(p))<>1 or rule='distinct'and(select count(distinct z.p)from unnest(shapes)z(p))<>np then st:='no';end if;
if rule='manual'then st:='pending';end if;return jsonb_build_object('status',st,'signature',signature);end $$;
create or replace function public.mg_cut_check(c jsonb,solution jsonb)returns text language plpgsql immutable set search_path=''as $$
declare result jsonb;variants jsonb;v jsonb;ways int:=coalesce((c->>'ways')::int,1);signatures text[]:='{}';st text:='yes';begin
perform public.mg_cut_variant(c,null);if solution is null then return 'valid';end if;
if solution?'variants'then if solution?'cuts'then raise exception 'Не смешивайте форматы решения';end if;variants:=solution->'variants';else if ways<>1 then raise exception 'Нужно отправить % способов',ways;end if;variants:=jsonb_build_array(solution);end if;
if jsonb_typeof(variants)is distinct from 'array'or jsonb_array_length(variants)<>ways then raise exception 'Нужно отправить % способов',ways;end if;
for v in select *from jsonb_array_elements(variants)loop
result:=public.mg_cut_variant(c,v);if result->>'status'='no'or result->>'signature'=any(signatures)then st:='no';end if;signatures:=array_append(signatures,result->>'signature');end loop;
if c->>'rule'='manual'then return 'pending';end if;return st;end $$;
revoke all on function public.mg_cut_variant(jsonb,jsonb)from public,anon,authenticated;
commit;
