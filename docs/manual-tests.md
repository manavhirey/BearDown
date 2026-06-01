# BearDown manual test checklist

Run these on a real device before each TestFlight build. The XCUITest suite covers happy paths; this catches the things that need iCloud, real Claude calls, or two devices.

## Onboarding
- [ ] Fresh install: onboarding appears, key field is masked, "Get a key" link opens browser
- [ ] Empty key shows inline error
- [ ] Invalid key (random string) shows "Couldn't validate that key"
- [ ] Valid key dismisses onboarding and lands on Week tab (default)
- [ ] Settings → Replace key flow saves successfully

## Agent loop
- [ ] First Coach message produces text + at least one `upsert_workout` tool chip per scheduled day
- [ ] Tool chips render with workout title and date
- [ ] Tapping a tool chip switches to Week tab focused on that date
- [ ] New chat button archives the current thread (new prompt shows fresh conversation)
- [ ] Long agent message scrolls smoothly; streaming caret visible

## Week tab
- [ ] Today is highlighted with accent color
- [ ] Workouts populated from agent appear
- [ ] Status icons: empty / green check / red X correctly reflect persisted status
- [ ] `<` `>` arrows step weeks; Today button returns to current week
- [ ] Empty state shows "Open Coach" button that switches tabs

## Plan tab
- [ ] Sections grouped by week with "Week N · MMM d – MMM d"
- [ ] Progress pill updates after marking a workout
- [ ] Tap row opens the same detail sheet as Week
- [ ] Empty-while-syncing state shows "Loading your plan…" with iCloud icon
- [ ] No-plan-yet state shows "Ask the Coach to build one"

## Detail sheet
- [ ] All blocks render (strength tables, cardio details, mobility notes)
- [ ] Mark Completed / Mark Failed each open optional-note field
- [ ] Skip saves without note; Save persists note text
- [ ] Re-opening shows current status reflected in the menu label

## Notifications
- [ ] First-enable triggers iOS auth prompt
- [ ] Notification fires at the scheduled time for a pending workout
- [ ] Marking a workout complete cancels its pending notification
- [ ] Changing reminder time in Settings re-anchors all pending requests
- [ ] Disabling master toggle clears all pending workout notifications

## iCloud sync (requires two signed-in devices)
- [ ] Workout created on device A appears on device B within ~10s
- [ ] Marking a workout complete on B updates the status on A
- [ ] API key on A is NOT visible on B (Keychain isn't synced — onboarding required on B)
- [ ] Notifications scheduled on A do NOT appear on B (device-local)

## Failure modes
- [ ] Airplane mode: Coach send shows error banner with Retry button; tapping Retry replays
- [ ] Replace key with an invalid one mid-session; next Coach send shows "Anthropic API error (HTTP …)"
- [ ] Force quit and relaunch: chat history and plans persist
- [ ] App-launch reconciliation: notifications for completed/deleted workouts get cleaned up
