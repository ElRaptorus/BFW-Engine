const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
process.stdout.write(JSON.stringify({ handled_by: "node_script", input: data }));
