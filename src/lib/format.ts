import type { UsageWindow } from '../types.js';

function formatDuration(totalMinutes: number): string {
    const hours = Math.floor(totalMinutes / 60);
    const minutes = totalMinutes % 60;

    if (hours === 0) {
        return `${minutes}m`;
    }

    if (minutes === 0) {
        return `${hours}h`;
    }

    return `${hours}h ${minutes}m`;
}

export function formatHours(totalMinutes: number): string {
    return `${(totalMinutes / 60).toFixed(1)}h`;
}

export function formatWindowLabel(window: UsageWindow): string {
    return `${formatDuration(window.remainingMinutes)} left of ${window.label.toLowerCase()}`;
}

export function formatPercentage(value: number): string {
    return `${Math.round(value)}%`;
}

export function formatCountdown(resetAt: string): string {
    const diffMs = new Date(resetAt).getTime() - Date.now();

    if (diffMs <= 0) {
        return 'resetting now';
    }

    const totalMinutes = Math.floor(diffMs / 60_000);
    const days = Math.floor(totalMinutes / (60 * 24));
    const hours = Math.floor((totalMinutes % (60 * 24)) / 60);
    const minutes = totalMinutes % 60;

    if (days > 0) {
        return `${days}d ${hours}h`;
    }

    if (hours > 0) {
        return `${hours}h ${minutes}m`;
    }

    return `${minutes}m`;
}

export function formatRelativeTime(value: string): string {
    const diffMs = Date.now() - new Date(value).getTime();
    const diffMinutes = Math.round(diffMs / 60_000);

    if (diffMinutes < 1) {
        return 'just now';
    }

    if (diffMinutes < 60) {
        return `${diffMinutes}m ago`;
    }

    const diffHours = Math.round(diffMinutes / 60);

    if (diffHours < 24) {
        return `${diffHours}h ago`;
    }

    const diffDays = Math.round(diffHours / 24);
    return `${diffDays}d ago`;
}

export function formatSyncAge(value: string): string {
    return `Updated ${formatRelativeTime(value)}`;
}
