import type { CachePayload } from '../types.js';

export async function fetchCache(): Promise<CachePayload> {
    const response = await fetch('/api/cache');

    if (!response.ok) {
        throw new Error(`Cache request failed with ${response.status}.`);
    }

    return (await response.json()) as CachePayload;
}
