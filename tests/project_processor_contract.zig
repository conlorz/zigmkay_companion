const std = @import("std");
const firmware = @import("zigmkay");
const core = firmware.core;
const profile = @import("generated-project");

test "exported 34-key project drives the selected official processor" {
    try std.testing.expectEqual(@as(usize, 34), profile.dimensions.key_count);
    const Processor = firmware.processing.CreateProcessorType(&profile.dimensions, &profile.keymap, &profile.sides, &profile.combos, &profile.custom_functions, &profile.encoder_actions, null);
    var input = core.MatrixStateChangeQueue.Create();
    var encoders = core.EncoderEventQueue.Create();
    var output = core.OutputCommandQueue.Create();
    var processor: Processor = .{ .input_matrix_changes = &input, .encoder_event_changes = &encoders, .output_usb_commands = &output };
    try input.enqueue(.{ .pressed = true, .key_index = 0, .time = .from_absolute_us(1000) });
    try processor.Process(.from_absolute_us(1000));
    // The template reserves key 0 for a combo; a lone press waits for timeout.
    try std.testing.expectEqual(@as(usize, 0), output.Count());
    try processor.Process(.from_absolute_us(50000));
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 20 }, output.dequeue());
    try input.enqueue(.{ .pressed = false, .key_index = 0, .time = .from_absolute_us(51000) });
    try processor.Process(.from_absolute_us(51000));
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 20 }, output.dequeue());
    try std.testing.expectEqual(@as(usize, 0), output.Count());
}

test "overlay candidate emits ordered press and release without a keyboard usage" {
    if (!std.mem.eql(u8, &profile.identity(firmware.device_protocol).profile_id, "ovrtest\x00")) return;
    const Capture = struct {
        events: [2]firmware.device_protocol.Signal = undefined,
        count: usize = 0,
        fn write(context: *anyopaque, signal: firmware.device_protocol.Signal) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(self.count < self.events.len);
            self.events[self.count] = signal;
            self.count += 1;
        }
    };
    var capture = Capture{};
    const Processor = firmware.processing.CreateProcessorType(&profile.dimensions, &profile.keymap, &profile.sides, &profile.combos, &profile.custom_functions, &profile.encoder_actions, null);
    var input = core.MatrixStateChangeQueue.Create();
    var encoders = core.EncoderEventQueue.Create();
    var output = core.OutputCommandQueue.Create();
    output.companion_signals = .{ .context = &capture, .write = Capture.write };
    var processor: Processor = .{ .input_matrix_changes = &input, .encoder_event_changes = &encoders, .output_usb_commands = &output };
    try input.enqueue(.{ .pressed = true, .key_index = 1, .time = .from_absolute_us(1000) });
    try processor.Process(.from_absolute_us(1000));
    try input.enqueue(.{ .pressed = false, .key_index = 1, .time = .from_absolute_us(2000) });
    try processor.Process(.from_absolute_us(2000));
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(firmware.device_protocol.Signal{ .kind = .overlay_toggle, .pressed = true }, capture.events[0]);
    try std.testing.expectEqual(firmware.device_protocol.Signal{ .kind = .overlay_toggle, .pressed = false }, capture.events[1]);
    try std.testing.expectEqual(@as(usize, 0), output.Count());
}
