local time = require("ui/time")
local ok, version = pcall(require, "deskdash_version")
if not ok then version = "dev" end

local Bench = {}

function Bench.start(enabled, kind)
    if not enabled then return nil end
    local now = time.now()
    return { kind = kind, started = now, last = now, phases = {} }
end

function Bench.mark(sample, phase)
    if not sample then return end
    local now = time.now()
    sample.phases[#sample.phases + 1] = { phase, time.to_ms(now - sample.last) }
    sample.last = now
end

function Bench.finish(sample)
    if not sample then return end
    sample.phases[#sample.phases + 1] = { "total", time.to_ms(time.now() - sample.started) }
    local file = io.open("/tmp/deskdash_bench.tsv", "a")
    if not file then return end
    local stamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    for _, phase in ipairs(sample.phases) do
        file:write(string.format("%s\t%s\t%s\t%s\t%.1f\n", stamp, version, sample.kind, phase[1], phase[2]))
    end
    file:close()
end

return Bench
