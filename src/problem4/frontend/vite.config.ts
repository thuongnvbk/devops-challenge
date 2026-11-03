import { defineConfig } from 'vitest/config'

export default defineConfig({
  build: {
    // Everything under assets/ is content-hashed (Vite's default naming), which
    // is what lets the deploy cache it for a year and never invalidate it.
    assetsDir: 'assets',
    sourcemap: false,
  },
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
  },
})
