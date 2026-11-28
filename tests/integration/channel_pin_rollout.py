#!/usr/bin/env python3
"""Exercise pre-pin and pin-only API artifacts against additive migrations and restore."""
import argparse
import os
import subprocess
import tempfile
import uuid
from pathlib import Path

import delivery as d
from private_blobs import database, postgres


def sql(db, statement):
    return postgres('psql', '-U', 'securemesh', '-d', db, '-v', 'ON_ERROR_STOP=1',
                    '-Atc', statement, stdout=subprocess.PIPE, text=True).stdout.strip()


def publish(posts, token, body):
    return d.request(posts, {'requestId': str(uuid.uuid4()), 'body': body}, token=token,
                     expected=201)['seq']


def pin(route, token, revision, sequence):
    d.request(route, {'expectedRevision': revision, 'seq': sequence}, method='PUT',
              token=token, expected=204)


def check_feed(posts, token, revision, pinned):
    feed = d.request(posts, token=token)
    assert feed['pinRevision'] == revision
    assert feed['pinned'] == pinned
    return feed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pre-pin', type=Path, required=True, help='API built before migration 112')
    parser.add_argument('--pin-only', type=Path, required=True, help='API built with migration 112 and without 113')
    args = parser.parse_args()
    d.BASE = os.environ.get('SECUREMESH_TEST_URLS', 'https://127.0.0.1:5099')
    room = str(uuid.uuid4())
    route = '/v1/public-channels/' + room
    posts = route + '/posts'
    pin_route = route + '/pin'

    with database() as db, database() as restored, tempfile.TemporaryDirectory() as work:
        with d.Server(db, api_dll=args.pre_pin):
            token = d.account(Path(work))['session']['accessToken']
            d.request('/v1/public-channels', {'id': room, 'slug': 'pin_' + room[:8],
                      'title': 'Pin rollout'}, token=token, expected=201)
            first = publish(posts, token, 'Post from pre-pin release')
            assert 'pinRevision' not in d.request(posts, token=token)
            d.request(pin_route, {'expectedRevision': 0, 'seq': first}, method='PUT',
                      token=token, expected=404)
            assert sql(db, 'SELECT count(*) FROM information_schema.columns '
                           "WHERE table_name='channel_catalog' AND column_name='pinned_seq'") == '0'

        # Reproduce the stale FK state on the historical release that first added pins.
        with d.Server(db, api_dll=args.pin_only):
            assert check_feed(posts, token, 0, None)['items'][0]['seq'] == first
            pin(pin_route, token, 0, first)
        with d.Server(db, api_dll=args.pre_pin):
            d.request(f'{posts}/{first}', token=token, method='DELETE', expected=204)
            assert sql(db, f"SELECT pinned_seq || ':' || pin_revision FROM channel_catalog WHERE id='{room}'") == f'{first}:1'

        with d.Server(db):
            check_feed(posts, token, 2, None)
            second = publish(posts, token, 'Post pinned before rollback')
            pin(pin_route, token, 2, second)
        with d.Server(db, api_dll=args.pre_pin):
            for _ in range(2):
                d.request(f'{posts}/{second}', token=token, method='DELETE', expected=204)
            assert sql(db, f"SELECT pinned_seq IS NULL AND pin_revision=4 FROM channel_catalog WHERE id='{room}'") == 't'
            sql(db, f"UPDATE public_channel_posts SET deleted_at=now()-interval '2 days' WHERE seq IN ({first},{second})")
            third = publish(posts, token, 'Rollback publish purges day-old tombstones')
            assert sql(db, f'SELECT count(*) FROM public_channel_posts WHERE seq IN ({first},{second})') == '0'

        with d.Server(db):
            check_feed(posts, token, 4, None)
            pin(pin_route, token, 4, third)
            with tempfile.TemporaryFile() as dump:
                postgres('pg_dump', '-U', 'securemesh', '-d', db, '-Fc', stdout=dump)
                dump.seek(0)
                postgres('pg_restore', '-U', 'securemesh', '-d', restored, '--no-owner',
                         '--exit-on-error', stdin=dump)

        with d.Server(restored):
            check_feed(posts, token, 5, {'seq': third, 'body': 'Rollback publish purges day-old tombstones'})
        with d.Server(restored, api_dll=args.pre_pin):
            d.request(f'{posts}/{third}', token=token, method='DELETE', expected=204)
        with d.Server(restored):
            check_feed(posts, token, 6, None)
            fourth = publish(posts, token, 'Post permanently deleted while pinned')
            pin(pin_route, token, 6, fourth)
            sql(restored, f'DELETE FROM public_channel_posts WHERE seq={fourth}')
            check_feed(posts, token, 8, None)
            fifth = publish(posts, token, 'Post removed with the channel')
            pin(pin_route, token, 8, fifth)
            d.request(route, token=token, method='DELETE', expected=204)

    print('PASS channel pin mixed-version upgrade, backfill, rollback, tombstone purge and restore')


if __name__ == '__main__':
    main()
