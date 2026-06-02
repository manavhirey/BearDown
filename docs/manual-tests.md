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

## Multi-Plan

1. **Implicit plan creation via Coach.** Ask the Coach in plain English: *"Build me a race prep block for a 3.5mi race on June 24."* Confirm the assistant emits multiple `upsert_workout` calls and a single SWITCH TO chip appears in the chat (dedup'd across the burst of workouts). The chip background is filled black/white; the text reads `SWITCH TO: <PLAN TITLE>`.

2. **Switch chip activates and navigates.** Tap the SWITCH TO chip. Verify: (a) the Plans tab becomes selected, (b) the new plan's detail screen is pushed, (c) the ACTIVE pill is showing on the new plan.

3. **Plans list shows both plans, active first.** Pop back to the Plans tab root. The list shows the new active plan on top and the formerly-active plan below it (without the ACTIVE pill). Each card shows date range, optional goal, and a `NN / NN` completion ratio.

4. **Make active from detail.** Tap the archived plan. Confirm MAKE ACTIVE + DELETE buttons are in the bottom bar. Tap MAKE ACTIVE. The ACTIVE pill flips on; MAKE ACTIVE disappears. The other plan, when revisited, no longer shows the pill.

5. **Delete with confirmation.** From any plan, tap DELETE. A destructive alert appears. The message text mentions "your active plan" when applicable, otherwise "All workouts in this plan will be removed." Confirm DELETE — the detail pops back to the list and the card is gone.

6. **Notifications cancelled on delete.** Before deleting a plan with scheduled workouts, open iOS Settings → Notifications → BearDown to inspect pending notifications. After delete, confirm pending notifications for the removed workouts are no longer scheduled.

7. **Empty state after deleting all plans.** Delete the only remaining plan. The Plans tab shows "Build your block." with an ASK COACH CTA. Today shows the rest-day empty state. Type a Coach message asking for a new plan and confirm the auto-create path puts you back at one plan called "Current Block" (no `plan_title` set).

## Chat History

1. **List populates on Coach tab.** Send a few messages, tap NEW CHAT, send a few more. Tap HISTORY in the top-left of the Coach toolbar — both conversations appear, the most-recent on top. The current (empty) conversation is filtered out and does not appear.

2. **Tap a row to resume.** Tap the first row. The view dismisses back to Coach showing that conversation's messages. Tap HISTORY again — the first row's timestamp is unchanged (switching a conversation does not modify `lastMessageAt`).

3. **Swipe-delete a non-current chat.** Swipe a row's trailing edge to reveal Delete; tap it. A destructive alert ("Delete this chat? All messages will be removed.") appears. Confirm DELETE. The row is gone from the list; other conversations are untouched.

4. **Delete the current chat.** Resume an existing conversation, return to HISTORY, swipe-delete the row that has the 2pt leading accent (the current chat). After confirming, the row is gone; the freshly-minted current conversation is filtered out and does not appear in the list. Pop back to Coach: the composer is blank (same end-state as NEW CHAT).

5. **CloudKit cross-device sync.** On device B, send messages on a new conversation. On device A, open HISTORY and pull-to-refresh. The new conversation appears within ~10s.

6. **HISTORY is disabled during streaming.** Send a message that triggers a long agent reply. While the stream is in progress, confirm HISTORY's label is greyed and untappable. After the stream completes, HISTORY re-enables.
