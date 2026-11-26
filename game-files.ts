// Supabase Edge Function: game-files. verify_jwt=true. Gateway JWT + mandatory game capability authentication.
// Service credentials are provided by Supabase runtime only, never sent to the browser.
import { createClient } from 'npm:@supabase/supabase-js@2';
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
const bucket=db.storage.from('game-solutions');
const headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'content-type, apikey, authorization','Access-Control-Allow-Methods':'POST, OPTIONS','Cache-Control':'no-store'};
const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...headers,'Content-Type':'application/json'}});
async function access(op:string,k:string,g:string|null,t:string,p:unknown={}){const{data,error}=await db.rpc('mg_files_access',{op,k,g,t,p});if(error)throw Error(error.message);return data}
function mime(bytes:Uint8Array):string{if(bytes[0]===255&&bytes[1]===216&&bytes[2]===255)return'image/jpeg';if(bytes.slice(0,8).join(',')==='137,80,78,71,13,10,26,10')return'image/png';if(new TextDecoder().decode(bytes.slice(0,5))==='%PDF-')return'application/pdf';if(new TextDecoder().decode(bytes.slice(4,8))==='ftyp'){const brand=new TextDecoder().decode(bytes.slice(8,40));if(/heic|heix|hevc|hevx|mif1|msf1/.test(brand))return'image/heic'}throw Error('Содержимое файла не соответствует JPG, PNG, HEIC или PDF')}
Deno.serve(async req=>{if(req.method==='OPTIONS')return new Response('ok',{headers});if(req.method!=='POST')return reply({error:'POST required'},405);try{
if((req.headers.get('content-type')||'').includes('multipart/form-data')){
 const form=await req.formData(),file=form.get('file');if(!(file instanceof File)||file.size<1||file.size>20971520)throw Error('Файл: до 20 МБ');
 const k=String(form.get('kind')||''),g=String(form.get('game')||''),token=String(form.get('token')||''),bytes=new Uint8Array(await file.arrayBuffer()),type=mime(bytes);
 const record=await access('upload',k,g,token,{code:String(form.get('code')),team:form.get('team'),name:file.name,mime:type,size:bytes.length});
 const{error}=await bucket.upload(record.path,bytes,{contentType:type,upsert:false,cacheControl:'0'});if(error)throw Error('Storage: '+error.message);
 await access('ready',k,g,token,{id:record.id});return reply({id:record.id,name:record.name,mime:type,size:record.size});
}
const p=await req.json();if(p.op==='cleanup'){
 const rows=await access('cleanup','',null,p.token);if(rows.length){const{error}=await bucket.remove(rows.map((r:{path:string})=>r.path));if(error)throw Error(error.message);await access('purged','',null,p.token,{ids:rows.map((r:{id:string})=>r.id)})}return reply({removed:rows.length});
}
if(p.op==='get'||p.op==='discard'){
 const row=await access(p.op,p.kind,p.game,p.token,{id:p.id});if(p.op==='discard'){const{error}=await bucket.remove([row.path]);if(error)throw Error(error.message);return reply({ok:true})}
 const{data,error}=await bucket.createSignedUrl(row.path,60,{download:p.download?row.name:false});if(error)throw Error(error.message);return reply({url:data.signedUrl,name:row.name,mime:row.mime,size:row.size});
}throw Error('Неизвестное действие');
}catch(e){return reply({error:e instanceof Error?e.message:'Ошибка вложения'},400)}});
