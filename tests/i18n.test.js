const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("fs")
const path = require("path")
const { english } = require("./catalog")

const dir = path.join(__dirname, "..", "i18n")
const read = (code) => JSON.parse(fs.readFileSync(path.join(dir, code + ".json"), "utf8"))
const holes = (text) => (String(text).match(/%\d/g) || []).sort().join(",")

test("en.json is the English the code carries", () => {
  assert.deepEqual(read("en"), english())
})

test("every catalog translates every key, with the same %N holes", () => {
  const en = read("en")
  for (const file of fs.readdirSync(dir).filter((f) => f !== "en.json" && f.endsWith(".json"))) {
    const other = read(file.replace(/\.json$/, ""))
    assert.deepEqual(Object.keys(other).sort(), Object.keys(en).sort(), file)
    for (const key of Object.keys(en)) {
      const forms = typeof other[key] === "object" ? Object.values(other[key]) : [other[key]]
      const want = holes(typeof en[key] === "object" ? en[key].other : en[key])
      assert.equal(typeof en[key], typeof other[key], file + " " + key)
      for (const form of forms) {
        assert.ok(typeof form === "string" && form.length > 0, file + " " + key)
        assert.equal(holes(form), want, file + " " + key)
      }
    }
  }
})

// The terminal skin pads these into fixed cells.
test("short level names fit the terminal grid", () => {
  for (const file of fs.readdirSync(dir).filter((f) => f.endsWith(".json"))) {
    const c = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"))
    for (const key of Object.keys(c).filter((k) => k.endsWith(".short")))
      assert.ok([...c[key]].length <= 7, file + " " + key + " " + c[key])
  }
})
