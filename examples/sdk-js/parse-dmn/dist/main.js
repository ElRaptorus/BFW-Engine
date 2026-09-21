import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { parseDmn } from '@elraptorus/bfw_engine_sdk';
export function main() {
    const decisionModelFilePath = resolve(import.meta.dirname, '../dmn/sample.dmn');
    const dmnXml = readFileSync(decisionModelFilePath, 'utf8');
    const definitions = parseDmn(dmnXml);
    console.log(`DMN Definitions: ${definitions.name ?? definitions.id}`);
    console.log(`  Decisions: ${definitions.decisions.length}`);
    for (const decision of definitions.decisions) {
        console.log(`\n  Decision: ${decision.name ?? decision.id}`);
        const expression = decision.expression;
        if (!expression || !('hitPolicy' in expression))
            continue;
        const table = expression;
        console.log(`    Hit Policy: ${table.hitPolicy}`);
        console.log(`    Inputs:  ${table.inputs.map((input) => input.label ?? input.id).join(', ')}`);
        console.log(`    Outputs: ${table.outputs.map((output) => output.label ?? output.name ?? output.id).join(', ')}`);
        console.log(`    Rules:   ${table.rules.length}`);
        for (const rule of table.rules) {
            const inputTexts = rule.inputEntries.map((entry) => entry.text).join(' | ');
            const outputTexts = rule.outputEntries.map((entry) => entry.text).join(' | ');
            console.log(`      ${rule.id}: [${inputTexts}] → [${outputTexts}]`);
        }
    }
}
main();
