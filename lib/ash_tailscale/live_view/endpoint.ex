defmodule AshTailscale.LiveView.Endpoint do
  @moduledoc """
  Installs the required header bridge **before** Phoenix socket dispatch.

  Add `use AshTailscale.LiveView.Endpoint` after `use Phoenix.Endpoint`. Ordinary
  endpoint/router plugs run too late for WebSocket upgrades. This module uses
  Plug's `call/2` / `super` contract and has no compile-time LiveView dependency.

  The final wrapper strips all incoming `x-ash-tailscale-*` headers and copies
  only canonical Serve assertion headers from a real Unix connection. It does
  not authenticate, read cookies, or change the HTTP session/CSRF pipeline.

  The integration marker is a configuration invariant, not a signature. Do not
  override the generated wrapper/marker in a later before-compile callback or
  route socket requests around the endpoint. Trusted application code and a
  private Unix socket remain required. Use the matching socket and mount helpers
  in `AshTailscale.LiveView`; an internal header prefix alone is never authority.
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
        super(unquote(__MODULE__).bridge(conn), opts)
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

    copied =
      if unix_peer?(conn) do
        for {name, value} <- headers, name in @headers, do: {@prefix <> name, value}
      else
        []
      end

    %{conn | req_headers: copied ++ headers}
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
