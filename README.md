# sway-dmemcg-booster

A small foreground VRAM booster for [Sway](https://swaywm.org/), written in [Zig](https://ziglang.org/).

It uses the Linux `dmem` cgroup controller to prioritize VRAM usage for the application currently in focus, moving the priority whenever the focused window changes.

## References

* [Fixing AMDGPU's VRAM management for low-end GPUs — Natalie Vock](https://pixelcluster.dev/VRAM-Mgmt-fixed/)
* [dmemcg-booster](https://gitlab.steamos.cloud/holo/dmemcg-booster)
* [niri-focused-booster](https://github.com/1Naim/niri-focused-booster)
* [hyprland-focused-booster](https://github.com/tumrin/hyprland-focused-booster)
