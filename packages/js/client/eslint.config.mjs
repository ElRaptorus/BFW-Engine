import prettier from 'eslint-config-prettier';
import { defineConfig } from 'eslint/config';
import globals from 'globals';
import tseslint from 'typescript-eslint';
import js from '@eslint/js';

import { customRules } from '../eslint.config.base.mjs';

export default defineConfig(
  { ignores: ['dist/', 'node_modules/'] },

  js.configs.recommended,
  ...tseslint.configs.recommended,
  prettier,
  {
    files: ['src/**/*.ts', 'test/**/*.ts'],
    languageOptions: {
      globals: { ...globals.node },
    },
    rules: { ...customRules },
  },
);
