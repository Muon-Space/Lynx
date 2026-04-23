import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import flatpickr from "flatpickr"
import {hooks as colocatedHooks} from "phoenix-colocated/lynx"
import {CodeEditorHook} from "../../deps/live_monaco_editor/priv/static/live_monaco_editor.esm"
import {registerRego} from "./rego_lang"

// Expose Flatpickr to colocated hooks (e.g. `<.date_input>`'s init).
// Hooks can't `import` from npm directly because they run as inline JS
// extracted at compile time; the colocated-hooks build pipeline injects
// them into the bundle but they share `window` for runtime access.
window.flatpickr = flatpickr

// Register the Rego language tokenizer once Monaco loads. The bundled
// editor doesn't ship with Rego support, so we wire a Monarch provider
// the first time any editor mounts.
window.addEventListener("lme:editor_mounted", (ev) => {
  registerRego(window.monaco)
})

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, CodeEditorHook}
})

topbar.config({barColors: {0: "#3b82f6"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket
