export const strengthCategories = ["3", "2", "1", "unrated"]

export function normalizeStrengthFilter(value) {
  if (Array.isArray(value)) {
    const selected = strengthCategories.filter(category => value.includes(category))
    return value.length && !selected.length ? [...strengthCategories] : selected
  }
  // Keep preferences saved by the previous single-select version.
  if (strengthCategories.includes(value)) return [value]
  if (typeof value === "string" && value.startsWith("[")) {
    try { return normalizeStrengthFilter(JSON.parse(value)) } catch { /* Invalid saved preference. */ }
  }
  return [...strengthCategories]
}

export function matchesStrengthFilter(strength, chartVisible, filter) {
  return chartVisible && normalizeStrengthFilter(filter).includes(strength)
}

// Shared by the strength selector and eye buttons: neither overrides the other.
export function applyLevelVisibility(group) {
  const chart = group.closest('[data-controller~="chart-strength-filter"]')
  const visible = matchesStrengthFilter(group.dataset.levelStrength, group.dataset.chartVisible === "true", chart?.dataset.strengthFilter)
  group.setAttribute("display", visible ? "inline" : "none")
}
