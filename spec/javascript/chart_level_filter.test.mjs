import test from "node:test"
import assert from "node:assert/strict"
import { normalizeStrengthFilter, matchesStrengthFilter, applyLevelVisibility } from "../../app/javascript/chart_level_filter.js"

test("strength filters select the exact category, including unrated", () => {
  for (const selected of ["1", "2", "3", "unrated"]) {
    for (const strength of ["1", "2", "3", "unrated"]) {
      assert.equal(matchesStrengthFilter(strength, true, selected), selected === strength)
      assert.equal(matchesStrengthFilter(strength, true, "all"), true)
    }
  }
})

test("all filters respect levels hidden by the eye", () => {
  for (const filter of ["all", "1", "2", "3", "unrated"]) {
    assert.equal(matchesStrengthFilter("3", false, filter), false)
  }
})

test("missing or obsolete saved selections default to all levels", () => {
  for (const value of [undefined, null, "invalid", "4"]) {
    assert.deepEqual(normalizeStrengthFilter(value), ["3", "2", "1", "unrated"])
    assert.equal(matchesStrengthFilter("unrated", true, value), true)
  }
})

test("eye changes and filter changes compose without modifying the user's preference", () => {
  const chart = { dataset: { strengthFilter: "3" } }
  const group = {
    dataset: { levelStrength: "1", chartVisible: "true" },
    closest: () => chart,
    setAttribute(name, value) { this[name] = value }
  }
  applyLevelVisibility(group)
  assert.equal(group.display, "none")
  assert.equal(group.dataset.chartVisible, "true")
  group.dataset.chartVisible = "false"
  chart.dataset.strengthFilter = "all"
  applyLevelVisibility(group)
  assert.equal(group.display, "none")
  group.dataset.chartVisible = "true"
  applyLevelVisibility(group)
  assert.equal(group.display, "inline")
  chart.dataset.strengthFilter = "3"
  applyLevelVisibility(group)
  assert.equal(group.display, "none")
})


test("multiple selections combine categories while preserving eye visibility", () => {
  const filter = JSON.stringify(["3", "2"])
  assert.equal(matchesStrengthFilter("3", true, filter), true)
  assert.equal(matchesStrengthFilter("2", true, filter), true)
  assert.equal(matchesStrengthFilter("1", true, filter), false)
  assert.equal(matchesStrengthFilter("unrated", true, filter), false)
  assert.equal(matchesStrengthFilter("3", false, filter), false)
})

test("an intentionally empty selection survives serialization and hides all levels", () => {
  assert.deepEqual(normalizeStrengthFilter("[]"), [])
  for (const strength of ["3", "2", "1", "unrated"]) {
    assert.equal(matchesStrengthFilter(strength, true, "[]"), false)
  }
})

test("legacy, duplicated and malformed saved preferences normalize safely", () => {
  assert.deepEqual(normalizeStrengthFilter("3"), ["3"])
  assert.deepEqual(normalizeStrengthFilter('["2","3","2","obsolete"]'), ["3", "2"])
  assert.deepEqual(normalizeStrengthFilter("[broken"), ["3", "2", "1", "unrated"])
  assert.deepEqual(normalizeStrengthFilter('["obsolete"]'), ["3", "2", "1", "unrated"])
})
