// What the relay logs (companion-v0 §12): method, endpoint pattern, status, duration, and an hourly count per
// device. Never a token, an id, a body, a setup code or a fragment; so the hourly counts carry no device ids.

export interface Log {
    request(method: string, route: string, status: number, ms: number): void;
    /** Counts one call by a device toward the hourly line. The id is only a map key; it is never written. */
    device(deviceId: string): void;
    event(name: string, fields?: Record<string, string | number | boolean>): void;
}

export function jsonLog(write: (line: string) => void, now: () => number = Date.now): Log {
    let hour = Math.floor(now() / 3_600_000);
    let counts = new Map<string, number>();
    const flush = (): void => {
        const current = Math.floor(now() / 3_600_000);
        if (current === hour) return;
        if (counts.size > 0) {
            const perDevice = [...counts.values()].sort((a, b) => b - a);
            write(JSON.stringify({ event: 'device-calls', hour: new Date(hour * 3_600_000).toISOString(), perDevice }));
        }
        hour = current;
        counts = new Map();
    };
    return {
        request(method, route, status, ms) {
            flush();
            write(JSON.stringify({ t: new Date(now()).toISOString(), method, route, status, ms }));
        },
        device(deviceId) {
            flush();
            counts.set(deviceId, (counts.get(deviceId) ?? 0) + 1);
        },
        event(name, fields = {}) {
            write(JSON.stringify({ t: new Date(now()).toISOString(), event: name, ...fields }));
        },
    };
}

export const silentLog: Log = { request() {}, device() {}, event() {} };
