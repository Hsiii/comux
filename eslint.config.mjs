import { completeConfigBase } from 'eslint-config-complete';

export default [
    ...completeConfigBase,

    {
        ignores: ['dist/**', 'node_modules/**', 'server.mjs'],
    },

    {
        rules: {
            '@stylistic/quotes': [
                'error',
                'single',
                {
                    avoidEscape: true,
                },
            ],
            'import-x/no-unassigned-import': [
                'error',
                {
                    allow: ['**/*.css'],
                },
            ],
        },
    },
];
