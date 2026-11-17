//! Tutor result capture and persistence scheduling, separate from GUI rendering.
const std = @import("std");
const desktop = @import("desktop-core");
const tutor = @import("practice-ui");
pub const Frame = struct { now_us: u64, practicing: bool, rundown_fixture: bool, data_preview: bool };
pub fn update(io: std.Io, practice: *desktop.practice_controller.Controller, practice_view: *tutor.View, practice_history: *desktop.practice_history_runtime.Runtime, practice_labels: *const desktop.label_cache.LabelCache, practice_timing: *desktop.practice_timing.Recorder, loaded: *bool, frame: Frame) !void {
    if ((practice.session.state == .complete or practice.stopped_result_pending) and practice.completed == null) {
        const result_labels = if (std.mem.eql(u8, &practice.cohort.mapping, &practice.captured_cohort.mapping)) practice_labels.practiceLabels() else null;
        var record = if (practice.stopped_result_pending) try desktop.practice_results.captureStopped(&practice.session, practice.captured_cohort, result_labels, frame.now_us) else try desktop.practice_results.capture(&practice.session, practice.captured_cohort, result_labels);
        try std.Io.randomSecure(io, &record.id);
        record.timestamp = @intCast(std.Io.Clock.real.now(io).toNanoseconds());
        record.seed = practice.exercise_seed;
        record.target_count = practice.captured_config.target_count;
        record.targets = practice.captured_config.targets;
        record.profile = practice.captured_profile;
        record.input_source = practice.captured_source;
        practice.completed = record;
        practice.completed_enqueued = frame.rundown_fixture and !frame.data_preview;
    }
    if (practice_view.rundown.cleared) practice.completed_enqueued = true;
    if (practice.completed) |record| if (!practice.completed_enqueued and practice_history.queued < practice_history.queue.len) {
        if (practice_history.enqueueWithTiming(record, practice_timing.payload())) |_| {
            practice.completed_enqueued = true;
        } else |err| practice_history.error_value = err;
    };
    practice.save_blocked = practice.completed != null and !practice.completed_enqueued and practice_history.queued == practice_history.queue.len;
    if (practice.save_blocked) practice_history.error_value = error.PracticeSaveQueueFull;
    const history_cohort = if (practice_view.curriculum_open) practice.cohortFor(practice_view.curriculum.config) else if (practice_view.review_open) practice.configCohort() else if (practice_view.rundown.reviewed) |record| record.cohort else if (practice.completed) |record| record.cohort else practice.configCohort();
    const requested_history = practice_view.rundown.refresh or practice_view.rundown.retry or practice_view.rundown.clear;
    if (practice_history.worker == null and (practice_history.error_value == null or practice_view.rundown.retry or practice_view.rundown.clear) and (practice_history.queued > 0 or requested_history or (frame.practicing and !frame.rundown_fixture and (!loaded.* or !std.meta.eql(history_cohort, practice_history.cohort))))) {
        practice_history.request(history_cohort, practice_view.rundown.before, practice_view.rundown.clear, practice_view.rundown.retry, practice_view.progress.inspect orelse (if (practice_view.rundown.reviewed) |record| record.id else if (practice.completed) |record| record.id else null)) catch |err| {
            practice_history.error_value = err;
        };
        loaded.* = true;
        practice_view.rundown.refresh = false;
        practice_view.rundown.retry = false;
        practice_view.rundown.clear = false;
    }
}
