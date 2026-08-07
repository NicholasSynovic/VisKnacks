# TODO.ability — Code Quality Review

_Scope: `skills/` — the `paraview-coder` OpenCode skill (`SKILL.md` + six
`references/*.md` pvpython snippet catalogs) and `skills/README.md`. All eight
files read in full. Looked outward at `agents/paraview-prompt-formatter.md`,
the root `Makefile` build target, `opencode.json.template`, `AGENTS.md`, and the
repo-wide `TODO.ability.md` to judge cohesion and interoperability. This target
is prose/config, not executable code: "findings" are about the correctness,
clarity, and durability of the instructions and the pvpython snippets they
carry, since those snippets are copied verbatim into generated scripts._
_Last reviewed: 2026-08-04 08:10_

## Summary

| Ability          | 5 Crit | 4 Maj | 3 Mod | 2 Min | 1 Nag |
| ---------------- | ------ | ----- | ----- | ----- | ----- |
| Accessibility    | 0      | 0     | 1     | 0     | 0     |
| Documentation    | 0      | 0     | 1     | 1     | 0     |
| Maintainability  | 0      | 0     | 2     | 1     | 0     |
| Interpretability | 0      | 0     | 1     | 2     | 0     |
| Interoperability | 0      | 0     | 1     | 1     | 0     |
| Reusability      | 0      | 0     | 0     | 1     | 0     |
| Sustainability   | 0      | 0     | 1     | 1     | 0     |
| Cohesion         | 0      | 1     | 2     | 1     | 0     |

## Accessibility

- [ ] **[S3] `skills/README.md` gives the wrong path to the reference files** — `skills/README.md:45`
      Why it matters: the "Reference files" heading reads
      "`skills/paraview/references/`", but the directory is
      `skills/paraview-coder/references/`. A reader following the README to
      inspect or edit a snippet lands on a nonexistent path. This is the same
      drift already tracked repo-wide, but it lives inside the reviewed scope.
      Suggested fix: change the caption to `skills/paraview-coder/references/`.

## Documentation

- [ ] **[S3] Data-inspection guidance ignores cell-centered datasets** — `skills/paraview-coder/SKILL.md:63-67`, `skills/paraview-coder/references/readers.md:169-179`
      Why it matters: SKILL.md and `readers.md` both tell the generator to fall
      back to "the first PointData array" when the user names none, but many
      ParaView datasets (Exodus/IOSS, `.vtr` cell arrays — the skill's own
      `readers.md:66` and `filters.md:348` examples use `CellArrayStatus` /
      `CellDatatoPointData`) carry only CellData. `PointData.GetArray(0)`
      returns `None` there, so `array_name`/range extraction crashes with an
      `AttributeError`, and the resulting `'var0'`/null-array path is the exact
      blank-render failure the skill is built to prevent.
      Suggested fix: add a note to inspect CellData when PointData is empty (or
      run `CellDatatoPointData` first), and guard `GetArray(0)` against `None`.

- [ ] **[S2] `layout-and-views.md` histogram snippet uses undefined `SelectInputArray` semantics inconsistently** — `skills/paraview-coder/references/layout-and-views.md:74`
      Why it matters: `filters.md:315` documents `SelectInputArray` as taking
      `[location, name]` (a two-element list) for the `Histogram` filter, but
      the histogram-view snippet here sets
      `histogram.SelectInputArray = ['POINTS', 'RTData']` on a _view display_
      object, which is a different proxy with different properties. A reader
      copying this into a chart view may not get the documented behavior; the
      intent (which array the histogram bins) is left implicit.
      Suggested fix: state that this is the histogram _view_ representation, not
      the `Histogram` filter, and confirm the property name for the view proxy.

## Maintainability

- [ ] **[S3] `README.md` duplicates the SKILL.md workflow and will drift** — `skills/README.md:28-54`
      Why it matters: the numbered workflow, trigger list, and reference-file
      table in `README.md` restate content that also lives in `SKILL.md`
      (steps 0–8, triggers, the same six files). Two copies of the same spec
      guarantee they diverge — the wrong reference path at `README.md:45`, which
      SKILL.md gets right, is already an instance. Every future edit to the
      workflow must be made twice.
      Suggested fix: make `README.md` point at `SKILL.md` as the single source
      of truth for the workflow/triggers and keep only a short overview here.

- [ ] **[S3] Histogram bin-count fallback expression can never fall back** — `skills/paraview-coder/references/filters.md:316`
      Why it matters: `histogram1.GetProperty('NumberOfBins') or histogram1.GetProperty('BinCount')`
      relies on the first `GetProperty` returning a falsy value when the
      property is absent. In pvpython a missing property returns `None` (falsy,
      OK) but an existing property returns a proxy object that is always truthy,
      so on versions where `NumberOfBins` exists the `BinCount` branch is dead —
      and on versions where `GetProperty` raises instead of returning `None`,
      the whole line throws. The pattern reads as robust but is fragile.
      Suggested fix: check membership explicitly, e.g.
      `nbins = histogram1.GetProperty('NumberOfBins')` then
      `if nbins is None: nbins = histogram1.GetProperty('BinCount')`, and note
      the version split rather than relying on truthiness.

- [ ] **[S2] `min`/`max` used as variable names shadow Python builtins across snippets** — `skills/paraview-coder/references/readers.md:178`, `skills/paraview-coder/references/displays-and-color.md:88-102`
      Why it matters: `min, max = pd.GetArray(0).GetRange()` binds the builtins
      `min`/`max`, and the transfer-function snippets then read them back
      (`(min + max) / 2.0`). Copied together into one generated script this
      works, but the moment the generator also needs `min()`/`max()` elsewhere
      (e.g. clamping isovalues) it silently gets the numbers instead of the
      functions — a subtle bug the snippets actively encourage.
      Suggested fix: rename to `data_min, data_max` (or `rmin, rmax`)
      consistently across `readers.md` and `displays-and-color.md`.

## Interpretability

- [ ] **[S3] Sentinel conventions are split between two forms without a single legend** — `skills/paraview-coder/SKILL.md:54-67`
      Why it matters: the skill mixes angle-bracket sentinels (`<input_path>`,
      `<output_path>`) with a bare-string placeholder (`'var0'`) and, in
      `readers.md`, filename-encoded values (`foot_256x256x256_uint8.raw`). The
      distinction — substitute-me vs. real-example-adapt-me — is explained in
      prose but never as one at-a-glance legend, so a reader scanning a
      reference file cannot instantly tell which tokens must be replaced. Left
      unreplaced, each is a documented cause of a broken render.
      Suggested fix: add a short "Placeholders vs. examples" legend table and
      mark example-only strings (like `['velocity', 'temperature', ...]`) as
      such consistently.

- [ ] **[S2] Inconsistent reader variable names obscure the pipeline pattern** — `skills/paraview-coder/references/readers.md:32,40,56,65`; `filters.md:39,55,87`
      Why it matters: reader variables are named after the dataset in some
      snippets (`ml100vtk`, `mpasvtp`, `predictionvtr`) and generically
      (`reader`, `csv`, `wavelet1`) in others, and `filters.md` chains off
      whichever name happened to appear. A reader must mentally re-map the
      variable on every snippet to see that `Input=` should point at the
      previous stage.
      Suggested fix: standardize on one convention (e.g. always `reader` for the
      source, `slice1`/`contour1` for filters) or add a one-line note that the
      names are illustrative and must be unified in the final script.

- [ ] **[S2] `IsoVolume` still uses `ThresholdRange` while `Threshold` was migrated off it** — `skills/paraview-coder/references/filters.md:89` vs `filters.md:96-104`
      Why it matters: the skill loudly documents that `Threshold` dropped the
      single `ThresholdRange` pair for `LowerThreshold`/`UpperThreshold` on
      5.10+, but the adjacent `IsoVolume` snippet uses `ThresholdRange = [...]`
      with no version note. A reader who internalized the Threshold warning will
      be confused about whether IsoVolume is stale too.
      Suggested fix: add a one-line note that `IsoVolume` legitimately keeps
      `ThresholdRange` (it is a different filter), so the contrast is intentional
      and not an oversight.

## Interoperability

- [ ] **[S3] Version floor stated as 5.12+ but snippets rely on ≥5.10 / ≤5.13 behavior without a compatibility note per snippet** — `skills/paraview-coder/SKILL.md:18-20`, `references/rendering-and-camera.md:120-128`, `references/filters.md:94`
      Why it matters: the declared target is "5.12+", yet several snippets carry
      version-conditional advice ("On 5.10+ use `BackgroundColorMode`; older
      versions use `UseGradientBackground`") that only matters below the stated
      floor, while others (`ResetActiveCameraToPositiveX`) are newer API. A
      generator pointed at a real pvpython that is _older_ than 5.12 gets no
      clear signal which calls will fail. The floor and the per-snippet caveats
      don't line up.
      Suggested fix: either raise/lower the single stated floor to match the
      oldest API actually used, or tag each version-sensitive snippet with the
      minimum version, and drop caveats for versions below the declared floor.

- [ ] **[S2] Animation/mesh output extensions assume codecs/writers that may be absent** — `skills/paraview-coder/references/output.md:86,94`
      Why it matters: `SaveAnimation('...avi', ...)` and
      `ExportView('...gltf', ...)` depend on the local ParaView build shipping
      the AVI encoder and GLTF exporter, which are not guaranteed across
      platforms/builds. A generated script can fail at the final step on a
      headless server that lacks them, with no fallback suggested.
      Suggested fix: note the format dependency and suggest a portable fallback
      (e.g. PNG frame series for animation, `.vtp`/`.ply` for geometry) when the
      codec/exporter is unavailable.

## Reusability

- [ ] **[S2] Reference snippets carry file-specific array names that must be scrubbed** — `skills/paraview-coder/references/readers.md:57,66`; `filters.md:157,178,261`
      Why it matters: several snippets hard-code array names from specific
      datasets (`['velocity', 'temperature', 'salinity']`, `'AngularVelocity'`,
      `'EQPS'`). These are meant as examples, but because they are valid Python
      they lift cleanly into a generated script and produce a wrong-array or
      null-array failure if not replaced — the reuse boundary between "template"
      and "example data" is soft.
      Suggested fix: replace dataset-specific names with an obvious placeholder
      style (e.g. `'<array>'`) or an inline `# example — replace` comment on each.

## Sustainability

- [ ] **[S3] Snippets pin to API names ParaView is actively churning, with no update process noted** — `skills/paraview-coder/references/filters.md:96-108`, `SKILL.md:169-173`
      Why it matters: the skill's whole value rests on encoding version-specific
      API facts (`LowerThreshold`, `NumberOfBins` vs `BinCount`, `InsideOut`
      unreliability). These are exactly the things ParaView keeps changing, and
      there is no note of which ParaView version the catalog was last validated
      against — so the snippets will silently rot as ParaView advances past the
      last check.
      Suggested fix: add a "last validated against ParaView X.Y" line to
      `SKILL.md` (and/or a per-file footer) and a short note on how to re-verify.

- [ ] **[S2] License field is prose, not an SPDX identifier** — `skills/paraview-coder/SKILL.md:15`
      Why it matters: `license: Proprietary. Part of the ChatVis research
    artifact.` is human-readable but not machine-parseable, and it names
      "ChatVis" while the repo/README brand is "SciVisAgent"/"VisKnacks".
      Tooling that scans skill frontmatter for a license can't classify it, and
      the naming drift muddies provenance/ownership over time.
      Suggested fix: use a recognized token (e.g. `LicenseRef-Proprietary`) plus
      a stable product name, and reconcile "ChatVis" with the current brand.

## Cohesion

- [ ] **[S4] SKILL.md hard-codes 1920×1080 while snippets scatter conflicting sizes** — `skills/paraview-coder/SKILL.md:78`, `references/rendering-and-camera.md:20`, `references/layout-and-views.md:31-38,68,98`, `references/output.md:27,35`
      Why it matters: the workflow bakes in a "1920 × 1080 screenshot
      convention" (matching the prompt-formatter agent), yet the reference
      snippets use `[1920, 1080]`, `[900, 1400]`/`SetSize(1800, 1400)`,
      `[500, 780]`, and `SetSize(1280, 800)` with no explanation of when the
      convention is overridden. A generator following the convention and then
      copying a layout snippet emits contradictory sizes, and the saved image
      resolution (`ImageResolution` in `output.md`) can disagree with
      `ViewSize`, producing scaled/cropped output.
      Suggested fix: state that multi-view/chart snippet sizes are illustrative
      and must be reconciled to the 1920×1080 convention (or its explicit
      override), and keep `ViewSize`/layout `SetSize`/`ImageResolution`
      consistent.

- [ ] **[S3] SKILL.md and README.md disagree on the ParaView version floor wording** — `skills/README.md:20` vs `skills/paraview-coder/SKILL.md:18`
      Why it matters: both say "5.12+", but README also says "5.12+ running
      headless" while SKILL.md's `compatibility` block adds "adapt if the local
      pvpython rejects a call" and the gotchas cite 5.10+. Two documents in the
      same skill describing the same constraint slightly differently is the kind
      of drift that compounds; a maintainer bumping the floor will likely miss
      one.
      Suggested fix: state the version floor once (in SKILL.md frontmatter) and
      have README reference it rather than restating it.

- [ ] **[S3] `skills/README.md` is not shipped by the build, unlike the skill it documents** — `skills/README.md:1`, root `Makefile:13`
      Why it matters: the build copies only subdirectories of `skills/`
      (`find skills/ -maxdepth 1 -mindepth 1 -type d`), so `SKILL.md` and its
      references ship but `skills/README.md` never reaches `build/.opencode/`.
      The README therefore serves only in-repo readers, yet it duplicates
      user-facing workflow content as if it were the front door — an
      inconsistency between what's documented and what's delivered.
      Suggested fix: either fold the README's essential content into `SKILL.md`
      (the artifact that ships) or clearly scope `skills/README.md` as
      repo-internal developer docs.

- [ ] **[S2] Placeholder registrationName conventions vary across reference files** — `skills/paraview-coder/references/readers.md:32,40`, `filters.md:39,55`, `layout-and-views.md:84`
      Why it matters: some snippets set `registrationName='input'`, others
      `'Slice1'`, `'Contour1'`, `'Text1'`, and some omit it entirely
      (`XMLMultiBlockDataReader`, `NetCDFReader`). The project otherwise stresses
      determinism (deterministic glyph thinning, explicit array names); the
      inconsistent naming convention is minor drift from that discipline.
      Suggested fix: adopt one `registrationName` convention (or state it's
      optional/illustrative) across all reference files.

## Review log

- 2026-08-04 08:10 — first review of `skills/` scope; 15 findings across all
  eight abilities (0 crit, 1 major, 8 moderate, 6 minor). No blocking/critical
  issues: the skill is well-structured and its gotchas are sound; findings
  center on doc drift (README vs SKILL.md), placeholder/example ambiguity in
  snippets, and version-durability. Root-level repo review lives in
  `../TODO.ability.md`.
