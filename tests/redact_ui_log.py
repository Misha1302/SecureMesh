import sys
for line in sys.stdin:
    if 'VM service' in line or 'DevTools' in line:
        print('Local debug endpoint started (address redacted)',flush=True)
    else:print(line.rstrip(),flush=True)
