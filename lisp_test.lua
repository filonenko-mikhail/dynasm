local log = require('log')

local lisp = require('lisp')

local lisp_compiler = require('lisp_compiler')
local lisp_eval = require('lisp_eval')

box.cfg{}

box.schema.space.create('test', {if_not_exists=true})
box.schema.space.create('test2', {if_not_exists=true})
box.schema.space.create('test3', {if_not_exists=true})

box.space.test:create_index('pkey', {if_not_exists=true})
box.space.test2:create_index('pkey', {if_not_exists=true})
box.space.test3:create_index('pkey', {if_not_exists=true})

box.space.test:create_index('skey', {if_not_exists=true})
box.space.test2:create_index('skey', {if_not_exists=true})
box.space.test3:create_index('skey', {if_not_exists=true})

print(box.space.test.index.skey.id)

--print(box.space.test.id)


local codes = {
    {[[ 1222 ]], 1222},
    {[[ (bitnot 1) ]], tonumber64('0xfffffffffffffffe')},

    {[[ (+ 1 2 4)]], 7},

    {[[ (+ 1 2 4 5 (+ 4 5)) ]], 21},

    {[[ (+ (+ (+ (+ (+ 1 10) )))) ]], 11},
    {[[ (- 1)]], -1LL},
    {[[ (- 1 2 3)]], -4LL},
    {[[ (* 1 0)]], 0LL},
    {[[ (* 0 0)]], 0LL},
    {[[ (* 0 1 1)]], 0LL},
    {[[ (* 1 1)]], 1LL},
    {[[ (* 1 2)]], 2LL},
    {[[ (* 1 2 4)]], 8LL},
    {[[ (* (- 1) 2)]], -2LL},
    {[[ (+ (- 1) 2 (+ 0 (+ 1 2)) (- 2 1))]], 5LL},
    {[[ (+ (- 1) 2 (+ 0 (+ 1 2)) (- 2 1))]], 5LL},
    {[[ (* (- 1) 2 (+ 0 (+ 1 2)) (- 2 1))]], -6LL},

    {[[ (bitand 1 1)]], 1LL},
    {[[ (bitand 2 1)]], 0LL},
    {[[ (bitand 0xFF 33)]], 33LL},

    {[[ (bitor 0xFF 33)]], 255LL},
    {[[ (bitor 0x1 0x2)]], 3LL},

    {[[ (bitxor 0xF0 0x0F)]], 0xFF},
    {[[ (bitxor 0xF1 0x0F)]], 0xFE},

    {[[ (/ 0 1)]], 0ULL},
    {[[ (/ 4 2)]], 2ULL},
    {[[ (/ 6 3)]], 2ULL},
    {[[ (/ 26 5)]], 5ULL},

    {[[ (elt8 hello 1) ]], 0x65},

    {[[ (not 1) ]], 0ULL},

    {[[ (not (+ 1 2 (* 4 5) (- 23))) ]], 1ULL},
    {[[ (not (+ 1 2 (* 4 5) (- 22))) ]], 0ULL},

    {[[ (and 0 1 2 3) ]], 0ULL},
    {[[ (and 1 2 3) ]], 3ULL},
    {[[ (and (+ 1 2 3) 0 (+ 3 5) 2 3) ]], 0ULL},
    {[[ (and (+ 1 2 3) (+ 3 5 (- 1 2)) 0 2 3) ]], 0ULL},
    {[[ (and (not 1) (not 2))]], 0ULL},

    {[[ (or (+ 1 2 3) (+ 3 5 (- 1 2)) 0 2 3) ]], 6ULL},
    {[[ (or (not 1) 0 2 3) ]], 2ULL},

    {[[ (if (not 1) 2 3) ]], 3ULL},
    {[[ (if 1 2 3) ]], 2ULL},
    {[[ (if 1 2 0) ]], 2ULL},
    {[[ (if 0 2 3) ]], 3ULL},

    {[[ (do (break))]], 0ULL},
    {[[ (do (progn (break)))]], 0ULL},
    {[[ (do (progn (progn (break))))]], 0ULL},

    {[[ (do (progn (progn (if 1 (break) 0))))]], 0ULL},

    {[[ (do (progn (progn (if 1 (if 0 1 (break)) 0))))]], 0ULL},
    {[[ (do (progn 1 2 3 (if 1 (if 2 (break) 0) 0) ))]], 0ULL},
    {[[ (do (progn 1 (if 1 (if 2 (if 3 (if 0 3 (if 1 (if 1 (+ 2 3 4 (break)) 0) 0)) 0) 0) 0)))]], 0ULL},

    {[[ (do (progn (do (progn (if 1 (break) 0))) (+ 1 (+ 3 (+ 4 (+ 5 (if 1 (break) 0)))))))]], 0ULL},

    {[[
(do
 (progn
   (do
     (progn
       (if 1
         (+ 1 2 3 (- (break))) 0) 2 4 5))
   (+ 1 (+ 3 (+ 4 (+ 5 (if 1 (break) 0)))))
   1 2 3 (if 0 3 0)))]], 0ULL},

    {[[ (progn (stdcall write 1 asdf 4) (stdcall sleep 0) (stdcall write 1 qqqq 4) 1)]], 1ULL},

    {[[ (let (hello) (set hello 1))]], 1ULL},

    {[[
         (let (hello)
           (progn
             (set hello 0x22)
             (do
               (progn
                 (set hello (+ hello 1))
                 (if (= hello 0x25) (break) 0))
             )
             (stdcall write 1 aaaa 4)))
     ]], 4ULL
    },

    {[[ (> 1 0) ]], 1ULL},
    {[[ (< 1 2) ]], 1ULL},
    {[[ (= 1 1) ]], 1ULL},

    {[[ (<= 1 1) ]], 1ULL},
    {[[ (<= 1 2) ]], 1ULL},
}

for idx, code in ipairs(codes) do
    for register_count= 0, 4 do
        local ast = lisp.parse(code[1])
        local rc, jit = pcall(lisp_compiler.compile, ast, register_count)
        if rc then
            local result = lisp_eval.eval(jit)
            --log.info(jit.disasm)
            if result ~= code[2] then
                log.info('FAILED test %q ', idx)
                log.info(code[1])
                log.info(result)
                log.info(code[2])
                log.info('!!!!')
                log.info('-----')
            end
        else
            log.info(jit)
            break
        end
    end
end
