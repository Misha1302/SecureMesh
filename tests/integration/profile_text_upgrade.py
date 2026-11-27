#!/usr/bin/env python3
"""Check the profile-text migration on real accounts created by a previous API build.

Run after make bootstrap and dotnet build. Pass the directory containing the
previous SecureMesh.Api.dll and its runtime dependencies as the only argument.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

import delivery as d
import process_spike
from directory import establish
from profile_text import verify


def upgrade(previous_api: Path):
    repo = d.ROOT
    current = repo / 'src/SecureMesh.Api/bin/Debug/net10.0'
    for build in (previous_api, current):
        if not (build / 'SecureMesh.Api.dll').is_file():
            raise FileNotFoundError(build / 'SecureMesh.Api.dll')

    database = 'securemesh_profile_upgrade_' + uuid.uuid4().hex

    def pg(*args):
        return subprocess.check_output(
            ['docker', 'compose', 'exec', '-T', 'db', *args], cwd=repo, text=True).strip()

    def scalar(sql):
        return pg('psql', '-U', 'securemesh', '-d', database, '-v', 'ON_ERROR_STOP=1', '-Atc', sql)

    pg('createdb', '-U', 'securemesh', database)
    try:
        with tempfile.TemporaryDirectory(dir=repo / '.local', prefix='profile-upgrade-') as tmp:
            scratch = Path(tmp)
            d.ROOT = scratch
            d.BASE = 'https://127.0.0.1:5198'
            local = scratch / '.local'
            local.mkdir()
            for name in ('tls.pem', 'tls.key'):
                (local / name).symlink_to(repo / '.local' / name)
            (scratch / '.env').symlink_to(repo / '.env')
            (scratch / 'src').mkdir()
            target = Path(os.environ.get('CARGO_TARGET_DIR', repo / 'src/crypto_core/target'))
            process_spike.BIN = (target / 'debug/securemesh-crypto').resolve(strict=True)
            validator = scratch / 'src/crypto_core/target/debug/securemesh-crypto'
            validator.parent.mkdir(parents=True)
            validator.symlink_to(process_spike.BIN)
            executable = scratch / 'src/SecureMesh.Api/bin/Debug/net10.0'
            executable.parent.mkdir(parents=True)
            executable.symlink_to(previous_api)
            with d.Server(database=database, legacy_bootstrap=False):
                assert scalar("SELECT count(*) FROM information_schema.columns WHERE "
                              "table_name='users' AND column_name='bio'") == '0'
                owner, peer, outsider = [d.account(scratch) for _ in range(3)]
                owner['device'].pin(peer['device'])
                peer['device'].pin(owner['device'])
                group = establish(owner, peer)
                pending = d.login(outsider['username'], outsider['password'], d.Device(scratch))

            executable.unlink()
            executable.symlink_to(current)
            with d.Server(database=database, legacy_bootstrap=False) as server:
                owner_token, peer_token, outsider_token = [
                    account['session']['accessToken'] for account in (owner, peer, outsider)]
                verify(d.request, owner_token, peer_token, outsider_token, pending['accessToken'],
                       group, owner['device'].identity)
                server.restart()
                assert d.request('/v1/users/me/profile-text', token=owner_token)['revision'] == 2
                assert scalar('SELECT count(*) FROM "__EFMigrationsHistory" WHERE '
                              '"MigrationId"=\'202611270015_ProfileText\'') == '1'
                print('PASS old accounts, sessions and established chat survived the additive '
                      'migration; scoped profile disclosure, concurrent edits and restart verified.')
    finally:
        d.ROOT = repo
        pg('dropdb', '-U', 'securemesh', database)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('previous_api', type=Path)
    upgrade(parser.parse_args().previous_api.resolve())
