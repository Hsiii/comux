import type { CSSProperties, JSX } from 'react';
import { useEffect, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Clock3, Pencil, RefreshCw } from 'lucide-react';

import { fetchCache } from '../lib/api.js';
import {
    formatCountdown,
    formatPercentage,
    formatRelativeTime,
} from '../lib/format.js';
import type { AccountSnapshot, CachePayload, UsageWindow } from '../types.js';

const nicknameStorageKey = 'codexboard.nicknames.v1';

type NicknameMap = Record<string, string>;

function getAccountSnapshotKey(account: AccountSnapshot): string {
    return [account.accountId, account.plan, account.workspaceLabel].join('::');
}

function clampPercentage(value: number): number {
    return Math.min(100, Math.max(0, value));
}

function getTierLabel(plan: string): string {
    const normalized = plan.trim().toLowerCase();

    if (normalized.includes('team')) {
        return 'Team';
    }

    if (normalized.includes('free')) {
        return 'Free';
    }

    if (normalized.includes('pro')) {
        return 'Pro';
    }

    if (normalized.startsWith('codex ')) {
        return plan.slice(6);
    }

    return plan;
}

function getRemainingPercentage(window: UsageWindow): number {
    return clampPercentage(100 - window.usedPercentage);
}

function getWindowDurationMs(window: UsageWindow): number | undefined {
    const label = window.label.trim().toLowerCase();

    if (label.includes('week')) {
        return 7 * 24 * 60 * 60 * 1000;
    }

    if (label.includes('5h')) {
        return 5 * 60 * 60 * 1000;
    }

    return undefined;
}

function getPacePercentage(window: UsageWindow): number {
    if (window.available === false) {
        return 0;
    }

    const durationMs = getWindowDurationMs(window);
    const resetAtMs = new Date(window.resetsAt).getTime();

    if (
        durationMs === undefined ||
        Number.isNaN(resetAtMs) ||
        durationMs <= 0
    ) {
        return 0;
    }

    const startAtMs = resetAtMs - durationMs;
    const elapsedMs = Date.now() - startAtMs;
    return clampPercentage((elapsedMs / durationMs) * 100);
}

function getNextResetWindow(account: AccountSnapshot): UsageWindow {
    if (account.rollingWindow.available === false) {
        return account.weeklyWindow;
    }

    return new Date(account.rollingWindow.resetsAt).getTime() <=
        new Date(account.weeklyWindow.resetsAt).getTime()
        ? account.rollingWindow
        : account.weeklyWindow;
}

function getDisplayName(
    account: AccountSnapshot,
    nicknames: NicknameMap
): string {
    const nickname = nicknames[account.accountId] ?? '';
    const trimmedNickname = nickname.trim();
    return trimmedNickname === '' ? account.label : trimmedNickname;
}

function loadNicknames(): NicknameMap {
    try {
        const raw = globalThis.localStorage.getItem(nicknameStorageKey);

        if (raw === null) {
            return {};
        }

        const parsed = JSON.parse(raw) as NicknameMap;
        return parsed;
    } catch {
        return {};
    }
}

function saveNicknames(nicknames: NicknameMap) {
    globalThis.localStorage.setItem(
        nicknameStorageKey,
        JSON.stringify(nicknames)
    );
}

function renderUsageBar(
    window: UsageWindow,
    options: {
        compact?: boolean;
    } = {}
): JSX.Element | undefined {
    if (window.available === false) {
        return undefined;
    }

    const remaining = getRemainingPercentage(window);
    const pace = getPacePercentage(window);
    const className =
        options.compact === true
            ? 'usage-block usage-block-compact'
            : 'usage-block';

    return (
        <section className={className}>
            <div className='usage-copy'>
                <span>{window.label}</span>
                <strong>{formatPercentage(remaining)} left</strong>
            </div>

            <div
                aria-hidden='true'
                className='usage-rail'
                style={
                    {
                        '--bar-progress': `${clampPercentage(
                            window.usedPercentage
                        )}%`,
                        '--pace-progress': `${pace}%`,
                    } as CSSProperties
                }
            >
                <div className='usage-pace' />
                <div className='usage-fill' />
            </div>
        </section>
    );
}

function renderAccount(
    account: AccountSnapshot,
    nicknames: NicknameMap,
    onEdit: (account: AccountSnapshot) => void
): JSX.Element {
    const nextResetWindow = getNextResetWindow(account);
    const displayName = getDisplayName(account, nicknames);
    const tier = getTierLabel(account.plan);

    return (
        <article className='account-card' key={getAccountSnapshotKey(account)}>
            <header className='account-header'>
                <div className='account-title-block'>
                    <div className='account-title-row'>
                        <h2>{displayName}</h2>
                        <button
                            className='edit-button'
                            onClick={() => {
                                onEdit(account);
                            }}
                            type='button'
                        >
                            <Pencil aria-hidden='true' size={14} />
                            Edit
                        </button>
                    </div>
                    <p className='account-tier'>{tier}</p>
                </div>

                <p className='account-sync'>
                    <RefreshCw aria-hidden='true' size={14} />
                    {formatRelativeTime(account.lastSyncedAt)}
                </p>
            </header>

            {renderUsageBar(account.weeklyWindow)}
            {renderUsageBar(account.rollingWindow, { compact: true })}

            <footer className='account-reset'>
                <span>Next reset</span>
                <strong>
                    {nextResetWindow.label} in{' '}
                    {formatCountdown(nextResetWindow.resetsAt)}
                </strong>
            </footer>
        </article>
    );
}

function renderNextReset(
    cache: CachePayload,
    nicknames: NicknameMap
): JSX.Element | undefined {
    const nextResetAccount = [...cache.accounts]
        .map((account) => ({
            account,
            window: getNextResetWindow(account),
        }))
        .toSorted(
            (left, right) =>
                new Date(left.window.resetsAt).getTime() -
                new Date(right.window.resetsAt).getTime()
        )
        .at(0);

    if (nextResetAccount === undefined) {
        return undefined;
    }

    return (
        <section className='section-shell next-reset-shell'>
            <div className='section-heading'>
                <div>
                    <span className='section-overline'>Next reset</span>
                    <h1>
                        {getDisplayName(nextResetAccount.account, nicknames)}{' '}
                        resets first.
                    </h1>
                </div>

                <div className='reset-pulse'>
                    <Clock3 aria-hidden='true' size={16} />
                    <strong>
                        {formatCountdown(nextResetAccount.window.resetsAt)}
                    </strong>
                </div>
            </div>

            <p className='next-reset-note'>
                {nextResetAccount.window.label} window for{' '}
                {getTierLabel(nextResetAccount.account.plan)} tier. Updated{' '}
                {formatRelativeTime(nextResetAccount.account.lastSyncedAt)}.
            </p>
        </section>
    );
}

function renderDialog(
    account: AccountSnapshot | undefined,
    draftNickname: string,
    setDraftNickname: (value: string) => void,
    onClose: () => void,
    onSave: () => void
): JSX.Element | undefined {
    if (account === undefined) {
        return undefined;
    }

    return (
        <div className='dialog-backdrop' role='presentation'>
            <dialog
                aria-labelledby='nickname-dialog-title'
                className='nickname-dialog'
                open
            >
                <div className='dialog-copy'>
                    <span className='section-overline'>Account nickname</span>
                    <h2 id='nickname-dialog-title'>{account.label}</h2>
                    <p>{account.email}</p>
                </div>

                <label className='dialog-field'>
                    <span>Nickname</span>
                    <input
                        onChange={(event) => {
                            setDraftNickname(event.target.value);
                        }}
                        type='text'
                        value={draftNickname}
                    />
                </label>

                <div className='dialog-actions'>
                    <button
                        className='dialog-button dialog-button-muted'
                        onClick={onClose}
                        type='button'
                    >
                        Cancel
                    </button>
                    <button
                        className='dialog-button'
                        onClick={onSave}
                        type='button'
                    >
                        Save
                    </button>
                </div>
            </dialog>
        </div>
    );
}

export function App(): JSX.Element {
    const cacheQuery = useQuery({
        queryKey: ['cache'],
        queryFn: fetchCache,
        refetchInterval: 60_000,
    });
    const [nicknames, setNicknames] = useState<NicknameMap>({});
    const [editingAccount, setEditingAccount] = useState<AccountSnapshot>();
    const [draftNickname, setDraftNickname] = useState('');

    useEffect(() => {
        setNicknames(loadNicknames());
    }, []);

    const cache = cacheQuery.data;

    function openEditor(account: AccountSnapshot) {
        setEditingAccount(account);
        setDraftNickname(nicknames[account.accountId] ?? '');
    }

    function closeEditor() {
        setEditingAccount(undefined);
        setDraftNickname('');
    }

    function saveNickname() {
        if (editingAccount === undefined) {
            return;
        }

        const nextNicknames = { ...nicknames };
        const trimmed = draftNickname.trim();

        if (trimmed === '') {
            const restNicknames = Object.fromEntries(
                Object.entries(nextNicknames).filter(
                    ([accountId]) => accountId !== editingAccount.accountId
                )
            );
            setNicknames(restNicknames);
            saveNicknames(restNicknames);
        } else {
            nextNicknames[editingAccount.accountId] = trimmed;
            setNicknames(nextNicknames);
            saveNicknames(nextNicknames);
        }

        closeEditor();
    }

    return (
        <>
            <main className='app-shell'>
                {cacheQuery.isError ? (
                    <section className='section-shell error-panel'>
                        <span className='section-overline'>
                            Cache unavailable
                        </span>
                        <h1>CodexBoard could not load account snapshots.</h1>
                        <p>
                            Check the Supabase envs or the local cache endpoint,
                            then refresh.
                        </p>
                    </section>
                ) : undefined}

                {cache === undefined
                    ? undefined
                    : renderNextReset(cache, nicknames)}

                <section className='section-shell accounts-shell'>
                    <div className='section-heading'>
                        <div>
                            <span className='section-overline'>Accounts</span>
                            <h1>Quota posture at a glance.</h1>
                        </div>

                        <p className='accounts-note'>
                            Weekly is the main bar. Team accounts expose a
                            subtle 5-hour sub bar under it.
                        </p>
                    </div>

                    <div className='accounts-grid'>
                        {cache?.accounts.map((account) =>
                            renderAccount(account, nicknames, openEditor)
                        )}
                    </div>
                </section>
            </main>

            {renderDialog(
                editingAccount,
                draftNickname,
                setDraftNickname,
                closeEditor,
                saveNickname
            )}
        </>
    );
}
