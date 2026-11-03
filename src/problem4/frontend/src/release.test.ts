import { describe, expect, it } from 'vitest'
import { parseBackendRelease, shortRelease } from './release'

describe('parseBackendRelease', () => {
  it('returns the release from a well-formed payload', () => {
    expect(parseBackendRelease({ release: 'abc123' })).toBe('abc123')
  })

  it.each([null, undefined, 'abc', 42, {}, { release: '' }, { release: 7 }])(
    'rejects malformed payload %j',
    (body) => {
      expect(parseBackendRelease(body)).toBeNull()
    },
  )
})

describe('shortRelease', () => {
  it('shortens a full git SHA', () => {
    expect(shortRelease('0123456789abcdef0123456789abcdef01234567')).toBe('0123456')
  })

  it('leaves non-SHA identifiers alone', () => {
    expect(shortRelease('dev')).toBe('dev')
  })
})
