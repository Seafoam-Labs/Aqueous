#!/usr/bin/env python3
import json,sys,time
mode=sys.argv[1]
if mode == 'malformed':
    print('this is not json')
elif mode == 'failure':
    print(json.dumps(dict(ok=False,code='external_change',message='Changed externally')))
    sys.exit(1)
elif mode == 'delay':
    time.sleep(2)
    print(json.dumps(dict(ok=True,protocol=1,helper_version='0.7.0',generation='delayed')))
elif mode == 'old':
    print(json.dumps(dict(ok=True,protocol=1,helper_version='0.6.0')))
else:
    data=json.load(sys.stdin) if '--request' in sys.argv else None
    print(json.dumps(dict(ok=True,protocol=1,helper_version='0.7.0',generation='new',request=data)))
