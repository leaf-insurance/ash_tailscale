defmodule AshTailscale.Test.LiveFixture do
  @moduledoc false

  @spec session_options() :: keyword()
  def session_options do
    [
      store: :cookie,
      key: "__Host-live_test",
      signing_salt: "ui-only",
      secure: true,
      http_only: true,
      same_site: "Lax",
      path: "/"
    ]
  end

  @spec page_session(Plug.Conn.t()) :: map()
  def page_session(_conn),
    do: %{"current_user" => "page-admin", "capabilities" => %{"admin" => true}}

  @spec snapshot(AshTailscale.User.t()) :: map()
  def snapshot(actor) do
    %{
      login: actor.login,
      capabilities: actor.capabilities,
      read: match?({:ok, _}, Ash.read(AshTailscale.Example.Report, actor: actor))
    }
  end

  @spec fail_predicate(AshTailscale.capabilities()) :: no_return()
  def fail_predicate(_caps), do: raise("consumer predicate failed")

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) :: {:cont, map()}
  def on_mount(:stale, _params, _session, socket) do
    {:cont,
     Phoenix.Component.assign(socket, :current_user, AshTailscale.test_actor!("stale-admin"))}
  end
end

defmodule AshTailscale.Test.LiveComponent do
  @moduledoc false
  use Phoenix.LiveComponent
  alias AshTailscale.Test.LiveFixture

  @impl true
  def render(assigns) do
    ~H"""
    <button phx-target={@myself} phx-click="snapshot">Component: {@current_user.login}</button>
    """
  end

  @impl true
  def handle_event("snapshot", _params, socket) do
    {:reply, LiveFixture.snapshot(socket.assigns.current_user), socket}
  end
end

defmodule AshTailscale.Test.ProbeLive do
  @moduledoc false
  use Phoenix.LiveView
  alias AshTailscale.Example.Report
  alias AshTailscale.Test.LiveFixture

  @impl true
  def render(assigns) do
    ~H"""
    <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
    <p id="identity">{@current_user.login}</p>
    <.live_component module={AshTailscale.Test.LiveComponent} id="probe" current_user={@current_user} />
    """
  end

  @impl true
  def handle_event("snapshot", _params, socket) do
    {:reply, LiveFixture.snapshot(socket.assigns.current_user), socket}
  end

  @impl true
  def handle_event("predicate_error", _params, socket) do
    allowed =
      AshTailscale.CapabilityCheck.match?(socket.assigns.current_user, %{},
        predicate: {LiveFixture, :fail_predicate, []}
      )

    {:reply, %{allowed: allowed}, socket}
  end

  @impl true
  def handle_event("write", _params, socket) do
    actor = socket.assigns.current_user

    result =
      with {:ok, report} <- Ash.create(Report, %{title: "one"}, actor: actor),
           {:ok, report} <- Ash.update(report, %{title: "two"}, actor: actor) do
        Ash.destroy(report, actor: actor)
      end

    {:reply, %{write: result == :ok}, socket}
  end
end

defmodule AshTailscale.Test.LiveFailureController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params), do: send_resp(conn, 401, "Unauthorized")
end

defmodule AshTailscale.Test.LiveRouter do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:poison_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(AshTailscale.Plug)
  end

  scope "/" do
    pipe_through(:browser)
    get("/failure", AshTailscale.Test.LiveFailureController, :index)

    live_session :test,
      session: {AshTailscale.Test.LiveFixture, :page_session, []},
      on_mount: [{AshTailscale.Test.LiveFixture, :stale}, {AshTailscale.LiveView, "/failure"}] do
      live("/", AshTailscale.Test.ProbeLive)
      live("/other", AshTailscale.Test.ProbeLive)
    end
  end

  defp poison_session(conn, _opts) do
    conn
    |> put_session(:current_user, "cookie-admin")
    |> put_session(:capabilities, %{"admin" => true})
  end
end

defmodule AshTailscale.Test.LiveEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :ash_tailscale
  use AshTailscale.LiveView.Endpoint
  alias AshTailscale.Test.LiveFixture

  socket("/live", AshTailscale.Example.Socket,
    websocket: [
      connect_info: [
        :peer_data,
        :x_headers,
        session: {AshTailscale.Test.LiveFixture, :session_options, []}
      ],
      check_csrf: true
    ],
    longpoll: false
  )

  plug(Plug.Session, LiveFixture.session_options())
  plug(AshTailscale.Test.LiveRouter)

  # A consumer override after `use` still runs INSIDE the final bridge wrapper.
  # remote_ip is deliberately forged: only actual adapter peer data may authorize.
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, opts), do: super(%{conn | remote_ip: {:local, "forged"}}, opts)
end

defmodule AshTailscale.Test.UnbridgedEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :ash_tailscale
  alias AshTailscale.Test.LiveFixture

  socket("/live", AshTailscale.Example.Socket,
    websocket: [
      connect_info: [
        :peer_data,
        :x_headers,
        session: {AshTailscale.Test.LiveFixture, :session_options, []}
      ]
    ],
    longpoll: false
  )

  plug(Plug.Session, LiveFixture.session_options())
  plug(AshTailscale.Test.LiveRouter)
end
