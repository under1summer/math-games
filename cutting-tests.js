/* Run after cutting.js in a JS runtime with window. */
(function(){
var M=window.TaskModules.registry.get('cutting');var c={width:3,height:2,cells:[[0,0],[1,0],[2,0],[0,1],[1,1],[2,1]],parts:2,rule:'congruent'};if(M.check(c,{cuts:['0,0|0,1','1,0|1,1','2,0|2,1']}).status!=='yes')throw Error('congruent');if(M.check(c,{cuts:[]}).status!=='no')throw Error('part count');if(M.shape([[0,0],[1,0],[1,1]])!==M.shape([[3,3],[3,4],[2,4]]))throw Error('rotation/reflection');c.rule='distinct';if(M.check(c,{cuts:['0,0|1,0','0,1|1,1']}).status!=='yes')throw Error('distinct');var disconnected=false;try{M.validate({width:3,height:3,cells:[[0,0],[1,1]],parts:2,rule:'manual'})}catch(e){disconnected=true}if(!disconnected)throw Error('connectivity'); 'Cutting algorithms PASS';
})();
