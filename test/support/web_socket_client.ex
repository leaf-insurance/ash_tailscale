defmodule AshTailscale.Test.WebSocketClient do
  @moduledoc false
  # Small real HTTP/1 + RFC6455 test client. No browser, proxy or LiveViewTest shortcuts.
  import Bitwise

  @spec request(Path.t() | {:tcp, pos_integer()}, String.t(), list()) :: map()
  def request(address, target, headers), do: request(address, "GET", target, headers, "")

  @spec request(Path.t() | {:tcp, pos_integer()}, String.t(), String.t(), list(), String.t()) ::
          map()
  def request(address, method, target, headers, body) do
    socket = open(address)
    send_request(socket, target, [{"connection", "close"} | headers], method, body)
    response = response(socket)
    :gen_tcp.close(socket)
    response
  end

  @spec upgrade(Path.t() | {:tcp, pos_integer()}, String.t(), list()) :: {port(), map()}
  def upgrade(address, target, headers) do
    socket = open(address)
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    send_request(socket, target, [
      {"connection", "Upgrade"},
      {"upgrade", "websocket"},
      {"sec-websocket-version", "13"},
      {"sec-websocket-key", key} | headers
    ])

    response = response(socket)

    if response.status == 101 do
      expected =
        :sha |> :crypto.hash(key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

      ^expected = response.headers["sec-websocket-accept"]
    end

    :inet.setopts(socket, packet: :raw)
    {socket, response}
  end

  @spec send_message(port(), list()) :: :ok
  def send_message(socket, message), do: send_frame(socket, 1, Jason.encode!(message))

  @spec receive_message(port()) :: list()
  def receive_message(socket) do
    {:ok, <<1::1, 0::3, opcode::4, 0::1, size::7>>} = :gen_tcp.recv(socket, 2, 5000)
    payload = receive_payload(socket, frame_length(socket, size))

    case opcode do
      1 ->
        Jason.decode!(payload)

      9 ->
        :ok = send_frame(socket, 10, payload)
        receive_message(socket)
    end
  end

  @spec reply(port(), String.t()) :: map()
  def reply(socket, ref) do
    case receive_message(socket) do
      [_, ^ref, _, "phx_reply", payload] -> payload
      _ -> reply(socket, ref)
    end
  end

  defp frame_length(socket, 126) do
    {:ok, <<size::16>>} = :gen_tcp.recv(socket, 2, 5000)
    size
  end

  defp frame_length(socket, 127) do
    {:ok, <<size::64>>} = :gen_tcp.recv(socket, 8, 5000)
    size
  end

  defp frame_length(_socket, size), do: size

  defp receive_payload(_socket, 0), do: ""

  defp receive_payload(socket, size) do
    {:ok, payload} = :gen_tcp.recv(socket, size, 5000)
    payload
  end

  defp send_frame(socket, opcode, payload) do
    mask = :crypto.strong_rand_bytes(4)
    <<a, b, c, d>> = mask
    bytes = {a, b, c, d}

    masked =
      payload
      |> :binary.bin_to_list()
      |> Enum.with_index(fn byte, index -> bxor(byte, elem(bytes, rem(index, 4))) end)
      |> :binary.list_to_bin()

    length = byte_size(payload)
    size = if length < 126, do: <<1::1, length::7>>, else: <<1::1, 126::7, length::16>>
    :gen_tcp.send(socket, [<<1::1, 0::3, opcode::4>>, size, mask, masked])
  end

  defp open({:tcp, port}), do: connect({127, 0, 0, 1}, port)
  defp open(path), do: connect({:local, String.to_charlist(path)}, 0)

  defp connect(address, port) do
    {:ok, socket} = :gen_tcp.connect(address, port, [:binary, packet: :line, active: false], 5000)
    socket
  end

  defp send_request(socket, target, headers), do: send_request(socket, target, headers, "GET", "")

  defp send_request(socket, target, headers, method, body) do
    :ok =
      :gen_tcp.send(socket, [
        "#{method} #{target} HTTP/1.1\r\n",
        Enum.map(headers, fn {key, value} -> "#{key}: #{value}\r\n" end),
        "content-length: #{byte_size(body)}\r\n\r\n",
        body
      ])
  end

  defp response(socket) do
    {:ok, status_line} = :gen_tcp.recv(socket, 0, 5000)
    status = status_line |> String.split(" ") |> Enum.at(1) |> String.to_integer()
    headers = receive_headers(socket, %{})
    :inet.setopts(socket, packet: :raw)
    length = headers |> Map.get("content-length", "0") |> String.to_integer()
    body = receive_payload(socket, length)
    %{status: status, headers: headers, body: body}
  end

  defp receive_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, "\r\n"} ->
        headers

      {:ok, line} ->
        [key, value] = String.split(line, ":", parts: 2)
        receive_headers(socket, Map.put(headers, String.downcase(key), String.trim(value)))
    end
  end
end
