#!/usr/bin/env bash
# SPEC-h9k5: a Codex loop run starts no turn of its own, and a restricted one has
# no command tool. A stub `codex` records each launch and renders a tool list.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-env.sh"
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch
import json, os, subprocess, sys, tempfile, tomllib

source = Path(sys.argv[1])
os.environ.pop('NOGG_STARTUP_LOG', None)
wrapper = source / 'scripts/session-launch'

STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
state = pathlib.Path(os.environ["STUB_STATE"])
args = sys.argv[1:]
if args == ["--help"]:
    print("Usage: codex [OPTIONS]")
    sys.exit(0)
if args[:2] == ["mcp", "list"]:
    print((state / "mcp").read_text())
    sys.exit(0)
if args[:2] != ["debug", "prompt-input"]:
    with (state / "launches").open("a") as log:
        log.write(json.dumps(args) + "\n")
    sys.exit(0)
with (state / "renders").open("a") as log:
    log.write(json.dumps(args) + "\n")
mode = (state / "mode").read_text().strip()
if mode == "fail":
    print("Error: unknown subcommand", file=sys.stderr)
    sys.exit(2)
if mode == "garbage":
    print("not json")
    sys.exit(0)
disabled = [args[i + 1] for i, arg in enumerate(args) if arg == "--disable"]
nested = ["apply_patch", "view_image"]
if mode == "no-list":
    print(json.dumps([{"type": "message", "role": "user", "content": []}]))
    sys.exit(0)
if mode != "renamed" and (mode == "leaky" or "shell_tool" not in disabled):
    nested += ["exec_command", "write_stdin"]
if mode == "fallback" and disabled:
    nested += ["run_anything"]
decls = "\n".join(f"declare const tools: {{ {name}(args: {{}}): Promise<string>; }};" for name in nested)
print(json.dumps([
    {"type": "additional_tools", "role": "developer", "tools": [
        {"type": "namespace", "name": "functions", "tools": [
            {"type": "custom", "name": "exec", "description": "await tools.exec_command(...)\n" + decls},
            {"type": "function", "name": "wait"}]}]},
    {"type": "message", "role": "user", "content": []}]))
'''

with tempfile.TemporaryDirectory(prefix='nogg loop codex ') as td:
    scratch = Path(td)
    bin_dir, state, work = scratch / 'bin', scratch / 'state', scratch / 'work'
    for directory in (bin_dir, state, work):
        directory.mkdir()
    subprocess.run(['git', 'init', '-q', str(work)], check=True)
    stub = bin_dir / 'codex'
    stub.write_text(STUB)
    stub.chmod(0o755)
    env = dict(os.environ, PATH=f'{bin_dir}{os.pathsep}{os.environ["PATH"]}', STUB_STATE=str(state))
    loop_text = 'Loop rules: "quoted", \\backslash, ümlaut, del \x7f\nsecond line\n'
    features = ['shell_tool', 'unified_exec', 'apps', 'plugins', 'browser_use', 'computer_use']
    prompt = scratch / 'loop.md'
    prompt.write_text(loop_text, encoding='utf-8')

    def launch(*extra, mode='sound', agent='codex', prompt_path=prompt, mcp='[]'):
        (state / 'mode').write_text(mode)
        (state / 'mcp').write_text(mcp)
        (state / 'launches').write_text('')
        (state / 'renders').write_text('')
        argv = [str(wrapper), '--agent', agent, '--sandbox', 'workspace-write', '--approval', 'on-request',
                '--network', 'off', '--writable-roots', '[]', '--prompt', str(prompt_path), '--cwd', str(work)]
        result = subprocess.run(argv + list(extra), env=env, capture_output=True, text=True)
        rows = (state / 'launches').read_text().splitlines()
        return result, [json.loads(row) for row in rows]

    def flag_values(argv, flag):
        return [argv[i + 1] for i, arg in enumerate(argv) if arg == flag]

    def instructions(argv):
        found = [v for v in flag_values(argv, '-c') if v.startswith('developer_instructions=')]
        assert len(found) == 1, argv
        return tomllib.loads(found[0])['developer_instructions']

    # --- restricted: no command tool, no turn of its own -------------------
    result, launches = launch('--read-only', '--instructions-only', '--no-commands')
    assert result.returncode == 0, result.stderr
    assert len(launches) == 1, launches
    argv = launches[0]
    assert flag_values(argv, '--disable') == features, argv
    assert flag_values(argv, '--sandbox') == ['read-only'], argv
    assert '--add-dir' not in argv, argv
    assert instructions(argv) == loop_text
    assert 'no command tools' in result.stdout
    # Every argument is a flag or its value: nothing could start a turn.
    assert argv[-2] == '-c' and argv[-1].startswith('developer_instructions='), argv

    # --- the proof is for the model the run will use ------------------------
    result, launches = launch('--read-only', '--no-commands', '--model', 'gpt-test')
    assert result.returncode == 0, result.stderr
    renders = [json.loads(row) for row in (state / 'renders').read_text().splitlines()]
    assert len(renders) == 2 and all(flag_values(row, '-c') == ['model="gpt-test"'] for row in renders), renders
    assert flag_values(renders[0], '--disable') == [] and flag_values(renders[1], '--disable') == features, renders
    assert flag_values(launches[0], '--model') == ['gpt-test'], launches

    # --- trusted: commands stay, the first turn is still the kickoff -------
    result, launches = launch('--instructions-only')
    assert result.returncode == 0, result.stderr
    argv = launches[0]
    assert '--disable' not in argv and flag_values(argv, '--sandbox') == ['workspace-write'], argv
    assert instructions(argv) == loop_text
    assert argv[-2] == '-c', argv

    # --- every other Codex launch keeps its positional startup prompt ------
    result, launches = launch('--bead', 'SPEC-x')
    assert result.returncode == 0, result.stderr
    argv = launches[0]
    assert '--disable' not in argv and not flag_values(argv, '-c')[-1].startswith('developer_instructions='), argv
    assert argv[-1].startswith('Startup only:') and loop_text.strip() in argv[-1], argv

    # --- an unproven removal never starts the agent ------------------------
    for mode, expected in (('leaky', 'exec_command, write_stdin'), ('renamed', 'cannot find the command tool'),
                           ('no-list', 'cannot find the command tool'), ('fallback', 'run_anything'),
                           ('fail', 'cannot read `codex debug prompt-input`'),
                           ('garbage', 'cannot read `codex debug prompt-input`')):
        result, launches = launch('--read-only', '--instructions-only', '--no-commands', mode=mode)
        assert result.returncode != 0, mode
        assert expected in result.stderr, (mode, result.stderr)
        assert launches == [], (mode, launches)

    # --- an MCP server is invisible to the proof, so it refuses -------------
    enabled = json.dumps([{'name': 'off', 'enabled': False}, {'name': 'demo', 'enabled': True}])
    result, launches = launch('--read-only', '--no-commands', mcp=enabled)
    assert result.returncode != 0 and 'MCP servers enabled (demo)' in result.stderr, result.stderr
    assert launches == [] and (state / 'renders').read_text() == '', 'a render started the MCP server'
    result, launches = launch('--read-only', '--no-commands', mcp=json.dumps([{'name': 'off', 'enabled': False}]))
    assert result.returncode == 0 and len(launches) == 1, result.stderr
    result, launches = launch('--read-only', '--no-commands', mcp='not json')
    assert result.returncode != 0 and 'cannot read `codex mcp list`' in result.stderr, result.stderr
    assert launches == []

    # --- no commands needs the read-only sandbox, or apply_patch writes unasked
    result, launches = launch('--no-commands')
    assert result.returncode == 2 and 'read-only sandbox' in result.stderr, result.stderr
    assert launches == []

    # --- the flags are Codex-only and take no resume or missing prompt -----
    for flag in ('--instructions-only', '--no-commands'):
        result, launches = launch(flag, agent='claude')
        assert result.returncode == 2 and 'Codex-only' in result.stderr, result.stderr
        assert launches == []
        result, launches = launch(flag, '--resume', '01a18e08-9b8e-7f03-ab04-9366a7f67526')
        assert result.returncode == 2 and 'no --resume' in result.stderr, result.stderr
        assert launches == []
    result, launches = launch('--instructions-only', prompt_path=scratch / 'absent.md')
    assert result.returncode == 2 and 'readable --prompt' in result.stderr, result.stderr
    assert launches == []

    # --- the contract names both flags, so an older wrapper is refused -----
    contract = json.loads(subprocess.run([str(wrapper), '--contract'], capture_output=True, text=True).stdout)
    assert contract['options']['--instructions-only'] == 0 and contract['options']['--no-commands'] == 0

    # --- the verification itself, against a timeout -------------------------
    os.environ['NOGGING_ROOT'] = str(source)
    m = SourceFileLoader('loop_codex', str(source / 'scripts/nogg')).load_module()
    with patch.object(m.subprocess, 'run', side_effect=m.subprocess.TimeoutExpired('codex', 30)):
        try:
            m.verify_codex_no_commands(str(work))
        except RuntimeError as exc:
            assert 'cannot read `codex mcp list`' in str(exc)
        else:
            raise AssertionError('a hung Codex call was accepted')
print('loop-codex-launch: ok')
PY
