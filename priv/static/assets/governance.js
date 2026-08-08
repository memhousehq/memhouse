// SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0
//
// The console's whole client. It stays a hand-written same-origin ES module so
// that the strict `script-src 'self'` policy needs no exception and the project
// needs no bundler.

import {Socket} from "/vendor/phoenix/phoenix.mjs"
import {LiveSocket} from "/vendor/phoenix_live_view/phoenix_live_view.esm.js"

// Identifiers and scope paths are shortened for scanning, which makes them
// unusable unless the whole value can be retrieved. The clipboard API is the
// only way to offer that, and it is unreachable from markup alone.
const Copy = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const value = this.el.dataset.copy
      if (!value) return

      this.el.classList.remove("copied", "copy-failed")

      try {
        await navigator.clipboard.writeText(value)
        this.flag("copied")
      } catch {
        // Insecure origins and denied permissions both land here. Saying so is
        // better than a control that silently does nothing.
        this.flag("copy-failed")
      }
    })
  },

  flag(className) {
    this.el.classList.add(className)
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.el.classList.remove(className), 1500)
  },

  destroyed() {
    clearTimeout(this.timer)
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {Copy}
})

liveSocket.connect()
window.liveSocket = liveSocket
