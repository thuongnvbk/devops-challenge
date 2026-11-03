import { parseBackendRelease, shortRelease } from './release'
import './style.css'

const app = document.querySelector<HTMLElement>('#app')
if (!app) {
  throw new Error('#app mount point missing from index.html')
}

const frontendRelease =
  document.querySelector('meta[name="release"]')?.getAttribute('content') ?? 'unknown'

const heading = document.createElement('h1')
heading.textContent = 'Ship It Twice'

const status = document.createElement('p')
const render = (backend: string): void => {
  status.textContent = `frontend ${shortRelease(frontendRelease)} / backend ${backend}`
}
render('loading')
app.append(heading, status)

// Same-origin: CloudFront routes /api/* to the backend ALB, so the bundle
// carries no environment-specific URLs and one build serves every stage.
fetch('/api/version', { headers: { accept: 'application/json' } })
  .then((res) => (res.ok ? res.json() : Promise.reject(new Error(`HTTP ${res.status}`))))
  .then((body: unknown) => render(shortRelease(parseBackendRelease(body) ?? 'unknown')))
  .catch(() => render('unreachable'))
