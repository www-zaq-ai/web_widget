// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "topbar"
import {getHooks} from "live_react"
import components from "../react-components"
import "../css/app.css"
import "./widget-demo"
import {WidgetContext} from "./widget-context"
import {currentConversationId, currentIdentityToken} from "./widget-bootstrap"
import {widgetSessionToken} from "./widget-session"
import {startWidgetSessionConnection} from "./widget-session-connection"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
class WidgetTransportSocket extends Socket {
  constructor(url, opts) {
    super(url, {...opts, params: () => ({_csrf_token: csrfToken})})
  }
}

const socketPath = document.querySelector("meta[name='web-widget-socket']")?.getAttribute("content") || "/live"
const liveSocket = new LiveSocket(socketPath, WidgetTransportSocket, {
  longPollFallbackMs: 2500,
  params: () => ({
    _csrf_token: csrfToken,
    identity_token: currentIdentityToken(),
    conversation_id: currentConversationId(),
  }),
  hooks: {...getHooks(components), WidgetContext},
})

// Show progress bar on live navigation and form submits
topbar.config({className: "widget-progress", barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
let sessionFailed = false
window.addEventListener("phx:page-loading-start", _info => { if (!sessionFailed) topbar.show(300) })
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

const sessionPath = document.querySelector("meta[name='web-widget-session']")?.getAttribute("content")
document.getElementById("widget-session-retry")?.addEventListener("click", () => window.location.reload())
const sessionFailure = error => {
  sessionFailed = true
  topbar.hide()
  const alert = document.getElementById("widget-session-error")
  if (alert) { alert.hidden = false; alert.dataset.reason = error.message || "session_bootstrap_failed" }
}
const prepareSession = async (verifyOnly, signal) => {
  const token = await widgetSessionToken(sessionPath, {verifyOnly, signal})
  if (signal.aborted) return
  csrfToken = token
  document.querySelector("meta[name='csrf-token']").setAttribute("content", csrfToken)
}

if (sessionPath && document.getElementById("widget-context")) {
  const connection = startWidgetSessionConnection({
    prepare: prepareSession,
    connect: () => liveSocket.connect(),
    disconnect: () => liveSocket.disconnect(),
    failure: sessionFailure,
  })
  liveSocket.getSocket().onError(() => connection.error())
  liveSocket.getSocket().onClose(() => connection.lost())
} else if (!sessionPath) {
  // The standalone parent/demo retains its normal Phoenix session.
  liveSocket.connect()
}

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
