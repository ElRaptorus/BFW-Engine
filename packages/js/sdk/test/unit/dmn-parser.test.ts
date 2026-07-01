/**
 * Unit tests for the SDK DMN parser: decision tables, hit policies,
 * information requirements, and edge cases for literal text in cells.
 */
import { describe, expect, it } from 'vitest';

import { DmnHitPolicy, parseDmn } from '../../src/index.js';
import type {
  DmnBoxedConditional,
  DmnBoxedContext,
  DmnBoxedEvery,
  DmnBoxedFilter,
  DmnBoxedFor,
  DmnBoxedInvocation,
  DmnBoxedList,
  DmnBoxedSome,
  DmnDecisionTable,
  DmnDefinitions,
  DmnLiteralExpression,
  DmnRelation,
} from '../../src/index.js';

function minimalDefinitions(inner: string, definitionsAttributes = ''): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL"
  id="definitions_1" name="Test Definitions"${definitionsAttributes}>
${inner}
</definitions>`;
}

describe('parseDmn', () => {
  describe('simple single-input, single-output decision table', () => {
    it('parses UNIQUE hit policy with exactly one rule', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_single" name="Single rule discount">
    <decisionTable id="dt_single" hitPolicy="UNIQUE">
      <input id="input_1" label="Customer Type">
        <inputExpression typeRef="string"><text>customerType</text></inputExpression>
      </input>
      <output id="output_1" label="Discount" name="discount" typeRef="number" />
      <rule id="rule_1">
        <inputEntry id="ie_1"><text>"gold"</text></inputEntry>
        <outputEntry id="oe_1"><text>0.15</text></outputEntry>
      </rule>
    </decisionTable>
  </decision>
`);

      const definitions: DmnDefinitions = parseDmn(xml);
      const table = definitions.decisions[0]!.expression as DmnDecisionTable;
      expect(table.hitPolicy).toBe(DmnHitPolicy.Unique);
      expect(table.rules).toHaveLength(1);
      expect(table.rules[0]!.inputEntries[0]!.text).toBe('"gold"');
      expect(table.rules[0]!.outputEntries[0]!.text).toBe('0.15');
    });

    it('parses UNIQUE hit policy with multiple rules', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_1" name="Discount">
    <decisionTable id="dt_1" hitPolicy="UNIQUE">
      <input id="input_1" label="Customer Type">
        <inputExpression typeRef="string"><text>customerType</text></inputExpression>
      </input>
      <output id="output_1" label="Discount" name="discount" typeRef="number" />
      <rule id="rule_1">
        <inputEntry id="ie_1"><text>"gold"</text></inputEntry>
        <outputEntry id="oe_1"><text>0.15</text></outputEntry>
      </rule>
      <rule id="rule_2">
        <inputEntry id="ie_2"><text>"silver"</text></inputEntry>
        <outputEntry id="oe_2"><text>0.10</text></outputEntry>
      </rule>
    </decisionTable>
  </decision>
`);

      const definitions: DmnDefinitions = parseDmn(xml);
      expect(definitions.decisions).toHaveLength(1);
      const decision = definitions.decisions[0]!;
      expect(decision.id).toBe('Decision_1');
      expect(decision.name).toBe('Discount');
      expect(decision.outputLabel).toBeNull();

      const table = decision.expression as DmnDecisionTable;
      expect(table.id).toBe('dt_1');
      expect(table.hitPolicy).toBe(DmnHitPolicy.Unique);
      expect(table.inputs).toHaveLength(1);
      expect(table.outputs).toHaveLength(1);
      expect(table.rules).toHaveLength(2);

      expect(table.inputs[0]!.inputExpression).toBe('customerType');
      expect(table.inputs[0]!.typeRef).toBe('string');
      expect(table.outputs[0]!.name).toBe('discount');
      expect(table.rules[0]!.inputEntries[0]!.text).toBe('"gold"');
      expect(table.rules[0]!.outputEntries[0]!.text).toBe('0.15');
    });
  });

  describe('multi-input, multi-output decision table', () => {
    it('parses several inputs, outputs, and matching rule rows', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_risk" name="Risk score">
    <decisionTable id="dt_risk" hitPolicy="FIRST">
      <input id="in_age" label="Age">
        <inputExpression typeRef="number"><text>applicant.age</text></inputExpression>
      </input>
      <input id="in_income" label="Income">
        <inputExpression typeRef="number"><text>applicant.income</text></inputExpression>
      </input>
      <output id="out_band" label="Band" name="riskBand" typeRef="string" />
      <output id="out_score" label="Score" name="riskScore" typeRef="number" />
      <rule id="r1">
        <inputEntry><text>&gt; 65</text></inputEntry>
        <inputEntry><text>&lt; 20000</text></inputEntry>
        <outputEntry><text>"high"</text></outputEntry>
        <outputEntry><text>90</text></outputEntry>
      </rule>
    </decisionTable>
  </decision>
`);

      const definitions = parseDmn(xml);
      const table = definitions.decisions[0]!.expression as DmnDecisionTable;
      expect(table.inputs).toHaveLength(2);
      expect(table.outputs).toHaveLength(2);
      expect(table.rules[0]!.inputEntries).toHaveLength(2);
      expect(table.rules[0]!.outputEntries).toHaveLength(2);
      expect(table.inputs[0]!.inputExpression).toBe('applicant.age');
      expect(table.inputs[1]!.inputExpression).toBe('applicant.income');
      expect(table.rules[0]!.outputEntries[0]!.text).toBe('"high"');
      expect(table.rules[0]!.outputEntries[1]!.text).toBe('90');
    });
  });

  describe('hit policies', () => {
    const cases: { attribute: string; expected: DmnHitPolicy }[] = [
      { attribute: 'UNIQUE', expected: DmnHitPolicy.Unique },
      { attribute: 'FIRST', expected: DmnHitPolicy.First },
      { attribute: 'ANY', expected: DmnHitPolicy.Any },
      { attribute: 'COLLECT', expected: DmnHitPolicy.Collect },
      { attribute: 'RULE_ORDER', expected: DmnHitPolicy.RuleOrder },
      { attribute: 'OUTPUT_ORDER', expected: DmnHitPolicy.OutputOrder },
      { attribute: 'PRIORITY', expected: DmnHitPolicy.Priority },
    ];

    const abbreviations: { letter: string; expected: DmnHitPolicy }[] = [
      { letter: 'U', expected: DmnHitPolicy.Unique },
      { letter: 'F', expected: DmnHitPolicy.First },
      { letter: 'A', expected: DmnHitPolicy.Any },
      { letter: 'C', expected: DmnHitPolicy.Collect },
      { letter: 'R', expected: DmnHitPolicy.RuleOrder },
      { letter: 'O', expected: DmnHitPolicy.OutputOrder },
      { letter: 'P', expected: DmnHitPolicy.Priority },
    ];

    for (const { letter, expected } of abbreviations) {
      it(`parses single-letter abbreviation "${letter}"`, () => {
        const xml = minimalDefinitions(`
  <decision id="D_abbrev" name="Abbreviated">
    <decisionTable id="dt" hitPolicy="${letter}">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="y" typeRef="string" />
      <rule id="r1">
        <inputEntry><text>true</text></inputEntry>
        <outputEntry><text>"a"</text></outputEntry>
      </rule>
    </decisionTable>
  </decision>
`);
        expect((parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).hitPolicy).toBe(expected);
      });
    }

    for (const { attribute, expected } of cases) {
      it(`parses hitPolicy="${attribute}"`, () => {
        const xml = minimalDefinitions(`
  <decision id="D1" name="Policy ${attribute}">
    <decisionTable id="dt" hitPolicy="${attribute}">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="y" typeRef="string" />
      <rule id="r1">
        <inputEntry><text>true</text></inputEntry>
        <outputEntry><text>"a"</text></outputEntry>
      </rule>
    </decisionTable>
  </decision>
`);
        const table = parseDmn(xml).decisions[0]!.expression as DmnDecisionTable;
        expect(table.hitPolicy).toBe(expected);
      });
    }
  });

  describe('input values (allowed value lists)', () => {
    it('parses inputValues with nested text', () => {
      const xml = minimalDefinitions(`
  <decision id="D1" name="With inputValues">
    <decisionTable id="dt" hitPolicy="UNIQUE">
      <input id="in1" label="Tier">
        <inputExpression typeRef="string"><text>tier</text></inputExpression>
        <inputValues><text>"gold", "silver", "bronze"</text></inputValues>
      </input>
      <output id="o1" name="discount" typeRef="number" />
      <rule id="r1">
        <inputEntry><text>"gold"</text></inputEntry>
        <outputEntry><text>0.2</text></outputEntry>
      </rule>
    </decisionTable>
  </decision>
`);
      const input = (parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).inputs[0]!;
      expect(input.inputValues).toBe('"gold", "silver", "bronze"');
    });
  });

  describe('output values and default output entry', () => {
    it('parses outputValues and defaultOutputEntry', () => {
      const xml = minimalDefinitions(`
  <decision id="D1" name="Defaults">
    <decisionTable id="dt" hitPolicy="UNIQUE">
      <input id="i1"><inputExpression typeRef="boolean"><text>flag</text></inputExpression></input>
      <output id="o1" name="result" typeRef="string">
        <outputValues><text>"yes", "no", "maybe"</text></outputValues>
        <defaultOutputEntry><text>"maybe"</text></defaultOutputEntry>
      </output>
      <rule id="r1">
        <inputEntry><text>true</text></inputEntry>
        <outputEntry><text>"yes"</text></outputEntry>
      </rule>
    </decisionTable>
  </decision>
`);
      const output = (parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).outputs[0]!;
      expect(output.outputValues).toBe('"yes", "no", "maybe"');
      expect(output.defaultOutputValue).toBe('"maybe"');
    });
  });

  describe('multiple decisions', () => {
    it('parses more than one decision under the same definitions', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_A" name="First">
    <decisionTable id="dt_a" hitPolicy="UNIQUE">
      <input id="i"><inputExpression typeRef="string"><text>a</text></inputExpression></input>
      <output id="o" name="out" typeRef="string" />
      <rule id="r"><inputEntry><text>-</text></inputEntry><outputEntry><text>"x"</text></outputEntry></rule>
    </decisionTable>
  </decision>
  <decision id="Decision_B" name="Second">
    <decisionTable id="dt_b" hitPolicy="ANY">
      <input id="i2"><inputExpression typeRef="number"><text>b</text></inputExpression></input>
      <output id="o2" name="out2" typeRef="number" />
      <rule id="r2"><inputEntry><text>1</text></inputEntry><outputEntry><text>2</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      const definitions = parseDmn(xml);
      expect(definitions.decisions).toHaveLength(2);
      expect(definitions.decisions[0]!.id).toBe('Decision_A');
      expect(definitions.decisions[1]!.id).toBe('Decision_B');
      expect((definitions.decisions[0]!.expression as DmnDecisionTable).hitPolicy).toBe(DmnHitPolicy.Unique);
      expect((definitions.decisions[1]!.expression as DmnDecisionTable).hitPolicy).toBe(DmnHitPolicy.Any);
    });
  });

  describe('information requirements', () => {
    it('parses requiredDecision and requiredInput href fragments', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_root" name="Root">
    <informationRequirement id="ir_1">
      <requiredDecision href="#Decision_prior" />
    </informationRequirement>
    <informationRequirement>
      <requiredInput href="#InputData_customer" />
    </informationRequirement>
    <decisionTable id="dt" hitPolicy="UNIQUE">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="y" typeRef="string" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>"z"</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      const requirements = parseDmn(xml).decisions[0]!.informationRequirements;
      expect(requirements).toHaveLength(2);
      expect(requirements[0]!.id).toBe('ir_1');
      expect(requirements[0]!.requiredDecisionId).toBe('Decision_prior');
      expect(requirements[0]!.requiredInputId).toBeNull();
      expect(requirements[1]!.requiredDecisionId).toBeNull();
      expect(requirements[1]!.requiredInputId).toBe('InputData_customer');
    });
  });

  describe('input data at definitions level', () => {
    it('parses inputData with variable typeRef', () => {
      const xml = minimalDefinitions(`
  <inputData id="InputData_customer" name="Customer">
    <variable id="var_c" name="customer" typeRef="string" />
  </inputData>
  <decision id="D1" name="Uses customer">
    <decisionTable id="dt" hitPolicy="UNIQUE">
      <input id="i1"><inputExpression typeRef="string"><text>customer</text></inputExpression></input>
      <output id="o1" name="out" typeRef="string" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>""</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      const definitions = parseDmn(xml);
      expect(definitions.inputData).toHaveLength(1);
      expect(definitions.inputData[0]!.id).toBe('InputData_customer');
      expect(definitions.inputData[0]!.name).toBe('Customer');
      expect(definitions.inputData[0]!.typeRef).toBe('string');
    });
  });

  describe('aggregation on COLLECT', () => {
    it('parses aggregation="COUNT"', () => {
      const xml = minimalDefinitions(`
  <decision id="D_collect_count" name="Count matches">
    <decisionTable id="dt_cc" hitPolicy="COLLECT" aggregation="COUNT">
      <input id="i1"><inputExpression typeRef="boolean"><text>flag</text></inputExpression></input>
      <output id="o1" name="matches" typeRef="number" />
      <rule id="r1"><inputEntry><text>true</text></inputEntry><outputEntry><text>1</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      const table = parseDmn(xml).decisions[0]!.expression as DmnDecisionTable;
      expect(table.hitPolicy).toBe(DmnHitPolicy.Collect);
      expect(table.aggregation).toBe('COUNT');
    });

    it('parses aggregation="SUM"', () => {
      const xml = minimalDefinitions(`
  <decision id="D_collect" name="Sum scores">
    <decisionTable id="dt_c" hitPolicy="COLLECT" aggregation="SUM">
      <input id="i1"><inputExpression typeRef="number"><text>n</text></inputExpression></input>
      <output id="o1" name="total" typeRef="number" />
      <rule id="r1"><inputEntry><text>1</text></inputEntry><outputEntry><text>10</text></outputEntry></rule>
      <rule id="r2"><inputEntry><text>2</text></inputEntry><outputEntry><text>20</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      const table = parseDmn(xml).decisions[0]!.expression as DmnDecisionTable;
      expect(table.hitPolicy).toBe(DmnHitPolicy.Collect);
      expect(table.aggregation).toBe('SUM');
    });

    it('parses aggregation="MIN"', () => {
      const xml = minimalDefinitions(`
  <decision id="D_min" name="Min val">
    <decisionTable id="dt_min" hitPolicy="COLLECT" aggregation="MIN">
      <input id="i1"><inputExpression typeRef="number"><text>n</text></inputExpression></input>
      <output id="o1" name="val" typeRef="number" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>5</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      expect((parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).aggregation).toBe('MIN');
    });

    it('parses aggregation="MAX"', () => {
      const xml = minimalDefinitions(`
  <decision id="D_max" name="Max val">
    <decisionTable id="dt_max" hitPolicy="COLLECT" aggregation="MAX">
      <input id="i1"><inputExpression typeRef="number"><text>n</text></inputExpression></input>
      <output id="o1" name="val" typeRef="number" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>5</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      expect((parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).aggregation).toBe('MAX');
    });

    it('returns null aggregation for non-COLLECT hit policy even if attribute is present', () => {
      const xml = minimalDefinitions(`
  <decision id="D_noagg" name="No aggregation">
    <decisionTable id="dt_na" hitPolicy="UNIQUE" aggregation="SUM">
      <input id="i1"><inputExpression typeRef="number"><text>n</text></inputExpression></input>
      <output id="o1" name="val" typeRef="number" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>5</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      const table = parseDmn(xml).decisions[0]!.expression as DmnDecisionTable;
      expect(table.hitPolicy).toBe(DmnHitPolicy.Unique);
      expect(table.aggregation).toBe('SUM');
    });
  });

  describe('preferred orientation', () => {
    it('parses Rule-as-Row explicitly', () => {
      const xml = minimalDefinitions(tableWithOrientation('Rule-as-Row'));
      expect((parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).preferredOrientation).toBe('Rule-as-Row');
    });

    it('parses Rule-as-Column', () => {
      const xml = minimalDefinitions(tableWithOrientation('Rule-as-Column'));
      expect((parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).preferredOrientation).toBe('Rule-as-Column');
    });

    it('parses CrossTable', () => {
      const xml = minimalDefinitions(tableWithOrientation('CrossTable'));
      expect((parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).preferredOrientation).toBe('CrossTable');
    });

    it('parses cross-table spelling with hyphen', () => {
      const xml = minimalDefinitions(tableWithOrientation('cross-table'));
      expect((parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).preferredOrientation).toBe('CrossTable');
    });

    it('defaults to Rule-as-Row when attribute omitted', () => {
      const xml = minimalDefinitions(minimalTableXml('UNIQUE'));
      expect((parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).preferredOrientation).toBe('Rule-as-Row');
    });
  });

  describe('dash input entries', () => {
    it('preserves hyphen as the input entry text', () => {
      const xml = minimalDefinitions(`
  <decision id="D1" name="Dash">
    <decisionTable id="dt" hitPolicy="FIRST">
      <input id="i1"><inputExpression typeRef="string"><text>s</text></inputExpression></input>
      <output id="o1" name="o" typeRef="string" />
      <rule id="r1">
        <inputEntry id="ie_dash"><text>-</text></inputEntry>
        <outputEntry><text>"any"</text></outputEntry>
      </rule>
    </decisionTable>
  </decision>
`);
      const text = (parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).rules[0]!.inputEntries[0]!.text;
      expect(text).toBe('-');
    });
  });

  describe('empty input entries', () => {
    it('yields empty string for empty text element', () => {
      const xml = minimalDefinitions(`
  <decision id="D1" name="Empty cell">
    <decisionTable id="dt" hitPolicy="UNIQUE">
      <input id="i1"><inputExpression typeRef="string"><text>s</text></inputExpression></input>
      <output id="o1" name="o" typeRef="string" />
      <rule id="r1">
        <inputEntry id="ie_empty"><text></text></inputEntry>
        <outputEntry><text>"v"</text></outputEntry>
      </rule>
    </decisionTable>
  </decision>
`);
      const text = (parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).rules[0]!.inputEntries[0]!.text;
      expect(text).toBe('');
    });
  });

  describe('malformed XML', () => {
    it('returns empty definitions when the document has no DMN structure', () => {
      const result = parseDmn('this is not XML <<<garbage>>>');
      expect(result.decisions).toHaveLength(0);
      expect(result.inputData).toHaveLength(0);
      expect(result.businessKnowledgeModels).toHaveLength(0);
      expect(result.knowledgeSources).toHaveLength(0);
      expect(result.itemDefinitions).toHaveLength(0);
      expect(result.imports).toHaveLength(0);
      expect(result.rawXml).toBe('this is not XML <<<garbage>>>');
    });
  });

  describe('XML without definitions element', () => {
    it('returns empty structure with raw XML preserved', () => {
      const xml = '<?xml version="1.0" encoding="UTF-8"?><unrelatedRoot/>';
      const definitions = parseDmn(xml);
      expect(definitions.decisions).toHaveLength(0);
      expect(definitions.inputData).toHaveLength(0);
      expect(definitions.id).toBeNull();
      expect(definitions.namespace).toBeNull();
      expect(definitions.rawXml).toBe(xml);
    });
  });

  describe('definitions namespace', () => {
    it('reads namespace from targetNamespace', () => {
      const xml = minimalDefinitions(
        `
  <decision id="D1" name="N">
    ${minimalTableXml('UNIQUE')}
  </decision>
`,
        ' targetNamespace="https://example.com/dmn/catalog"',
      );
      const definitions = parseDmn(xml);
      expect(definitions.namespace).toBe('https://example.com/dmn/catalog');
      expect(definitions.id).toBe('definitions_1');
    });
  });

  describe('rule descriptions', () => {
    it('captures description on a rule', () => {
      const xml = minimalDefinitions(`
  <decision id="D1" name="Described rules">
    <decisionTable id="dt" hitPolicy="UNIQUE">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="y" typeRef="string" />
      <rule id="r1">
        <description>Preferred customers receive the highest discount.</description>
        <inputEntry><text>"gold"</text></inputEntry>
        <outputEntry><text>0.2</text></outputEntry>
      </rule>
    </decisionTable>
  </decision>
`);
      const rule = (parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).rules[0]!;
      expect(rule.description).toBe('Preferred customers receive the highest discount.');
    });
  });

  describe('annotation entries', () => {
    it('collects annotationEntry bodies on rules', () => {
      const xml = minimalDefinitions(`
  <decision id="D1" name="Annotated">
    <decisionTable id="dt" hitPolicy="RULE_ORDER">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="y" typeRef="string" />
      <rule id="r1">
        <inputEntry><text>-</text></inputEntry>
        <outputEntry><text>1</text></outputEntry>
        <annotationEntry><text>audited: tier-A</text></annotationEntry>
        <annotationEntry><text>source: policy v3</text></annotationEntry>
      </rule>
    </decisionTable>
  </decision>
`);
      const rule = (parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).rules[0]!;
      expect(rule.annotationEntries).toEqual(['audited: tier-A', 'source: policy v3']);
    });
  });

  describe('decision variable output label', () => {
    it('reads outputLabel from variable name when present', () => {
      const xml = minimalDefinitions(`
  <decision id="D1" name="Labeled output">
    <variable id="var1" name="computedDiscount" typeRef="number" />
    <decisionTable id="dt" hitPolicy="UNIQUE">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="discount" typeRef="number" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>0</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      expect(parseDmn(xml).decisions[0]!.outputLabel).toBe('computedDiscount');
    });
  });

  describe('output typeRef', () => {
    it('reads typeRef from the output element attribute', () => {
      const xml = minimalDefinitions(`
  <decision id="D1" name="TypeRef on output">
    <decisionTable id="dt" hitPolicy="UNIQUE">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="discount" typeRef="number" label="Discount" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>0</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      const output = (parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).outputs[0]!;
      expect(output.typeRef).toBe('number');
      expect(output.label).toBe('Discount');
      expect(output.name).toBe('discount');
    });

    it('returns null typeRef when attribute is omitted', () => {
      const xml = minimalDefinitions(`
  <decision id="D1" name="No typeRef">
    <decisionTable id="dt" hitPolicy="UNIQUE">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="out" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>0</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      const output = (parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).outputs[0]!;
      expect(output.typeRef).toBeNull();
    });
  });

  describe('entries without explicit id attribute', () => {
    it('defaults to empty string when inputEntry and outputEntry lack id', () => {
      const xml = minimalDefinitions(`
  <decision id="D1" name="No entry ids">
    <decisionTable id="dt" hitPolicy="UNIQUE">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="y" typeRef="string" />
      <rule id="r1">
        <inputEntry><text>"a"</text></inputEntry>
        <outputEntry><text>"b"</text></outputEntry>
      </rule>
    </decisionTable>
  </decision>
`);
      const rule = (parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).rules[0]!;
      expect(rule.inputEntries[0]!.id).toBe('');
      expect(rule.inputEntries[0]!.text).toBe('"a"');
      expect(rule.outputEntries[0]!.id).toBe('');
      expect(rule.outputEntries[0]!.text).toBe('"b"');
    });
  });

  describe('missing hitPolicy attribute', () => {
    it('defaults to UNIQUE when hitPolicy is not specified', () => {
      const xml = minimalDefinitions(`
  <decision id="D1" name="Default HP">
    <decisionTable id="dt">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="y" typeRef="string" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>"z"</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      expect((parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).hitPolicy).toBe(DmnHitPolicy.Unique);
    });
  });

  describe('Literal Expression (G8)', () => {
    it('parses decision with literalExpression in unified expression field', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_calc" name="Calculator">
    <literalExpression id="le_1" typeRef="number">
      <text>x + y</text>
    </literalExpression>
  </decision>
`);
      const result = parseDmn(xml);
      expect(result.decisions).toHaveLength(1);
      const decision = result.decisions[0]!;
      const literalExpression = decision.expression as DmnLiteralExpression;
      expect(literalExpression.text).toBe('x + y');
      expect(literalExpression.id).toBe('le_1');
      expect(literalExpression.typeRef).toBe('number');
    });

    it('parses literalExpression with expressionLanguage attribute', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_feel" name="FEEL Calc">
    <literalExpression id="le_2" typeRef="number" expressionLanguage="FEEL">
      <text>a * b + c</text>
    </literalExpression>
  </decision>
`);
      const literalExpression = parseDmn(xml).decisions[0]!.expression as DmnLiteralExpression;
      expect(literalExpression.expressionLanguage).toBe('FEEL');
      expect(literalExpression.text).toBe('a * b + c');
    });

    it('parses mixed model: one table + one literal expression', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_table" name="Table Decision">
    <decisionTable id="dt_1" hitPolicy="UNIQUE">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="y" typeRef="string" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>"z"</text></outputEntry></rule>
    </decisionTable>
  </decision>
  <decision id="Decision_literal" name="Literal Decision">
    <literalExpression id="le_mixed" typeRef="string">
      <text>"hello " + name</text>
    </literalExpression>
  </decision>
`);
      const definitions = parseDmn(xml);
      expect(definitions.decisions).toHaveLength(2);
      expect((definitions.decisions[0]!.expression as DmnDecisionTable).hitPolicy).toBe(DmnHitPolicy.Unique);
      const literalExpression = definitions.decisions[1]!.expression as DmnLiteralExpression;
      expect(literalExpression.text).toBe('"hello " + name');
    });

    it('parses table-only decisions with decision table expression', () => {
      const xml = minimalDefinitions(`
  <decision id="D1" name="Table only">
    <decisionTable id="dt" hitPolicy="UNIQUE">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="y" typeRef="string" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>"a"</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      expect((parseDmn(xml).decisions[0]!.expression as DmnDecisionTable).hitPolicy).toBe(DmnHitPolicy.Unique);
    });

    it('handles literalExpression with empty text', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_empty" name="Empty Literal">
    <literalExpression id="le_empty" typeRef="string">
      <text></text>
    </literalExpression>
  </decision>
`);
      const literalExpression = parseDmn(xml).decisions[0]!.expression as DmnLiteralExpression;
      expect(literalExpression.text).toBe('');
    });

    it('handles literalExpression without id attribute', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_noid" name="No ID">
    <literalExpression typeRef="number">
      <text>42</text>
    </literalExpression>
  </decision>
`);
      const literalExpression = parseDmn(xml).decisions[0]!.expression as DmnLiteralExpression;
      expect(literalExpression.id).toBeNull();
      expect(literalExpression.text).toBe('42');
    });
  });

  describe('businessKnowledgeModel', () => {
    it('parses BKM with encapsulatedLogic containing a decisionTable', () => {
      const xml = minimalDefinitions(`
  <businessKnowledgeModel id="BKM_discount" name="Discount function">
    <encapsulatedLogic id="logic_1" kind="FEEL">
      <decisionTable id="dt_bkm" hitPolicy="UNIQUE">
        <input id="i1"><inputExpression typeRef="number"><text>amount</text></inputExpression></input>
        <output id="o1" name="rate" typeRef="number" />
        <rule id="r1">
          <inputEntry><text>&gt; 100</text></inputEntry>
          <outputEntry><text>0.1</text></outputEntry>
        </rule>
      </decisionTable>
    </encapsulatedLogic>
  </businessKnowledgeModel>
`);
      const definitions = parseDmn(xml);
      expect(definitions.businessKnowledgeModels).toHaveLength(1);
      const businessKnowledgeModel = definitions.businessKnowledgeModels[0]!;
      expect(businessKnowledgeModel.id).toBe('BKM_discount');
      expect(businessKnowledgeModel.name).toBe('Discount function');
      expect(businessKnowledgeModel.encapsulatedLogic).not.toBeNull();
      expect(businessKnowledgeModel.encapsulatedLogic!.kind).toBe('FEEL');
      expect(businessKnowledgeModel.encapsulatedLogic!.body).not.toBeNull();
      const decisionTable = businessKnowledgeModel.encapsulatedLogic!.body as DmnDecisionTable;
      expect(decisionTable.hitPolicy).toBe(DmnHitPolicy.Unique);
      expect(decisionTable.rules).toHaveLength(1);
    });
  });

  describe('BKM with formalParameter', () => {
    it('parses formalParameter children as formalParameters list', () => {
      const xml = minimalDefinitions(`
  <businessKnowledgeModel id="BKM_calc" name="Calculator">
    <encapsulatedLogic id="logic_calc" kind="FEEL">
      <formalParameter id="param_x" name="x" typeRef="number" />
      <formalParameter id="param_y" name="y" typeRef="number" />
      <literalExpression id="le_calc" typeRef="number">
        <text>x + y</text>
      </literalExpression>
    </encapsulatedLogic>
  </businessKnowledgeModel>
`);
      const formalParameters = parseDmn(xml).businessKnowledgeModels[0]!.encapsulatedLogic!.formalParameters;
      expect(formalParameters).toHaveLength(2);
      expect(formalParameters[0]!.id).toBe('param_x');
      expect(formalParameters[0]!.name).toBe('x');
      expect(formalParameters[0]!.typeRef).toBe('number');
      expect(formalParameters[1]!.name).toBe('y');
    });
  });

  describe('BKM with variable', () => {
    it('parses variable as DmnInformationItem', () => {
      const xml = minimalDefinitions(`
  <businessKnowledgeModel id="BKM_out" name="Output BKM">
    <variable id="var_result" name="resultValue" typeRef="number" />
    <encapsulatedLogic id="logic_out" kind="FEEL">
      <literalExpression typeRef="number"><text>1</text></literalExpression>
    </encapsulatedLogic>
  </businessKnowledgeModel>
`);
      const variable = parseDmn(xml).businessKnowledgeModels[0]!.variable!;
      expect(variable.id).toBe('var_result');
      expect(variable.name).toBe('resultValue');
      expect(variable.typeRef).toBe('number');
    });
  });

  describe('knowledgeRequirement on decision', () => {
    it('parses requiredKnowledgeId from href fragment', () => {
      const xml = minimalDefinitions(`
  <businessKnowledgeModel id="BKM_ref" name="Referenced BKM">
    <encapsulatedLogic kind="FEEL">
      <literalExpression typeRef="number"><text>1</text></literalExpression>
    </encapsulatedLogic>
  </businessKnowledgeModel>
  <decision id="Decision_invoke" name="Invoke BKM">
    <knowledgeRequirement id="kr_1">
      <requiredKnowledge href="#BKM_ref" />
    </knowledgeRequirement>
    <decisionTable id="dt" hitPolicy="UNIQUE">
      <input id="i1"><inputExpression typeRef="number"><text>x</text></inputExpression></input>
      <output id="o1" name="y" typeRef="number" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>1</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      const knowledgeRequirements = parseDmn(xml).decisions[0]!.knowledgeRequirements;
      expect(knowledgeRequirements).toHaveLength(1);
      expect(knowledgeRequirements[0]!.id).toBe('kr_1');
      expect(knowledgeRequirements[0]!.requiredKnowledgeId).toBe('BKM_ref');
    });
  });

  describe('knowledgeSource with authorityRequirement', () => {
    it('preserves authorityRequirement on knowledgeSource', () => {
      const xml = minimalDefinitions(`
  <knowledgeSource id="KS_policy" name="Policy manual" type="authority">
    <authorityRequirement id="ar_ks">
      <requiredAuthority href="#KS_policy" />
    </authorityRequirement>
  </knowledgeSource>
`);
      const knowledgeSource = parseDmn(xml).knowledgeSources[0]!;
      expect(knowledgeSource.id).toBe('KS_policy');
      expect(knowledgeSource.name).toBe('Policy manual');
      expect(knowledgeSource.type).toBe('authority');
      expect(knowledgeSource.authorityRequirements).toHaveLength(1);
      expect(knowledgeSource.authorityRequirements[0]!.requiredAuthorityId).toBe('KS_policy');
    });
  });

  describe('authorityRequirement', () => {
    it('parses requiredAuthority, requiredDecision, and requiredInput href fragments', () => {
      const xml = minimalDefinitions(`
  <knowledgeSource id="KS_1" name="Source" />
  <inputData id="InputData_1" name="Input" />
  <decision id="Decision_base" name="Base">
    <decisionTable id="dt" hitPolicy="UNIQUE">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="y" typeRef="string" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>""</text></outputEntry></rule>
    </decisionTable>
  </decision>
  <decision id="Decision_derived" name="Derived">
    <authorityRequirement id="ar_all">
      <requiredAuthority href="#KS_1" />
      <requiredDecision href="#Decision_base" />
      <requiredInput href="#InputData_1" />
    </authorityRequirement>
    <decisionTable id="dt2" hitPolicy="UNIQUE">
      <input id="i2"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o2" name="z" typeRef="string" />
      <rule id="r2"><inputEntry><text>-</text></inputEntry><outputEntry><text>""</text></outputEntry></rule>
    </decisionTable>
  </decision>
`);
      const authorityRequirement = parseDmn(xml).decisions[1]!.authorityRequirements[0]!;
      expect(authorityRequirement.id).toBe('ar_all');
      expect(authorityRequirement.requiredAuthorityId).toBe('KS_1');
      expect(authorityRequirement.requiredDecisionId).toBe('Decision_base');
      expect(authorityRequirement.requiredInputId).toBe('InputData_1');
    });
  });

  describe('itemDefinition', () => {
    it('parses nested itemComponent as a type tree', () => {
      const xml = minimalDefinitions(`
  <itemDefinition id="Item_address" name="Address">
    <itemComponent id="Item_street" name="street">
      <typeRef>string</typeRef>
    </itemComponent>
    <itemComponent id="Item_city" name="city">
      <typeRef>string</typeRef>
    </itemComponent>
  </itemDefinition>
`);
      const itemDefinition = parseDmn(xml).itemDefinitions[0]!;
      expect(itemDefinition.id).toBe('Item_address');
      expect(itemDefinition.name).toBe('Address');
      expect(itemDefinition.itemComponents).toHaveLength(2);
      expect(itemDefinition.itemComponents[0]!.name).toBe('street');
      expect(itemDefinition.itemComponents[0]!.typeRef).toBe('string');
      expect(itemDefinition.itemComponents[1]!.name).toBe('city');
    });

    it('parses isCollection="true" as isCollection true', () => {
      const xml = minimalDefinitions(`
  <itemDefinition id="Item_tags" name="Tags" isCollection="true">
    <typeRef>string</typeRef>
  </itemDefinition>
`);
      const itemDefinition = parseDmn(xml).itemDefinitions[0]!;
      expect(itemDefinition.isCollection).toBe(true);
      expect(itemDefinition.typeRef).toBe('string');
    });

    it('captures allowedValues text', () => {
      const xml = minimalDefinitions(`
  <itemDefinition id="Item_status" name="Status">
    <typeRef>string</typeRef>
    <allowedValues>"active", "inactive"</allowedValues>
  </itemDefinition>
`);
      const itemDefinition = parseDmn(xml).itemDefinitions[0]!;
      expect(itemDefinition.allowedValues).toBe('"active", "inactive"');
    });
  });

  describe('import element', () => {
    it('parses namespace, locationUri, and importType', () => {
      const xml = minimalDefinitions(
        `
  <import id="imp_1"
    namespace="https://example.com/dmn/external"
    locationURI="https://example.com/models/external.dmn"
    importType="model" />
`,
        '',
      );
      const importElement = parseDmn(xml).imports[0]!;
      expect(importElement.id).toBe('imp_1');
      expect(importElement.namespace).toBe('https://example.com/dmn/external');
      expect(importElement.locationUri).toBe('https://example.com/models/external.dmn');
      expect(importElement.importType).toBe('model');
    });
  });

  describe('complex model with all CL1 elements', () => {
    it('populates all CL1 fields on definitions and decisions', () => {
      const xml = minimalDefinitions(`
  <import id="imp_cl1"
    namespace="https://example.com/dmn/imported"
    locationURI="imported.dmn"
    importType="model" />
  <itemDefinition id="Item_person" name="Person">
    <typeRef>string</typeRef>
    <allowedValues>"A", "B"</allowedValues>
    <itemComponent id="Item_person_name" name="fullName">
      <typeRef>string</typeRef>
    </itemComponent>
  </itemDefinition>
  <inputData id="InputData_score" name="Score">
    <variable name="score" typeRef="number" />
  </inputData>
  <knowledgeSource id="KS_regulator" name="Regulator" type="authority">
    <authorityRequirement>
      <requiredAuthority href="#KS_regulator" />
    </authorityRequirement>
  </knowledgeSource>
  <businessKnowledgeModel id="BKM_multiplier" name="Multiplier">
    <variable id="var_product" name="product" typeRef="number" />
    <encapsulatedLogic id="logic_mult" kind="FEEL">
      <formalParameter id="param_factor" name="factor" typeRef="number" />
      <literalExpression typeRef="number"><text>factor * 2</text></literalExpression>
    </encapsulatedLogic>
    <knowledgeRequirement>
      <requiredKnowledge href="#BKM_multiplier" />
    </knowledgeRequirement>
  </businessKnowledgeModel>
  <decision id="Decision_final" name="Final decision">
    <variable id="var_out" name="finalResult" typeRef="number" />
    <informationRequirement>
      <requiredInput href="#InputData_score" />
    </informationRequirement>
    <knowledgeRequirement>
      <requiredKnowledge href="#BKM_multiplier" />
    </knowledgeRequirement>
    <authorityRequirement>
      <requiredAuthority href="#KS_regulator" />
      <requiredDecision href="#Decision_final" />
    </authorityRequirement>
    <decisionTable id="dt_final" hitPolicy="FIRST">
      <input id="in_score"><inputExpression typeRef="number"><text>score</text></inputExpression></input>
      <output id="out_band" name="band" typeRef="string" />
      <rule id="rule_high">
        <inputEntry><text>&gt; 80</text></inputEntry>
        <outputEntry><text>"high"</text></outputEntry>
      </rule>
    </decisionTable>
  </decision>
`);
      const definitions = parseDmn(xml);

      expect(definitions.imports).toHaveLength(1);
      expect(definitions.itemDefinitions).toHaveLength(1);
      expect(definitions.itemDefinitions[0]!.itemComponents).toHaveLength(1);
      expect(definitions.itemDefinitions[0]!.allowedValues).toBe('"A", "B"');
      expect(definitions.inputData).toHaveLength(1);
      expect(definitions.knowledgeSources).toHaveLength(1);
      expect(definitions.businessKnowledgeModels).toHaveLength(1);

      const businessKnowledgeModel = definitions.businessKnowledgeModels[0]!;
      expect(businessKnowledgeModel.variable!.name).toBe('product');
      expect(businessKnowledgeModel.encapsulatedLogic!.formalParameters).toHaveLength(1);
      expect(businessKnowledgeModel.knowledgeRequirements).toHaveLength(1);

      const decision = definitions.decisions[0]!;
      expect(decision.variable!.name).toBe('finalResult');
      expect(decision.outputLabel).toBe('finalResult');
      expect(decision.informationRequirements).toHaveLength(1);
      expect(decision.knowledgeRequirements[0]!.requiredKnowledgeId).toBe('BKM_multiplier');
      expect(decision.authorityRequirements[0]!.requiredAuthorityId).toBe('KS_regulator');
      expect((decision.expression as DmnDecisionTable).hitPolicy).toBe(DmnHitPolicy.First);
    });
  });

  describe('CL3 boxed expressions', () => {
    it('parses boxed context with entries', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_context" name="Context Decision">
    <variable id="var_ctx" name="contextResult" typeRef="number"/>
    <context id="ctx_1">
      <contextEntry>
        <variable name="x" typeRef="number"/>
        <literalExpression id="le_x"><text>2 + 3</text></literalExpression>
      </contextEntry>
      <contextEntry>
        <variable name="y" typeRef="number"/>
        <literalExpression id="le_y"><text>x * 2</text></literalExpression>
      </contextEntry>
      <contextEntry>
        <literalExpression id="le_result"><text>y + 1</text></literalExpression>
      </contextEntry>
    </context>
  </decision>
`);
      const context = parseDmn(xml).decisions[0]!.expression as DmnBoxedContext;
      expect(context.id).toBe('ctx_1');
      expect(context.contextEntries).toHaveLength(3);
      expect(context.contextEntries[0]!.variable!.name).toBe('x');
      expect((context.contextEntries[0]!.expression as DmnLiteralExpression).text).toBe('2 + 3');
      expect(context.contextEntries[1]!.variable!.name).toBe('y');
      expect((context.contextEntries[2]!.expression as DmnLiteralExpression).text).toBe('y + 1');
      expect(context.contextEntries[2]!.variable).toBeNull();
    });

    it('parses boxed invocation with bindings', () => {
      const xml = minimalDefinitions(`
  <businessKnowledgeModel id="BKM_tax" name="Tax Calculation">
    <encapsulatedLogic id="FL_tax" kind="FEEL">
      <formalParameter id="FP_income" name="income" typeRef="number"/>
      <literalExpression><text>income * rate</text></literalExpression>
    </encapsulatedLogic>
  </businessKnowledgeModel>
  <decision id="Decision_apply_tax" name="Apply Tax">
    <knowledgeRequirement id="KR_1">
      <requiredKnowledge href="#BKM_tax"/>
    </knowledgeRequirement>
    <invocation id="Inv_1">
      <literalExpression id="LE_called">
        <text>Tax Calculation</text>
      </literalExpression>
      <binding>
        <parameter id="BP_income" name="income"/>
        <literalExpression id="LE_bind_income"><text>50000</text></literalExpression>
      </binding>
      <binding>
        <parameter id="BP_rate" name="rate"/>
        <literalExpression id="LE_bind_rate"><text>0.2</text></literalExpression>
      </binding>
    </invocation>
  </decision>
`);
      const invocation = parseDmn(xml).decisions[0]!.expression as DmnBoxedInvocation;
      expect(invocation.id).toBe('Inv_1');
      expect(invocation.calledFunction).toBe('Tax Calculation');
      expect(invocation.bindings).toHaveLength(2);
      expect(invocation.bindings[0]!.parameter!.name).toBe('income');
      expect((invocation.bindings[0]!.expression as DmnLiteralExpression).text).toBe('50000');
      expect(invocation.bindings[1]!.parameter!.name).toBe('rate');
      expect((invocation.bindings[1]!.expression as DmnLiteralExpression).text).toBe('0.2');
    });

    it('parses boxed list elements', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_list" name="List Decision">
    <list id="list_1">
      <literalExpression><text>10</text></literalExpression>
      <literalExpression><text>20</text></literalExpression>
      <literalExpression><text>30</text></literalExpression>
    </list>
  </decision>
`);
      const list = parseDmn(xml).decisions[0]!.expression as DmnBoxedList;
      expect(list.id).toBe('list_1');
      expect(list.elements).toHaveLength(3);
      expect((list.elements[0] as DmnLiteralExpression).text).toBe('10');
      expect((list.elements[2] as DmnLiteralExpression).text).toBe('30');
    });

    it('parses relation columns and rows', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_relation" name="Relation Decision">
    <relation id="rel_1">
      <column id="col_name" name="Name" typeRef="string"/>
      <column id="col_age" name="Age" typeRef="number"/>
      <row>
        <literalExpression><text>"Alice"</text></literalExpression>
        <literalExpression><text>30</text></literalExpression>
      </row>
      <row>
        <literalExpression><text>"Bob"</text></literalExpression>
        <literalExpression><text>25</text></literalExpression>
      </row>
    </relation>
  </decision>
`);
      const relation = parseDmn(xml).decisions[0]!.expression as DmnRelation;
      expect(relation.id).toBe('rel_1');
      expect(relation.columns).toHaveLength(2);
      expect(relation.columns[0]!.name).toBe('Name');
      expect(relation.rows).toHaveLength(2);
      expect((relation.rows[0]![0] as DmnLiteralExpression).text).toBe('"Alice"');
      expect((relation.rows[1]![1] as DmnLiteralExpression).text).toBe('25');
    });

    it('parses boxed conditional if/then/else', () => {
      const xml = minimalDefinitions(`
  <inputData id="InputData_score" name="score"/>
  <decision id="Decision_conditional" name="Conditional Decision">
    <conditional id="cond_1">
      <if>
        <literalExpression><text>score > 100</text></literalExpression>
      </if>
      <then>
        <literalExpression><text>"high"</text></literalExpression>
      </then>
      <else>
        <literalExpression><text>"low"</text></literalExpression>
      </else>
    </conditional>
  </decision>
`);
      const conditional = parseDmn(xml).decisions[0]!.expression as DmnBoxedConditional;
      expect(conditional.id).toBe('cond_1');
      expect((conditional.ifExpression as DmnLiteralExpression).text).toBe('score > 100');
      expect((conditional.thenExpression as DmnLiteralExpression).text).toBe('"high"');
      expect((conditional.elseExpression as DmnLiteralExpression).text).toBe('"low"');
    });

    it('parses boxed filter in and match expressions', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_filter" name="Filter Decision">
    <context id="ctx_filter">
      <contextEntry>
        <variable name="numbers"/>
        <list>
          <literalExpression><text>1</text></literalExpression>
          <literalExpression><text>5</text></literalExpression>
        </list>
      </contextEntry>
      <contextEntry>
        <filter id="flt_1">
          <in>
            <literalExpression><text>numbers</text></literalExpression>
          </in>
          <match>
            <literalExpression><text>item > 2</text></literalExpression>
          </match>
        </filter>
      </contextEntry>
    </context>
  </decision>
`);
      const context = parseDmn(xml).decisions[0]!.expression as DmnBoxedContext;
      const filter = context.contextEntries[1]!.expression as DmnBoxedFilter;
      expect(filter.id).toBe('flt_1');
      expect((filter.inExpression as DmnLiteralExpression).text).toBe('numbers');
      expect((filter.matchExpression as DmnLiteralExpression).text).toBe('item > 2');
    });

    it('parses boxed for iterator', () => {
      const xml = minimalDefinitions(`
  <inputData id="InputData_numbers" name="numbers"/>
  <decision id="Decision_for" name="For Decision">
    <for id="for_1" iteratorVariable="x">
      <in>
        <literalExpression><text>numbers</text></literalExpression>
      </in>
      <return>
        <literalExpression><text>x * 2</text></literalExpression>
      </return>
    </for>
  </decision>
`);
      const boxedFor = parseDmn(xml).decisions[0]!.expression as DmnBoxedFor;
      expect(boxedFor.id).toBe('for_1');
      expect(boxedFor.iteratorVariable).toBe('x');
      expect((boxedFor.inExpression as DmnLiteralExpression).text).toBe('numbers');
      expect((boxedFor.returnExpression as DmnLiteralExpression).text).toBe('x * 2');
    });

    it('parses boxed every iterator', () => {
      const xml = minimalDefinitions(`
  <inputData id="InputData_numbers" name="numbers"/>
  <decision id="Decision_every" name="Every Decision">
    <every id="every_1" iteratorVariable="n">
      <in>
        <literalExpression><text>numbers</text></literalExpression>
      </in>
      <satisfies>
        <literalExpression><text>n > 0</text></literalExpression>
      </satisfies>
    </every>
  </decision>
`);
      const boxedEvery = parseDmn(xml).decisions[0]!.expression as DmnBoxedEvery;
      expect(boxedEvery.iteratorVariable).toBe('n');
      expect((boxedEvery.satisfiesExpression as DmnLiteralExpression).text).toBe('n > 0');
    });

    it('parses boxed some iterator', () => {
      const xml = minimalDefinitions(`
  <inputData id="InputData_numbers" name="numbers"/>
  <decision id="Decision_some" name="Some Decision">
    <some id="some_1" iteratorVariable="n">
      <in>
        <literalExpression><text>numbers</text></literalExpression>
      </in>
      <satisfies>
        <literalExpression><text>n > 10</text></literalExpression>
      </satisfies>
    </some>
  </decision>
`);
      const boxedSome = parseDmn(xml).decisions[0]!.expression as DmnBoxedSome;
      expect(boxedSome.iteratorVariable).toBe('n');
      expect((boxedSome.satisfiesExpression as DmnLiteralExpression).text).toBe('n > 10');
    });

    it('parses nested context entry containing list containing literal expression', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_nested" name="Nested">
    <context id="ctx_outer">
      <contextEntry>
        <variable name="items" typeRef="number"/>
        <list id="list_inner">
          <literalExpression><text>42</text></literalExpression>
        </list>
      </contextEntry>
    </context>
  </decision>
`);
      const context = parseDmn(xml).decisions[0]!.expression as DmnBoxedContext;
      const list = context.contextEntries[0]!.expression as DmnBoxedList;
      expect(list.id).toBe('list_inner');
      expect((list.elements[0] as DmnLiteralExpression).text).toBe('42');
    });
  });

  describe('CL3 decision service', () => {
    it('parses decision service output, encapsulated, and input references', () => {
      const xml = minimalDefinitions(`
  <inputData id="InputData_age" name="Age"/>
  <inputData id="InputData_income" name="Income"/>
  <decision id="Decision_risk" name="Risk Score">
    <literalExpression><text>"low"</text></literalExpression>
  </decision>
  <decision id="Decision_eligibility" name="Eligibility">
    <literalExpression><text>"approved"</text></literalExpression>
  </decision>
  <decisionService id="DS_eligibility" name="Eligibility Service">
    <outputDecision href="#Decision_eligibility"/>
    <encapsulatedDecision href="#Decision_risk"/>
    <inputData href="#InputData_age"/>
    <inputData href="#InputData_income"/>
  </decisionService>
`);
      const decisionService = parseDmn(xml).decisionServices[0]!;
      expect(decisionService.id).toBe('DS_eligibility');
      expect(decisionService.name).toBe('Eligibility Service');
      expect(decisionService.outputDecisions).toEqual(['Decision_eligibility']);
      expect(decisionService.encapsulatedDecisions).toEqual(['Decision_risk']);
      expect(decisionService.inputDecisions).toEqual([]);
      expect(decisionService.inputData).toEqual(['InputData_age', 'InputData_income']);
    });

    it('parses decision service inputDecision references', () => {
      const xml = minimalDefinitions(`
  <decision id="Decision_base" name="Base">
    <literalExpression><text>1</text></literalExpression>
  </decision>
  <decision id="Decision_fee" name="Fee">
    <literalExpression><text>2</text></literalExpression>
  </decision>
  <decisionService id="DS_with_input_decisions" name="Service With Input Decisions">
    <outputDecision href="#Decision_fee"/>
    <inputDecision href="#Decision_base"/>
  </decisionService>
`);
      const decisionService = parseDmn(xml).decisionServices[0]!;
      expect(decisionService.inputDecisions).toEqual(['Decision_base']);
      expect(decisionService.outputDecisions).toEqual(['Decision_fee']);
    });
  });

  describe('CL3 DMNDI', () => {
    it('parses diagrams, shapes, edges, bounds, and waypoints', () => {
      const xml = `<?xml version="1.0" encoding="UTF-8"?>
<definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL"
  xmlns:dmndi="https://www.omg.org/spec/DMN/20191111/DMNDI/"
  xmlns:dc="http://www.omg.org/spec/DD/20100524/DC"
  xmlns:di="http://www.omg.org/spec/DD/20100524/DI"
  id="definitions_dmndi" name="DMNDI Test">
  <inputData id="InputData_x" name="x"/>
  <decision id="Decision_result" name="Result">
    <literalExpression><text>x + 1</text></literalExpression>
  </decision>
  <dmndi:DMNDI>
    <dmndi:DMNDiagram id="Diagram_1" name="DRD">
      <dmndi:DMNShape id="Shape_Decision" dmnElementRef="Decision_result">
        <dc:Bounds x="200" y="100" width="180" height="80"/>
      </dmndi:DMNShape>
      <dmndi:DMNShape id="Shape_Input" dmnElementRef="InputData_x">
        <dc:Bounds x="200" y="300" width="180" height="45"/>
      </dmndi:DMNShape>
      <dmndi:DMNEdge id="Edge_ir" dmnElementRef="ir_x">
        <di:waypoint x="290" y="300"/>
        <di:waypoint x="290" y="180"/>
      </dmndi:DMNEdge>
    </dmndi:DMNDiagram>
  </dmndi:DMNDI>
</definitions>`;
      const definitions = parseDmn(xml);
      expect(definitions.dmndi).not.toBeNull();
      expect(definitions.dmndi!.diagrams).toHaveLength(1);
      const diagram = definitions.dmndi!.diagrams[0]!;
      expect(diagram.id).toBe('Diagram_1');
      expect(diagram.name).toBe('DRD');
      expect(diagram.shapes).toHaveLength(2);
      expect(diagram.shapes[0]!.dmnElementRef).toBe('Decision_result');
      expect(diagram.shapes[0]!.bounds).toEqual({ x: 200, y: 100, width: 180, height: 80 });
      expect(diagram.shapes[1]!.bounds.height).toBe(45);
      expect(diagram.edges).toHaveLength(1);
      expect(diagram.edges[0]!.dmnElementRef).toBe('ir_x');
      expect(diagram.edges[0]!.waypoints).toEqual([
        { x: 290, y: 300 },
        { x: 290, y: 180 },
      ]);
    });
  });
});

function minimalTableXml(hitPolicy: string): string {
  return `
  <decision id="D_min" name="Minimal">
    <decisionTable id="dt_min" hitPolicy="${hitPolicy}">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="y" typeRef="string" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>"z"</text></outputEntry></rule>
    </decisionTable>
  </decision>
  `;
}

function tableWithOrientation(orientation: string): string {
  return `
  <decision id="D_orientation" name="Orientation ${orientation}">
    <decisionTable id="dt_o" hitPolicy="UNIQUE" preferredOrientation="${orientation}">
      <input id="i1"><inputExpression typeRef="string"><text>x</text></inputExpression></input>
      <output id="o1" name="y" typeRef="string" />
      <rule id="r1"><inputEntry><text>-</text></inputEntry><outputEntry><text>""</text></outputEntry></rule>
    </decisionTable>
  </decision>
`;
}
