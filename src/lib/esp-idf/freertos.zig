//! Minimal FreeRTOS bindings for the bits we touch from Zig.
//!
//! Only the RISC-V / ESP-IDF flavor is covered: 32-bit `BaseType_t`,
//! 32-bit `TickType_t`, dynamic allocation enabled.

pub const BaseType_t = c_int;
pub const UBaseType_t = c_uint;
pub const TickType_t = u32;

pub const portMAX_DELAY: TickType_t = 0xFFFFFFFF;
pub const tskNO_AFFINITY: BaseType_t = 0x7FFFFFFF;

const queueQUEUE_TYPE_BASE: u8 = 0;
const queueSEND_TO_BACK: BaseType_t = 0;

pub const Queue = opaque {};
pub const QueueHandle = ?*Queue;

pub const Task = opaque {};
pub const TaskHandle = ?*Task;

pub const TaskFunction = *const fn (?*anyopaque) callconv(.c) void;

extern fn xQueueGenericCreate(uxQueueLength: UBaseType_t, uxItemSize: UBaseType_t, ucQueueType: u8) QueueHandle;
extern fn xQueueReceive(xQueue: QueueHandle, pvBuffer: *anyopaque, xTicksToWait: TickType_t) BaseType_t;
extern fn xQueueGenericSendFromISR(
    xQueue: QueueHandle,
    pvItemToQueue: *const anyopaque,
    pxHigherPriorityTaskWoken: ?*BaseType_t,
    xCopyPosition: BaseType_t,
) BaseType_t;

extern fn xTaskCreatePinnedToCore(
    pxTaskCode: TaskFunction,
    pcName: [*:0]const u8,
    usStackDepth: u32,
    pvParameters: ?*anyopaque,
    uxPriority: UBaseType_t,
    pxCreatedTask: ?*TaskHandle,
    xCoreID: BaseType_t,
) BaseType_t;

pub inline fn queueCreate(length: UBaseType_t, item_size: UBaseType_t) error{OutOfMemory}!*Queue {
    return xQueueGenericCreate(length, item_size, queueQUEUE_TYPE_BASE) orelse error.OutOfMemory;
}

pub inline fn queueReceive(queue: *Queue, dest: *anyopaque, ticks_to_wait: TickType_t) bool {
    return xQueueReceive(queue, dest, ticks_to_wait) != 0;
}

pub inline fn queueSendFromISR(queue: *Queue, item: *const anyopaque, higher_priority_task_woken: ?*BaseType_t) bool {
    return xQueueGenericSendFromISR(queue, item, higher_priority_task_woken, queueSEND_TO_BACK) != 0;
}

pub inline fn taskCreate(
    code: TaskFunction,
    name: [*:0]const u8,
    stack_depth: u32,
    parameters: ?*anyopaque,
    priority: UBaseType_t,
    created_task: ?*TaskHandle,
) error{OutOfMemory}!void {
    if (xTaskCreatePinnedToCore(code, name, stack_depth, parameters, priority, created_task, tskNO_AFFINITY) == 0) {
        return error.OutOfMemory;
    }
}
