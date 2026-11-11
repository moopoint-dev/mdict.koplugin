require("spec.helper")
local Selectors = require("mdict/selectors")

describe("selectors", function()
    local function flat(css) return Selectors.flatten(css) end

    it("writes :is() and :where() out as the selectors they stand for", function()
        assert.equal(".a img.c, .a .b.c {x:1}", flat(".a :is(img, .b).c{x:1}"))
        assert.equal(".box caption.x {display:none}", flat(".box .x:where(caption){display:none}"))
        assert.equal("a c, a d, b c, b d {x:1}", flat(":is(a,b) :is(c,d){x:1}"))
        assert.equal(".a.b, .a.c {x:1}", flat(".a:IS(.b , .c ){x:1}"))
        assert.equal(".a.b::before {content:\":is(\"}", flat(".a:is(.b)::before{content:\":is(\"}"))
        assert.equal("a[title=\"x,y\"], b {x:1}", flat(":is(a[title=\"x,y\"], b){x:1}"))
        assert.equal(".a\\:is\\(b\\).c {x:1}", flat(".a\\:is\\(b\\):is(.c){x:1}"))
        -- (Safari's older name)
        assert.equal(".a.b {x:1}", flat(".a:matches(.b){x:1}"))
    end)

    it("writes :not() with a list or a compound as :not()s of one simple selector", function()
        assert.equal(".a:not(.b):not(.c) d {x:1}", flat(".a:where(:not(.b, .c)) d{x:1}"))
        assert.equal(":not(.a), :not(.b) {x:1}", flat(":not(.a.b){x:1}"))
        assert.equal(".a:not(.b):not(.c) {x:1}", flat(".a:not(:is(.b, .c)){x:1}"))
        -- already readable: left as it is
        assert.equal(".a:not([style]):not([dir]){x:1}", flat(".a:not([style]):not([dir]){x:1}"))
    end)

    it("joins an argument's ancestors with the compound's own in each order", function()
        assert.equal(".root sup .x {x:1}", flat(":where(.root sup) .x{x:1}"))
        assert.equal(".x .a > .y, .a.x > .y {z:1}", flat(".a > :is(.x .y){z:1}"))
        assert.equal(".c .a > .b .d, .a.c > .b .d, .a > .b .c .d, .a > .b.c .d {x:1}",
            flat(".a > .b :is(.c .d){x:1}"))
        assert.equal(".c .a + .b .d, .a + .b .c .d, .a + .b.c .d {x:1}", flat(".a + .b :is(.c .d){x:1}"))
        assert.equal(".a > .c ~ .d {x:1}", flat(".a > :is(.c ~ .d){x:1}"))
    end)

    it("leaves out what an older browser still cannot read, so that the rest of the list applies", function()
        assert.equal("a {x:1}", flat("a, b:has(c){x:1}"))
        assert.equal(".a.b {x:1}", flat(".a:is(.b, :has(.c)){x:1}"))
        -- nothing left, or nothing to write out: the rule stays as it was
        assert.equal(".a:not(.b .c){x:1}", flat(".a:not(.b .c){x:1}"))
        assert.equal("div:is(span){x:1}", flat("div:is(span){x:1}"))
        assert.equal(".a:is(.b{x:1}", flat(".a:is(.b{x:1}"))
        -- too many selectors
        local many = ":is(.a, .b) :is(.c, .d) :is(.e, .f) :is(.g, .h) :is(.i, .j) :is(.k, .l)"
            .. " :is(.m, .n) :is(.o, .p) :is(.q, .r){x:1}"
        assert.equal(many, flat(many))
    end)

    it("rewrites rules inside conditional groups and keeps the others as they are", function()
        assert.equal("@media screen{.a.b > p, .a.c > p {x:1}} .z{y:2}", flat("@media screen{.a:is(.b,.c)>p{x:1}} .z{y:2}"))
        assert.equal("@supports (display:grid){@media print{.a c, .b c {x:1}}}",
            flat("@supports (display:grid){@media print{:where(.a,.b) c{x:1}}}"))
        assert.equal("@font-face{font-family:x;src:url(a.ttf)} .q.r {a:b}",
            flat("@font-face{font-family:x;src:url(a.ttf)} .q:is(.r){a:b}"))
        assert.equal("@keyframes k{from{x:0}to{x:1}} .a.b {x:1}", flat("@keyframes k{from{x:0}to{x:1}} .a:is(.b){x:1}"))
        assert.equal("@import url(x.css); .a.b {x:1}", flat("@import url(x.css); .a:where(.b){x:1}"))
        assert.equal(".a.x {x:1}", flat("/* c */ .a:where(.x) /* d */ {x:1}"))
        local plain = ".a{color:red} .b > p:not(.c){x:\":is(\"}"
        assert.equal(plain, flat(plain))
        -- once is enough
        local once = flat(".a :is(img, .b).c{x:1} .d:not(.e.f){y:2}")
        assert.equal(once, flat(once))
    end)

    -- (needs Node.js; the WebView runs the same code)
    local node = os.execute("node --version >/dev/null 2>&1")
    local with_node = (node == 0 or node == true) and it or pending
    with_node("does in the pager what it does here (flattenSelectors in pager.js)", function()
        local helper = require("spec.helper")
        local fs = require("mdict/fs")
        local dir = helper.tmpdir("selectors-js")
        local seed = 7
        local function rnd(k)
            seed = (seed * 1103515245 + 12345) % 2147483648
            return seed % k
        end
        local types = { "a", "div", "span", "P", "*" }
        local simple = { ".x", ".y", "#i", "[dir]", "[lang=ja]", ":first-child", ".A" }
        local list
        local function compound(depth)
            local s = rnd(2) == 1 and types[rnd(#types) + 1] or ""
            for _ = 1, 1 + rnd(2) do
                local r = rnd(12)
                local fn = ({ [0] = "is", "where", "not", "has", "matches" })[r]
                if depth < 2 and fn then
                    s = s .. ":" .. fn .. "(" .. list(depth + 1) .. ")"
                else
                    s = s .. simple[rnd(#simple) + 1]
                end
            end
            return s
        end
        local function complex(depth)
            local s = compound(depth)
            for _ = 1, rnd(3) do s = s .. ({ " ", " > ", " + ", " ~ ", "  " })[rnd(5) + 1] .. compound(depth) end
            return s
        end
        list = function(depth)
            local items = {}
            for i = 1, 1 + rnd(depth > 0 and 2 or 3) do items[i] = complex(depth) end
            return table.concat(items, rnd(2) == 1 and ", " or ",")
        end
        local inputs = {}
        for i = 1, 2000 do
            local css = list(0) .. "{x:" .. i .. "}"
            inputs[i] = rnd(5) == 0 and ("@media screen{" .. css .. "}") or css
        end
        for i, css in ipairs(inputs) do fs.writeAtomic(string.format("%s/in/%04d.css", dir, i), css) end
        fs.writeAtomic(dir .. "/run.js", [[
const fs = require("fs");
const [pager, dir] = process.argv.slice(2);
const src = fs.readFileSync(pager, "utf8");
const from = src.indexOf("  var HAS_SELECTORS"), to = src.indexOf("  // CSS rewritten for");
if (from < 0 || to < from) throw new Error("flattenSelectors not found in pager.js");
const flatten = new Function("document", src.slice(from, to) + "\nreturn flattenSelectors;")(
  { querySelector() { throw new Error("old browser"); } });
fs.mkdirSync(dir + "/out");
for (const name of fs.readdirSync(dir + "/in")) {
  fs.writeFileSync(dir + "/out/" + name, flatten(fs.readFileSync(dir + "/in/" + name, "utf8")));
}
]])
        local ok = os.execute(string.format("node '%s/run.js' '%s/mdict.koplugin/renderers/pager.js' '%s'",
            dir, helper.root, dir))
        assert.truthy(ok == 0 or ok == true)
        local changed = 0
        for i, css in ipairs(inputs) do
            local want = Selectors.flatten(css)
            assert.equal(want, fs.readAll(string.format("%s/out/%04d.css", dir, i)), css)
            if want ~= css then changed = changed + 1 end
        end
        assert.truthy(changed > 1000)
    end)

    it("tells which stylesheets need it", function()
        assert.is_true(Selectors.uses(".a:where(.b){}"))
        assert.is_true(Selectors.uses(".a:IS(.b){}"))
        assert.is_true(Selectors.uses(".a:has(.b){}"))
        assert.is_true(Selectors.uses(".a:not(.b, .c){}"))
        assert.is_true(Selectors.uses(".a:not(p.b){}"))
        assert.is_false(Selectors.uses(".a:not(.b):not([dir]) > p{} .this{}"))
        assert.is_false(Selectors.uses(".a{line-height:1.5}"))
    end)
end)
