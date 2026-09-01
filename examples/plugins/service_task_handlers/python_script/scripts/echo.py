import json
import sys

data = json.load(sys.stdin)
json.dump({"handled_by": "python_script", "input": data}, sys.stdout)
