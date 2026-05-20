import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

const config = defineConfig({
    plugins: [react()],
    server: {
        open: true,
        proxy: {
            '/api': {
                target: 'http://localhost:8787',
            },
        },
    },
});

export default config;
