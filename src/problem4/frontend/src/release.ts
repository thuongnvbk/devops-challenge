/** Extracts the release id from the backend's GET /api/version payload. */
export function parseBackendRelease(body: unknown): string | null {
  if (typeof body !== 'object' || body === null || !('release' in body)) {
    return null
  }
  const { release } = body as { release: unknown }
  return typeof release === 'string' && release.length > 0 ? release : null
}

/** Shortens a full git SHA for display; leaves anything else untouched. */
export function shortRelease(release: string): string {
  return /^[0-9a-f]{40}$/.test(release) ? release.slice(0, 7) : release
}
