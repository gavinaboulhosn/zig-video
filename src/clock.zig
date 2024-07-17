const raylib = @import("raylib");

pub const Clock = struct {
    start_time: f64,
    pause_time: f64,
    is_paused: bool,
    speed: f64,

    pub fn init() Clock {
        return Clock{
            .start_time = raylib.getTime(),
            .pause_time = 0,
            .is_paused = false,
            .speed = 1.0,
        };
    }

    pub fn getTime(self: *Clock) f64 {
        if (self.is_paused) {
            return (self.pause_time - self.start_time) * self.speed;
        } else {
            return (raylib.getTime() - self.start_time) * self.speed;
        }
    }

    pub fn pause(self: *Clock) void {
        if (!self.is_paused) {
            self.pause_time = raylib.getTime();
            self.is_paused = true;
        }
    }

    pub fn unpause(self: *Clock) void {
        if (self.is_paused) {
            self.start_time += raylib.getTime() - self.pause_time;
            self.is_paused = false;
        }
    }

    pub fn reset(self: *Clock) void {
        self.start_time = raylib.getTime();
        self.pause_time = 0;
        self.is_paused = false;
    }

    pub fn setSpeed(self: *Clock, speed: f64) void {
        const current_time = self.getTime();
        self.speed = speed;
        self.start_time = raylib.getTime() - current_time / speed;
    }
};
