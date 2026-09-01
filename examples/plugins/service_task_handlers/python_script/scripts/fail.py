import json
import sys

json.load(sys.stdin)
print("intentional failure", file=sys.stderr)
sys.exit(1)
