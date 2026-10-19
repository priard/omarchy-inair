// Loads the plugin's QML-flavoured JS files into node without changing them.
// They are plain scripts (no modules); QML's `.import` and `.pragma` lines are
// stripped, and Sources.js gets Model as the global QML would give it.
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const root = path.join(__dirname, "..")

function load(name, globals) {
  const file = path.join(root, name)
  if (!fs.existsSync(file)) return null
  const source = fs.readFileSync(file, "utf8").replace(/^\.(pragma|import)\b.*$/gm, "")
  const context = vm.createContext(Object.assign({ console: console, module: { exports: {} } }, globals || {}))
  vm.runInContext(source, context, { filename: name })
  return context
}

const Model = load("Model.js")
const Sources = load("Sources.js", { Model: Model })

function fixture(name) {
  return fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8")
}

module.exports = { Model, Sources, fixture }
