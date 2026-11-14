---
name: herk-edit-kit
description: Nate Herk's video-editing kit (HyperFrames) - edit videos, reels, YouTube Shorts with transcript-driven cuts, storytelling, and 406 motion-graphics cards. Use when the user wants to edit a recording, cut silences/mistakes, make a reel or Short, or build motion graphics/animations.
---

# Herk Edit Kit (pointer skill)

The full kit is checked out at `__KIT_ROOT__`
(source: https://github.com/nateherkai/herk-edit-kit).

## How to use this skill

1. Treat `__KIT_ROOT__` as the kit workspace root. All kit-relative paths below
   resolve from there (`style-library/...`, `docs/...`, `video-projects/...`).
2. Before doing a task, read the matching real skill bundle:
   `__KIT_ROOT__\.agents\skills\<skill-name>\SKILL.md`.
3. First-time setup on a fresh machine (kit needs Node 22+, Git, FFmpeg with
   ffprobe, Chrome/Chromium): run inside the kit root:
   `npm ci` then `npm run setup` (creates `.env` only if absent; optional API
   keys for ElevenLabs/Kie.ai - local Whisper path needs none).

## Skill map

| Bundle (`__KIT_ROOT__\.agents\skills\`) | Purpose |
| --- | --- |
| edit-video | Full edit pipeline: transcribe, cut silences+mistakes, storytelling, motion graphics, verified render |
| cut-silences | Agent 1: remove silences/dead air from talking-head recordings |
| cut-mistakes | Agent 2: find/remove spoken mistakes (stutters, retakes) |
| video-storytelling | Visual arc for long-form talking-head videos |
| short-form-edit | Turn footage into reels/YouTube Shorts with hook + captions + B-roll |
| short-form-video | Legacy May Shorts teaching compositions |
| motion-showreel | 10-30 s motion-design showreel/brand reel on a beat grid |
| make-a-video | Beginner end-to-end video creator |
| hyperframes | Create compositions, animations, title cards, overlays, captions |
| hyperframes-cli | `npx hyperframes` CLI: init, lint, preview, render, transcribe, doctor |
| hyperframes-registry | Install/wire registry blocks into compositions |
| hyperframes-video-beats | Plan/time/validate motion-graphic beats |
| style-library | Pick/adapt from 406 motion-graphics cards + templates |
| gsap | GSAP animation reference for HyperFrames |
| website-to-hyperframes | Turn a website into HyperFrames scenes |

Slash command note (Antigravity CLI): each bundle installed under
`~\.gemini\config\skills\` also becomes a `/command` automatically; with this
pointer installed, just say the task (e.g. "edit my recording at <path>") and
the agent routes to the right bundle.
