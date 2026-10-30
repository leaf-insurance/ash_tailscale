defmodule AshTailscale.LiveView.Endpoint do
  @moduledoc """
  Installs the required header bridge **before** Phoenix socket dispatch.

  Add `use AshTailscale.LiveView.Endpoint` after `use Phoenix.Endpoint`. Ordinary
  endpoint/router plugs run too late for socket transports. This module uses
  Plug's `call/2` / `super` contract and has no compile-time LiveView dependency.

  The final wrapper strips all incoming `x-ash-tailscale-*` headers and copies
  only canonical Serve assertion headers from a real Unix connection. Non-Unix
  requests halt with generic HTTP 403 before dispatch, including longpoll token
  resumptions that do not run the socket connect callback. It does not authenticate
  identity, read cookies, or replace Phoenix's normal session/CSRF validation.

  The integration marker is a configuration invariant, not a signature. Do not
  override the generated wrapper/marker in a later before-compile callback or
  route socket requests around the endpoint. Every HTTP entrypoint capable of
  resuming the same longpoll signing/PubSub context must enforce this boundary
  (or be isolated): token resumption bypasses connect, and later mounts still use
  the original endpoint/connect info. An unbridged shared-context entrypoint is
  unsafe/unsupported. Trusted application code and a private Unix socket remain
  required. Use the matching socket and mount helpers in `AshTailscale.LiveView`;
  an internal header prefix alone is never authority.
  """

  @prefix "x-ash-tailscale-"
  @headers ~w(tailscale-user-login tailscale-user-name tailscale-user-profile-pic tailscale-app-capabilities)

  @doc "Installs the final pre-dispatch wrapper on a Phoenix endpoint."
  defmacro __using__([]) do
    quote do
      @before_compile unquote(__MODULE__)
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
      def call(conn, opts) do
        case unquote(__MODULE__).bridge(conn) do
          %{halted: true} = conn -> conn
          conn -> super(conn, opts)
        end
      end

      @doc false
      @spec __ash_tailscale_bridge__() :: true
      def __ash_tailscale_bridge__, do: true
    end
  end

  @doc false
  @spec bridge(Plug.Conn.t()) :: Plug.Conn.t()
  def bridge(conn) do
    headers =
      Enum.reject(conn.req_headers, fn {name, _} -> String.starts_with?(name, @prefix) end)

    conn = %{conn | req_headers: headers}

    if unix_peer?(conn) do
      copied = for {name, value} <- headers, name in @headers, do: {@prefix <> name, value}
      %{conn | req_headers: copied ++ headers}
    else
      conn |> Plug.Conn.send_resp(403, "Forbidden") |> Plug.Conn.halt()
    end
  end

  @doc false
  @spec installed?(module()) :: boolean()
  def installed?(endpoint) do
    is_atom(endpoint) and Code.ensure_loaded?(endpoint) and
      function_exported?(endpoint, :__ash_tailscale_bridge__, 0) and
      endpoint.__ash_tailscale_bridge__() == true
  end

  @doc false
  @spec canonical_headers(AshTailscale.headers()) :: AshTailscale.headers()
  def canonical_headers(headers) do
    for {@prefix <> name, value} <- headers, name in @headers, do: {name, value}
  end

  defp unix_peer?(conn) do
    match?(%{address: {:local, _}}, Plug.Conn.get_peer_data(conn))
  rescue
    _ -> false
  end
end
