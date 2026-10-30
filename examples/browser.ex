defmodule AshTailscale.Example.HTML do
  @moduledoc false
  # Static controller rendering only: no LiveView process, mount, or socket.
  use Phoenix.Component

  @spec index(map()) :: Phoenix.LiveView.Rendered.t()
  def index(assigns) do
    ~H"""
    <meta name="csrf-token" content={@csrf_token} />
    <p>
      Signed in as: {if @current_user.name && @current_user.name != @current_user.login,
        do: "#{@current_user.name} (#{@current_user.login})",
        else: @current_user.login}
    </p>
    <h2>Write-permission / CSRF demo</h2>
    <form method="post" action="/form">
      <input type="hidden" name="_csrf_token" value={@csrf_token} />
      <button>Create report</button>
    </form>
    """
  end
end

defmodule AshTailscale.Example.Controller do
  @moduledoc false
  use Phoenix.Controller, formats: [:html, :json]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _) do
    conn
    |> put_view(html: AshTailscale.Example.HTML)
    |> render("index.html", csrf_token: Plug.CSRFProtection.get_csrf_token())
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _) do
    actor = Ash.PlugHelpers.get_actor(conn)

    case Ash.create(AshTailscale.Example.Report, %{title: "Browser submission"}, actor: actor) do
      {:ok, report} -> json(conn, %{id: report.id, login: actor.login})
      {:error, _} -> conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    end
  end
end

defmodule AshTailscale.Example.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(AshTailscale.Plug)
  end

  scope "/" do
    pipe_through(:browser)
    get("/", AshTailscale.Example.Controller, :index)
    post("/form", AshTailscale.Example.Controller, :create)
    post("/json", AshTailscale.Example.Controller, :create)

    live_session :tailscale,
      on_mount: [{AshTailscale.LiveView, "/"}],
      root_layout: {AshTailscale.Example.LiveLayout, :root} do
      live("/live-demo", AshTailscale.Example.ReportLive)
      live("/live-other", AshTailscale.Example.ReportLive)
    end
  end
end

defmodule AshTailscale.Example.ErrorHTML do
  @spec render(String.t(), map() | keyword()) :: String.t()
  def render(template, _), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule AshTailscale.Example.Endpoint do
  use Phoenix.Endpoint, otp_app: :ash_tailscale
  use AshTailscale.LiveView.Endpoint

  @session_options [
    store: :cookie,
    key: "__Host-tailscale_example",
    path: "/",
    signing_salt: "csrf-ui-only",
    same_site: "Lax",
    secure: true,
    http_only: true
  ]

  socket("/live", AshTailscale.Example.Socket,
    websocket: [
      connect_info: [:peer_data, :x_headers, session: @session_options],
      check_csrf: true
    ],
    longpoll: false
  )

  plug(Plug.Static, at: "/assets/phoenix", from: {:phoenix, "priv/static"})
  plug(Plug.Static, at: "/assets/live_view", from: {:phoenix_live_view, "priv/static"})

  # Safe only because the socket accepts connections exclusively from the trusted proxy.
  plug(Plug.SSL, rewrite_on: [:x_forwarded_proto])
  plug(Plug.Parsers, parsers: [:urlencoded, :json], pass: [], json_decoder: Jason)

  plug(Plug.Session, @session_options)

  plug(AshTailscale.Example.Router)
end

defmodule AshTailscale.Example do
  @moduledoc """
  Minimal Phoenix endpoint, compiled only in tests. Copy into a consumer application.
  Prepare a private directory (0700, app-owned; root tailscaled can traverse it)
  and launch with umask 0077. No TCP listener is configured.
  """
  # Unix-only launcher preflight. id -u reports the effective OS identity.
  @spec check_directory!(Path.t()) :: :ok
  def check_directory!(path) do
    import Bitwise
    {uid, 0} = System.cmd("id", ["-u"])
    directory = File.lstat!(path)

    unless directory.type == :directory and (directory.mode &&& 0o777) == 0o700 and
             directory.uid == String.to_integer(String.trim(uid)) do
      raise "require a 0700 directory owned by the effective OS user"
    end

    :ok
  end

  @spec config(Path.t(), String.t(), String.t()) :: keyword()
  def config(socket_path, host, secret_key_base) do
    [
      adapter: Bandit.PhoenixAdapter,
      server: true,
      url: [scheme: "https", host: host, port: 443],
      check_origin: ["https://#{host}"],
      secret_key_base: secret_key_base,
      live_view: [signing_salt: "live-page-integrity"],
      http: [
        ip: {:local, socket_path},
        port: 0,
        http_1_options: [max_header_length: 66_000],
        http_2_options: [enabled: false]
      ],
      render_errors: [formats: [html: AshTailscale.Example.ErrorHTML], layout: false],
      pubsub_server: AshTailscale.Example.PubSub
    ]
  end
end
