--[[--
Pure math for the dashboard's charts (no KOReader dependencies, so tests/run.lua can test it).
]]
local Curve = {}

--- Monotone cubic interpolation (Fritsch–Carlson) through the points (1, ys[1]) .. (n, ys[n]).
--- Returns f(x) for x in [1, n]: smooth, passes through every point and never leaves the range of the two points
--- around x, so the curve doesn't overshoot at a maximum or minimum.
function Curve.monotone(ys)
    local n = #ys
    if n == 1 then return function() return ys[1] end end
    local d, m = {}, {}
    for k = 1, n - 1 do d[k] = ys[k + 1] - ys[k] end
    m[1], m[n] = d[1], d[n - 1]
    for k = 2, n - 1 do
        m[k] = d[k - 1] * d[k] > 0 and (d[k - 1] + d[k]) / 2 or 0
    end
    for k = 1, n - 1 do
        if d[k] == 0 then
            m[k], m[k + 1] = 0, 0
        else
            local a, b = m[k] / d[k], m[k + 1] / d[k]
            local s = a * a + b * b
            if s > 9 then
                local t = 3 / math.sqrt(s)
                m[k], m[k + 1] = t * a * d[k], t * b * d[k]
            end
        end
    end
    return function(x)
        local k = math.max(1, math.min(n - 1, math.floor(x)))
        local t = math.max(0, math.min(1, x - k))
        local t2, t3 = t * t, t * t * t
        return (2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * m[k]
            + (-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * m[k + 1]
    end
end

--- Lowest and highest value, with the range widened symmetrically to at least min_span.
function Curve.range(ys, min_span)
    local lo, hi = math.huge, -math.huge
    for _, y in ipairs(ys) do lo, hi = math.min(lo, y), math.max(hi, y) end
    local pad = math.max(0, (min_span or 0) - (hi - lo)) / 2
    return lo - pad, hi + pad
end

return Curve
