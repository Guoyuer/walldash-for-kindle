local time = require("ui/time")
local ok, version = pcall(require, "deskdash_version")
if not ok then version = "dev" end

local Bench = {}

-- Samples are always taken (a few clock reads); `write` only controls the per-sample TSV.
-- Bench.finish adds each phase to an in-memory stats table that the dashboard flushes hourly.
function Bench.start(write, kind)
    local now = time.now()
    return { kind = kind, write = write, started = now, last = now, phases = {} }
end

-- Add one value (ms or a count) to stats[key] = { n, sum, max }.
function Bench.add(stats, key, value)
    if not stats then return end
    local s = stats[key]
    if not s then s = { n = 0, sum = 0, max = 0 }; stats[key] = s end
    s.n = s.n + 1
    s.sum = s.sum + value
    if value > s.max then s.max = value end
end

function Bench.mark(sample, phase)
    if not sample then return end
    local now = time.now()
    sample.phases[#sample.phases + 1] = { phase, time.to_ms(now - sample.last) }
    sample.last = now
end

function Bench.finish(sample, stats)
    if not sample then return end
    sample.phases[#sample.phases + 1] = { "total", time.to_ms(time.now() - sample.started) }
    for _, phase in ipairs(sample.phases) do Bench.add(stats, sample.kind .. "." .. phase[1], phase[2]) end
    if not sample.write then return end
    local file = io.open("/tmp/deskdash_bench.tsv", "a")
    if not file then return end
    local stamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    for _, phase in ipairs(sample.phases) do
        file:write(string.format("%s\t%s\t%s\t%s\t%.1f\n", stamp, version, sample.kind, phase[1], phase[2]))
    end
    file:close()
end

return Bench
