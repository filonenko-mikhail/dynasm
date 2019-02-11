local ffi = require('ffi')

local function eval(jit)
    local callable = ffi.cast('uint64_t __cdecl (*) ()', jit.buf)
    return callable()
end

return {
    eval = eval
}
