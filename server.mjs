import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

const samplePath = new URL('./storage/sample-cache.json', import.meta.url);
const cachePath = join(homedir(), '.codexboard', 'cache.json');
const systemSyncIntervalMs = 2 * 60 * 1000;

function ensureCacheFile() {
    mkdirSync(dirname(cachePath), { recursive: true });

    if (existsSync(cachePath)) {
        return;
    }

    const sample = readFileSync(samplePath, 'utf8');
    writeFileSync(cachePath, sample, 'utf8');
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
            'access-control-allow-headers': 'content-type',
            'access-control-allow-origin': '*',
            'content-type': 'application/json; charset=utf-8',
        },
        ...init,
    });
}

function buildSnapshotKey(account) {
    return [account.accountId, account.plan, account.workspaceLabel].join('::');
}

function replaceAccount(payload, nextAccount) {
    const nextAccountKey = buildSnapshotKey(nextAccount);
    const existingAccount = payload.accounts.find(
        (account) => buildSnapshotKey(account) === nextAccountKey
    );
    const accounts = payload.accounts.filter(
        (account) => buildSnapshotKey(account) !== nextAccountKey
    );

    accounts.push({
        ...nextAccount,
        history: buildHistory(existingAccount, nextAccount),
    });
    accounts.sort((left, right) => left.label.localeCompare(right.label));

    return {
        ...payload,
        meta: {
            ...payload.meta,
            cachePath,
            generatedAt: new Date().toISOString(),
            source: 'local-bun-cache',
        },
        accounts,
    };
}

function buildHistory(previousAccount, nextAccount) {
    const latestEntry = {
        capturedAt: nextAccount.lastSyncedAt,
        note: nextAccount.pace.detail,
        rollingUsedMinutes: nextAccount.rollingWindow.usedMinutes,
        weeklyUsedMinutes: nextAccount.weeklyWindow.usedMinutes,
    };

    if (previousAccount === undefined) {
        return [latestEntry];
    }

    const history = previousAccount.history ?? [];
    const previousEntry = history.at(-1);

    if (
        previousEntry !== undefined &&
        previousEntry.weeklyUsedMinutes === latestEntry.weeklyUsedMinutes &&
        previousEntry.rollingUsedMinutes === latestEntry.rollingUsedMinutes
    ) {
        return history;
    }

    return [...history, latestEntry].slice(-12);
}

function decodeJwtPayload(token) {
    const [, payload = ''] = token.split('.');
    return JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
}

function getCodexHome() {
    const configured = process.env.CODEX_HOME?.trim();
    return configured === undefined || configured === ''
        ? join(homedir(), '.codex')
        : configured;
}

function loadSystemCodexAuth() {
    const authPath = join(getCodexHome(), 'auth.json');

    if (!existsSync(authPath)) {
        return undefined;
    }

    const auth = JSON.parse(readFileSync(authPath, 'utf8'));
    const accessToken = auth.tokens?.access_token;
    const idToken = auth.tokens?.id_token;

    if (typeof accessToken !== 'string' || accessToken === '') {
        return undefined;
    }

    const identity =
        typeof idToken === 'string' && idToken !== ''
            ? decodeJwtPayload(idToken)
            : undefined;

    return {
        accessToken,
        accountId: auth.tokens?.account_id ?? auth.account_id ?? undefined,
        authPath,
        email: identity?.email ?? undefined,
        name: identity?.name ?? undefined,
        planType: identity?.['https://api.openai.com/auth']?.chatgpt_plan_type,
        sub: identity?.sub ?? undefined,
    };
}

function minutesFromPercent(limitWindowSeconds, usedPercent) {
    return Math.round((limitWindowSeconds / 60) * (usedPercent / 100));
}

function buildUnavailableWindow(label) {
    return {
        available: false,
        label,
        limitMinutes: 0,
        remainingMinutes: 0,
        resetsAt: '',
        usedMinutes: 0,
        usedPercentage: 0,
    };
}

function buildWindow(label, rawWindow) {
    if (rawWindow === null || rawWindow === undefined) {
        return buildUnavailableWindow(label);
    }

    const limitMinutes = Math.round((rawWindow.limit_window_seconds ?? 0) / 60);
    const resetAfterMinutes = Math.round(
        (rawWindow.reset_after_seconds ?? 0) / 60
    );
    const usedPercentage = Number(rawWindow.used_percent ?? 0);
    const usedMinutes = minutesFromPercent(
        rawWindow.limit_window_seconds ?? 0,
        usedPercentage
    );
    const remainingMinutes = Math.max(limitMinutes - usedMinutes, 0);

    return {
        available: true,
        label,
        limitMinutes,
        remainingMinutes,
        resetsAt: new Date((rawWindow.reset_at ?? 0) * 1000).toISOString(),
        usedMinutes,
        usedPercentage,
        windowShareMinutes: usedMinutes,
        windowResetAfterMinutes: resetAfterMinutes,
    };
}

function resolveWindows(rateLimit) {
    const primaryWindow = rateLimit?.primary_window;
    const secondaryWindow = rateLimit?.secondary_window;
    const primarySeconds = primaryWindow?.limit_window_seconds ?? 0;
    const secondarySeconds = secondaryWindow?.limit_window_seconds ?? 0;

    const primaryLooksWeekly = primarySeconds >= 6 * 24 * 60 * 60;
    const secondaryLooksWeekly = secondarySeconds >= 6 * 24 * 60 * 60;

    if (primaryLooksWeekly) {
        return {
            rollingWindow:
                secondaryWindow === null || secondaryWindow === undefined
                    ? buildUnavailableWindow('Rolling 5-hour window')
                    : buildWindow('Rolling 5-hour window', secondaryWindow),
            weeklyWindow: buildWindow('Weekly window', primaryWindow),
        };
    }

    if (secondaryLooksWeekly) {
        return {
            rollingWindow: buildWindow('Rolling 5-hour window', primaryWindow),
            weeklyWindow: buildWindow('Weekly window', secondaryWindow),
        };
    }

    return {
        rollingWindow: buildWindow('Rolling window', primaryWindow),
        weeklyWindow:
            secondaryWindow === null || secondaryWindow === undefined
                ? buildUnavailableWindow('Weekly window')
                : buildWindow('Weekly window', secondaryWindow),
    };
}

function projectPace(weeklyWindow, rollingWindow) {
    if (!weeklyWindow.available) {
        return {
            detail: 'The current system account did not expose a weekly window.',
            status: 'steady',
            summary: 'Weekly pace unavailable',
        };
    }

    if (!rollingWindow.available) {
        const remaining = Math.max(100 - weeklyWindow.usedPercentage, 0);

        return {
            detail: 'Codex exposed the weekly system window but not a rolling 5-hour window for this account.',
            status:
                weeklyWindow.usedPercentage >= 85
                    ? 'over'
                    : weeklyWindow.usedPercentage >= 70
                      ? 'tight'
                      : 'steady',
            summary: `${Math.round(remaining)}% weekly headroom left`,
        };
    }

    const paceStatus =
        weeklyWindow.usedPercentage >= 90
            ? 'over'
            : weeklyWindow.usedPercentage >= 75
              ? 'tight'
              : weeklyWindow.usedPercentage >= 45
                ? 'steady'
                : 'ahead';
    const projectedHeadroom = Math.max(
        Math.round(100 - weeklyWindow.usedPercentage),
        0
    );

    return {
        detail: `Current system account is using ${Math.round(
            rollingWindow.usedPercentage
        )}% of the rolling window and ${Math.round(
            weeklyWindow.usedPercentage
        )}% of the weekly window.`,
        status: paceStatus,
        summary: `${projectedHeadroom}% weekly headroom left`,
    };
}

async function fetchSystemAccountSnapshot() {
    const auth = loadSystemCodexAuth();

    if (auth === undefined) {
        return undefined;
    }

    const response = await fetch('https://chatgpt.com/backend-api/wham/usage', {
        headers: {
            Accept: 'application/json',
            Authorization: `Bearer ${auth.accessToken}`,
        },
    });

    if (!response.ok) {
        throw new Error(
            `System account usage fetch failed with ${response.status}.`
        );
    }

    const usage = await response.json();
    const now = new Date().toISOString();
    const windows = resolveWindows(usage.rate_limit);
    const plan = usage.plan_type ?? auth.planType ?? 'Codex';
    const label =
        auth.name ?? usage.email ?? auth.email ?? 'Current system account';

    return {
        accountId:
            usage.account_id ?? auth.accountId ?? auth.sub ?? 'system-account',
        color: '#8cf5b0',
        email: usage.email ?? auth.email ?? 'Unknown account',
        history: [],
        label,
        lastSyncedAt: now,
        pace: projectPace(windows.weeklyWindow, windows.rollingWindow),
        plan:
            typeof plan === 'string' && plan !== ''
                ? `Codex ${plan[0].toUpperCase()}${plan.slice(1)}`
                : 'Codex',
        rollingWindow: windows.rollingWindow,
        source: 'live system auth',
        weeklyWindow: windows.weeklyWindow,
        workspaceLabel: 'Ambient ~/.codex session',
    };
}

function systemSnapshotIsFresh(payload) {
    const systemAccount = payload.accounts.find(
        (account) => account.source === 'live system auth'
    );

    if (systemAccount === undefined) {
        return false;
    }

    return (
        Date.now() - new Date(systemAccount.lastSyncedAt).getTime() <
        systemSyncIntervalMs
    );
}

async function hydrateSystemAccount(payload) {
    if (systemSnapshotIsFresh(payload)) {
        return payload;
    }

    const snapshot = await fetchSystemAccountSnapshot();

    if (snapshot === undefined) {
        return payload;
    }

    return replaceAccount(payload, snapshot);
}

const server = Bun.serve({
    async fetch(request) {
        const url = new URL(request.url);

        if (request.method === 'OPTIONS') {
            return new Response(null, { status: 204 });
        }

        if (url.pathname === '/') {
            return jsonResponse({
                endpoints: ['/api/health', '/api/cache', '/api/cache/sample'],
                message: 'CodexBoard local cache server',
                ok: true,
            });
        }

        if (url.pathname === '/api/health') {
            return jsonResponse({
                cachePath,
                codexHome: getCodexHome(),
                ok: true,
                systemAccountDetected: loadSystemCodexAuth() !== undefined,
            });
        }

        if (url.pathname === '/api/cache' && request.method === 'GET') {
            const payload = await hydrateSystemAccount(readCache());
            writeCache(payload);
            return jsonResponse(payload);
        }

        if (url.pathname === '/api/cache' && request.method === 'POST') {
            const nextAccount = await request.json();
            const merged = replaceAccount(readCache(), nextAccount);

            writeCache(merged);
            return jsonResponse(merged, { status: 201 });
        }

        if (url.pathname === '/api/cache/sample' && request.method === 'POST') {
            const payload = JSON.parse(readFileSync(samplePath, 'utf8'));
            payload.meta = {
                ...payload.meta,
                cachePath,
                generatedAt: new Date().toISOString(),
                source: 'sample-reset',
            };

            writeCache(payload);
            return jsonResponse(payload, { status: 201 });
        }

        return new Response('Not found', { status: 404 });
    },
    port: 8787,
});

console.log(`CodexBoard cache server listening on ${server.url}`);
