// @vitest-environment happy-dom
// Settings → Apple Watch: one Apple Health story. The phone's Apple Health switch (Settings → Data)
// is the one switch; this page says what the watch makes of it and leads there.
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createRoot } from 'react-dom/client'
import { act } from 'react'
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom'

const mocks = vi.hoisted(() => ({ health: { on: false }, link: { paired: true, installed: true }, traces: null, exported: 0 }))
vi.mock('../lib/health-sync.js', () => ({ loadHealth: async () => mocks.health, onHealthChange: () => () => {} }))
vi.mock('../lib/watch-sync.js', () => ({
  watchStatus: async () => mocks.link,
  watchTraces: async () => mocks.traces,
  exportWatchTraces: async () => { mocks.exported++; return mocks.traces?.count || 0 },
}))

import WatchSettingsPage from './WatchSettings.jsx'
import { readWatchPrefs, writeWatchStatus } from '../lib/watch-settings.js'

globalThis.IS_REACT_ACT_ENVIRONMENT = true
let where = null
function Where() { where = useLocation(); return null }

async function mount() {
  const el = document.createElement('div')
  document.body.replaceChildren(el)
  await act(async () => {
    createRoot(el).render(<MemoryRouter initialEntries={['/settings/watch']}><Routes>
      <Route path="/settings/watch" element={<WatchSettingsPage />} />
      <Route path="*" element={<Where />} />
    </Routes></MemoryRouter>)
  })
  return el
}
const row = (el, title) => [...el.querySelectorAll('.lrow')].find(r => r.querySelector('.lrow-t')?.textContent === title)

beforeEach(() => { localStorage.clear(); mocks.health = { on: false }; mocks.traces = null; mocks.exported = 0; where = null })

describe('Settings → Apple Watch', () => {
  it('shows Apple Health as the phone has it, and leads to its switch', async () => {
    const el = await mount()
    expect(row(el, 'Apple Health').querySelector('.lrow-v').textContent).toBe('Off')
    expect(el.textContent).toContain('Turn on Apple Health and the watch measures your heart rate for every set.')
    expect(row(el, 'Apple Health').querySelector('[role="switch"]')).toBeNull()
    await act(async () => { row(el, 'Apple Health').click() })
    expect(where.pathname).toBe('/settings/data')
    expect(where.state).toEqual({ find: 'Write to Apple Health' })
  })

  it('says when the watch was not allowed to', async () => {
    mocks.health = { on: true }
    writeWatchStatus({ health: 'denied' })
    const el = await mount()
    expect(row(el, 'Apple Health').querySelector('.lrow-v').textContent).toBe('Not allowed')
    expect(el.textContent).toContain('Allow it in the Health app on your iPhone.')
  })

  // TestFlight "the watch is not syncing": the page shows whether the watch app ever checked in
  // (it does each time it starts), so "installed" alone no longer reads as "in touch".
  it('says whether the watch has checked in, and when it last did', async () => {
    let el = await mount()
    expect(el.textContent).toContain('The watch hasn’t checked in yet. Open openGym on it once.')
    writeWatchStatus({ health: 'on', at: Date.now() - 5 * 60e3 })
    el = await mount()
    expect(el.textContent).toContain('Last heard from the watch: 5 minutes ago')
    expect(el.textContent).not.toContain('checked in yet')
  })

  it('has the switch for opening on the watch, on to begin with', async () => {
    const el = await mount()
    const sw = row(el, 'Open on the watch').querySelector('[role="switch"]')
    expect(sw.getAttribute('aria-checked')).toBe('true')
    await act(async () => { sw.click() })
    expect(readWatchPrefs().autoShow).toBe(false)
  })

  it('counts reps on the watch with a tap at each, and leaves ending the set to Done, to begin with', async () => {
    const el = await mount()
    const sw = title => row(el, title)?.querySelector('[role="switch"]')
    expect(sw('Count reps on the watch').getAttribute('aria-checked')).toBe('true')
    expect(sw('Tap the wrist at each rep').getAttribute('aria-checked')).toBe('true')
    expect(sw('End the set by itself').getAttribute('aria-checked')).toBe('false')
    await act(async () => { sw('End the set by itself').click() })
    expect(readWatchPrefs().autoEnd).toBe(true)
    // Off: nothing left to choose about it.
    await act(async () => { sw('Count reps on the watch').click() })
    expect(readWatchPrefs().autoReps).toBe(false)
    expect(row(el, 'Tap the wrist at each rep')).toBeUndefined()
    expect(row(el, 'End the set by itself')).toBeUndefined()
  })

  it('shows the recorded sets this phone has and exports them, when there are some', async () => {
    let el = await mount()
    expect(row(el, 'Recorded sets')).toBeUndefined()
    mocks.traces = { count: 0 }
    el = await mount()
    expect(row(el, 'Recorded sets').querySelector('.lrow-v').textContent).toBe('0')
    expect(row(el, 'Export recorded sets')).toBeUndefined()
    mocks.traces = { count: 12 }
    el = await mount()
    expect(row(el, 'Recorded sets').querySelector('.lrow-v').textContent).toBe('12')
    await act(async () => { row(el, 'Export recorded sets').click() })
    expect(mocks.exported).toBe(1)
  })

  it('lets you pick what the watch shows, one switch at a time, clean to begin with', async () => {
    const el = await mount()
    const sw = title => row(el, title).querySelector('[role="switch"]')
    expect(sw('Exercise animation').getAttribute('aria-checked')).toBe('true')
    expect(sw('Calories').getAttribute('aria-checked')).toBe('false')
    expect(sw('Time so far').getAttribute('aria-checked')).toBe('false')
    await act(async () => { sw('Calories').click() })
    await act(async () => { sw('Exercise animation').click() })
    expect(readWatchPrefs().show).toMatchObject({ kcal: true, clip: false, hr: true, rest: 'ring' })
    expect(row(el, 'Rest timer')).toBeTruthy()
    expect(row(el, 'The Digital Crown turns first')).toBeUndefined()
  })
})

