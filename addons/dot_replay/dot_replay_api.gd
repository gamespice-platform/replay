extends RefCounted

## GameSpice Replay's API level. The rule for bumping it is on [GSAddonApi].

# 1: before this file (absent reads as 1). 2: killcam (GSKillcamBuffer, GSKillcam, GSKillcamBanner). 3: kill view (GSKillViewRules, Ring, Clip, Player).
# 4: GSKillcamFraming, mp_killview_camera. 5: GSKillViewServer/Client, Clip.pack/unpack. 6: GSKillcamHost.
# 7: Host pose_fn/apply_pose_fn/poses, mp_killview_pose_hz, clip v3 (AUX 12). 8: GSKillcamHost.event_fn. 9: GSKillcam.wait_for_frames (a kill view clip starts at once). 10: Host.pose_unchanged_fn.
# 11: Host.repose() (skipped while a replay posing after it will draw over it).
const LEVEL := 11
const OLDEST := 1
