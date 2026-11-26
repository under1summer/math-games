// Existing game-files endpoint: same shared handler and legacy capability resolver.
import {gameFilesHandler} from './game-files-core.ts';
Deno.serve(gameFilesHandler());
