---@module 'testing.stamp.sha'
---@brief SHA-256 and HMAC-SHA-256 over byte strings (LuaJIT `bit`), for the optional HMAC of a stamp.
---@description
--- `vim.fn.sha256` hashes TEXT: a byte string with an embedded NUL (the padded key blocks of an HMAC) does not
--- pass through it unchanged. HMAC needs raw bytes, so this module hashes them itself. It is small, pure and
--- checked against `vim.fn.sha256` and the vectors of RFC 4231 in the specs. Nothing here is used for a secret
--- that must resist timing attacks on the machine that computes it: the one place that compares two MACs
--- (`M.equal`) compares in constant time over the length.

local bit = require("bit")
local band, bxor, bnot, rshift, lshift, bor =
  bit.band, bit.bxor, bit.bnot, bit.rshift, bit.lshift, bit.bor
local tobit, tohex = bit.tobit, bit.tohex

local M = {}

---@type integer[]
local K = {
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
}

---@param x integer
---@param n integer
---@return integer
local function ror(x, n)
  return bor(rshift(x, n), lshift(x, 32 - n))
end

---SHA-256 of a byte string, as 32 raw bytes.
---@param msg string
---@return string
function M.raw(msg)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local len = #msg
  -- padding: 0x80, zeros up to 56 mod 64, the bit length as 8 big-endian bytes
  local pad = "\128" .. ("\0"):rep((55 - len) % 64)
  local bits_hi = math.floor(len / 0x20000000)
  local bits_lo = (len * 8) % 0x100000000
  local function be32(n)
    return string.char(
      band(rshift(n, 24), 255),
      band(rshift(n, 16), 255),
      band(rshift(n, 8), 255),
      band(n, 255)
    )
  end
  local data = msg .. pad .. be32(bits_hi) .. be32(bits_lo)
  local w = {}
  for chunk = 1, #data, 64 do
    for i = 0, 15 do
      local a, b, c, d = data:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = tobit(a * 16777216 + b * 65536 + c * 256 + d)
    end
    for i = 16, 63 do
      local x, y = w[i - 15], w[i - 2]
      local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
      local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
      w[i] = tobit(w[i - 16] + s0 + w[i - 7] + s1)
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 0, 63 do
      local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = tobit(h + S1 + ch + K[i + 1] + w[i])
      local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local t2 = tobit(S0 + maj)
      h, g, f, e, d, c, b, a = g, f, e, tobit(d + t1), c, b, a, tobit(t1 + t2)
    end
    h0, h1, h2, h3 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d)
    h4, h5, h6, h7 = tobit(h4 + e), tobit(h5 + f), tobit(h6 + g), tobit(h7 + h)
  end
  return be32(h0)
    .. be32(h1)
    .. be32(h2)
    .. be32(h3)
    .. be32(h4)
    .. be32(h5)
    .. be32(h6)
    .. be32(h7)
end

---@param raw string
---@return string
local function to_hex(raw)
  local out = {}
  for i = 1, #raw do
    out[i] = tohex(raw:byte(i), 2)
  end
  return table.concat(out)
end

---SHA-256 of a byte string, as 64 lower-case hex digits.
---@param msg string
---@return string
function M.hex(msg)
  return to_hex(M.raw(msg))
end

---HMAC-SHA-256 (RFC 2104), as 64 lower-case hex digits.
---@param key string
---@param msg string
---@return string
function M.hmac(key, msg)
  if #key > 64 then
    key = M.raw(key)
  end
  key = key .. ("\0"):rep(64 - #key)
  local ipad, opad = {}, {}
  for i = 1, 64 do
    local b = key:byte(i)
    ipad[i] = string.char(bxor(b, 0x36))
    opad[i] = string.char(bxor(b, 0x5c))
  end
  return to_hex(M.raw(table.concat(opad) .. M.raw(table.concat(ipad) .. msg)))
end

---Are two strings equal? The time depends on the length only, not on where they first differ.
---@param a any
---@param b any
---@return boolean
function M.equal(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then
    return false
  end
  local diff = 0
  for i = 1, #a do
    diff = bor(diff, bxor(a:byte(i), b:byte(i)))
  end
  return diff == 0
end

return M
