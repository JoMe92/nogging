#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import base64, contextlib, importlib.machinery, importlib.util, io, json, pathlib, subprocess, sys, tempfile
from unittest.mock import patch
loader = importlib.machinery.SourceFileLoader('nogg_credentials', 'scripts/nogg')
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = m
loader.exec_module(m)
with tempfile.TemporaryDirectory() as tmp:
    key = pathlib.Path(tmp) / 'app.pem'
    subprocess.run(['openssl', 'genrsa', '-out', str(key), '2048'], check=True, capture_output=True)
    m.CFG = {'personas': {'lead': {'github_app': {'app_id': 42, 'private_key_path': str(key)}}}}
    real_run = subprocess.run
    requests = []
    def run(args, **kwargs):
        if args[0] == 'git':
            return subprocess.CompletedProcess(args, 0, 'git@github.com:owner/repo.git\n', '')
        return real_run(args, **kwargs)
    class Opener:
        def open(self, request, timeout):
            requests.append(request)
            jwt = request.get_header('Authorization').split()[1]
            header, payload, signature = jwt.split('.')
            claims = json.loads(base64.urlsafe_b64decode(payload + '==='))
            assert claims['iss'] == '42' and claims['exp'] - claims['iat'] == 600
            sig = pathlib.Path(tmp) / 'signature'
            pub = pathlib.Path(tmp) / 'public.pem'
            sig.write_bytes(base64.urlsafe_b64decode(signature + '==='))
            pub.write_bytes(real_run(['openssl', 'rsa', '-in', str(key), '-pubout'], capture_output=True, check=True).stdout)
            real_run(['openssl', 'dgst', '-sha256', '-verify', str(pub), '-signature', str(sig)], input=(header+'.'+payload).encode(), capture_output=True, check=True)
            if request.data is not None:
                assert json.loads(request.data) == {'repositories': ['repo']}
                assert request.full_url.endswith('/app/installations/7/access_tokens')
                return io.StringIO('{"token":"synthetic-test-value"}')
            assert request.full_url == 'https://api.github.com/repos/owner/repo/installation'
            return io.StringIO('{"id":7}')
    def invoke(operation='get', request='protocol=https\nhost=github.com\n\n', fails=False):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(sys, 'stdin', io.StringIO(request)), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                m.credential_helper('lead', operation)
                assert not fails
            except SystemExit as exc:
                assert fails and exc.code == 1
        if fails:
            assert out.getvalue() == '' and err.getvalue() == 'nogg: credential-helper failed; no credential returned\n'
        return out.getvalue()
    with patch.object(m.subprocess, 'run', run), patch.object(m.urllib.request, 'build_opener', return_value=Opener()):
        for _ in range(2):
            assert invoke() == 'username=x-access-token\npassword=synthetic-test-value\n\n'
        assert len(requests) == 4
        assert invoke('store') == '' and invoke('erase') == ''
        invoke(request='protocol=https\nhost=attacker.example\n\n', fails=True)
        invoke(request='protocol=http\nhost=github.com\n\n', fails=True)
        invoke(request='protocol=https\nhost=github.com\npath=other/repo\n\n', fails=True)
        with patch.object(Opener, 'open', side_effect=RuntimeError('secret-response')):
            invoke(fails=True)
        key.unlink()
        invoke(fails=True)
print('credential-helper protocol, real RS256 signing, isolation and failure checks passed')
PY
