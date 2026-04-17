import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let Hooks = {}

Hooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      let target = document.querySelector(this.el.dataset.target)
      if (!target) return
      let text = target.textContent || target.innerText
      navigator.clipboard.writeText(text).then(() => {
        let orig = this.el.textContent
        this.el.textContent = "Copied!"
        setTimeout(() => { this.el.textContent = orig }, 1500)
      })
    })
  }
}

Hooks.DarkMode = {
  mounted() {
    this.el.addEventListener("click", () => {
      document.documentElement.classList.toggle("dark")
      let dark = document.documentElement.classList.contains("dark")
      localStorage.setItem("theme", dark ? "dark" : "light")
      this.el.innerHTML = dark ? "\u2600\uFE0F" : "\uD83C\uDF19"
    })
    let dark = document.documentElement.classList.contains("dark")
    this.el.innerHTML = dark ? "\u2600\uFE0F" : "\uD83C\uDF19"
  }
}

Hooks.CustomSelect = {
  mounted() {
    this.isOpen = false
    this.multiple = this.el.dataset.multiple === "true"
    this.name = this.el.dataset.name

    this.trigger = this.el.querySelector("[data-trigger]")
    this.dropdown = this.el.querySelector("[data-dropdown]")
    this.inputs = this.el.querySelector("[data-inputs]")
    this.labelEl = this.trigger.querySelector("[data-label]")

    this.trigger.addEventListener("click", e => {
      e.preventDefault()
      this.isOpen ? this.close() : this.open()
    })

    this.dropdown.addEventListener("click", e => {
      let opt = e.target.closest("[data-value]")
      if (!opt) return

      if (this.multiple) {
        let wasSelected = opt.dataset.selected === "true"
        opt.dataset.selected = wasSelected ? "false" : "true"
        opt.classList.toggle("bg-blue-50", !wasSelected)
        opt.classList.toggle("dark:bg-blue-900/30", !wasSelected)
        opt.classList.toggle("text-blue-700", !wasSelected)
        opt.classList.toggle("dark:text-blue-400", !wasSelected)
        let check = opt.querySelector("[data-check]")
        if (check) check.textContent = !wasSelected ? "\u2713" : ""
        this.syncMultiple()
      } else {
        this.dropdown.querySelectorAll("[data-value]").forEach(o => {
          o.classList.remove("bg-blue-50", "dark:bg-blue-900/30", "text-blue-700", "dark:text-blue-400")
        })
        opt.classList.add("bg-blue-50", "dark:bg-blue-900/30", "text-blue-700", "dark:text-blue-400")
        this.labelEl.textContent = opt.dataset.label
        this.inputs.innerHTML = `<input type="hidden" name="${this.name}" value="${this.esc(opt.dataset.value)}" />`
        this.close()
        this.notify()
      }
    })

    this._close = e => { if (!this.el.contains(e.target)) this.close() }
    this._esc = e => { if (e.key === "Escape") this.close() }
    document.addEventListener("click", this._close)
    document.addEventListener("keydown", this._esc)
  },

  destroyed() {
    document.removeEventListener("click", this._close)
    document.removeEventListener("keydown", this._esc)
  },

  open() {
    this.isOpen = true
    this.dropdown.classList.remove("hidden")
  },

  close() {
    this.isOpen = false
    this.dropdown.classList.add("hidden")
  },

  syncMultiple() {
    let selected = this.dropdown.querySelectorAll('[data-selected="true"]')
    let n = this.name + "[]"
    let html = ""
    let labels = []
    selected.forEach(s => {
      html += `<input type="hidden" name="${n}" value="${this.esc(s.dataset.value)}" />`
      labels.push(s.dataset.label)
    })
    this.inputs.innerHTML = html
    this.labelEl.textContent = labels.length ? labels.join(", ") : "Select..."
  },

  notify() {
    let input = this.inputs.querySelector("input")
    if (input) input.dispatchEvent(new Event("input", { bubbles: true }))
  },

  esc(s) {
    let d = document.createElement("div")
    d.textContent = s
    return d.innerHTML
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

topbar.config({barColors: {0: "#3b82f6"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket
