import "phoenix_html"
import {diffLines} from "diff"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let Hooks = {}

Hooks.AutoDismiss = {
  mounted() {
    this.timer = setTimeout(() => {
      this.el.style.transition = "opacity 500ms"
      this.el.style.opacity = "0"
      setTimeout(() => { this.el.remove() }, 500)
    }, 5000)
  },
  destroyed() {
    clearTimeout(this.timer)
  }
}

Hooks.JsonHighlight = {
  mounted() { this.highlight() },
  updated() { this.highlight() },
  highlight() {
    let raw = this.el.textContent
    try {
      let parsed = JSON.parse(raw)
      this.el.innerHTML = this.colorize(JSON.stringify(parsed, null, 2))
    } catch(e) {}
  },
  colorize(json) {
    let s = getComputedStyle(document.documentElement)
    let ck = s.getPropertyValue('--json-key').trim()
    let cs = s.getPropertyValue('--json-string').trim()
    let cn = s.getPropertyValue('--json-number').trim()
    let cb = s.getPropertyValue('--json-boolean').trim()
    let cl = s.getPropertyValue('--json-null').trim()
    return json.replace(/("(?:\\.|[^"\\])*")\s*:/g, `<span style="color:${ck}">$1</span>:`)
      .replace(/:\s*("(?:\\.|[^"\\])*")/g, `: <span style="color:${cs}">$1</span>`)
      .replace(/:\s*(\d+\.?\d*)/g, `: <span style="color:${cn}">$1</span>`)
      .replace(/:\s*(true|false)/g, `: <span style="color:${cb}">$1</span>`)
      .replace(/:\s*(null)/g, `: <span style="color:${cl}">$1</span>`)
  }
}

Hooks.DiffHighlight = {
  mounted() { this.diff() },
  updated() { this.diff() },
  diff() {
    let leftEl = document.querySelector('[data-diff="left"]')
    let rightEl = document.querySelector('[data-diff="right"]')
    if (!leftEl || !rightEl) return

    let leftText = leftEl.textContent
    let rightText = rightEl.textContent
    let s = getComputedStyle(document.documentElement)
    let addBg = s.getPropertyValue('--diff-highlight').trim() || 'rgba(239,68,68,0.15)'
    let removeBg = 'rgba(34,197,94,0.12)'

    let changes = diffLines(leftText, rightText)

    let leftHtml = []
    let rightHtml = []

    changes.forEach(part => {
      let lines = part.value.replace(/\n$/, '').split('\n')
      lines.forEach(line => {
        let escaped = line.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
        if (part.added) {
          rightHtml.push(`<span style="background:${addBg};display:inline-block;width:100%">${escaped}</span>`)
        } else if (part.removed) {
          leftHtml.push(`<span style="background:${removeBg};display:inline-block;width:100%">${escaped}</span>`)
        } else {
          leftHtml.push(escaped)
          rightHtml.push(escaped)
        }
      })
    })

    leftEl.innerHTML = leftHtml.join('\n')
    rightEl.innerHTML = rightHtml.join('\n')
  }
}

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

// CopyApiKey listens for a server-pushed `copy_api_key` event and writes
// the value to the clipboard. The key is never embedded in the DOM — it
// only crosses the LV socket when the user clicks Copy.
Hooks.CopyApiKey = {
  mounted() {
    this.handleEvent("copy_api_key", ({value}) => {
      if (!value) return
      navigator.clipboard.writeText(value).then(() => {
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
        opt.classList.toggle("bg-select-bg", !wasSelected)
        opt.classList.toggle("text-select-text", !wasSelected)
        let check = opt.querySelector("[data-check]")
        if (check) check.textContent = !wasSelected ? "\u2713" : ""
        this.syncMultiple()
      } else {
        this.dropdown.querySelectorAll("[data-value]").forEach(o => {
          o.classList.remove("bg-select-bg", "text-select-text")
        })
        opt.classList.add("bg-select-bg", "text-select-text")
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
