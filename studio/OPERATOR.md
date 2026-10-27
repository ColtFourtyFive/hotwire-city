# Studio Operator protocol

This repo is built by a cloud Claude Code session (the **lead**), which has no Roblox Studio. A Claude session on the owner's Mac (the **operator**) has the official Roblox Studio MCP. It runs Studio jobs for the lead and pushes the evidence back to GitHub.

## One-time setup (operator)

1. Clone this repo, for example to `~/HotwireCity`.
2. Install the Roblox tooling:
   - Install [Rokit](https://github.com/rojo-rbx/rokit).
   - Run `rokit install` in the repo, which installs the pinned `rojo`, `selene`, `stylua` and `lune`.
   - Run `rojo plugin install`.
3. In Studio:
   - Open the published place with **File → Open from Roblox → Hotwire City** (universe 10773288390, place 106226892419530). Use the place from Roblox, not a local file: the game's 3D assets only load in a place owned by the account that uploaded them.
   - Never open or modify the experience "Cursed Clash".
4. In the repo, run `rojo serve` and keep it running. In Studio, go to **Plugins → Rojo → Connect**. Code now live-syncs from the checkout into the open place.
5. Make sure the Roblox Studio MCP tools are available. You should see `list_roblox_studios`, `screen_capture`, `start_stop_play`, `get_console_output` and others.

## Job loop

Run this every ~10 minutes, for example with `/loop 10m follow studio/OPERATOR.md job loop`.

1. Run `git pull --ff-only origin main`. Rojo syncs any changed code into Studio automatically. If `default.project.json` changed, reconnect Rojo.
2. Find jobs: every `studio/jobs/NNNN-*.md` on `main` that has no `studio/results/NNNN/DONE` on the `studio-results` branch.
3. Run each job, in order, exactly as written. Jobs list:
   - which play mode to use;
   - how long to wait after starting;
   - the camera shots to take (position, look-at and name);
   - the playtest steps;
   - what to copy from the console.
4. Write the results into a worktree of the `studio-results` branch: `git worktree add ../HotwireCity-results studio-results`. Create the branch from `main` the first time.
   - `studio/results/NNNN/<shot-name>.png`: every `screen_capture`, saved as a PNG file.
   - `studio/results/NNNN/console.txt`: the full output from `get_console_output`. Include errors and warnings verbatim.
   - `studio/results/NNNN/report.md`: what you did, what you saw, anything that failed, and the Studio version.
   - `studio/results/NNNN/DONE`: an empty file.
5. Commit and `git push origin studio-results`. Then notify the lead with either of these:
   - `claude -p "studio job NNNN done: <one-line summary>" --cloud session_013hTzzkEbxNRPuu2R1Xna4H`
   - SendMessage, if the lead session appears in `/list-agents`.
6. Always stop play mode after a job, and never save or publish the place. The lead publishes through Open Cloud.

## Rules

- Do not edit code in this repo, and never push to `main`. The lead owns `main`. You write only to `studio-results`.
- If a job is ambiguous or impossible, record why in `report.md`, write `DONE`, and move on.
- Screenshots are evidence. Never retouch or crop them, and keep the default UI unless the job says to hide it.
