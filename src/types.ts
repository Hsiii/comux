export interface UsageWindow {
    label: string;
    usedMinutes: number;
    limitMinutes: number;
    remainingMinutes: number;
    usedPercentage: number;
    resetsAt: string;
}

export interface PaceSnapshot {
    status: 'ahead' | 'steady' | 'tight' | 'over';
    summary: string;
    detail: string;
}

export interface HistorySnapshot {
    capturedAt: string;
    weeklyUsedMinutes: number;
    rollingUsedMinutes: number;
    note: string;
}

export interface AccountSnapshot {
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
}

export interface CachePayload {
    meta: {
        generatedAt: string;
        cachePath: string;
        source: string;
    };
    accounts: AccountSnapshot[];
}
