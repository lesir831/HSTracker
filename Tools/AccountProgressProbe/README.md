# Account progress preview

This is a read-only native Swift reader for Hearthstone's account quests and
achievements. The same core sources are compiled into HSTracker and into the
standalone `progress-probe` tool. It does not derive account progress from game
logs, inject code, call game methods, or modify the game process.

## Validated runtime

- Apple Silicon, native arm64 Hearthstone 36.6.0.251952, Unity 6000.3.11f1.
- Mono UUID: `07aedcd386773366a75feb184f6ac069`.
- Inspected Assembly-CSharp MVID: `8b199bd2-af87-4560-b20a-110b24bdc14f`.
- Live main-menu validation read account quests, achievements and localized
  achievement definitions. Weekly progress values matched the game's visible
  quest panel. An empty main-menu live table
  is expected and is not interpreted as zero progress.

Other Mono UUIDs and Intel/Rosetta processes are deliberately rejected. Revalidate
the runtime layout and container representation before adding another profile.
Field offsets in game objects are resolved by Mono field metadata rather than
hardcoded game-class offsets. This still needs maintenance when the client changes
its classes, field types, or lifecycle.

## Build and inspect

From the repository root:

```sh
swift test --package-path Tools/AccountProgressProbe
swift build --package-path Tools/AccountProgressProbe
```

Reading another process requires the same task-port authorization used by
HSTracker. Sign the probe with your available Apple Development identity and its
debugger entitlement, then use the pinned framework's authorizer:

```sh
codesign --force --sign 'Apple Development: YOUR IDENTITY' \
  --entitlements Tools/AccountProgressProbe/Probe.entitlements \
  Tools/AccountProgressProbe/.build/debug/progress-probe
Tools/AccountProgressProbe/.build/debug/progress-probe \
  --authorize-framework downloaded-frameworks/HearthMirror/HearthMirror.framework/HearthMirror
```

Launch Hearthstone through Battle.net first. No root shell or SIP changes are
needed. Successful output is JSON with `status: snapshotRead`, a timestamped
snapshot, and a separate `inGameAchievements` array. Failures exit nonzero with
`status: unavailable`; they never return a fabricated empty successful snapshot.
The probe emits no BattleTag, account ID, credentials, or memory addresses. Its
output still contains personal gameplay progress; keep it local.

The optional .NET 7 metadata utility inspects DLL metadata without executing it:

```sh
dotnet run --project Tools/AccountProgressProbe/Metadata -- \
  /Applications/Hearthstone/Hearthstone.app/Contents/Resources/Data/Managed/Assembly-CSharp.dll \
  QuestManager AchievementManager PlayerQuestState PlayerAchievementState
```

## App behavior

Quest tracking is enabled by default and controlled in **Preferences → Overlay
layout → Quests**. The Debug-only **Window → Quests & Achievements (Preview)**
window provides achievement search and pins, snapshot timestamps, and explicit
unavailable states; it is not the release entry for quest progress.

That section also has independent **Traditional Hearthstone quests** and
**Battlegrounds quests** checkboxes. Traditional quests are on by default;
Battlegrounds quests are off. They filter by the task's reward track, so ordinary
quests cover the shared Standard/Wild/Tavern Brawl reward route rather than only
ranked Standard. Changes immediately affect both menu and match panels and are
saved between launches. Turning both off closes/hides task entry points while
leaving the existing experience counter and underlying account snapshots intact.
The signed Release settings page was checked with all four checkbox combinations;
the final saved selection is traditional on and Battlegrounds off. The 46 app
tests include immediate filtering in open menu/match panels, preserving hidden
quest estimates and leaving authoritative snapshots unchanged.

- Ordinary daily/weekly action quests and Battlegrounds action quests now
  show separately labeled live estimates from local player tags, card plays,
  summons, damage and trigger blocks. The complete ID/quota/condition inventory
  and settlement-only exceptions are in [QUESTS.md](QUESTS.md).
  The confirmed account value remains visible. These estimates are
  never persisted, never count opponent/spectator tags, and are discarded at
  match end. Unknown quest IDs/quotas and completion-based quests stay on the
  server snapshot with an explicit after-match label. Mode eligibility and the
  final credited amount remain subject to server settlement. Open/enable the
  feature before the match; no opening baseline is invented mid-game.
- Quest and achievement snapshots refresh after scene changes and match end;
  active matches and the visible menu also retry every 15 seconds.
- While tracking an own match with a visible panel or pins, the live achievement
  table is sampled every 1.5 seconds on a utility queue. Spectator matches never
  start a live session. Opening the feature midway through a game does not invent
  a match-opening baseline.
- Live achievement values are cumulative totals. The displayed match delta is
  `live - opening snapshot`, only when both values exist and do not decrease.
  Live values never modify cached account totals. Match-end snapshots replace
  totals, so repeated polling cannot double-count progress.
- Pins advance along the game's next-stage links only after the current quota is
  met and a server record exists for the next stage. Missing stages are not
  synthesized as zero-progress records.
- Cache files and pins are separated by a SHA-256 scope derived from the complete
  account identifier and region. Account identity is checked before and after
  reads; failures and switches invalidate live state. Only authoritative snapshots
  are cached in `Application Support/HSTracker/AccountProgress`.
- Quest descriptions, quotas, reward tracks and daily/weekly pool types come
  from the running client's initialized `GameDbf.Quest` and `GameDbf.QuestPool`
  records. Localization follows the client's selected locale. Firestone's public
  locale-specific definition file remains a fallback for missing native text;
  it never overrides native quotas or cadence. Only the locale is sent, never
  account progress. Missing definitions are reported explicitly. Reward XP is
  omitted because account boosts can change the actual reward.
- Achievement names, descriptions, quotas, and next-stage links come from the
  game's initialized data model. If it has not been initialized, open the game's
  Achievements page and refresh; the reader never executes the lazy factory.

## Evidence and remaining acceptance

The tests cover Mach-O thin/fat slice selection, bounds and instruction rejection,
account switching, stale match samples, missing/decreased values, authoritative
replacement, repeated samples, and stage advancement. They do not prove live
game behavior.

Main-menu memory reading and quest UI agreement were verified on the runtime
above. The signed Debug app panel was also exercised with the live client: all
three traditional quest values matched, Chinese achievement search worked, and
pinning / pinned-only filtering worked. The test pin was removed afterward.
All 17 Swift package tests passed, including quest-estimate regressions for cumulative tags, opponent/spectator exclusion, account switches, and settlement. The updated app also built and signed successfully. Full app compilation and development signing
succeeded with Xcode 27; this local build used a command-line deployment-target
override of macOS 12 because that toolchain rejects upstream's macOS 10.15 target.
The repository deployment target was not changed. Full real-match acceptance still requires observing a tracked achievement
during play, its match-end server snapshot, and a game/account restart. Cross-account
behavior has deterministic state tests; spectator exclusion and restart handling
still need live acceptance.
The app panel remains a preview until those checks are complete.

## Provenance and implementation path

HSTracker was fast-forwarded to HearthSim/HSTracker `683a02d0` before integration.
The existing HearthMirror artifact pinned by `HearthMirror-version.txt` has no
public quest/achievement API. The current native HearthMirror source repository
was not publicly accessible during investigation. Public
[hackf5/unityspy](https://github.com/hackf5/unityspy) was cloned separately for
research; its old macOS reader assumes an older x86 Mono runtime and is not a
drop-in dependency. No UnitySpy source is bundled here.

The implementation follows the observable account-snapshot and live-table split
in Firestone's [quest service](https://github.com/Zero-to-Heroes/firestone/blob/master/libs/app/common/src/lib/services/quests.service.ts),
[achievement memory monitor](https://github.com/Zero-to-Heroes/firestone/blob/master/libs/achievements/common/src/lib/services/achievements-memory-monitor.service.ts),
and [live achievement tracking](https://github.com/Zero-to-Heroes/firestone/blob/master/libs/legacy/feature-shell/src/lib/js/services/achievement/achievements-live-progress-tracking.service.ts).
The independent Swift reader was validated against the installed client's
metadata and the loaded runtime. PR #1's log-derived behavior counters are not
used as authoritative daily quests or achievements.

## Overlay layout mode

Blue/purple blocks and example counter/effect icons are the upstream overlay's
unlocked layout editor, not account-progress data. Use **Window → Lock windows**
to return to normal gameplay. The root canvas now stays borderless even when
widgets are unlocked and only captures clicks in the reported widget regions;
its native title bar and traffic lights must never cover the game.

An earlier friendly-match report had lifecycle logs but a truncated Power.log,
so it could not retrospectively prove the new live-estimate path. Regression
tests use explicit cumulative-tag sequences; fresh-match validation is required
for that path rather than relying only on post-match account snapshots.

### Match-lifecycle regression fix

The panel now shows whether a match is connected, whether account verification
or a quest baseline is pending, and a visible `This game · estimated +0` once the
baseline is ready. It no longer silently omits all indicators before the first tag.

Only game log lifecycle events and tracker shutdown terminate a match. Delayed
Mirror scene observations refresh snapshots without ending it. A temporary
unavailable/zero account identifier hides account data until verified again but
preserves that match's baseline and cumulative log values; a confirmed account
switch still discards both. Player entity ownership is checked using PLAYER_ID,
with CONTROLLER only as a fallback for entities without a player identity.

`HSTrackerTests/AccountProgressLifecycleTests.swift` exercises the actual observable
model with injected reads, including delayed scene events, missing identity and
recovery, first-read failure, confirmed account changes, shutdown, and Player
entities without a CONTROLLER tag. The 17 core tests remain separate. These tests
validate the code paths; they are not a substitute for a new live match.


## In-game quest presentation

The user confirmed the main progress-tracking behavior before this UI work.
Daily and weekly quests now have a release entry on the shared RootOverlay
canvas. Tracking starts before the log reader; opening the diagnostic window is
not required. The Window-menu preview entry is compiled only in Debug.

The scroll button sits at the bottom right by default. Hover to inspect quests,
click to pin/unpin the list, or unlock the existing overlay layout to drag the
button. Opening a match and increasing a displayed total reveal the list for
five seconds. Preferences → Overlay layout contains the display and pin settings,
and the existing position reset restores the quest button as well.

In supported menu scenes, click the existing bottom-right experience/level bar
to show the same quest panel above it; click again to close. This panel displays
confirmed account progress and refreshes when opened. It closes when leaving
the menu, entering a match, hiding the experience bar, or disabling the overlay.
The in-match pin preference does not automatically open the menu panel. The
match button shows only the centered quest label and count, without a subtitle.

When HSTracker starts after the game has already reached a menu, its initial
stable client scene supplies menu/experience visibility until the first valid
log mode arrives. Valid log modes take precedence afterward. This bootstrap
does not start or end a match and cannot reopen the menu during a tracked match.

The view reuses bundled `xp_scroll_item`, `hs_banner`, `flavor_text`,
`xp_empty_bar`, `xp_filled_bar` and `xp_gem` artwork. The progress track uses
the experience counter’s scroll and gem end caps. Its 336-unit panel keeps the
standard Chinese class quest on one line at the existing text size. Confirmed values remain separate from
log estimates; an estimated completed quest is labeled as awaiting settlement.
Unknown definitions display a loading state without inventing a goal. Practice
and spectator sessions do not show this widget. Battlegrounds sessions can show
confirmed quest progress; Battlegrounds matches use their own reward-track estimates.
Game end/closure clears it; unavailable account identity hides task data. Enabling
mid-match shows account progress but waits until the next match for estimates.

Presentation/lifecycle tests exercise the real observable model without the
preview panel, including updates, end/spectator visibility, initial known-account
read failure and mid-match enabling. Geometry tests cover 4:3, 16:9 and ultrawide
canvases, edge placement, long lists and masked click-through. The rendering test
uses the production SwiftUI view and deterministic fixture quests; its PNGs are
visual QA artifacts, not a new live-match recording.

The signed Release menu entry was also exercised with the running client:
clicking the existing experience bar showed the current account's quest rows
above it, and a second coordinate click on the same bar closed the panel.
The 25 selected presentation/lifecycle/menu tests passed. The centered match
button was checked through the production-view render, without starting a new match.

## Complete recurring-quest display

Every account-assigned quest whose native pool is `DAILY` or `WEEKLY` is eligible
for display, subject to the selected task categories. Its objective, quota,
class, mode and bonus conditions do not otherwise filter it out.
The panel identifies ordinary, Battlegrounds and event daily/weekly tasks when
those types are supplied by the client. It displays the game's confirmed total,
so objective-specific conditions and bonuses remain governed by game settlement.
The explicit rules in [QUESTS.md](QUESTS.md) supply separate local live estimates.

For older caches or unavailable native metadata, known ordinary/Battlegrounds
tasks remain visible as unclassified quests. The public feed has no reliable
cadence and is never used to guess daily versus weekly. Assigned event tasks
are also displayed, with the classification rules below.

Within one verified account, a temporary metadata failure retains known native
definitions only for quests still present in the latest account snapshot. A
removed quest, account switch or game closure clears the applicable definitions;
this fallback does not retain old progress totals or create local estimates.

Reward-granted, acknowledged, rerolled, reset, abandoned and expired records are
excluded using the installed client's verified status values. Active and newly
assigned tasks remain visible, completed tasks are labeled complete, and future
unknown status values are preserved. Long descriptions grow their rows and the
panel scrolls when the list exceeds its available height. The release menu,
match overlay and diagnostic window share this projection.

Live validation covered ordinary daily and Battlegrounds weekly tasks, with
native Chinese descriptions, quotas and pool types. All 46
selected app lifecycle, presentation and menu tests passed; the core package's
21 tests cover legacy-cache compatibility, localized metadata round trips and
unknown enum values as well as the existing reader/session behavior. The 17
lifecycle tests include temporary whole/partial metadata loss, missing pool
classification, removal, account switching and game closure. Production
SwiftUI rendering verified long descriptions and a scrolling seven-task list.
These checks establish the display path; they do not prove settlement or bonuses
for every objective through separate live matches.

The signed Release was exercised with both categories visible: the existing menu
experience bar opened the tasks with their daily/Battlegrounds-weekly labels,
Chinese text and matching confirmed progress. The rendered panel fit the rows;
clicking the bar closed and reopened the list. The game's own quest journal also
showed matching ordinary daily tasks and progress. This verification did not
start a new match.

## Event quest display (offline integration)

The shared projection now includes assigned `EVENT` pool quests and assigned
event reward-track (`7`) quests even when their pool metadata is temporarily
missing. The public catalog is only a definition lookup: a historical quest or
future chain step never appears without a matching account quest state. The
existing traditional-task preference includes these event quests; reward-track
`2` still follows the independent Battlegrounds preference. The panel heading is
now “Quest progress” in both the menu and match overlays.

Classification uses client metadata, not IDs, XP amounts, quest names or quotas:

- The installed client's `QuestManager.InitializeQuestAssets` inserts both ends
  of each `NextInChain` edge into `m_chainQuestIds`, and the same edge into
  `m_chainQuestIdToPrevious`. The reader uses both keys and values of the latter
  dictionary, including terminal steps. Dictionary types, IDs, version and
  object identity are checked; an uninitialized/empty map stays unknown.
- `QuestManager.IsChainQuest` uses that membership, and
  `QuestLog.UpdateEventQuestList` uses `SortChainQuestsToFront`. An assigned event
  with verified membership is labeled “Event quest chain”.
- Explicit `DAILY` / `WEEKLY` metadata receives the corresponding event label.
  Other `EVENT` quests retain the generic “Event quest” label. A non-chain quest
  is **not** assumed to reset daily. Missing chain metadata can reuse the previous
  value only within the same account, quest ID and pool; explicit false, pool
  changes, removal, account changes and closure invalidate that fallback.

These field/method relationships were inspected as metadata/IL only in the
installed `Assembly-CSharp.dll`, MVID `8b199bd2-af87-4560-b20a-110b24bdc14f`.
The metadata tool can reproduce the inspection with `QuestManager QuestLog
QuestDbfRecord QuestPoolDbfRecord --il`; it never invokes game code. The optional
`isChainQuest` field is backward compatible with older snapshot JSON.

Trailing `<i>` notes in event descriptions have their own smaller, wrapping text
below the objective. Other formats retain their complete text. This presents
set/class/mode/card-attribute/win bonuses and co-op requirements without parsing
translated prose as executable rules. Row heights include both text blocks.

| Historical sample | Coverage in this integration |
| --- | --- |
| 1904: draw; 1890: summon; 1881: destroy minions | Objective, quota and confirmed progress |
| 1250: set +2, Ranked +1, Kindred +1 | Preserve the complete bonus note |
| 1923 / 1929: games, Ranked, wins and class | Preserve all conditions, use the confirmed aggregate |
| 1924: Deathrattle/class; 1935: spell schools/set | Preserve attribute and class/set conditions |
| 1921: cooperative Coin plays | Preserve co-op participation; do not substitute local-player totals |

Event progress is **snapshot-based**, including all credit already calculated by
the game. Local additive/multiplicative bonus estimation is not implemented;
event rows explicitly bypass ordinary-quest estimates, even on a reused
ID/quota. Match rows say that progress updates after settlement. A later server
snapshot replaces the aggregate once, without multiplying or adding it again.

`HSTrackerTests/Fixtures/event-quests.zhCN.json` preserves all 1,194 event
definitions from the previously collected public Firestone catalog, with source
URL, collection date and the original download's SHA-256. It contains no account
data. Tests synthesize assignments/progress, check every definition's text and
quota, and exercise targeted bonus examples, native classification, settlement,
chain replacement, expired/rewarded removal, metadata loss and account switching.
The SwiftUI test renders production views to
`/tmp/HSTracker-QuestOverlay-QA/events.png`; its native cadence/membership values
are synthetic fixtures, not observed historical event assignments.

No live event or real-game interface verification is performed for this
extension: no event is currently available, and the user explicitly waived that
step. Offline tests and rendering do not validate the event runtime reader or
the game's bonus accounting in an active event.

Validation for this extension: 53 selected app tests and 22 probe-core tests
passed; Release build and strict application signature verification passed.
