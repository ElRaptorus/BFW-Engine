import json
import sys

data = json.load(sys.stdin)
data["transformed"] = True
data["total"] = data.get("quantity", 0) * data.get("price", 0)
json.dump(data, sys.stdout)
