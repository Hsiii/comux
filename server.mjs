import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

const samplePath = new URL('./storage/sample-cache.json', import.meta.url);
const cachePath = join(homedir(), '.codexboard', 'cache.json');

function ensureCacheFile() {
    mkdirSync(dirname(cachePath), { recursive: true });

    try {
        readFileSync(cachePath, 'utf8');
    } catch {
        const sample = readFileSync(samplePath, 'utf8');
        writeFileSync(cachePath, sample, 'utf8');
    }
}

function readCache() {
    ensureCacheFile();
    return JSON.parse(readFileSync(cachePath, 'utf8'));
}

function writeCache(payload) {
    writeFileSync(cachePath, JSON.stringify(payload, null, 4), 'utf8');
}

function jsonResponse(payload, init = {}) {
    return new Response(JSON.stringify(payload, null, 4), {
        headers: {
            'content-type': 'application/json; charset=utf-8',
            'access-control-allow-origin': '*',
            'access-control-allow-headers': 'content-type',
        },
        ...init,
    });
}

function replaceAccount(payload, nextAccount) {
    const accounts = payload.accounts.filter(
        (account) => account.accountId !== nextAccount.accountId
    );

    accounts.push(nextAccount);
    accounts.sort((left, right) => left.label.localeCompare(right.label));

    return {
        ...payload,
        meta: {
            ...payload.meta,
            generatedAt: new Date().toISOString(),
            cachePath,
            source: 'local-bun-cache',
        },
        accounts,
    };
}

const server = Bun.serve({
    port: 8787,
    routes: {
        '/api/health': () =>
            jsonResponse({
                ok: true,
                cachePath,
            }),
        '/api/cache': {
            GET: () => {
                const payload = readCache();
                payload.meta = {
                    ...payload.meta,
                    generatedAt: new Date().toISOString(),
                    cachePath,
                    source: 'local-bun-cache',
                };

                return jsonResponse(payload);
            },
            POST: async (request) => {
                const nextAccount = await request.json();
                const payload = readCache();
                const merged = replaceAccount(payload, nextAccount);

                writeCache(merged);
                return jsonResponse(merged, { status: 201 });
            },
            OPTIONS: () => new Response(null, { status: 204 }),
        },
        '/api/cache/sample': {
            POST: () => {
                const payload = JSON.parse(readFileSync(samplePath, 'utf8'));
                payload.meta = {
                    ...payload.meta,
                    generatedAt: new Date().toISOString(),
                    cachePath,
                    source: 'sample-reset',
                };

                writeCache(payload);
                return jsonResponse(payload, { status: 201 });
            },
            OPTIONS: () => new Response(null, { status: 204 }),
        },
    },
    fetch(request) {
        const url = new URL(request.url);

        if (url.pathname === '/') {
            return jsonResponse({
                ok: true,
                message: 'CodexBoard local cache server',
                endpoints: ['/api/health', '/api/cache', '/api/cache/sample'],
            });
        }

        return new Response('Not found', { status: 404 });
    },
});

console.log(`CodexBoard cache server listening on ${server.url}`);
