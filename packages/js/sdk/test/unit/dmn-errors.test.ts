import { describe, expect, it } from 'vitest';

import {
  AmbiguousDecisionError,
  BkmNotFoundError,
  DaemonEngineError,
  DecisionDefinitionDisabledError,
  DecisionDefinitionNotFoundError,
  DecisionServiceNotFoundError,
  DecisionServiceValidationError,
  DecisionVersionExistsError,
  DecisionVersionNotFoundError,
  DmnCycleError,
  DmnEvaluationError,
  DmnParseError,
  InputValueViolationError,
  MissingServiceInputError,
} from '../../src/index.js';

describe('DecisionDefinitionNotFoundError', () => {
  it('is instanceof DaemonEngineError and Error', () => {
    const error = new DecisionDefinitionNotFoundError('decision missing');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error).toBeInstanceOf(Error);
  });

  it('has statusCode 404 and decision_definition_not_found errorCode', () => {
    const error = new DecisionDefinitionNotFoundError('not found', { id: 'discount-rules' });
    expect(error.statusCode).toBe(404);
    expect(error.errorCode).toBe('decision_definition_not_found');
    expect(error.name).toBe('DecisionDefinitionNotFoundError');
    expect(error.message).toBe('not found');
    expect(error.rawBody).toEqual({ id: 'discount-rules' });
  });
});

describe('DecisionDefinitionDisabledError', () => {
  it('is instanceof DaemonEngineError', () => {
    const error = new DecisionDefinitionDisabledError('disabled');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error).toBeInstanceOf(Error);
  });

  it('has statusCode 422 and decision_definition_disabled errorCode', () => {
    const error = new DecisionDefinitionDisabledError('definition is disabled', { id: 'risk-rules' });
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('decision_definition_disabled');
    expect(error.name).toBe('DecisionDefinitionDisabledError');
    expect(error.message).toBe('definition is disabled');
    expect(error.rawBody).toEqual({ id: 'risk-rules' });
  });
});

describe('DmnEvaluationError', () => {
  it('is instanceof DaemonEngineError', () => {
    const error = new DmnEvaluationError('evaluation failed', 'risk-model', 'hit policy violation');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error).toBeInstanceOf(Error);
  });

  it('preserves decisionModelId, details, statusCode, and errorCode', () => {
    const error = new DmnEvaluationError('evaluation failed', 'risk-model', 'no rule matched', {
      trace: [],
    });
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('dmn_evaluation_error');
    expect(error.name).toBe('DmnEvaluationError');
    expect(error.decisionModelId).toBe('risk-model');
    expect(error.details).toBe('no rule matched');
    expect(error.rawBody).toEqual({ trace: [] });
  });

  it('allows null decisionModelId and details', () => {
    const error = new DmnEvaluationError('generic failure', null, null);
    expect(error.decisionModelId).toBeNull();
    expect(error.details).toBeNull();
  });
});

describe('DecisionVersionNotFoundError', () => {
  it('is instanceof DaemonEngineError and Error', () => {
    const error = new DecisionVersionNotFoundError('version missing');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error).toBeInstanceOf(Error);
  });

  it('has statusCode 404 and decision_version_not_found errorCode', () => {
    const error = new DecisionVersionNotFoundError('version not found', { version: '2.0.0' });
    expect(error.statusCode).toBe(404);
    expect(error.errorCode).toBe('decision_version_not_found');
    expect(error.name).toBe('DecisionVersionNotFoundError');
    expect(error.message).toBe('version not found');
    expect(error.rawBody).toEqual({ version: '2.0.0' });
  });
});

describe('DmnParseError', () => {
  it('is instanceof DaemonEngineError', () => {
    const error = new DmnParseError('parse failed', []);
    expect(error).toBeInstanceOf(DaemonEngineError);
  });

  it('has statusCode 400, dmn_parse_error, and failures array', () => {
    const failures = [{ file: 'rules.dmn', details: ['unclosed tag'] }];
    const error = new DmnParseError('DMN parse error', failures);
    expect(error.statusCode).toBe(400);
    expect(error.errorCode).toBe('dmn_parse_error');
    expect(error.name).toBe('DmnParseError');
    expect(error.failures).toBe(failures);
  });
});

describe('DecisionVersionExistsError', () => {
  it('is instanceof DaemonEngineError', () => {
    const error = new DecisionVersionExistsError('already deployed', []);
    expect(error).toBeInstanceOf(DaemonEngineError);
  });

  it('has statusCode 409, decision_version_exists, and conflicts array', () => {
    const conflicts = [{ decisionDefinitionId: 'order-discount', version: '1.0.0' }];
    const error = new DecisionVersionExistsError('version exists', conflicts);
    expect(error.statusCode).toBe(409);
    expect(error.errorCode).toBe('decision_version_exists');
    expect(error.name).toBe('DecisionVersionExistsError');
    expect(error.conflicts).toBe(conflicts);
  });
});

describe('DmnCycleError', () => {
  it('is instanceof DaemonEngineError and Error', () => {
    const error = new DmnCycleError('cycle detected', ['Decision_A', 'Decision_B']);
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error).toBeInstanceOf(Error);
  });

  it('has statusCode 422, dmn_cycle_error, and preserves decisionIds', () => {
    const decisionIds = ['Decision_A', 'Decision_B', 'Decision_A'];
    const error = new DmnCycleError('dependency cycle', decisionIds, { trace: 'cycle' });
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('dmn_cycle_error');
    expect(error.name).toBe('DmnCycleError');
    expect(error.message).toBe('dependency cycle');
    expect(error.decisionIds).toBe(decisionIds);
    expect(error.rawBody).toEqual({ trace: 'cycle' });
  });
});

describe('BkmNotFoundError', () => {
  it('is instanceof DaemonEngineError and Error', () => {
    const error = new BkmNotFoundError('BKM missing');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error).toBeInstanceOf(Error);
  });

  it('has statusCode 404 and bkm_not_found errorCode', () => {
    const error = new BkmNotFoundError('business knowledge model not found', { id: 'BKM_missing' });
    expect(error.statusCode).toBe(404);
    expect(error.errorCode).toBe('bkm_not_found');
    expect(error.name).toBe('BkmNotFoundError');
    expect(error.message).toBe('business knowledge model not found');
    expect(error.rawBody).toEqual({ id: 'BKM_missing' });
  });
});

describe('DecisionServiceValidationError', () => {
  it('is instanceof DaemonEngineError and Error', () => {
    const error = new DecisionServiceValidationError('invalid service configuration');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error).toBeInstanceOf(Error);
  });

  it('has statusCode 422 and decision_service_validation_error errorCode', () => {
    const error = new DecisionServiceValidationError('no output decisions', {
      serviceId: 'DS_empty',
    });
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('decision_service_validation_error');
    expect(error.name).toBe('DecisionServiceValidationError');
    expect(error.message).toBe('no output decisions');
    expect(error.rawBody).toEqual({ serviceId: 'DS_empty' });
  });
});

describe('DecisionServiceNotFoundError', () => {
  it('is instanceof DaemonEngineError and Error', () => {
    const error = new DecisionServiceNotFoundError('service missing');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error).toBeInstanceOf(Error);
  });

  it('has statusCode 404 and service_not_found errorCode', () => {
    const error = new DecisionServiceNotFoundError('decision service not found', {
      id: 'DS_order',
    });
    expect(error.statusCode).toBe(404);
    expect(error.errorCode).toBe('service_not_found');
    expect(error.name).toBe('DecisionServiceNotFoundError');
    expect(error.message).toBe('decision service not found');
    expect(error.rawBody).toEqual({ id: 'DS_order' });
  });
});

describe('AmbiguousDecisionError', () => {
  it('is instanceof DaemonEngineError and Error', () => {
    const error = new AmbiguousDecisionError('multiple decisions');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error).toBeInstanceOf(Error);
  });

  it('has statusCode 422 and ambiguous_decision errorCode', () => {
    const error = new AmbiguousDecisionError('Multiple decisions found — specify a decision_id', {
      decisionIds: ['Decision_A', 'Decision_B'],
    });
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('ambiguous_decision');
    expect(error.name).toBe('AmbiguousDecisionError');
    expect(error.message).toBe('Multiple decisions found — specify a decision_id');
    expect(error.rawBody).toEqual({ decisionIds: ['Decision_A', 'Decision_B'] });
  });
});

describe('InputValueViolationError', () => {
  it('is instanceof DaemonEngineError and Error', () => {
    const error = new InputValueViolationError('constraint violated', 'Input_grade');
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error).toBeInstanceOf(Error);
  });

  it('has statusCode 422, input_value_violation errorCode, and preserves inputId', () => {
    const error = new InputValueViolationError(
      "Input 'grade' value does not satisfy inputValues constraint",
      'Input_grade',
      { inputId: 'Input_grade' },
    );
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('input_value_violation');
    expect(error.name).toBe('InputValueViolationError');
    expect(error.inputId).toBe('Input_grade');
    expect(error.rawBody).toEqual({ inputId: 'Input_grade' });
  });

  it('allows null inputId', () => {
    const error = new InputValueViolationError('constraint violated', null);
    expect(error.inputId).toBeNull();
  });
});

describe('MissingServiceInputError', () => {
  it('is instanceof DaemonEngineError and Error', () => {
    const error = new MissingServiceInputError('missing inputs', ['Income']);
    expect(error).toBeInstanceOf(DaemonEngineError);
    expect(error).toBeInstanceOf(Error);
  });

  it('has statusCode 422, missing_service_input errorCode, and preserves missingInputs', () => {
    const error = new MissingServiceInputError(
      'Required inputData not provided for Decision Service',
      ['Income', 'Age'],
      { missingInputs: ['Income', 'Age'] },
    );
    expect(error.statusCode).toBe(422);
    expect(error.errorCode).toBe('missing_service_input');
    expect(error.name).toBe('MissingServiceInputError');
    expect(error.missingInputs).toEqual(['Income', 'Age']);
    expect(error.rawBody).toEqual({ missingInputs: ['Income', 'Age'] });
  });
});

describe('DMN error inheritance', () => {
  it('DMN subclasses are not instanceof each other', () => {
    const notFound = new DecisionDefinitionNotFoundError('a');
    const parseError = new DmnParseError('b', []);

    expect(notFound).not.toBeInstanceOf(DmnParseError);
    expect(parseError).not.toBeInstanceOf(DecisionDefinitionNotFoundError);
  });
});
