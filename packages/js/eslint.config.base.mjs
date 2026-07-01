/**
 * Shared ESLint configuration for all JS/TS packages in the monorepo.
 *
 * This file exports plain objects only — no npm package imports.
 * Each consumer (sdk, client) imports their own ESLint packages
 * and composes them with these shared definitions.
 */

export const customRules = {
  // -- Readability: braces & structure --
  curly: ['error', 'all'],
  'no-nested-ternary': 'error',
  'no-unneeded-ternary': 'error',

  // -- Readability: naming --
  'id-length': ['warn', { min: 2, exceptions: ['_', 'i', 'j', 'k', 'x', 'y', 'e'] }],

  // -- Modern JS --
  'no-var': 'error',
  'prefer-const': 'error',
  'no-async-promise-executor': 'off',

  // -- TypeScript --
  '@typescript-eslint/consistent-type-imports': ['error', { disallowTypeAnnotations: true }],
  '@typescript-eslint/ban-ts-comment': 'off',
  '@typescript-eslint/no-explicit-any': 'off',
  '@typescript-eslint/no-unused-vars': ['warn', { args: 'none', varsIgnorePattern: '^_' }],
  '@typescript-eslint/no-require-imports': 'off',
  '@typescript-eslint/array-type': ['warn', { default: 'array' }],

  // -- Console --
  'no-console': 'off',
};
