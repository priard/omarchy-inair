const test = require("node:test")
const assert = require("node:assert/strict")
const { Model } = require("./load")

test("existing helpers load", () => {
  assert.equal(Model.slugify("Łódź Bałuty"), "lodz-baluty")
  assert.equal(Model.levelInfo("SATISFACTORY", "polish").label, "Sufficient")
  assert.equal(Model.formatDistance(1234), "1.2 km")
})
