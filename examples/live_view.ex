defmodule AshTailscale.Example.Socket do
  @moduledoc false
  use Phoenix.LiveView.Socket

  @impl true
  def connect(_params, socket, info), do: AshTailscale.LiveView.connect(socket, info)

  @impl true
  def id(_socket), do: nil
end

defmodule AshTailscale.Example.LiveLayout do
  @moduledoc false
  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Tailscale LiveView example</title>
        <script type="module">
          import {Socket} from "/assets/phoenix/phoenix.mjs"
          import {LiveSocket} from "/assets/live_view/phoenix_live_view.esm.js"
          const csrfToken = document.querySelector("meta[name='csrf-token']").content
          // No longPollFallbackMs: this integration supports WebSockets only.
          const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}})
          liveSocket.connect()
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end

defmodule AshTailscale.Example.ReportLive do
  @moduledoc false
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       csrf_token: Plug.CSRFProtection.get_csrf_token(),
       read_result: read_reports(socket.assigns.current_user)
     )}
  end

  @impl true
  def handle_event("read", _params, socket) do
    {:noreply, assign(socket, :read_result, read_reports(socket.assigns.current_user))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>LiveView: handshake-lifetime permissions</h1>
    <p id="live-login">Signed in as: {@current_user.name || @current_user.login}</p>
    <p>Read and write permissions can remain stale indefinitely until a new WebSocket connection.</p>
    <p>Channel rejoin, remount and live navigation do not refresh permissions.</p>
    <p id="read-result">{@read_result}</p>
    <button phx-click="read">Read with the handshake actor</button>
    <.link navigate="/live-other">Live navigation (same handshake)</.link>
    <.link href="/live-demo">Full reload (new connection)</.link>
    <h2>Write-permission / CSRF demo: fresh HTTP request</h2>
    <form method="post" action="/form">
      <input type="hidden" name="_csrf_token" value={@csrf_token} />
      <button>Create report over HTTP</button>
    </form>
    """
  end

  defp read_reports(actor) do
    case Ash.read(AshTailscale.Example.Report, actor: actor) do
      {:ok, reports} -> "Read allowed: #{length(reports)} reports"
      {:error, _} -> "Read forbidden"
    end
  end
end
