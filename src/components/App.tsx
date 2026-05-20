import type { CSSProperties, JSX } from 'react';
import { useQuery } from '@tanstack/react-query';
import {
    Activity,
    AlarmClock,
    ArrowUpRight,
    Blend,
    Clock3,
    Database,
    Gauge,
    Layers3,
    RefreshCw,
    ShieldCheck,
    TimerReset,
} from 'lucide-react';

import { fetchCache } from '../lib/api.js';
import {
    formatCountdown,
    formatHours,
    formatPercentage,
    formatRelativeTime,
    formatSyncAge,
    formatWindowLabel,
} from '../lib/format.js';
import type {
    AccountSnapshot,
    CachePayload,
    HistorySnapshot,
    UsageWindow,
} from '../types.js';

const approachList = [
    {
        title: 'Menu bar pusher',
        description:
            'Keep one lightweight macOS utility logged into each account profile and push normalized snapshots into the local cache every few minutes.',
    },
    {
        title: 'Browser profile collectors',
        description:
            'Run one Chrome profile per account and let a local script read the session, mint the access token, and update the same cache file.',
    },
    {
        title: 'Remote account relays',
        description:
            'Deploy small per-account workers or home agents that only ship sanitized usage windows into your machine, never raw cookies.',
    },
];

function getPaceTone(pace: AccountSnapshot['pace']): string {
    switch (pace.status) {
        case 'ahead': {
            return 'tone-ahead';
        }

        case 'tight': {
            return 'tone-tight';
        }

        case 'over': {
            return 'tone-over';
        }

        default: {
            return 'tone-steady';
        }
    }
}

function renderWindow(window: UsageWindow, icon: JSX.Element): JSX.Element {
    return (
        <article className='window-card'>
            <div className='window-heading'>
                <div className='window-label'>
                    {icon}
                    <span>{window.label}</span>
                </div>
                <span className='window-percent'>
                    {formatPercentage(window.usedPercentage)}
                </span>
            </div>

            <div aria-hidden='true' className='meter-shell'>
                <div
                    aria-hidden='true'
                    className='meter-fill'
                    style={
                        {
                            '--meter-width': `${window.usedPercentage}%`,
                        } as CSSProperties
                    }
                />
            </div>

            <div className='window-metrics'>
                <strong>
                    {formatHours(window.usedMinutes)} /{' '}
                    {formatHours(window.limitMinutes)}
                </strong>
                <span>{formatWindowLabel(window)}</span>
            </div>

            <div className='window-reset'>
                <span>Resets in</span>
                <strong>{formatCountdown(window.resetsAt)}</strong>
            </div>
        </article>
    );
}

function renderAccount(account: AccountSnapshot): JSX.Element {
    const history: HistorySnapshot[] = account.history.toReversed().slice(0, 5);

    return (
        <article className='account-card' key={account.accountId}>
            <header className='account-header'>
                <div>
                    <p className='account-kicker'>{account.plan}</p>
                    <h3>{account.label}</h3>
                    <p className='account-meta'>
                        {account.email} / {account.workspaceLabel}
                    </p>
                </div>

                <div
                    className='account-chip'
                    style={
                        {
                            '--chip-color': account.color,
                        } as CSSProperties
                    }
                >
                    <span className='account-chip-dot' />
                    {account.source}
                </div>
            </header>

            <div className='account-grid'>
                {renderWindow(
                    account.weeklyWindow,
                    <AlarmClock aria-hidden='true' size={16} />
                )}
                {renderWindow(
                    account.rollingWindow,
                    <Clock3 aria-hidden='true' size={16} />
                )}
            </div>

            <section className='pace-strip'>
                <div className='pace-copy'>
                    <span className='section-overline'>Pace</span>
                    <strong className={getPaceTone(account.pace)}>
                        {account.pace.summary}
                    </strong>
                </div>
                <p>{account.pace.detail}</p>
            </section>

            <section className='history-panel'>
                <div className='history-heading'>
                    <span className='section-overline'>Latest captures</span>
                    <span>
                        Last sync {formatRelativeTime(account.lastSyncedAt)}
                    </span>
                </div>

                <ul className='history-list'>
                    {history.map((entry: HistorySnapshot) => (
                        <li key={entry.capturedAt}>
                            <div>
                                <strong>
                                    {formatRelativeTime(entry.capturedAt)}
                                </strong>
                                <span>{entry.note}</span>
                            </div>
                            <div className='history-values'>
                                <span>
                                    Week {formatHours(entry.weeklyUsedMinutes)}
                                </span>
                                <span>
                                    5h {formatHours(entry.rollingUsedMinutes)}
                                </span>
                            </div>
                        </li>
                    ))}
                </ul>
            </section>
        </article>
    );
}

function renderSummary(cache: CachePayload): JSX.Element {
    const accountCount = cache.accounts.length;
    const weeklyMinutes = cache.accounts.reduce(
        (sum, account) => sum + account.weeklyWindow.usedMinutes,
        0
    );
    const rollingMinutes = cache.accounts.reduce(
        (sum, account) => sum + account.rollingWindow.usedMinutes,
        0
    );
    const mostUrgentReset: AccountSnapshot | undefined = [...cache.accounts]
        .toSorted(
            (left: AccountSnapshot, right: AccountSnapshot) =>
                new Date(left.rollingWindow.resetsAt).getTime() -
                new Date(right.rollingWindow.resetsAt).getTime()
        )
        .at(0);

    return (
        <section className='summary-strip'>
            <article>
                <span className='section-overline'>Tracked accounts</span>
                <strong>{accountCount}</strong>
                <p>Separate cookies, one local portfolio view.</p>
            </article>

            <article>
                <span className='section-overline'>Weekly burn</span>
                <strong>{formatHours(weeklyMinutes)}</strong>
                <p>Combined usage across the active cache.</p>
            </article>

            <article>
                <span className='section-overline'>Rolling 5h</span>
                <strong>{formatHours(rollingMinutes)}</strong>
                <p>Useful when choosing the next account to burn.</p>
            </article>

            <article>
                <span className='section-overline'>Next reset</span>
                <strong>
                    {mostUrgentReset === undefined
                        ? 'n/a'
                        : formatCountdown(
                              mostUrgentReset.rollingWindow.resetsAt
                          )}
                </strong>
                <p>
                    {mostUrgentReset === undefined
                        ? 'No accounts loaded.'
                        : `${mostUrgentReset.label} rolling window`}
                </p>
            </article>
        </section>
    );
}

export function App(): JSX.Element {
    const cacheQuery = useQuery({
        queryKey: ['cache'],
        queryFn: fetchCache,
        refetchInterval: 60_000,
    });

    const cache = cacheQuery.data;

    return (
        <main className='app-shell'>
            <section className='hero-panel'>
                <div className='hero-grid'>
                    <div className='hero-copy'>
                        <div className='eyebrow'>
                            <Blend aria-hidden='true' size={16} />
                            Multi-account Codex telemetry
                        </div>

                        <p className='hero-kicker'>CodexBoard</p>
                        <h1>
                            One local dashboard for every Codex account you are
                            cycling through.
                        </h1>
                        <p className='hero-lede'>
                            The browser view stays local. Small account agents
                            keep pushing fresh weekly, rolling 5-hour, pace, and
                            reset data into a shared cache so you can decide
                            where to spend the next prompt without tab hopping.
                        </p>

                        <div className='hero-actions'>
                            <a
                                className='primary-action'
                                href='http://localhost:8787/api/cache'
                                rel='noreferrer'
                                target='_blank'
                            >
                                Inspect local cache
                                <ArrowUpRight aria-hidden='true' size={16} />
                            </a>
                            <a
                                className='secondary-action'
                                href='https://github.com/steipete/CodexBar'
                                rel='noreferrer'
                                target='_blank'
                            >
                                CodexBar reference
                            </a>
                        </div>
                    </div>

                    <div className='status-panel'>
                        <div className='status-card'>
                            <div className='status-heading'>
                                <Database aria-hidden='true' size={16} />
                                Cache endpoint
                            </div>
                            <strong>localhost:8787</strong>
                            <p>
                                {cache === undefined
                                    ? 'Waiting for local API.'
                                    : cache.meta.cachePath}
                            </p>
                        </div>

                        <div className='status-card'>
                            <div className='status-heading'>
                                <RefreshCw aria-hidden='true' size={16} />
                                Freshness
                            </div>
                            <strong>
                                {cache === undefined
                                    ? 'Offline'
                                    : formatSyncAge(cache.meta.generatedAt)}
                            </strong>
                            <p>
                                {cache === undefined
                                    ? 'Start the Bun server and feeder.'
                                    : `Last build at ${new Date(
                                          cache.meta.generatedAt
                                      ).toLocaleString()}`}
                            </p>
                        </div>

                        <div className='status-card'>
                            <div className='status-heading'>
                                <ShieldCheck aria-hidden='true' size={16} />
                                Cookie model
                            </div>
                            <strong>Account-isolated</strong>
                            <p>
                                Each feeder keeps its own cookie and only emits
                                sanitized usage windows into the cache.
                            </p>
                        </div>
                    </div>
                </div>
            </section>

            {cacheQuery.isError ? (
                <section className='error-panel'>
                    <h2>Local cache unavailable</h2>
                    <p>
                        Start `bun run dev:server` or `bun run dev` to expose
                        the local cache API. The dashboard expects `GET
                        /api/cache`.
                    </p>
                </section>
            ) : undefined}

            {cache === undefined ? undefined : renderSummary(cache)}

            <section className='section-shell'>
                <div className='section-heading'>
                    <div>
                        <span className='section-overline'>
                            Account portfolio
                        </span>
                        <h2>
                            Weekly, 5-hour, pace, and reset timing together.
                        </h2>
                    </div>
                    <p>
                        The cards below are normalized snapshots. They do not
                        depend on holding every account open in the browser at
                        once.
                    </p>
                </div>

                <div className='accounts-grid'>
                    {cache?.accounts.map((account) => renderAccount(account))}
                </div>
            </section>

            <section className='section-shell architecture-panel'>
                <div className='section-heading'>
                    <div>
                        <span className='section-overline'>
                            Local architecture
                        </span>
                        <h2>Three moving pieces, one durable cache.</h2>
                    </div>
                    <p>
                        This is built for the current constraint: one cookie can
                        only expose one account context at a time.
                    </p>
                </div>

                <div className='architecture-grid'>
                    <article className='architecture-card'>
                        <Layers3 aria-hidden='true' size={20} />
                        <h3>Frontend dashboard</h3>
                        <p>
                            Vite + React renders the local cache, aggregates
                            resets, and lets you compare accounts side by side.
                        </p>
                    </article>

                    <article className='architecture-card'>
                        <Database aria-hidden='true' size={20} />
                        <h3>Bun cache service</h3>
                        <p>
                            A local API stores sanitized snapshots in a JSON
                            file under your home directory so the UI can poll
                            one stable source.
                        </p>
                    </article>

                    <article className='architecture-card'>
                        <Activity aria-hidden='true' size={20} />
                        <h3>macOS feeder</h3>
                        <p>
                            The Swift menu bar agent fetches per-account Codex
                            usage using that account&apos;s own ChatGPT cookie,
                            then posts the normalized result back to the local
                            cache.
                        </p>
                    </article>
                </div>
            </section>

            <section className='section-shell proposal-panel'>
                <div className='section-heading'>
                    <div>
                        <span className='section-overline'>
                            Other approaches
                        </span>
                        <h2>
                            Ways to improve multi-account tracking beyond the
                            MVP.
                        </h2>
                    </div>
                    <p>
                        If the cookie-based path becomes brittle, these are the
                        next practical upgrades.
                    </p>
                </div>

                <div className='proposal-grid'>
                    {approachList.map((approach) => (
                        <article className='proposal-card' key={approach.title}>
                            <Gauge aria-hidden='true' size={18} />
                            <h3>{approach.title}</h3>
                            <p>{approach.description}</p>
                        </article>
                    ))}
                </div>
            </section>

            <section className='section-shell footer-panel'>
                <div className='footer-note'>
                    <TimerReset aria-hidden='true' size={18} />
                    <p>
                        The bundled demo data is stored locally and can be
                        replaced by live snapshots once the feeder is
                        configured.
                    </p>
                </div>
            </section>
        </main>
    );
}
