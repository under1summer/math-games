// New endpoint only. Leaves the existing deployed game-files endpoint unchanged.
import {gameFilesHandler} from './game-files-core.ts';
Deno.serve(gameFilesHandler('ng_files_access'));
