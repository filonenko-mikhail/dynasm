local log = require('log')
local ffi = require('ffi')

local dynasm = require('dynasm')
local dasm = require('dasm')

local function errorx(format, ...)
    local message = format:format(...)
    error(message, 2)
end

ffi.cdef[[
enum iterator_type {
  /* ITER_EQ must be the first member for request_create  */
  ITER_EQ               =  0, /* key == x ASC order                  */
  ITER_REQ              =  1, /* key == x DESC order                 */
  ITER_ALL              =  2, /* all tuples                          */
  ITER_LT               =  3, /* key <  x                            */
  ITER_LE               =  4, /* key <= x                            */
  ITER_GE               =  5, /* key >= x                            */
  ITER_GT               =  6, /* key >  x                            */
  ITER_BITS_ALL_SET     =  7, /* all bits from x are set in key      */
  ITER_BITS_ANY_SET     =  8, /* at least one x's bit is set         */
  ITER_BITS_ALL_NOT_SET =  9, /* all bits are not set                */
  ITER_OVERLAPS         = 10, /* key overlaps x                      */
  ITER_NEIGHBOR         = 11, /* tuples in distance ascending order from specified point */
  iterator_type_MAX
};

uint32_t box_space_id_by_name(const char *name, uint32_t len);
uint32_t box_index_id_by_name(uint32_t space_id, const char *name, uint32_t len);


/* Search loop */
box_iterator_t *box_index_iterator(uint32_t space_id, uint32_t index_id, int type, const char *key, const char *key_end);
int box_iterator_next(box_iterator_t *iterator, box_tuple_t **result);
void box_iterator_free(box_iterator_t *iterator);


/* Utility */
int iterator_direction(enum iterator_type type);
ssize_t box_index_len(uint32_t space_id, uint32_t index_id);

]]

local lisp_x64 = dynasm.loadfile('lisp_x64.dasl')()

local LispState = {}

--local CompilerState = {
--    scratch = {},
--    returns = {},
--    arguments = {},
--    saved = {},
--}

local function prolog(state, ast, context)
    lisp_x64.gen.prolog(state)
end

local function epilog(state, ast, context)
    lisp_x64.gen.epilog(state)
end

local registers = {
    rax=0,
    rcx=1,
    rdx=2,
    rbx=3,
    rsp=4,
    rbp=5,
    rsi=6,
    rdi=7,
    r8=8,
    r9=9,
    r10=10,
    r11=11,
    r12=12,
    r13=13,
    r14=14,
    r15=15,
}

local compile_form = nil

local symbols = {}

function symbols.atom(state, form, context)
    if #form == 1 then
        lisp_x64.gen.push(state, 0, context)
    end

    local num = tonumber64(form[2].atom)
    if num ~= nil then
        lisp_x64.gen.push(state, num, context)
        return
    end

    local result = ffi.new('char[?]', #form[2].atom + 1, form[2].atom)
    table.insert(context.parking, result)
    lisp_x64.gen.push(state, result, context)
end

function symbols.nop(state, form, context)
    lisp_x64.gen.nop(state, context)
end

function symbols.comment(state, form, context)
    lisp_x64.gen.nop(state, context)
end

symbols['not'] = function(state, form, context)
    if #form == 1 then
        errorx('Too few arguments for bitand')
    end
    compile_form(state, form[2], context)
    lisp_x64.gen['logical_not'](state, context)
end

symbols['and'] = function(state, form, context)
    if #form == 1 then
        errorx('Too few arguments for and')
    end

    local label = context.label
    context.label = context.label + 1
    dasm.growpc(state, context.label)

    for i=2, #form do
        compile_form(state, form[i], context)
        lisp_x64.gen.test_jz(state, context, label)
        if i ~= #form then
            lisp_x64.gen.discard_result(state, context)
        end
    end

    lisp_x64.gen.label(state, context, label)
end

symbols['or'] = function(state, form, context)
    if #form == 1 then
        errorx('Too few arguments for or')
    end

    local label = context.label
    context.label = context.label + 1
    dasm.growpc(state, context.label)

    for i=2, #form do
        compile_form(state, form[i], context)
        lisp_x64.gen.test_jnz(state, context, label)
        if i ~= #form then
            lisp_x64.gen.discard_result(state, context)
        end
    end

    lisp_x64.gen.label(state, context, label)
end

symbols['if'] = function(state, form, context)
    if #form == 1 or #form == 2 then
        errorx('Too few arguments for if')
    end
    if #form > 4 then
        errorx('Too much arguments for if')
    end

    local label = context.label
    context.label = context.label + 1
    dasm.growpc(state, context.label)
    local label_end = context.label
    context.label = context.label + 1
    dasm.growpc(state, context.label)

    -- if
    compile_form(state, form[2], context)
    lisp_x64.gen.test_jz(state, context, label)

    -- then
    lisp_x64.gen.discard_result(state, context) -- discard if condition
    compile_form(state, form[3], context)
    lisp_x64.gen.jmp(state, context, label_end) -- jump to end

    -- else
    lisp_x64.gen.label(state, context, label)

    if #form == 4 then
        lisp_x64.gen.discard_result(state, context) -- discard if condition
        compile_form(state, form[4], context)
    end

    -- end
    lisp_x64.gen.label(state, context, label_end)
end


-- do
symbols['do'] = function(state, form, context)
    if #form == 1 then
        errorx('Too few arguments for do')
    end
    if #form > 2 then
        errorx('Too much arguments for do')
    end

    local label = context.label
    context.label = context.label + 1
    dasm.growpc(state, context.label)

    local label_end = context.label
    context.label = context.label + 1
    dasm.growpc(state, context.label)

    table.insert(context.dostack, label_end)

    -- begin
    lisp_x64.gen.label(state, context, label)

    compile_form(state, form[2], context)
    lisp_x64.gen.jmp(state, context, label)

    -- end
    lisp_x64.gen.label(state, context, label_end)

    table.remove(context.dostack)
    -- discard results of inner forms
    -- free_reg contains inner level
    lisp_x64.gen.unwind_results(state, context)
end

-- break
symbols['break'] = function(state, form, context)
    if #form > 3 then
        errorx('Too much arguments for do')
    end

    local label_end = context.dostack[#context.dostack]

    if label_end < 0  then
        errorx('No loop for break at position %q', form.position)
    end

    -- save form level to free_reg
    lisp_x64.gen.save_level_to_free_reg(state, context)
    lisp_x64.gen.jmp(state, context, label_end)
end

symbols['bitnot'] = function(state, form, context)
    if #form == 1 then
        errorx('Too few arguments for bitand')
    end
    compile_form(state, form[2], context)
    lisp_x64.gen['not'](state, context)
end

symbols['bitand'] = function(state, form, context)
    if #form == 1 or #form == 2 then
        errorx('Too few arguments for bitand')
    end

    compile_form(state, form[2], context)
    compile_form(state, form[3], context)

    lisp_x64.gen['and'](state, context)
end

symbols['bitor'] = function(state, form, context)
    if #form == 1 or #form == 2 then
        errorx('Too few arguments for bitor')
    end

    compile_form(state, form[2], context)
    compile_form(state, form[3], context)

    lisp_x64.gen['or'](state, context)
end

symbols['bitxor'] = function(state, form, context)
    if #form == 1 or #form == 2 then
        errorx('Too few arguments for bitxor')
    end

    compile_form(state, form[2], context)
    compile_form(state, form[3], context)

    lisp_x64.gen['xor'](state, context)
end

symbols['+'] = function(state, form, context)
    if #form == 1 then
        errorx('Too few arguments for plus')
    end

    local iter = 2

    compile_form(state, form[iter], context)
    iter = iter + 1

    while iter <= #form do
        compile_form(state, form[iter], context)
        iter = iter + 1

        lisp_x64.gen.add(state, context)
    end
end

symbols['-'] = function(state, form, context)
    if #form == 1 then
        errorx('Not enough arguments for substract at form %q position %q',
        form, form.position)
    end

    local iter = 2

    compile_form(state, form[iter], context)
    iter = iter + 1

    if #form == 2 then
        lisp_x64.gen.sub(state, context, 1)
        return
    end

    while iter <= #form do
        compile_form(state, form[iter], context)
        iter = iter +  1

        lisp_x64.gen.sub(state, context, 2)
    end
end

symbols['*'] = function(state, form, context)
    if #form == 1 or #form == 2 then
        errorx('Not enough arguments for multiply')
    end

    local iter = 2

    compile_form(state, form[iter], context)
    iter = iter + 1

    while iter <= #form do
        compile_form(state, form[iter], context)
        iter = iter + 1

        lisp_x64.gen.imul(state, context)
    end
end

symbols['/'] = function(state, form, context)
    if #form == 1 or #form == 2 then
        errorx('Not enough arguments for division at position %q', form.position)
    end

    local iter = 2

    compile_form(state, form[iter], context)
    iter = iter + 1

    while iter <= #form do
        compile_form(state, form[iter], context)
        iter = iter + 1

        lisp_x64.gen.idiv(state, context)
    end
end

symbols['elt'] = function(state, form, context)
    if #form == 1 or #form == 2 then
        errorx('Not enough arguments for [] at position %q', form.position)
    end
    compile_form(state, form[2], context)
    compile_form(state, form[3], context)
    lisp_x64.gen.mov8(state, context)
end

function symbols.int3(state, form, context)
    lisp_x64.gen.int3(state)
end

function symbols.progn(state, form, context, start_from)
    start_from = start_from or 2

    for i=start_from, #form do
        local old_index = context.reg_index
        compile_form(state, form[i], context)

        -- ignore result for non last forms
        if context.reg_index > old_index then
            if i ~= #form then
                lisp_x64.gen.pop_rq0(state, context)
            end
        end
    end
end

local function is_atom(state, form, context)
    if type(form) ~= 'table' then
        return false
    end

    return form.atom ~= nil
end

compile_form = function(state, form, context)
    if type(form) ~= 'table' then
        errorx('Can not compile form %q', form)
    end

    if is_atom(state, form, context) then
        local atomform =
            setmetatable({{atom='atom', position=form.position}, form}, {position=form.position})
        compile_form(state, atomform, context)
        return
    end

    if #form == 0 then
        errorx('Empty form at position', form.position)
    end

    if form[1].atom == nil then
        errorx('form first place have to be atom at position %q', form.position)
    end

    if symbols[form[1].atom] == nil then
        errorx('No special form %q position %q', form[1].atom, form[1].position)
    end

    local old_index = context.reg_index

    symbols[form[1].atom](state, form, context)

    if context.reg_index ~= old_index then
        if context.reg_index - 1 ~= old_index then
            errorx("Stack corrupt after form %q at position %q", form,
                   form.position)
        end
    end
end

local function compile(ast, register_count)
    register_count = register_count or 0
    local M = {}
    --local test_space_id = box.space.test.id
    --create a dynasm state with the generated action list
    local state, globals = dasm.new(lisp_x64.actions)
    local context = lisp_x64.gen.new_context_with_registers(register_count)

    --lisp_x64.gen.int3(state)
    prolog(state, ast, context)

    local old_index = context.reg_index
    symbols.progn(state, ast, context, 1)

    -- ignore result for non last forms
    if context.reg_index > old_index then
        lisp_x64.gen.pop_rq0(state, context)
    else
        lisp_x64.gen.clear_rq0(state, context)
    end

    --lisp_x64.gen.pop_rq0(state, context)

    epilog(state, ast, context)

    --check, link and encode the code
    local buf, size = state:build()

    --ping allocated atoms parking
    M.context = context

    --pin buf so it doesn't get collected
    M.buf = buf
    -- DEBUG
    local dump = {}
    local function capture_dump(line)
        table.insert(dump, line)
    end

    dasm.dump(buf, size, capture_dump)
    M.disasm = table.concat(dump)

    return M
end

return {compile=compile}
