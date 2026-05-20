import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.8';

const corsHeaders = {
    'Access-Control-Allow-Headers':
        'authorization, x-client-info, apikey, content-type, x-codexboard-token-id, x-codexboard-token',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Origin': '*',
};

type UsageWindow = {
    available: boolean;
    label: string;
    usedMinutes: number;
    limitMinutes: number;
    remainingMinutes: number;
    usedPercentage: number;
    resetsAt: string;
};

type PaceSnapshot = {
    status: string;
    summary: string;
    detail: string;
};

type HistorySnapshot = {
    capturedAt: string;
    weeklyUsedMinutes: number;
    rollingUsedMinutes: number;
    note: string;
};

type AccountSnapshot = {
    accountId: string;
    label: string;
    email: string;
    workspaceLabel: string;
    plan: string;
    color: string;
    source: string;
    lastSyncedAt: string;
    weeklyWindow: UsageWindow;
    rollingWindow: UsageWindow;
    pace: PaceSnapshot;
    history: HistorySnapshot[];
};

type IngestPayload = {
    account?: AccountSnapshot;
    accounts?: AccountSnapshot[];
};

function buildSnapshotKey(account: AccountSnapshot) {
    return [account.accountId, account.plan, account.workspaceLabel].join('::');
}

function json(status: number, body: Record<string, unknown>) {
    return new Response(JSON.stringify(body), {
        status,
        headers: {
            ...corsHeaders,
            'Content-Type': 'application/json',
        },
    });
}

async function sha256Hex(value: string) {
    const bytes = new TextEncoder().encode(value);
    const digest = await crypto.subtle.digest('SHA-256', bytes);

    return Array.from(new Uint8Array(digest))
        .map((byte) => byte.toString(16).padStart(2, '0'))
        .join('');
}

function normalizeRows(payload: IngestPayload) {
    const accounts =
        payload.accounts ?? (payload.account ? [payload.account] : []);

    return accounts.map((account) => ({
        account_id: buildSnapshotKey(account),
        color: account.color,
        email: account.email,
        history: account.history,
        label: account.label,
        last_synced_at: account.lastSyncedAt,
        pace: account.pace,
        plan: account.plan,
        rolling_window: account.rollingWindow,
        source: account.source,
        updated_at: new Date().toISOString(),
        weekly_window: account.weeklyWindow,
        workspace_label: account.workspaceLabel,
    }));
}

Deno.serve(async (request) => {
    if (request.method === 'OPTIONS') {
        return new Response('ok', { headers: corsHeaders });
    }

    if (request.method !== 'POST') {
        return json(405, { error: 'Method not allowed' });
    }

    const tokenID = request.headers.get('x-codexboard-token-id') ?? '';
    const token = request.headers.get('x-codexboard-token') ?? '';

    if (!tokenID || !token) {
        return json(401, { error: 'Missing ingest token' });
    }

    const supabaseURL = Deno.env.get('SUPABASE_URL');
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

    if (!supabaseURL || !serviceRoleKey) {
        return json(500, { error: 'Supabase environment is not configured' });
    }

    const client = createClient(supabaseURL, serviceRoleKey);
    const tokenHash = await sha256Hex(token);

    const { data: tokenRow, error: tokenError } = await client
        .from('codexboard_ingest_tokens')
        .select('token_id, token_sha256, revoked_at')
        .eq('token_id', tokenID)
        .maybeSingle();

    if (tokenError) {
        return json(500, { error: tokenError.message });
    }

    if (
        !tokenRow ||
        tokenRow.revoked_at !== null ||
        tokenRow.token_sha256 !== tokenHash
    ) {
        return json(403, { error: 'Invalid ingest token' });
    }

    const payload = (await request.json()) as IngestPayload;
    const rows = normalizeRows(payload);

    if (rows.length === 0) {
        return json(400, { error: 'No account snapshots supplied' });
    }

    const { error: upsertError } = await client
        .from('codex_account_snapshots')
        .upsert(rows, { onConflict: 'account_id' });

    if (upsertError) {
        return json(500, { error: upsertError.message });
    }

    return json(200, { ok: true, count: rows.length });
});
