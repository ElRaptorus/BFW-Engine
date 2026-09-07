/**
 * Integration tests for DMN decision evaluation.
 * Requires a running engine with DMN support.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { DaemonEngineClient } from '../../src/daemon-engine-client.js';
import {
  ensureEngineReachable,
  createAdminClient,
  deployDmnFixture,
} from '../support/test-engine.js';
import {
  DecisionDefinitionNotFoundError,
  DecisionDefinitionDisabledError,
  DecisionServiceNotFoundError,
} from '@elraptorus/daemonengine_sdk';

const discountDefinitionsId = 'definitions_discount';
const serviceDefinitionsId = 'Definitions_ds_basic';
const serviceId = 'DS_eligibility';
const collectSumDefinitionsId = 'definitions_bonus';
const hitPoliciesDefinitionsId = 'definitions_hit_policies';
const priorityDefinitionsId = 'definitions_priority';
const drgLinearChainDefinitionsId = 'definitions_linear_chain';
const bkmInvocationDefinitionsId = 'definitions_bkm_invoke_le';
const boxedContextDefinitionsId = 'definitions_context';

let adminClient: DaemonEngineClient;

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  await deployDmnFixture(adminClient, 'simple_unique.dmn');
  await deployDmnFixture(adminClient, 'decision_service_basic.dmn');
  await deployDmnFixture(adminClient, 'collect_with_sum.dmn');
  await deployDmnFixture(adminClient, 'all_hit_policies.dmn');
  await deployDmnFixture(adminClient, 'priority_hit_policy.dmn');
  await deployDmnFixture(adminClient, 'drg_linear_chain.dmn');
  await deployDmnFixture(adminClient, 'bkm_invocation_literal.dmn');
  await deployDmnFixture(adminClient, 'boxed_context_basic.dmn');
});

afterAll(async () => {
  const definitionIds = [
    discountDefinitionsId,
    serviceDefinitionsId,
    collectSumDefinitionsId,
    hitPoliciesDefinitionsId,
    priorityDefinitionsId,
    drgLinearChainDefinitionsId,
    bkmInvocationDefinitionsId,
    boxedContextDefinitionsId,
  ];

  for (const id of definitionIds) {
    try {
      await adminClient.decisions.undeploy(id);
    } catch {
      // best-effort cleanup
    }
  }
  adminClient?.dispose();
});

describe('Decision evaluation (integration)', { concurrent: false }, () => {
  it('deploys DMN and evaluates', async () => {
    const result = await adminClient.decisions.evaluate(discountDefinitionsId, { age: 25 });
    expect(result.hitPolicy).toBe('unique');
    expect(result.result).toBeDefined();
  });

  it('EvaluationResult shape verification', async () => {
    const result = await adminClient.decisions.evaluate(discountDefinitionsId, { age: 70 });
    expect(result).toHaveProperty('hitPolicy');
    expect(result).toHaveProperty('result');
    expect(result).toHaveProperty('trace');
    expect(result.hitPolicy).toBe('unique');
  });

  it('evaluate with includeUnmatchedDetails', async () => {
    const result = await adminClient.decisions.evaluate(
      discountDefinitionsId,
      { age: 25 },
      { includeUnmatchedDetails: true },
    );
    expect(result).toHaveProperty('trace');
  });

  it('evaluate non-existent model → DecisionDefinitionNotFoundError', async () => {
    await expect(
      adminClient.decisions.evaluate('nonexistent_model_xyz', { age: 25 }),
    ).rejects.toThrow(DecisionDefinitionNotFoundError);
  });

  it('evaluate disabled model → DecisionDefinitionDisabledError', async () => {
    await adminClient.decisions.disable(discountDefinitionsId);
    await expect(
      adminClient.decisions.evaluate(discountDefinitionsId, { age: 25 }),
    ).rejects.toThrow(DecisionDefinitionDisabledError);
    await adminClient.decisions.enable(discountDefinitionsId);
  });

  it('evaluates a Decision Service', async () => {
    const result = await adminClient.decisions.evaluateService(
      serviceDefinitionsId,
      serviceId,
      { Age: 30, Income: 50000 },
    );
    expect(result.serviceId).toBe(serviceId);
    expect(result.outputs['Eligibility']).toBe('approved');
  });

  it('evaluateService with non-existent service → DecisionServiceNotFoundError', async () => {
    await expect(
      adminClient.decisions.evaluateService(serviceDefinitionsId, 'nonexistent_service', {}),
    ).rejects.toThrow(DecisionServiceNotFoundError);
  });

  it('evaluateService with non-existent model → DecisionDefinitionNotFoundError', async () => {
    await expect(
      adminClient.decisions.evaluateService('nonexistent_model_xyz', serviceId, {}),
    ).rejects.toThrow(DecisionDefinitionNotFoundError);
  });

  it('COLLECT SUM aggregation over the wire', async () => {
    const result = await adminClient.decisions.evaluate(collectSumDefinitionsId, {
      category: 'electronics',
    });
    expect(result.hitPolicy).toBe('collect');
    expect(result.result).toBe(15);
  });

  it('PRIORITY hit policy returns highest-priority output', async () => {
    const result = await adminClient.decisions.evaluate(priorityDefinitionsId, { score: 95 });
    expect(result.hitPolicy).toBe('priority');
    expect(result.result).toHaveProperty('level');
  });

  it('OUTPUT ORDER hit policy returns sorted results', async () => {
    const result = await adminClient.decisions.evaluate(
      hitPoliciesDefinitionsId,
      { value: 5 },
      { decisionModelId: 'Decision_output_order' },
    );
    expect(result.hitPolicy).toBe('output_order');
    expect(Array.isArray(result.result)).toBe(true);
    const grades = (result.result as Array<Record<string, unknown>>).map(
      (r) => r['grade'],
    );
    expect(grades).toEqual(['A', 'B']);
  });

  it('RULE ORDER hit policy returns all matches in document order', async () => {
    const result = await adminClient.decisions.evaluate(
      hitPoliciesDefinitionsId,
      { value: 5 },
      { decisionModelId: 'Decision_rule_order' },
    );
    expect(result.hitPolicy).toBe('rule_order');
    expect(Array.isArray(result.result)).toBe(true);
  });

  it('DRG chaining — linear chain evaluation over the wire', async () => {
    const result = await adminClient.decisions.evaluate(
      drgLinearChainDefinitionsId,
      { x: 5 },
      { decisionModelId: 'Decision_A' },
    );
    expect(result.result).toBe(30);
    expect(result.trace).toBeDefined();
    expect(result.trace.decisions.length).toBeGreaterThanOrEqual(2);
  });

  it('BKM invocation via literal expression over the wire', async () => {
    const result = await adminClient.decisions.evaluate(
      bkmInvocationDefinitionsId,
      { income: 50000, taxRate: 0.2 },
      { decisionModelId: 'Decision_tax' },
    );
    expect(result.result).toBe(10100);
    expect(result.hitPolicy).toBe('literal');
  });

  it('boxed context evaluation over the wire (P4.12 — uses formerly orphan fixture)', async () => {
    const result = await adminClient.decisions.evaluate(
      boxedContextDefinitionsId,
      {},
      { decisionModelId: 'Decision_context' },
    );
    expect(result.hitPolicy).toBe('boxed_expression');
    expect(result.result).toBe(11);
  });
});
