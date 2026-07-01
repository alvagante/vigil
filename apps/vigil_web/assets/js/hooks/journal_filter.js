// JournalFilter hook — client-side text filtering per design §7.9.1 (JRN-103).
// Reads data-searchable on each entry child and toggles the "hidden" class.
// No server round-trip; works on already-rendered DOM entries only.
const JournalFilter = {
  mounted() {
    const inputSelector = this.el.dataset.filterInput || "#journal-text-filter"
    this._input = document.querySelector(inputSelector)
    if (!this._input) return

    this._onInput = () => this._filter()
    this._input.addEventListener("input", this._onInput)
  },

  updated() {
    this._filter()
  },

  destroyed() {
    if (this._input) {
      this._input.removeEventListener("input", this._onInput)
    }
  },

  _filter() {
    if (!this._input) return
    const term = this._input.value.trim().toLowerCase()

    Array.from(this.el.children).forEach(child => {
      if (!child.dataset.searchable) return
      const match = !term || child.dataset.searchable.includes(term)
      child.classList.toggle("hidden", !match)
    })
  }
}

export default JournalFilter
