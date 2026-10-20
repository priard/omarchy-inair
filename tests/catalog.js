// The English catalog as the code spells it: every t("key", "text"),
// Model.msg("key", "text") and tn("key", n, "one", "other") in the plugin,
// plus the keys built at run time (source hints and blurbs, level names).
// i18n/en.json must equal this; `node tests/catalog.js` prints it.
const fs = require("fs")
const path = require("path")
const { Model, Sources } = require("./load")

const root = path.join(__dirname, "..")
const STR = '"((?:[^"\\\\]|\\\\.)*)"'

function english() {
  const out = {}
  const files = fs.readdirSync(root).filter((f) => /\.(qml|js)$/.test(f))
  for (const f of files) {
    const text = fs.readFileSync(path.join(root, f), "utf8")
    for (const m of text.matchAll(new RegExp("\\b(?:t|msg)\\(\\s*" + STR + ",\\s*" + STR, "g")))
      out[m[1]] = JSON.parse('"' + m[2] + '"')
    for (const m of text.matchAll(new RegExp("\\btn\\(\\s*" + STR + ",[^,]+,\\s*" + STR + ",\\s*" + STR, "g")))
      out[m[1]] = { one: JSON.parse('"' + m[2] + '"'), other: JSON.parse('"' + m[3] + '"') }
  }
  for (const id of Sources.ORDER) {
    out["source." + id + ".hint"] = Sources.info(id).hint
    out["source." + id + ".blurb"] = Sources.info(id).blurb
  }
  for (const [scale, table] of [["polish", Model.LEVELS], ["european", Model.EU_LEVELS]])
    for (const key of Object.keys(table)) {
      out["level." + scale + "." + key] = table[key].label
      out["level." + scale + "." + key + ".short"] = table[key].short
    }
  out["level.none"] = Model.UNKNOWN_LEVEL.label
  out["level.none.short"] = Model.UNKNOWN_LEVEL.short
  // The generic t(key, text, args) helpers themselves match the pattern.
  delete out["key"]
  return Object.fromEntries(Object.keys(out).sort().map((k) => [k, out[k]]))
}

module.exports = { english }
if (require.main === module) process.stdout.write(JSON.stringify(english(), null, 2) + "\n")
