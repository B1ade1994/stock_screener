import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static outlets = ["chart-cursor"]

  select(event) {
    if (event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return
    if (!this.hasChartCursorOutlet) return
    const chart = this.chartCursorOutlet
    if (event.params.timeframe !== chart.svgTarget.dataset.timeframe) return

    event.preventDefault()
    chart.restoreInitial()
  }
}
