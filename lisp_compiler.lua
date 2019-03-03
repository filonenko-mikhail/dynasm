local log = require('log')
local ffi = require('ffi')

local dynasm = require('dynasm')
local dasm = require('dasm')

local utils = require('lisp_utils')

ffi.cdef[[
unsigned int sleep(unsigned int seconds);

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

typedef struct box_error_t {} box_error_t;
box_error_t * box_error_last(void);

const char *box_tuple_field(const box_tuple_t *tuple, uint32_t field_id);

/* Utility */
int iterator_direction(enum iterator_type type);
ssize_t box_index_len(uint32_t space_id, uint32_t index_id);

void* calloc(size_t count, size_t size);
void free(void*);
]]

local lisp_x64 = dynasm.loadfile('lisp_x64.dasl')()

local function discard_result(state, form, context, old_index)
    if old_index ~= context.reg_index then
        if old_index + 1 == context.reg_index then
            lisp_x64.gen.discard_result(state, context)
        else
            utils.errorx('stack corrupt at end form position %q',
                         form.position)
        end
    end
end

local function prolog(state, ast, context)
    lisp_x64.gen.prolog(state)
end

local function epilog(state, ast, context)
    lisp_x64.gen.epilog(state)
end

local compile_form = nil

local symbols = {}

symbols['atom'] = function(state, form, context)
    -- it's nil
    if #form == 1 then
        lisp_x64.gen.push(state, 0, context)
    end

    -- it's number
    local num = tonumber64(form[2].atom)
    if num ~= nil then
        lisp_x64.gen.push(state, num, context)
        return
    end

    -- it's binding
    if context.cells[form[2].atom] ~= nil then
        lisp_x64.gen.push_result_from_mem(state, context,
                                          context.cells[form[2].atom])
        return
    end

    -- it's symbol string
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
        utils.errorx('Too few arguments for not at position', form.position)
    end
    compile_form(state, form[2], context)
    lisp_x64.gen['logical_not'](state, context)
end

symbols['and'] = function(state, form, context)
    if #form == 1 then
        utils.errorx('Too few arguments for and at position %q', form.position)
    end

    local label = context.label
    context.label = context.label + 1
    dasm.growpc(state, context.label)

    for i=2, #form do
        local old_index = context.reg_index
        compile_form(state, form[i], context)
        lisp_x64.gen.test_jz(state, context, label)
        if i ~= #form then
            discard_result(state, form, context, old_index)
        end
    end

    lisp_x64.gen.label(state, context, label)
end

symbols['or'] = function(state, form, context)
    if #form == 1 then
        utils.errorx('Too few arguments for or at position %q', form.position)
    end

    local label = context.label
    context.label = context.label + 1
    dasm.growpc(state, context.label)

    for i=2, #form do
        local old_index = context.reg_index
        compile_form(state, form[i], context)
        lisp_x64.gen.test_jnz(state, context, label)
        if i ~= #form then
            discard_result(state, form, context, old_index)
        end
    end

    lisp_x64.gen.label(state, context, label)
end

symbols['if'] = function(state, form, context)
    if #form == 1 or #form == 2 then
        utils.errorx('Too few arguments for if at position %q', form.position)
    end
    if #form > 4 then
        utils.errorx('Too much arguments for if at position %q', form.position)
    end

    local label = context.label
    context.label = context.label + 1
    dasm.growpc(state, context.label)

    local label_end = context.label
    context.label = context.label + 1
    dasm.growpc(state, context.label)

    -- if
    local old_index = context.reg_index
    compile_form(state, form[2], context)
    if old_index + 1 ~= context.reg_index then
        utils.errorx('Condition have to return result at position %q', form[2].position)
    end
    lisp_x64.gen.pop_test_jz(state, context, label)

    -- then
    local old_index = context.reg_index
    compile_form(state, form[3], context)
    -- in case of non return return 0
    if old_index == context.reg_index then
        lisp_x64.gen.push(state, 0, context)
    end

    if #form == 4 then
        lisp_x64.gen.jmp(state, context, label_end) -- jump to end
        -- `else`
        -- decrease compiler context stack level
        -- because the only one will be executed
        -- `then` or `else` form
        context.reg_index = old_index
        lisp_x64.gen.label(state, context, label) -- else label
        local old_index = context.reg_index
        compile_form(state, form[4], context)
        if old_index == context.reg_index then
            lisp_x64.gen.push(state, 0, context)
        end
    else
        lisp_x64.gen.jmp(state, context, label_end) -- jump to end

        context.reg_index = old_index
        lisp_x64.gen.label(state, context, label) -- else label
        lisp_x64.gen.push(state, 0, context)
    end

    -- end
    lisp_x64.gen.label(state, context, label_end)
end

-- generate numeric comparators
for _, op in ipairs({'=', '<', '<=', '>', '>=', "/="}) do
    symbols[op] = function(state, form, context)
        if #form == 1 or #form == 2 then
            utils.errorx('Too few arguments for %s at position %q', op, form.position)
        end
        if #form > 3 then
            utils.errorx('Too much arguments for %s at position %q', op, form.position)
        end

        local old_index = context.reg_index
        compile_form(state, form[2], context)
        if context.reg_index ~= old_index + 1 then
            utils.errorx('No result 1st argument of %s at position %q', op, form.position)
        end
        old_index = context.reg_index
        compile_form(state, form[3], context)
        if context.reg_index ~= old_index + 1 then
            utils.errorx('No result 2nd argument of %s at position %q', op, form.position)
        end

        lisp_x64.gen[op](state, context)
    end
end

-- do
symbols['do'] = function(state, form, context)
    if #form == 1 then
        utils.errorx('Too few arguments for do at position %q', form.position)
    end
    if #form > 2 then
        utils.errorx('Too much arguments for do at position %q', form.position)
    end

    local label = context.label
    context.label = context.label + 1
    dasm.growpc(state, context.label)

    local label_end = context.label
    context.label = context.label + 1
    dasm.growpc(state, context.label)

    table.insert(context.docontinue, label)
    table.insert(context.dobreak, label_end)
    table.insert(context.dostack, context.reg_index)

    -- begin
    lisp_x64.gen.label(state, context, label)

    local old_index = context.reg_index
    compile_form(state, form[2], context)
    discard_result(state, form, context, old_index) -- discard body loop

    -- continue
    lisp_x64.gen.jmp(state, context, label)

    -- end
    lisp_x64.gen.label(state, context, label_end)

    table.remove(context.dostack)
    table.remove(context.dobreak)
    table.remove(context.docontinue)
end

-- break
symbols['break'] = function(state, form, context)
    if #form > 1 then
        utils.errorx('Too much arguments for break at position %q', form.position)
    end

    if #context.dobreak == 0 then
        utils.errorx('No loop for break at position %q', form.position)
    end

    local label_end = context.dobreak[#context.dobreak]

    -- save form level to free_reg
    lisp_x64.gen.unwind_results(state, context)
    lisp_x64.gen.jmp(state, context, label_end)
end

-- continue
symbols['continue'] = function(state, form, context)
    if #form > 1 then
        utils.errorx('Too much arguments for continue %q', form.position)
    end

    if #context.docontinue == 0 then
        utils.errorx('No loop for continue at position %q', form.position)
    end
    local label = context.docontinue[#context.docontinue]

    -- save form level to free_reg
    lisp_x64.gen.unwind_results(state, context)
    lisp_x64.gen.jmp(state, context, label)
end

symbols['bitnot'] = function(state, form, context)
    if #form == 1 then
        utils.errorx('Too few arguments for bitnot at position %q', form.position)
    end
    compile_form(state, form[2], context)
    lisp_x64.gen['not'](state, context)
end

for op, gen in pairs({
        ['bitand']='and',
        ['bitor']='or',
        ['bitxor']='xor',
        ['shl']='shl',
        ['shr']='shr'}) do

    symbols[op] = function(state, form, context)
        if #form == 1 or #form == 2 then
            utils.errorx('Too few arguments for %s at position %q', op, form.position)
        end

        local old_index = context.reg_index
        compile_form(state, form[2], context)
        if old_index + 1 ~= context.reg_index then
            utils.errorx('No 1st argument result at position %q', form.position)
        end
        old_index = context.reg_index
        compile_form(state, form[3], context)
        if old_index + 1 ~= context.reg_index then
            utils.errorx('No 2nd argument result at position %q', form.position)
        end

        lisp_x64.gen[gen](state, context)
    end

end


symbols['+'] = function(state, form, context)
    if #form == 1 then
        utils.errorx('Too few arguments for plus at position %q', form.position)
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
        utils.errorx('Too few arguments for - at position %q', form.position)
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
        utils.errorx('Too few arguments for * at position', form.position)
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
        utils.errorx('Too few arguments for / at position %q', form.position)
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

symbols['elt64'] = function(state, form, context)
    if #form == 1 or #form == 2 then
        utils.errorx('Not enough arguments for elt64 at position %q', form.position)
    end
    compile_form(state, form[2], context)
    compile_form(state, form[3], context)
    lisp_x64.gen.mov64(state, context)
end

symbols['set-elt64'] = function(state, form, context)
    if #form == 1 or #form == 2 then
        utils.errorx('Not enough arguments for set-elt64 at position %q', form.position)
    end
    compile_form(state, form[2], context)
    compile_form(state, form[3], context)
    lisp_x64.gen.mov64_to_mem(state, context)
end


symbols['int3'] = function(state, form, context)
    lisp_x64.gen.int3(state)
end

symbols['progn'] = function(state, form, context, start_from)
    start_from = start_from or 2

    for i=start_from, #form do
        local old_index = context.reg_index
        compile_form(state, form[i], context)

        -- ignore result for non last forms
        if i ~= #form then
            discard_result(state, form, context, old_index)
        end
    end
end

symbols['call'] = function(state, form, context)
    if #form == 1 then
        utils.errorx('Too few arguments for progn at position %q', form.position)
    end

    if form[2].atom == nil then
        utils.errorx('Second arg has to be atom at position %q', form.position)
    end

    for i = 1, #form-2 do
        if context.registers.args[i] == nil then
            utils.errorx('Sorry arguments overflow at position %q', form.position)
        end

        local old_index = context.old_index
        compile_form(state, form[i+2], context)
        if context.reg_index == old_index then
            utils.errorx('Argument form has no result at position %q', form[i+2].position)
        end
        lisp_x64.gen.pop_result_to(state, context, context.registers.args[i])
    end

    lisp_x64.gen.align_stack_to16(state, context)

    if form[2].atom then
        local rc, res = pcall(function() return ffi.C[form[2].atom] end)
        if not rc or not res then
            utils.errorx('ffi symbol %q not found at position %q',
                         form[2].atom,
                         form.position)
        end
    end

    lisp_x64.gen.call(state, form[2].atom)

    lisp_x64.gen.align_stack_back_to16(state, context)

    lisp_x64.gen.push_result_from(state, context, context.registers.returns[1])
end

local function is_atom(state, form, context)
    if type(form) ~= 'table' then
        return false
    end

    return form.atom ~= nil
end

symbols['set'] = function(state, form, context)
    if #form == 1 or #form == 2 then
        utils.errorx('Too few arguments for set at position %q', form.position)
    end

    if #form > 3 then
        utils.errorx('Too much arguments for set at position %q', form.position)
    end

    local subform = form[2]
    if not is_atom(state, subform, context) then
        utils.errorx('2nd argument of set has to be list with atoms at position', form.position)
    end

    if context.cells[subform.atom] == nil then
        utils.errorx('Symbol %q is not defined at position %q', subform.atom,
                     form.position)
    end

    local old_index = context.reg_index
    compile_form(state, form[3], context)
    if context.reg_index > old_index then
        lisp_x64.gen.mov_result_to_mem(state, context, context.cells[subform.atom])
    else
        utils.errorx('No result for assign at position %q', form.position)
    end
end

symbols['let'] = function(state, form, context)
    if #form == 1 or #form == 2 then
        utils.errorx('Too few arguments for let at position %q', form.position)
    end

    if #form > 3 then
        utils.errorx('Too much arguments for let at position %q', form.position)
    end

    for i=1,#form[2] do
        local subform = form[2][i]

        if not is_atom(state, subform, context) then
            utils.errorx('2nd argument of let has to be list with atoms at position %q', form.position)
        end

        if context.cells[subform.atom] ~= nil then
            utils.errorx('Symbol %q already defined error position %q',
                         subform.atom, form.position)
        end

        context.cells[subform.atom] = ffi.new('uint64_t[1]', 0)
    end

    compile_form(state, form[3], context)

    -- free context cells
    -- but save memory from gc to runtime
    for name, addr in pairs(context.cells) do
        table.insert(context.parking, addr)
        context.cells[name] = nil
    end
end


compile_form = function(state, form, context)
    if type(form) ~= 'table' then
        utils.errorx('Can not compile form at position %q', form.position)
    end

    if is_atom(state, form, context) then
        local atomform =
            setmetatable({{atom='atom', position=form.position}, form}, {position=form.position})
        compile_form(state, atomform, context)
        return
    end

    if #form == 0 then
        utils.errorx('Empty form at position', form.position)
    end

    if form[1].atom == nil then
        utils.errorx('form first place have to be atom at position %q', form.position)

    end

    if symbols[form[1].atom] == nil then
        utils.errorx('No special from %q at position %q', form[1].atom, form.position)
    end

    local old_index = context.reg_index

    symbols[form[1].atom](state, form, context)

    if old_index ~= context.reg_index then
        if old_index + 1 ~= context.reg_index then
            utils.errorx("Stack corrupt after form at position %q",
                   form.position)
        end
    end
end

local asm_lines = {}
local old_put = dasm.put
dasm.put = function (Dst, ...)
    asm_lines[Dst] = asm_lines[Dst] or {}

    asm_lines[Dst].step = asm_lines[Dst].step or 0

    asm_lines[Dst].step = asm_lines[Dst].step + 1

    old_put(Dst, ...)
end


local function compile(ast, register_count)
    register_count = register_count or 0

    local M = {}
    --create a dynasm state with the generated action list
    local state, globals = dasm.new(lisp_x64.actions)
    local context = lisp_x64.gen.new_context_with_registers(register_count)

    prolog(state, ast, context)

    local old_index = context.reg_index
    symbols.progn(state, ast, context, 1)

    -- ignore result for non last forms
    if context.reg_index > old_index then
        lisp_x64.gen.pop_result_to(state, context,
                                   context.registers.returns[1])
    else
        lisp_x64.gen.clear_rq0(state, context)
    end

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
