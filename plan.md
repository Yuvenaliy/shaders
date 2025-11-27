# Liquid Intro Studio — Technical & UX Blueprint

## Vision
Create a mobile-first “Liquid Intro Studio” that lets anyone generate 3–5s vertical intros/outros with liquid light visuals synced to music. Users choose format, drop in a name/@handle, pick a lo‑fi mood (BPM/Groove), and export/share instantly. All rendering and audio happen on-device (Metal + AVAudioEngine/AudioKit), with HDR/bloom visuals and beat-synced dynamics.

## Core Pillars
- **AAA visual fidelity:** HDR trails, ping‑pong accumulation, bloom, 120 fps target.
- **Audio-reactive:** On-device lo‑fi generator; beat and amplitude drive visual pulses.
- **One-tap creation:** Minimal UI; presets and timeline automation.
- **Share/export ready:** Vertical formats, clean video export without UI.

## User Flows

### 1) Launch / Home
- Fullscreen canvas preview.
- Primary CTA: `Create Liquid Intro`.
- Format chips: `TikTok/Reels (9:16, 3–5s)`, `Stories (9:16)`, `Wallpaper Loop (16:9 / device res)`.
- Secondary: `Settings` (less prominent), `Gallery/Exports`.

### 2) Intro Setup
- **Text input:** single field `@nickname / short phrase` (limit ~20 chars). Live preview overlay.
- **Audio options:**
  - `Use generated lo‑fi` (default).
  - `Pick from Files/Music` (local import; optional).
  - `No sound` (for wallpapers).
- **Preset picker:** segmented control or cards (e.g., `Pulsar`, `Supernova`, `Quark`, `Cold Nebula`, `Dreamy`, `Nostalgic`).
- **Minimal sliders:**
  - `BPM` (60–110).
  - `Groove/Swing` (0–1).
  - `Mood` (lo‑fi style enum).
- Start button: `Generate Preview`.

### 3) Preview Screen
- Fullscreen playback of 3–5s timeline loop.
- Bottom bar:
  - `Regenerate` (rerun seed/timeline).
  - `Edit Text`.
  - `Export / Share`.
  - Subtle indicators for BPM/Groove, preset name.
- Tap gesture still manipulates fluid in real time (optional, non-destructive).

### 4) Export
- Options: `Save Video (1080p/4K)`, `Share to TikTok/Reels/Stories`, `Save as Live Wallpaper` (if supported).
- Duration selector: `3s / 5s / 8s loop`.
- Quality toggle: `1080p` (default), `4K` (if perf allows).
- Background export with progress HUD; no UI in output.

### 5) Gallery
- Grid/list of past exports with thumbnail + duration + format badge.
- Tap to play; share/delete.

## Rendering & Audio Architecture

### Rendering (Metal)
- **Ping-pong trail buffers:** `TextureA/TextureB` in `rgba16Float`, diffusion + dissipation compute pass.
- **Particles:** ~262k points; compute sim updates pos/vel.
- **Bloom:** downsample to half res, separable Gaussian blur (X/Y), composite with tone mapping.
- **Tone map:** simple Reinhard + gamma; preserves neon glow.
- **Inputs to shaders:** time, touch force/pos, audio beat flags, amplitude envelope, preset params (color palette, glow gain, noise scale).
- **Future-proof hooks:** velocity field / Navier-Stokes grid (optional v2).

### Audio (LoFiEngine)
- **Engine:** `AVAudioEngine + AudioKit` (samplers).
- **Instruments:** kick, snare/clap, hi-hat, vinyl crackle loop, Rhodes chords (3–5), bass note.
- **Parameters:** `bpm`, `groove` (swing offset), `mood` (preset chord set / kit), `seed`.
- **Pattern:** 16-step kick/snare/hat with swing on even steps; simple chord/bass loop per bar.
- **Callbacks:** `onBeat(stepIndex, time)` per 16th, `onBar(barIndex)`.
- **Metrics:** `amplitude` (RMS/peak) updated per block; `isKick`/`isSnare` flags for current frame.
- **Sync:** Engine started ~2s before render capture; shared clock for timeline.

### Audio → Visual Mapping
- Uniforms extended with: `kickPulse`, `snarePulse`, `amplitude`, `beatPhase`, `bloomBoost`.
- On kick: multiply forceStrength / inject pulse, transient bloom boost.
- On amplitude: scale idle noise jitter, slight trail diffusion change for “breathing”.
- Preset maps define sensitivities (how much bloom/force responds).

### Timeline Automation (3–5s intro)
- **Phase 1 (0–1s):** chaotic flow, higher noise, no text.
- **Phase 2 (1–3s):** text forms; stabilize flow; bloom tied to kicks.
- **Phase 3 (3–5s):** text dissolves; final flare on last strong beat; fade to logo/blank.
- Optional: intro/outro pulses keyed to bar starts/ends.

## UI/UX Details
- Typography: bold, minimal (e.g., custom condensed sans for labels). Keep text overlaid unobtrusively on preview.
- Controls: thumb-friendly sliders; segmented presets; minimal clutter.
- Colors: UI chrome subdued (glass/blur), canvas is the hero.
- Haptics: light tick on beat-aligned interactions (start, export done).
- Accessibility: color-safe default palette; captions for errors; respectful of mute switch (visual-only mode).

## File/Module Layout
- `FluidMetalView/ParticleMagicView.swift` — renderer + shaders (current).
- `LoFiEngine.swift` — audio engine, patterns, callbacks, amplitude metrics.
- `Preset.swift` — visual/audio preset definitions (palettes, sensitivities, chord sets).
- `TimelineDirector.swift` — phase scheduling (chaos → text → dissolve), triggers for pulses.
- `TextLayer.swift` — render text to Metal texture (CoreGraphics → MTLTexture), composited into HDR chain.
- `ExportManager.swift` — AVAssetWriter pipeline for clean video export.
- `UI`: SwiftUI screens
  - `HomeView` (CTA + format chips)
  - `SetupView` (text, audio choice, preset, sliders)
  - `PreviewView` (playback, regenerate, edit text, export)
  - `GalleryView`

## Data Models (draft)
- `Preset`:
  - `name`, `palette`, `baseBloom`, `bloomResponse`, `forceResponse`, `noiseScale`, `chordSet`, `kitName`.
- `TimelinePhase`:
  - `start`, `end`, `mode` (.chaos/.text/.dissolve), `targetBloom`, `forceMultiplier`, `textVisibility`.
- `ExportConfig`:
  - `duration`, `resolution`, `format`, `loopCount`.

## Integration Steps (High Level)
1) **Stabilize renderer**: ensure 1D compute dispatch for particles; keep ping-pong/bloom working.
2) **LoFiEngine**: implement sampler loading, metronome, swing, callbacks, amplitude.
3) **Uniform extensions**: add audio-driven fields; wire to compute/fragment shaders (kick/bloom/noise).
4) **Text layer**: render @nickname into HDR texture; blend in pipeline (before bloom).
5) **TimelineDirector**: scripted phases tied to beats/bars; toggle text visibility/forces/bloom targets.
6) **UI scaffolding**: Home → Setup → Preview → Export; presets and sliders.
7) **Export**: AVAssetWriter from trail HDR → tone-mapped output; 1080p/4K options; background-friendly.
8) **Gallery**: store thumbnails + metadata; simple viewer/share/delete.
9) **Polish**: haptics, error states (missing audio permissions), performance tuning (MetalFX optional later).

## Open Technical Notes
- Current code needs particle compute dispatch set to 1D (threadsPerThreadgroup = (w,1,1)) to avoid SIGABRT.
- Text compositing: decide whether to diffuse text with trails or overlay post-bloom; likely pre-bloom for glow.
- Export performance: consider offscreen resolution (half res + MetalFX later) for thermals.
- Audio import: if local files used, compute RMS envelope offline per segment for sync.

## Milestones (suggested)
- **Week 1:** Fix dispatch, integrate LoFiEngine (kick/snare/amp callbacks), add uniforms, simple kick-driven bloom pulses.
- **Week 2:** Text layer + TimelineDirector phases; presets wired to visual/audio responses; Preview flow UI.
- **Week 3:** Export pipeline (1080p), Gallery, polish UX/haptics.
- **Stretch:** MetalFX upscale, 4K export, Navier-Stokes velocity grid.
