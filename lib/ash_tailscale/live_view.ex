defmodule AshTailscale.LiveView do
  @moduledoc """
  Authentication for router-mounted root LiveViews. Follow the
  [LiveView setup guide](live_view.html) for the required endpoint bridge, custom
  socket, matching transport connect info, HTTP plug and root mount hook.

  Pass `actor: socket.assigns.current_user` to every Ash operation. Components may
  receive the root actor explicitly; nested/sticky LiveViews are unsupported.
  Permissions belong to the initial logical transport, not each poll, rejoin or
  navigation. They may stay stale indefinitely; use fresh CSRF-protected HTTP when
  current grants are required. Reconnecting does not revoke old actors or work.

  Native longpoll tokens are bearer secrets: any holder reaching the service can
  resume the original actor without fresh identity/session authentication. Every
  entrypoint sharing signing keys/PubSub must enforce the Unix boundary or isolate
  that context. Keep normal Phoenix origin/CSRF checks; the mount hook does not
  replace the required socket callback.

  LiveView remains an optional package dependency; HTTP-only apps may omit it.
  """

  # Keep the module available without the optional web stack. When installed,
  # normal compiler checks still validate all remote calls against its API.
  unless Code.ensure_loaded?(Phoenix.LiveView) do
    @compile {:no_warn_undefined, [Phoenix.Component, Phoenix.LiveView]}
  end

  alias AshTailscale.LiveView.Endpoint

  @doc """
  Validates a consumer socket connection; returns `{:ok, socket}` or `:error`.

      def connect(_params, socket, info), do: AshTailscale.LiveView.connect(socket, info)

  The consumer uses `Phoenix.LiveView.Socket`, which preserves connect info for
  the mount helper. Runs on new WebSocket/longpoll transports, not resumed polls.
  No identity is stored in socket params or cookie sessions.
  """
  @spec connect(map(), map()) :: {:ok, map()} | :error
  def connect(%{endpoint: endpoint} = socket, %{session: session} = info) when is_map(session) do
    case actor(endpoint, info) do
      {:ok, _actor} -> {:ok, socket}
      :error -> :error
    end
  end

  def connect(_socket, _info), do: :error

  @doc """
  Replaces `current_user` from root mount connect info.

  Returns `{:ok, socket}` or `{:error, socket}` with `current_user` cleared on
  failure, including missing endpoint integration. Available only during root
  mount. Both disconnected and connected mounts independently validate the
  integration marker, actual peer and headers. The required consumer socket's
  `connect/3` callback must call `connect/2`, which requires Phoenix's validated
  session at logical transport creation. Mounts use only the documented
  peer/header connect-info accessors.
  Never falls back to existing assigns or session identity. Normally use
  `on_mount/4` instead.
  """
  @spec assign_actor(map()) :: {:ok, map()} | {:error, map()}
  def assign_actor(socket) do
    socket = Phoenix.Component.assign(socket, :current_user, nil)

    with true <- root?(socket),
         {:ok, actor} <- actor(socket.endpoint, mount_info(socket)) do
      {:ok, Phoenix.Component.assign(socket, :current_user, actor)}
    else
      _ -> {:error, socket}
    end
  end

  @doc """
  Required root mount hook. The hook argument is an application-chosen local
  HTTP failure path, e.g. `on_mount: [{AshTailscale.LiveView, "/"}]`.

  Run this hook after any other hook assigning `current_user`. Later hooks may
  read the actor, but no later identity/session loader may overwrite it.

  Transport session/CSRF is gated by `connect/2` through the required consumer
  socket's `connect/3` callback at logical transport creation, not this mount hook.
  Keep that callback and Phoenix's normal checks; this hook independently validates the
  integration marker, actual peer and assertions without rereading the session.

  Missing endpoint integration raises `ArgumentError`: a redirect cannot repair
  that configuration error. Invalid identity instead halts with an ordinary HTTP
  redirect (not live navigation). Choose a protected HTTP **controller** route,
  not another LiveView using this hook. `AshTailscale.Plug` returns generic 401 if
  the new HTTP request is unauthenticated. No login page or session identity is needed.
  """
  @spec on_mount(String.t(), map(), map(), map()) :: {:cont, map()} | {:halt, map()}
  def on_mount(failure_path, _params, _session, socket) when is_binary(failure_path) do
    unless Endpoint.installed?(socket.endpoint) do
      raise ArgumentError,
            "AshTailscale.LiveView requires `use AshTailscale.LiveView.Endpoint` " <>
              "after `use Phoenix.Endpoint` in #{inspect(socket.endpoint)}"
    end

    case assign_actor(socket) do
      {:ok, socket} -> {:cont, socket}
      {:error, socket} -> {:halt, Phoenix.LiveView.redirect(socket, to: failure_path)}
    end
  end

  defp root?(%{parent_pid: nil, sticky?: sticky, router: router}) when sticky in [nil, false],
    do: not is_nil(router)

  defp root?(_), do: false

  defp mount_info(socket) do
    %{
      peer_data: Phoenix.LiveView.get_connect_info(socket, :peer_data),
      x_headers: Phoenix.LiveView.get_connect_info(socket, :x_headers)
    }
  end

  defp actor(endpoint, %{peer_data: %{address: {:local, _}}, x_headers: headers})
       when is_list(headers) do
    with true <- Endpoint.installed?(endpoint),
         {:ok, actor} <- AshTailscale.from_headers(Endpoint.canonical_headers(headers)) do
      {:ok, actor}
    else
      _ -> :error
    end
  end

  defp actor(_endpoint, _info), do: :error
end
