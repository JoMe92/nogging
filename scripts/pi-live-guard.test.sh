#!/usr/bin/env bash
# Optional offline integration with the actual installed Pi loader and wrapper.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v pi >/dev/null; then
  echo 'SKIP: actual Pi guard activation (Pi CLI unavailable)'
  exit 0
fi
python3 - "$root" "$(command -v pi)" <<'PY'
from pathlib import Path
import tempfile, subprocess, os, json, sys
source, runtime = Path(sys.argv[1]), str(Path(sys.argv[2]).absolute())
with tempfile.TemporaryDirectory(prefix='nogg Pi live guard ') as directory:
    scratch = Path(directory)
    main, linked = scratch/'main checkout', scratch/'linked checkout'
    main.mkdir()
    subprocess.run(['git', 'init', '-q', str(main)], check=True)
    for relative in ['scripts/nogg', '.pi/extensions/nogging-guard.ts', '.nogging/config.json']:
        target = main/relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((source/relative).read_bytes())
    subprocess.run(['git', '-C', str(main), 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(main), '-c', 'user.name=Fixture', '-c',
                    'user.email=fixture@example.invalid', 'commit', '-qm', 'seed'], check=True)
    subprocess.run(['git', '-C', str(main), 'worktree', 'add', '-q', '--detach', str(linked)], check=True)
    verifier, result, agent_dir = scratch/'verify.ts', scratch/'result.json', scratch/'agent'
    agent_dir.mkdir()
    verifier.write_text('''import guard from %s;
import {writeFileSync} from "node:fs";
export default async function(pi) {
 let handler; guard({on(event, fn) {handler=fn;}});
 const ctx={cwd:process.cwd(),hasUI:false};
 const write=await handler({toolName:"write",input:{path:"openspec/test.md"}},ctx);
 const floor=await handler({toolName:"bash",input:{command:"sudo true"}},ctx);
 if (!write?.block || !floor?.block) throw new Error("guard did not block");
 writeFileSync(process.env.NOGG_VERIFY_RESULT, JSON.stringify({write:write.block,floor:floor.block,role:process.env.NOGG_SESSION_ROLE}));
}
''' % json.dumps(str(linked/'.pi/extensions/nogging-guard.ts')))
    binaries = scratch/'bin'
    binaries.mkdir()
    proxy = binaries/'pi'
    proxy.write_text('''#!/usr/bin/env python3
import os,sys
os.execv(os.environ['NOGG_REAL_PI'], [os.environ['NOGG_REAL_PI'], *sys.argv[1:],
 '--extension',os.environ['NOGG_VERIFY_EXTENSION'],'--offline','--mode','rpc','--no-session'])
''')
    proxy.chmod(0o755)
    env = os.environ.copy()
    for key in ['NOGGING_ROOT','NOGG_STARTUP_LOG']:
        env.pop(key, None)
    env.update(PI_CODING_AGENT_DIR=str(agent_dir), PI_OFFLINE='1', NOGG_SESSION_ROLE='lead',
               NOGG_VERIFY_RESULT=str(result), NOGG_VERIFY_EXTENSION=str(verifier), NOGG_REAL_PI=runtime,
               PATH=str(binaries)+os.pathsep+env['PATH'])
    launched = subprocess.run([str(source/'scripts/session-launch'), '--agent', 'pi',
                              '--cwd', str(linked), '--bead', 'SPEC-fixture'],
                             env=env, input='', text=True, capture_output=True, timeout=20)
    assert result.exists(), 'actual Pi did not execute the explicit guard verifier'
    assert json.loads(result.read_text()) == {'write':True,'floor':True,'role':'lead'}
    assert not (agent_dir/'trust.json').exists(), 'launch created standing trust'
    result.unlink()
    guard_path = linked/'.pi/extensions/nogging-guard.ts'
    guard_path.rename(guard_path.with_suffix('.disabled'))
    refused = subprocess.run([str(source/'scripts/session-launch'), '--agent', 'pi',
                              '--cwd', str(linked), '--bead', 'SPEC-fixture'],
                             env=env, input='', text=True, capture_output=True, timeout=5)
    assert refused.returncode == 2 and not result.exists()
    assert 'Pi guard is missing' in refused.stderr
    print('Actual Pi supervised wrapper: fresh linked worktree guard loaded, execution writes/floor blocked, no standing trust created')
PY
