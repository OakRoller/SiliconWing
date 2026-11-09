# Notes for AI assistants

SiliconWing welcomes AI-assisted work - much of the Apple Silicon port was built that way. A few things make it go well:

- Read `docs/ARM64-PORT-NOTES.md` first. It is the project's memory: what was tried, what was measured, what failed and
  why. Many ideas that look obvious were already tested there (items 87-91: what the GPU time is spent on).
- Build with the scripts in `build/arm64/` (`build_plugin.sh`, `build_nvk.sh`, `build_nvk_x86_64.sh`, `package.sh`).
- Test on real hardware before calling anything done: `tools/arm64-probes/cohprobe` (CPU/GPU coherence), then a game or
  3DMark Steel Nomad (`tools/arm64-probes/cp-*.sh`, `sn-run.sh`). A change that builds is not a tested change.
- Kernel extension changes (`kexts/`) need a boot on real hardware: a bad kext stops the Mac from starting.
- Never commit GSP firmware, build output (`out/`, `translator/*/target/`) or anything with personal paths or secrets.
- In pull requests, say that AI helped and what you ran to test the change, and make sure the person submitting it can
  answer questions about it.
