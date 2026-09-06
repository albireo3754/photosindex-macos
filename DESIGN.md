# Design

## Source of truth

- Status: Active — approved redesign direction for the human SwiftUI browser.
- Last refreshed: 2026-09-06.
- Primary product surfaces: the macOS setup workspace, contextual Photos-permission states, indexed capture-group browser, and selected-group detail.
- Evidence reviewed:
  - `CLAUDE.md` — module boundaries, privacy invariants, and read-only human UI boundary.
  - `README.md` — product behavior, human workflow, grouping semantics, and privacy limits.
  - `docs/agent-publication-privacy.md` — data minimization and public-artifact rules.
  - `docs/verified-move-design.md` — verified move is an agent workflow, not a human browser feature.
  - `Sources/PhotosIndexApp/Views/ContentView.swift` — current three-column browser, safe detail fields, and current state copy.
  - `Sources/PhotosIndexApp/ManualQAContract.swift` — stable accessibility identifiers and state/action contract.
  - `Sources/PhotosIndexApp/ViewModels/AppViewModel.swift` — permission, indexing, grouping, stale-index, and busy-state behavior.
- No prior `DESIGN.md`, design/UX documentation, visual assets, or screenshot baselines were present in the repository.
- Observed fact: the current UI uses a three-column `NavigationSplitView`; this document supersedes that layout with the approved setup, empty, and indexed layouts.
- Assumption: the current Asia/Seoul calendar semantics remain unchanged; this redesign changes presentation, not indexing behavior or permission policy.

## Brand

- Personality: calm, private, observant, and native to macOS — a field notebook for revisiting one day of captures.
- Trust signals: plain language, a focused date-first flow, contextual permission explanations, and visible limits on what the browser shows.
- Avoid: dashboards, surveillance aesthetics, urgency, AI-agent framing, technical implementation details, and decorative custom branding.

## Product goals

- Goals:
  - Let a person choose one calendar day, index it, and browse its capture groups without distraction.
  - Make permission needs understandable at the moment they block progress.
  - Let people recognize their captures through real thumbnails, large photo previews, and video playback without changing the library.
  - Make an indexed day easy to revisit through a simple group list and detail view.
- Non-goals:
  - Do not add evidence, classification, export, move, or delete controls to the human UI.
  - Do not show private identifiers, exact coordinates, transport details, OCR, filenames, hashes, or decision data. Media previews are local viewing surfaces, not publishable evidence.
  - Do not make agent-facing capability a primary navigation concept.
- Success signals:
  - Before indexing, the date picker and primary action are visible together without navigating empty columns.
  - After indexing, a person can switch grouping, select a group, and understand its safe detail with two columns only.
  - Permission states communicate the next action without showing authorized access as persistent chrome.

## Personas and jobs

- Primary personas: a macOS Photos owner browsing their own library; an operator checking what a date-level index contains before using a separate workflow.
- User jobs:
  - “Help me choose a day and see its captures grouped for browsing.”
  - “Tell me what Photos access is needed and what I can do if it is unavailable.”
  - “Let me inspect a group without exposing sensitive library details or changing anything.”
- Key contexts of use: a private, local macOS session; a short focused review of one date; limited Photos access where only selected items are visible.

## Information architecture

- Primary navigation: no persistent app navigation. The screen changes by workflow state.
- Core screens:
  - Setup (no index): one centered 520–560 pt plain `VStack` workspace with a clear heading, short explanation, fully visible date picker, and one strong primary action. Do not render empty split columns.
  - Permission needed: retain the setup context and show an authorization action beside the reason it is needed.
  - Permission limited: show an always-visible banner explaining that only selected Photos items can be indexed; keep browsing/indexing available.
  - Permission denied or restricted: show a dedicated, single workspace with the specific recovery guidance and a refresh action; do not imply that indexing can proceed.
  - Indexed groups: a two-column browser only — capture-group list on the left and safe selected-group detail on the right. Put date selection, re-index, and grouping controls in the group-list column header, not a toolbar.
  - Zero groups: one useful workspace, not an empty list/detail split. Keep date selection, re-index, and grouping controls visible with a clear no-results explanation.
- Content hierarchy:
  1. Current date and actionable next step.
  2. Grouping control and group list, when groups exist.
  3. Selected group’s thumbnail gallery; open a photo for a large preview or a video for native playback controls. Time, kind, and duration support recognition rather than dominate the gallery.
  4. Optional privacy disclosure.

## Design principles

- Date first: the selected calendar day is the organizing object before any group appears.
- One useful surface: setup, blocked, and zero-result states must solve the next task in one workspace rather than reserve empty panes.
- Privacy is legible, not noisy: explain limits when relevant; do not make authorized status or implementation details persistent UI chrome.
- Read-only by design: the browser supports understanding, never mutation or model-driven judgment.
- Native over novel: use standard macOS patterns before introducing custom presentation.
- Tradeoffs: retain technical precision where it changes user interpretation (for example, groups are browsing cohorts, not event labels), but omit fields that do not serve the browsing job or could reveal private information.

## Visual language

- Color: use SwiftUI system semantic colors, `Color.accentColor`, and system destructive/warning treatments. Do not define a palette or token layer.
- Typography: use system text styles. Setup heading uses a prominent native title style; explanatory and metadata text use body, callout, caption, and secondary emphasis.
- Spacing/layout rhythm: use standard SwiftUI padding and control spacing. Constrain the pre-index/blocked setup workspace to 520–560 pt; let indexed columns use native split-view sizing.
- Shape/radius/elevation: use native buttons, lists, column headers, banners, disclosure groups, and `ContentUnavailableView`; avoid branded cards, shadows, or bespoke container chrome.
- Motion: use only system progress and standard SwiftUI transitions. State changes must not rely on animation to convey completion or failure.
- Imagery/iconography: show actual Photos-managed thumbnails in a lazy gallery. Use SF Symbols for actions and loading/error placeholders, never as substitutes for loaded media.

## Components

- Existing components to reuse: SwiftUI `DatePicker`, `Button`, `Picker`, `List`, `LabeledContent`, `DisclosureGroup`, `ProgressView`, `ContentUnavailableView`, `NavigationSplitView`, native column headers, and SF Symbols.
- New/changed components:
  - Centered plain `VStack` setup workspace with date picker and primary action.
  - Contextual permission block for authorization, limited, denied, and restricted states.
  - Limited-access banner.
  - Indexed two-column capture-group browser with date, re-index, and grouping controls in the group-list column header.
  - Zero-groups workspace containing date and grouping controls.
  - Human-language privacy disclosure labeled “Your library stays private,” retaining `photosindex.agent-connection`.
  - Adaptive thumbnail gallery and a dismissible large viewer. Video uses native play, pause, and seek controls; never autoplay audio. Escape and a visible Close button dismiss the viewer.
- Variants and states: permission needed, limited, denied, restricted, ready to index, indexing/loading, indexed, zero groups, selected group, no selected group, stale index, and request failure.
- Token/component ownership: no custom design-system abstraction. Keep layout and styling local to native SwiftUI views.

## Accessibility

- Target standard: macOS VoiceOver and keyboard-operable native controls; support Dynamic Type/system text-size changes without clipping setup copy or controls.
- Keyboard/focus behavior: the setup flow reaches date picker then primary action in logical order. In the indexed browser, focus moves from group-list column-header controls to the group list to detail; selecting a group moves detail context without stealing keyboard focus unexpectedly.
- Contrast/readability: use semantic foreground styles and system controls; never convey permission, warning, selection, or busy status by color alone.
- Screen-reader semantics: give every state a concise heading, explanation, and available next action. Announce progress and errors through existing accessibility state values.
- Stable manual-QA identifiers: preserve every current `photosindex.*` identifier and its semantic target: `photosindex.workspace`, `photosindex.workflow-state`, `photosindex.permission-status`, `photosindex.permission-guidance`, `photosindex.request-photos-access`, `photosindex.refresh-photos-access`, `photosindex.calendar-date`, `photosindex.index-date`, `photosindex.agent-connection`, `photosindex.group-level`, `photosindex.group-list`, `photosindex.group-row`, `photosindex.group-detail`, `photosindex.asset-list`, `photosindex.asset-row`, `photosindex.sidebar-status`, `photosindex.group-list-status`, and `photosindex.group-detail-status`.
- Reduced motion and sensory considerations: honor system Reduce Motion; progress needs readable text, and alerts/banners must not flash or auto-dismiss before they can be read.
- Media controls: `photosindex.asset-preview.<ordinal>` opens an item; `photosindex.media-viewer`, `photosindex.media-player`, `photosindex.media-close`, and `photosindex.media-retry` identify the viewer and its controls. Thumbnail/viewer accessibility values expose load states without media identifiers.

## Responsive behavior

- Supported breakpoints/devices: macOS only. There is no phone or tablet layout.
- Layout adaptations: use the centered 520–560 pt setup workspace before an index, for blocked access, and for zero groups. When capture groups exist, use exactly two resizable columns; collapse neither into an always-visible third sidebar nor an empty detail region.
- Touch/hover differences: standard macOS pointer, keyboard, and VoiceOver behavior. Hover can use native list affordances but cannot be required to discover actions or metadata.

## Interaction states

- Loading: replace unavailable content with labeled `ProgressView` states for access request, indexing, group loading, and detail loading; disable conflicting controls while busy.
- Empty: before index, guide to date selection and indexing; after a successful index with zero groups, explain that no Photos items matched the selected date/grouping and retain date, grouping, and re-index controls.
- Error: show a concise recovery message for request failure or stale index; preserve the relevant next action and never expose raw errors.
- Success: after indexing, show group count/list; after selecting a group, show real thumbnails with supporting metadata. Opening an item displays a large photo or playable video. No success state implies library modification.
- Disabled: disable indexing until Photos access is readable and disable conflicting controls during an in-flight request.
- Offline/slow network: PhotoKit may download iCloud-only media. Show labeled progress and recoverable failure with Retry; never claim a download percentage without measured progress. Closing a preview or changing its date/group/run cancels requests and stops playback.

## Content voice

- Tone: calm, direct, and private.
- Terminology: say “calendar day,” “capture groups,” “photos and videos,” and “Photos access.” Describe groups as browsing cohorts, never as inferred events or semantic classifications.
- Microcopy rules:
  - Lead with the user’s next action: “Choose a day,” “Allow Photos access,” or “Select a group.”
  - Explain limited access in plain language and offer the settings path only when needed.
  - The privacy disclosure label is exactly “Your library stays private.” Its copy explains the benefit in human language without implementation terminology.
  - Avoid file, identifier, location, model, and implementation terminology in visible UI.

## Implementation constraints

- Framework/styling system: macOS SwiftUI with native system colors, type, controls, column-header patterns, and SF Symbols.
- Design-token constraints: do not add a custom design-system, theme, palette, spacing-token, or component-abstraction layer.
- Privacy constraints: keep the human UI read-only. Local photo/video content is intentionally visible only in the app; retain the existing limited metadata fields. Resolve media through public PhotoKit APIs, never filesystem paths or library internals, and do not export viewing artifacts. Do not surface private identifiers or agent-workflow controls.
- Performance constraints: request bounded thumbnails lazily, load large media only on open, and release images/player items when their views disappear. Revalidate index membership after asynchronous loads and reject stale or cancelled results.
- Compatibility constraints: preserve existing Photos authorization behavior, Asia/Seoul date interpretation, group-level semantics, stale-index invalidation, and every stable manual-QA identifier listed above.
- Test/screenshot expectations: update manual QA and UI validation for every state/layout change; assert stable accessibility identifiers and values, including the disclosure identifier. Use only synthetic fixtures; never capture or commit user-library content.

## Open questions

None for this redesign.
