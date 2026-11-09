# Contributing

Bug reports, test reports and pull requests are welcome. SiliconWing has been tested on one Mac with one card, so a
report from your machine - working or not - is one of the most useful things you can send.

## Reporting a bug

Open an issue with the bug form and include:

1. Your Mac (model and chip), macOS version, Thunderbolt enclosure and NVIDIA card.
2. The package version (`VERSION` in the package folder).
3. What you did and what you saw, in a few sentences.
4. The driver log (`/tmp/nvmtl.log`, `$TMPDIR/nvmtl.log`, or your `NVMTL_LOG_PATH`) as an attachment, and the panic report
   from `/Library/Logs/DiagnosticReports/` if the Mac restarted.

One problem per issue. If you found the cause, say how you know: what you ran and what it printed.

## AI-assisted contributions

Welcome. Use whatever tools help you, as long as:

- the change was tested on real hardware, and the pull request says how (Mac, card, what you ran);
- you say in the pull request that AI helped;
- you can answer review questions about it.

Untested generated code and long generated descriptions are hard to review and will be sent back.

## Pull requests

- One change per PR: a fix, a feature or a cleanup, not all three. Small PRs get merged.
- Say what you tested: Mac, card, macOS version, and what you ran. "Builds" is not tested.
- Keep the description short: what was wrong, what you changed, how you tested it. Link the issue.
- Commit messages: `component: short summary` under 72 characters, then a plain explanation if needed.
- Comments in code explain why the code does what it does.
- Kernel changes (`kexts/`) need a boot on real hardware before they can be merged. Say which Mac and card.

## Where help is needed

- Other Macs: M1/M2/M3/M4 in every variant; Thunderbolt 4/5 and USB4 enclosures.
- Other cards: RTX 20, RTX 40 and RTX 50 have not been tried on Apple Silicon.
- Games: which ones run, which don't, and how fast.
- Performance at low resolutions (see `docs/ARM64-PORT-NOTES.md`, items 87-91).

## Building

`build/arm64/rebuild_all.sh` builds everything; `build/arm64/package.sh` assembles the installer package in
`out/package-arm64`. `docs/ARM64-PORT-NOTES.md` has the details and `docs/HOW-IT-WORKS.md` the layout of the source.

Problems that also happen on Intel Macs or OpenCore PCs belong to the original driver:
https://github.com/nullmoth/nvidia-macos-driver
