from pathlib import Path
import sys
root=Path(__file__).parent
resolver='ng_files_access' if '--new' in sys.argv else 'mg_files_access'
# Deployment bundle is generated from one maintained handler; no duplicate implementation.
print((root/'game-files-core.ts').read_text().replace('export function gameFilesHandler','function gameFilesHandler'))
print('Deno.serve(gameFilesHandler('+repr(resolver)+'));')
