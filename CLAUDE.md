# GameSpice Replay

Match demos: what a dedicated server authoritatively decided, recorded as tick-stamped opaque records on named channels, in a chunked, compressed, hash-chained file that seeks by keyframe, survives a crash and refuses an edit.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to replays.

**The distributable is `addons/gs_replay/`.** It requires [GameSpice Core](../gs-core) and nothing else (`ln -s ../../gs-core/addons/gs_core addons/gs_core`, gitignored). gs-server and gs-net are reached by duck typing.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | anything: why it exists, opaque payloads, keyframes, the hash chain and what it does not buy, truncation, bounds, the net tap, where it runs, what is not here |
| [docs/history.md](docs/history.md) | what arming the suite and a DEBUG run found |

## Layout

| Path | What |
| --- | --- |
| `core/gs_replay_record.gd` | `GSReplayRecord`: one tick, one channel, one payload, keyframe flag; `value()` |
| `core/gs_replay_header.gd` | `GSReplayHeader`: game, map, tick rate, start time, players at the start, `meta`. Plain data only |
| `core/gs_replay_format.gd` | `GSReplayFormat`: magic, sizes, compression modes, `digest`, `contains_object`, `plain`. The format is drawn in its doc comment |
| `core/gs_replay_chunk.gd` | `GSReplayChunk`: the unit of loss, seeking and verification; carries its own channel table |
| `core/gs_replay_writer.gd` | `GSReplayWriter`: streams and flushes chunks, `finish()` writes index and footer, `evidence()` |
| `core/gs_replay_file.gd` | `GSReplayFile`: the reader. Complete, truncated, or refused with `CODE_INTEGRITY` |
| `runtime/gs_replay_recorder.gd` | `GSReplayRecorder`: `advance` / `record` / `record_value` / `keyframe` / `stop` / `save_clip`; asks `keyframe_fn` |
| `runtime/gs_replay_ring.gd` | `GSReplayRing`: the last N seconds, from a keyframe, capped in bytes; `save()` |
| `runtime/gs_replay_player.gd` | `GSReplayPlayer`: a `Node`; `state_reset` / `record_played` / `seeked` / `finished`, any positive speed, `seek`, `step_ticks`, a channel filter, `now_fn` |
| `runtime/gs_killcam_buffer.gd` | `GSKillcamBuffer`: a client's last seconds of decoded frames and events (kills), bounded by time, frames and events; `frames_between`, `sample`, `last_event` |
| `runtime/gs_killcam.gd` | `GSKillcam`: a `Node` that replays the last kill from a buffer, 3.5 s before to 1 s after, slowed at the kill, inside `max_seconds` (0 disables); skippable; `advance` for tests |
| `runtime/gs_killcam_host.gd` | `GSKillcamHost`: the final-killcam wrapper every game needs (records frames and kills, replays the last at the match end, poses bodies, places the camera); a game assigns `players_fn`, `player_for_fn`, `state_fn`, `place_body_fn`, `restore_body_fn` and friends. [docs/killcam-host.md](docs/killcam-host.md) |
| `runtime/gs_killcam_banner.gd` | `GSKillcamBanner`: the letterbox bars, "FINAL KILLCAM", killer, weapon (and a picture when `icon_provider`, a weapon id -> Texture2D Callable, gives one), progress and a skip button |
| `core/gs_killview_rules.gd` | `GSKillViewRules`: the kill-view policy as `mp_killview*` cvars (`bind_cvars`, `follow_cvars`, `set_cvar`) |
| `runtime/gs_killview_ring.gd` | `GSKillViewRing`: server; per-entity ring of view samples (nothing while off), `note_kill` / `collect` / `clip_for` |
| `runtime/gs_killview_clip.gd` | `GSKillViewClip`: a clip as a `GSKillcamBuffer`; `view_at(sample)` |
| `runtime/gs_killview_player.gd` | `GSKillViewPlayer`: client; plays a clip through `GSKillcam`; `moment` (seconds from the kill, for the game to pose its bodies) / `view` / `finished` / `respawn_requested` |
| `runtime/gs_killview_server.gd` | `GSKillViewServer`: the server half over the ring; the game assigns `eyes_fn` and `hold_fn`/`release_fn` (or `use_respawn_queue`); `record` / `note_kill` / `collect` (holds the respawn) / `skip` / `forget` |
| `runtime/gs_killview_solo.gd` | `GSKillViewSolo`: the offline game's per-tick record and delivery over a `GSKillViewServer`; the local victim's clip goes to `deliver_fn`, `note_kill` / `skip` |
| `runtime/gs_killview_client.gd` | `GSKillViewClient`: the client half; its own camera, the killer's `crosshair`, `hide_fn`, an optional duck-typed `stage` that poses bodies; `play` / `over` / `respawn_requested` |
| `runtime/gs_killcam_framing.gd` | `GSKillcamFraming`: the camera for a killer's eye, the eye itself or behind the killer on a `GSCameraProbe` boom looking at the victim (`mp_killview_camera`) |
| `gs_replay_api.gd` | the API level (7: recorded body poses, clip v3; 6: `GSKillcamHost`; 5: the server and client halves, `GSKillViewClip.pack`) |
| `gs_replay_config.gd` | `GSReplayConfig`: directory, chunk and keyframe sizes, compression, caps, ring; layered (`--replay-ring-seconds 300`) |
| `bridge/gs_replay_event_tap.gd` | `GSReplayEventTap`: a GameSpice Server event bus's `event_fired`, objects replaced by `describe()` |
| `bridge/gs_replay_net_tap.gd` | `GSReplayNetTap`: wraps a GameSpice Net manager's `send_fn` for one peer |
| `examples/replay_selftest.tscn` | the suite; files only under `user://gs_replay_selftest`, emptied first |
| `examples/replay.yml` | the documented example (defaults; copy to `cfg/addons/gs_replay/`, not shipped live so it cannot shadow the flat shim); `GSReplayConfig.user_cfg_entry()` is the `user_cfg_files` entry for the player tier |
| `examples/net_selftest.tscn` | the net tap against a real gs-net server and clients: record, replay into a fresh client, counts, order, payload hash, a mid-stream joiner (needs `ln -s ../../gs-net/addons/gs_net addons/gs_net`, gitignored) |
| `examples/killcam_selftest.tscn` | the killcam suite: the rewind's frames, the kill kept, slowed playback, the budget, a stalled stream, skip, disabled |
| `examples/killview_selftest.tscn` | the kill view: off records nothing, a bot's view cut into a clip, playback slowed, skip action respawns, cvars, the server and client halves |
| `examples/cfg_selftest.tscn` | `replay.yml` through `GSReplayConfig.load_cfg`: `cfg/addons/gs_replay/`, `cfg/server/addons/gs_replay/` over it, the flat `cfg/replay.yml` shim (WARN once, removed 2026-12-31) |

Paths except `examples/` are in `addons/gs_replay/`.

## Running and testing

The family's two steps ([family CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 120 godot --headless --path . res://examples/replay_selftest.tscn`; stderr should be empty. The section to keep above all is "Seeking reaches exactly the state linear playback does": seeks and linear playback compared against the state the match actually had at each tick. `CHECKS` is counted from the file; update it when you add a check.

## Rules that bite

- Payloads stay opaque: the addon never parses a snapshot or a game event, and the player applies nothing. [design](docs/design.md#the-payload-is-opaque)
- Decode with `bytes_to_var`, never `_with_objects`; headers and records refuse objects. [design](docs/design.md#the-payload-is-opaque)
- A keyframe begins a chunk and is taken in `advance(tick)`, at the top of the tick, before anything of that tick is recorded. [design](docs/design.md#a-keyframe-always-begins-a-chunk)
- Each chunk's hash covers the previous one; an unkeyed chain is tamper-evident, not tamper-proof. Do not claim more. [design](docs/design.md#the-hashes-are-a-chain)
- Truncated is a success, an edited complete chunk is a refusal. [design](docs/design.md#truncated-is-a-success-edited-is-a-failure)
- Check a chunk's declared unpacked size before `decompress`; every size a file can declare is bounded. [design](docs/design.md#bounded-in-every-direction-a-file-can-make-a-reader-allocate)
- Ticks only move forward; a late record is refused, never sorted in. [design](docs/design.md#ticks-only-move-forward-and-late-records-are-refused)
- Every flushed chunk under `user://` calls `GSWeb.sync_filesystem()`. [design](docs/design.md#smaller-decisions)
- The net tap records one observer peer; seeking its stream depends on the game's `keyframe_fn`. [design](docs/design.md#the-net-tap-records-one-peer-and-does-not-solve-seeking)
- The killcam buffer holds what a client already drew, never a new stream, and is the game's to fill; the game decides what a frame is. [design](docs/design.md#the-killcam-is-a-separate-buffer)
- An integrity check needs a case only it can catch: the transplant check is what fails without the chain. [history](docs/history.md#a-chain-nothing-tested)

## Open items

- **No game records through `GSReplayNetTap` yet.** `examples/net_selftest` runs it against a real GameSpice Net server and plays the stream back into a client; seeking that stream still needs the game's `keyframe_fn`. [design](docs/design.md#where-it-runs-for-real)

Deliberately not here: replacing `GSTimerReplay`, decoding netcode, a broadcast delay, storage, asymmetric signing, reverse playback, a timeline UI, older format versions. [design](docs/design.md#deliberately-not-here)
